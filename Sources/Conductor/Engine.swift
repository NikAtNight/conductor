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
    private let faceTracker = FaceTracker()
    private let input = InputController()
    /// Moves the cursor between the pipeline's targets at `CursorGlide.rate`; see aim.
    private var glide = CursorGlide()
    private var glideTimer: DispatchSourceTimer?
    private var frameTimes: [CFTimeInterval] = []
    private var permissionTimer: Timer?

    // Touched only on the camera queue.
    private var pipeline: FramePipeline
    private var prefs: Settings
    private var gestureLog: GestureLog?
    private var quality = TrackingQuality()
    private var frameCount = 0
    private var lastHandTime: CFTimeInterval = 0
    private var calibrationEnd: CFTimeInterval?
    private var calibrationSamples: [CGPoint] = []
    private var onCalibrated: ((CGRect?) -> Void)?
    /// Set while a calibration takes the frames instead of the recognizer; see startSampling.
    private var sampling: (handler: @MainActor ([HandPose], FacePose?) -> Void, wantsFace: Bool, label: String)?
    private var publishedBox: CGRect?
    /// The connected displays, for naming the one the control box targets.
    private var displayLayout: [DisplayInfo] = []
    private var publishedTargetName: String?
    /// The last face seen, kept across the frames look mode skips so the preview doesn't flicker.
    private var lastFace: FacePose?
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
        prefs = preferences.settings
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
            try camera.configure(deviceID: preferences.settings.cameraDeviceID)
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
            stopGlide()
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
            stopGlide()
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
        publishedBox = nil // undo the live preview
        publishBox()
        let done = onCalibrated
        onCalibrated = nil
        done?(nil)
    }

    /// Snapshots main-actor-owned values for the camera queue. Called on start and whenever
    /// preferences change.
    @MainActor
    func refreshFromMainActor(promptForAccessibility: Bool = false) {
        let started = CACurrentMediaTime()
        let snapshot = preferences.settings
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
            displayLayout = layout
            post(pipeline.apply(snapshot, map: map, displays: bounds,
                                cameraMount: resolved.map { ($0.x, $0.display.bounds) },
                                lookDisplays: Dictionary(uniqueKeysWithValues: layout.map { ($0.uuid, $0.bounds) })))
            post(pipeline.setInputAllowed(trusted))
            publishBox()
            publishTargetDisplay()
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

    /// Look calibration: starts the camera if needed, then hands every frame's face (or nil when
    /// none is seen) to `handler` on the main actor until `stopSampling`. Hands are shown in the
    /// preview but not acted on meanwhile. Returns false if the camera couldn't start.
    @MainActor
    func startLookSampling(_ handler: @escaping @MainActor (FacePose?) -> Void) async -> Bool {
        await startSampling(label: "Calibrating look", face: true) { _, face in handler(face) }
    }

    /// The gesture check: like look sampling, but hands every frame's hands to `handler` and
    /// leaves the face alone.
    @MainActor
    func startHandSampling(_ handler: @escaping @MainActor ([HandPose]) -> Void) async -> Bool {
        await startSampling(label: "Checking gestures", face: false) { hands, _ in handler(hands) }
    }

    @MainActor
    private func startSampling(label: String, face: Bool,
                               _ handler: @escaping @MainActor ([HandPose], FacePose?) -> Void) async -> Bool {
        if !state.isRunning { await start() }
        guard state.isRunning else { return false }
        camera.queue.async { [self] in
            post(pipeline.releaseHeld())
            lastHandTime = CACurrentMediaTime() // full frame rate while sampling
            sampling = (handler, face, label)
        }
        return true
    }

    @MainActor
    func stopSampling() {
        camera.queue.async { [self] in
            sampling = nil
            pipeline.reset()
        }
    }

    /// Writes a note to the gesture log, if it's recording. Look calibration marks each dot with
    /// one, so a log can be split into the samples for each display afterwards.
    @MainActor
    func logNote(_ text: String) {
        camera.queue.async { [self] in gestureLog?.note(text) }
    }

    /// One sampling frame. Returns true while sampling, so the caller skips gesture handling.
    /// Logged like any other frame, so a calibration that goes wrong can be read back.
    private func samplingStep(_ buffer: CMSampleBuffer, hands: [HandPose], primary: HandPose?, fps: Double,
                              now: CFTimeInterval, sinceLastMs: Double?, detectMs: Double) -> Bool {
        guard let sampling else { return false }
        var face: FacePose?
        var faceMs: Double?
        if sampling.wantsFace {
            let faceStart = CACurrentMediaTime()
            face = faceTracker.detect(in: buffer)
            faceMs = (CACurrentMediaTime() - faceStart) * 1000
        }
        gestureLog?.write(time: Date(), fps: fps, hands: hands, primary: primary, face: face,
                          output: GestureRecognizer.Output(mode: .idle, pointer: nil, actions: [], label: sampling.label),
                          cursor: nil, sinceLastMs: sinceLastMs, detectMs: detectMs, faceMs: faceMs,
                          processMs: (CACurrentMediaTime() - now) * 1000)
        Task { @MainActor in
            self.state.hands = hands
            if sampling.wantsFace { self.state.face = face }
            self.state.fps = fps
            self.state.gestureLabel = sampling.label
            sampling.handler(hands, face)
        }
        return true
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
            // Stretch the green box over what's been traced so far, so you see what's measured.
            let traced = calibrationSamples.count >= Calibration.minimumSamples
                ? Calibration.extent(of: calibrationSamples).map { ScreenMapper.visionRect(forViewBox: $0, mirrored: prefs.mirrored) }
                : nil
            Task { @MainActor in
                self.state.hands = hands
                self.state.fps = fps
                self.state.gestureLabel = "Calibrating: move your whole hand around the edge of your comfortable reach, \(seconds)s"
                self.state.calibration = .running(secondsLeft: seconds)
                if let traced { self.state.controlBox = traced }
            }
            return true
        }
        calibrationEnd = nil
        let result = Calibration.box(from: calibrationSamples)
        let traced = Calibration.extent(of: calibrationSamples) ?? .zero
        gestureLog?.note(String(format: "calibration: %d samples, traced %.3f x %.3f, %@", calibrationSamples.count,
                                traced.width, traced.height, result == nil ? "rejected" : "saved"))
        calibrationSamples = []
        pipeline.reset()
        // The live preview overwrote the published box. A saved box is published by the refresh the
        // preference change triggers; a rejected one puts the old box back now.
        publishedBox = nil
        if result == nil { publishBox() }
        let done = onCalibrated
        onCalibrated = nil
        Task { @MainActor in
            self.state.calibration = result == nil ? .failed : .finished
            self.state.gestureLabel = result == nil
                ? "Calibration saw too small an area. Move your whole hand, not just your fingers."
                : "Calibrated"
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

    /// Camera queue. Publishes the name of the display the control box maps onto when it changes,
    /// in the modes where it can change. Nil elsewhere so the UI shows nothing.
    private func publishTargetDisplay() {
        var name: String?
        if prefs.displayMode == .lookedAt || prefs.displayMode == .followCursor {
            let screen = pipeline.screen
            name = displayLayout.first { $0.bounds == screen }?.name
        }
        guard name != publishedTargetName else { return }
        publishedTargetName = name
        Task { @MainActor in self.state.targetDisplayName = name }
    }

    /// Camera queue. Hands the pipeline's commands to the input adapter, in order.
    private func post(_ commands: [InputCommand]) {
        for command in commands {
            switch command {
            case .move(let point): aim(point)
            case .leftDown(let count):
                // The button goes down where the cursor is now. Gliding on to the last target
                // with the button held would be a drag.
                stopGlide()
                input.leftDown(clickCount: count)
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

    /// Camera queue. The pipeline aims the cursor once per camera frame; the cursor gets there over
    /// the frame that follows, a tick at a time, so motion reads as motion and not as 30 hops a
    /// second. The glide starts from wherever the cursor really is, which also covers the mouse
    /// having been touched meanwhile. A button going down stops the glide (see post), and the
    /// pipeline holds the cursor while the click dead zone lasts, so a click doesn't drag.
    private func aim(_ target: CGPoint) {
        let current = CGEvent(source: nil)?.location ?? input.location
        glide.aim(at: target, from: current, at: CACurrentMediaTime())
        guard glideTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: camera.queue)
        timer.schedule(deadline: .now() + 1 / CursorGlide.rate, repeating: 1 / CursorGlide.rate, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if let point = glide.position(at: CACurrentMediaTime()) { input.move(to: point) }
            // The timer only runs while there's ground to cover, so an idle hand costs no wakeups.
            if !glide.isGliding { stopGlide() }
        }
        timer.resume()
        glideTimer = timer
    }

    /// Camera queue. Ends a glide in progress; the cursor stays where it is.
    private func stopGlide() {
        glide.stop()
        glideTimer?.cancel()
        glideTimer = nil
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
        if samplingStep(buffer, hands: hands, primary: primary, fps: Double(frameTimes.count), now: now,
                        sinceLastMs: sinceLast.map { $0 * 1000 }, detectMs: detectMs) { return }
        let fps = Double(frameTimes.count)

        // The face feeds the log and, in look mode, the display pick. Look mode alone detects it on
        // every other frame to save CPU; the picker's dwell makes a frame's delay invisible.
        let looking = prefs.displayMode == .lookedAt
        let wantsFace = gestureLog != nil || looking
        var face: FacePose?
        var faceMs: Double = 0
        if wantsFace, gestureLog != nil || frameCount % 2 == 0 {
            let faceStart = CACurrentMediaTime()
            face = faceTracker.detect(in: buffer)
            faceMs = (CACurrentMediaTime() - faceStart) * 1000
            lastFace = face
        } else if looking {
            face = lastFace
        } else {
            lastFace = nil
        }

        let frame = pipeline.step(hands: hands, face: face, at: now) { CGEvent(source: nil)?.location }
        post(frame.commands)
        publishBox()
        publishTargetDisplay()
        if let gestureLog {
            gestureLog.write(time: Date(), fps: fps, hands: hands, primary: primary, face: face,
                             output: frame.recognized, cursor: frame.cursor, sinceLastMs: sinceLast.map { $0 * 1000 },
                             detectMs: detectMs, faceMs: faceMs, processMs: (CACurrentMediaTime() - now) * 1000)
        }
        let recognized = frame.recognized
        let clicked = frame.commands.contains(where: \.isClick)

        Task { @MainActor in
            self.state.hands = hands
            self.state.face = face
            self.state.fps = fps
            self.state.gestureLabel = idle ? "Idle: checking for your hand a few times a second" : recognized.label
            if self.state.warning != warning { self.state.warning = warning }
            if self.state.idle != idle { self.state.idle = idle }
            if self.state.mode != recognized.mode { self.state.mode = recognized.mode }
            if self.state.feedback != recognized.feedback { self.state.feedback = recognized.feedback }
            if self.state.activeTrigger != recognized.trigger { self.state.activeTrigger = recognized.trigger }
            if clicked { self.state.clicks.send() }
            for event in recognized.events { self.state.events.send(event) }
        }
    }
}
