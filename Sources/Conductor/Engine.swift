import AVFoundation
import AppKit

/// Runs the camera -> tracker -> pipeline -> input loop. One instance for the app's life.
///
/// The per-frame decisions live in FramePipeline. Engine owns what that can't: the camera queue,
/// Vision, the clock, the stall watchdog, calibration, the gesture log, posting input, and
/// publishing to TrackingState. Marked `@unchecked Sendable` because the mutable state is only
/// ever touched on `camera.queue`; main-actor code hands values over through `refreshFromMainActor`.
final class Engine: @unchecked Sendable {
    let camera = CameraCapture()
    let state: TrackingState
    let preferences: Preferences

    private let tracker = HandTracker()
    private let input = InputController()
    private var frameTimes: [CFTimeInterval] = []
    private var permissionTimer: Timer?

    // Touched only on the camera queue.
    private var pipeline: FramePipeline
    private var prefs: Preferences.Snapshot
    private var gestureLog: GestureLog?
    private var quality = TrackingQuality()
    private var frameCount = 0
    private var lastHandTime: CFTimeInterval = 0
    private var calibrationEnd: CFTimeInterval?
    private var calibrationSamples: [CGPoint] = []
    private var onCalibrated: ((CGRect?) -> Void)?
    private var publishedBox: CGRect?
    /// When the last camera frame arrived, for the stalled-camera watchdog.
    private var lastFrameTime: CFTimeInterval = 0
    private var watchdog: DispatchSourceTimer?
    /// If no frame arrives for this long while running, let go of everything.
    private static let stallAfter: CFTimeInterval = 1.0

    /// Bundle ID of the frontmost app, for per-app gesture profiles. Main actor.
    @MainActor var frontmostBundleID: String?

    @MainActor
    init(state: TrackingState, preferences: Preferences) {
        self.state = state
        self.preferences = preferences
        prefs = preferences.snapshot
        pipeline = FramePipeline(prefs)
        camera.onFrame = { [weak self] buffer in self?.process(buffer) }
    }

    @MainActor
    func start() async {
        guard await CameraCapture.requestAccess() else {
            state.error = "Camera access denied. Enable it in System Settings > Privacy & Security > Camera."
            return
        }
        do {
            try camera.configure(deviceID: preferences.cameraDeviceID)
        } catch {
            state.error = "Camera setup failed: \(error)"
            return
        }
        refreshFromMainActor(promptForAccessibility: true)
        // Ask again here rather than read the pipeline's flag: that's set on the camera queue and
        // isn't updated yet, which flashed a false "not granted" for the first two seconds.
        state.error = Permissions.accessibilityGranted(prompt: false) ? nil
            : "Accessibility not granted. Cursor won't move until you allow Conductor in System Settings."
        camera.queue.async { [self] in
            pipeline.reset()
            lastFrameTime = CACurrentMediaTime()
            startWatchdog()
        }
        camera.start()
        state.isRunning = true
        // The grant can be flipped in System Settings while we run, and AXIsProcessTrusted picks it
        // up live. Poll so the user doesn't have to pause and restart to make the cursor move.
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.recheckAccessibility() }
        }
    }

    @MainActor
    private func recheckAccessibility() {
        let trusted = Permissions.accessibilityGranted(prompt: false)
        camera.queue.async { [self] in post(pipeline.setInputAllowed(trusted)) }
        state.error = trusted ? nil
            : "Accessibility not granted. Cursor won't move until you allow Conductor in System Settings."
    }

    @MainActor
    func stop() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        camera.stop()
        camera.queue.async { [self] in
            watchdog?.cancel()
            watchdog = nil
            post(pipeline.releaseHeld())
            cancelCalibration()
        }
        if case .running = state.calibration { state.calibration = .none }
        state.isRunning = false
        state.hands = []
        state.gestureLabel = "Paused"
    }

    /// Quitting: let go of every button and key before the process exits. Synchronous on purpose;
    /// an async release would be queued behind the session teardown and never run.
    @MainActor
    func shutdown() {
        camera.queue.sync {
            watchdog?.cancel()
            input.releaseAll()
        }
        camera.stop()
    }

    /// Camera queue. Catches a camera that stops delivering frames (unplugged, Continuity Camera
    /// walking away, a session error): frame-driven release logic can't run without frames.
    private func startWatchdog() {
        watchdog?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: camera.queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            guard let self, CACurrentMediaTime() - lastFrameTime > Self.stallAfter else { return }
            // Let go of held input, but keep control: a stall isn't the user's doing. A calibration
            // can't finish without frames, so it ends here rather than hang at "running".
            post(pipeline.releaseHeld())
            let calibrating = calibrationEnd != nil
            cancelCalibration()
            gestureLog?.note("watchdog: no camera frame for \(Int((CACurrentMediaTime() - lastFrameTime) * 1000)) ms, released held input")
            Task { @MainActor in
                self.state.gestureLabel = "Camera stopped sending frames"
                if calibrating { self.state.calibration = .failed }
            }
        }
        timer.resume()
        watchdog = timer
    }

    /// Camera queue. Abandons a calibration in progress and tells the caller it failed.
    private func cancelCalibration() {
        guard calibrationEnd != nil else { return }
        calibrationEnd = nil
        calibrationSamples = []
        let done = onCalibrated
        onCalibrated = nil
        done?(nil)
    }

    /// Snapshots main-actor-owned values for the camera queue. Called on start and whenever
    /// preferences change.
    @MainActor
    func refreshFromMainActor(promptForAccessibility: Bool = false) {
        let started = CACurrentMediaTime()
        let snapshot = preferences.snapshot
        let map = Preferences.effectiveMap(base: snapshot.gestureMap, profiles: snapshot.appProfiles,
                                           frontmost: frontmostBundleID)
        let layout = DisplayLayout.current()
        let bounds = layout.map(\.bounds)
        // Device discovery can take a while, so it happens here and not on the queue frames use.
        let device = CameraCapture.preferredDevice(id: snapshot.cameraDeviceID)
        let resolved = CameraPlacement.resolve(snapshot.cameraPlacement, displays: layout,
                                               builtInCamera: device?.deviceType == .builtInWideAngleCamera)
        // No-op unless the camera is running and the choice actually changed (checked on its queue).
        camera.switchDevice(to: device)
        let trusted = Permissions.accessibilityGranted(prompt: promptForAccessibility)
        let mainMs = (CACurrentMediaTime() - started) * 1000
        camera.queue.async { [self] in
            prefs = snapshot
            post(pipeline.apply(snapshot, map: map, displays: bounds,
                                cameraMount: resolved.map { ($0.x, $0.display.bounds) }))
            post(pipeline.setInputAllowed(trusted))
            publishBox()
            if !snapshot.recordGestureLog {
                gestureLog = nil
            } else if gestureLog == nil {
                do {
                    gestureLog = try GestureLog()
                } catch {
                    NSLog("Conductor: can't start the gesture log: \(error)")
                }
            }
            gestureLog?.note("refresh: \(Int(mainMs)) ms on the main thread")
        }
    }

    /// Starts the camera if needed, then records the hand for `Calibration.duration` seconds.
    /// No input is sent meanwhile. `completion` gets the measured box (Vision space) or nil.
    @MainActor
    func calibrate(completion: @escaping @MainActor (CGRect?) -> Void) async {
        if !state.isRunning { await start() }
        guard state.isRunning else { completion(nil); return }
        // A second press while one runs would orphan the first completion.
        if case .running = state.calibration { completion(nil); return }
        state.calibration = .running(secondsLeft: Int(Calibration.duration))
        let finish: (CGRect?) -> Void = { box in Task { @MainActor in completion(box) } }
        camera.queue.async { [self] in
            post(pipeline.releaseHeld())
            calibrationSamples = []
            lastHandTime = CACurrentMediaTime() // full frame rate while calibrating
            calibrationEnd = CACurrentMediaTime() + Calibration.duration
            onCalibrated = finish
        }
    }

    /// One calibration frame. Returns true while calibrating, so the caller skips gesture handling.
    private func calibrationStep(hands: [HandPose], now: CFTimeInterval, fps: Double) -> Bool {
        guard let end = calibrationEnd else { return false }
        if let pointer = GestureRecognizer.primaryHand(hands, prefer: prefs.mainHand)?.pointer {
            calibrationSamples.append(pointer)
        }
        let left = end - now
        if left > 0 {
            let seconds = Int(left.rounded(.up))
            Task { @MainActor in
                self.state.hands = hands
                self.state.fps = fps
                self.state.gestureLabel = "Calibrating: trace the edge of your comfortable reach, \(seconds)s"
                self.state.calibration = .running(secondsLeft: seconds)
            }
            return true
        }
        calibrationEnd = nil
        let result = Calibration.box(from: calibrationSamples)
        calibrationSamples = []
        pipeline.reset()
        let done = onCalibrated
        onCalibrated = nil
        Task { @MainActor in
            self.state.calibration = result == nil ? .failed : .finished
            self.state.gestureLabel = result == nil ? "Calibration didn't see enough movement" : "Calibrated"
        }
        done?(result)
        return true
    }

    /// Camera queue. Publishes the control box when it changes.
    private func publishBox() {
        let box = pipeline.box
        guard box != publishedBox else { return }
        publishedBox = box
        Task { @MainActor in self.state.controlBox = box }
    }

    /// Camera queue. Hands the pipeline's commands to the input adapter, in order.
    private func post(_ commands: [InputCommand]) {
        for command in commands {
            switch command {
            case .move(let point): input.move(to: point)
            case .leftDown(let count): input.leftDown(clickCount: count)
            case .leftUp(let count): input.leftUp(clickCount: count)
            case .rightClick: input.rightClick()
            case .middleClick: input.middleClick()
            case .keyPress(let key, let flags): input.keyPress(key, flags: flags)
            case .keyDown(let key): input.keyDown(key)
            case .keyUp(let key): input.keyUp(key)
            case .scroll(let dy, let flags): input.scroll(dy: dy, flags: flags)
            case .releaseAll: input.releaseAll()
            }
        }
    }

    /// Power saving: after this long with no hand, analyze only every `idleStride`th frame.
    private static let idleAfter: CFTimeInterval = 60
    private static let idleStride = 6

    /// Runs on the camera queue.
    private func process(_ buffer: CMSampleBuffer) {
        let now = CACurrentMediaTime()
        let sinceLast = lastFrameTime > 0 ? now - lastFrameTime : nil
        lastFrameTime = now
        frameCount += 1
        let idle = prefs.powerSaving && lastHandTime > 0 && now - lastHandTime > Self.idleAfter
        if idle, frameCount % Self.idleStride != 0 { return }

        if frameCount % 15 == 0, let pixels = CMSampleBufferGetImageBuffer(buffer),
           let luma = TrackingQuality.meanLuma(of: pixels) {
            quality.addBrightness(luma)
        }
        let detectStart = CACurrentMediaTime()
        let hands = tracker.detect(in: buffer)
        let detectMs = (CACurrentMediaTime() - detectStart) * 1000
        if lastHandTime == 0 || !hands.isEmpty { lastHandTime = now }
        let primary = GestureRecognizer.primaryHand(hands, prefer: prefs.mainHand)
        if let primary {
            let values = primary.confidence.values
            if !values.isEmpty { quality.addConfidence(Double(values.reduce(0, +)) / Double(values.count)) }
        } else {
            quality.handLost()
        }
        let warning = quality.warning
        frameTimes.append(now)
        frameTimes.removeAll { now - $0 > 1 }
        if calibrationStep(hands: hands, now: now, fps: Double(frameTimes.count)) { return }
        let fps = Double(frameTimes.count)

        let frame = pipeline.step(hands: hands, at: now) { CGEvent(source: nil)?.location }
        post(frame.commands)
        publishBox()
        gestureLog?.write(time: Date(), fps: fps, hands: hands, primary: primary,
                          output: frame.recognized, cursor: frame.cursor, sinceLastMs: sinceLast.map { $0 * 1000 },
                          detectMs: detectMs, processMs: (CACurrentMediaTime() - now) * 1000)
        let recognized = frame.recognized
        let clicked = frame.commands.contains(where: \.isClick)

        Task { @MainActor in
            self.state.hands = hands
            self.state.fps = fps
            self.state.gestureLabel = idle ? "Idle: checking for your hand a few times a second" : recognized.label
            if self.state.warning != warning { self.state.warning = warning }
            if self.state.idle != idle { self.state.idle = idle }
            if self.state.mode != recognized.mode { self.state.mode = recognized.mode }
            if self.state.feedback != recognized.feedback { self.state.feedback = recognized.feedback }
            if clicked { self.state.clicks.send() }
            for event in recognized.events { self.state.events.send(event) }
        }
    }
}
