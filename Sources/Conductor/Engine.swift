import AVFoundation
import AppKit

/// Runs the camera -> tracker -> gesture -> input pipeline. One instance for the app's life.
///
/// Marked `@unchecked Sendable` because the mutable pipeline state is only ever touched on
/// `camera.queue`; main-actor code hands values over through `refreshFromMainActor`.
final class Engine: @unchecked Sendable {
    let camera = CameraCapture()
    let state: TrackingState
    let preferences: Preferences

    private let tracker = HandTracker()
    private let input = InputController()
    private var frameTimes: [CFTimeInterval] = []
    private var permissionTimer: Timer?

    // Pipeline state, touched only on the camera queue.
    private var filter = PointFilter()
    private var recognizer = GestureRecognizer()
    private var prefs: Preferences.Snapshot
    private var displays: [CGRect] = []
    private var screen: CGRect = .zero
    private var cameraMount: (x: CGFloat, display: CGRect) = (0, .zero)
    private var box = CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.5)
    private var wasIdle = true
    private var accessibilityOK = false
    private var zoomAccumulator: CGFloat = 0
    private var lastPosted = CGPoint(x: -1, y: -1)
    private var relative = RelativePointer()
    private var relativeCursor: CGPoint = .zero
    private var momentum = MomentumScroller()
    private var previousMode: GestureRecognizer.Mode = .idle
    private var quality = TrackingQuality()
    private var frameCount = 0
    private var lastHandTime: CFTimeInterval = 0
    private var calibrationEnd: CFTimeInterval?
    private var calibrationSamples: [CGPoint] = []
    private var onCalibrated: ((CGRect?) -> Void)?
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
        // Ask again here rather than read `accessibilityOK`: that's set on the camera queue and
        // isn't updated yet, which flashed a false "not granted" for the first two seconds.
        state.error = Permissions.accessibilityGranted(prompt: false) ? nil
            : "Accessibility not granted. Cursor won't move until you allow Conductor in System Settings."
        camera.queue.async { [self] in
            recognizer.reset()
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
        camera.queue.async { [self] in
            // Losing access mid-hold drops our release events; reset so held state can't go stale.
            if accessibilityOK, !trusted {
                input.releaseAll()
                recognizer.reset()
            }
            accessibilityOK = trusted
        }
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
            input.releaseAll()
            momentum.stop()
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
            input.releaseAll()
            momentum.stop()
            recognizer.reset()
            Task { @MainActor in self.state.gestureLabel = "Camera stopped sending frames" }
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
        let snapshot = preferences.snapshot
        let map = Preferences.effectiveMap(base: snapshot.gestureMap, profiles: snapshot.appProfiles,
                                           frontmost: frontmostBundleID)
        let layout = DisplayLayout.current()
        let bounds = layout.map(\.bounds)
        let resolved = CameraPlacement.resolve(snapshot.cameraPlacement, displays: layout,
                                               builtInCamera: CameraCapture.isBuiltIn(id: snapshot.cameraDeviceID))
        // No-op unless the camera is running and the choice actually changed (checked on its queue).
        camera.switchDevice(to: snapshot.cameraDeviceID)
        let trusted = Permissions.accessibilityGranted(prompt: promptForAccessibility)
        camera.queue.async { [self] in
            prefs = snapshot
            displays = bounds
            screen = Self.targetScreen(mode: snapshot.displayMode, displays: bounds, current: screen)
            if let resolved { cameraMount = (resolved.x, resolved.display.bounds) }
            relayoutBox()
            accessibilityOK = trusted
            // Rebinding mid-gesture could orphan a held button; replaceMap lets go of it.
            for action in recognizer.replaceMap(map) { perform(action) }
            filter = PointFilter(minCutoff: snapshot.smoothing, beta: Self.filterBeta)
            recognizer.config.pinchEngage = snapshot.pinchEngage
            recognizer.config.pinchRelease = snapshot.pinchRelease
            recognizer.config.mainHand = snapshot.mainHand
            recognizer.config.requireReadyPose = snapshot.requireReadyPose
            recognizer.config.dwellClick = snapshot.dwellClick
            recognizer.config.dwellTime = snapshot.dwellTime
            recognizer.config.dwellRadius = CGFloat(snapshot.dwellRadius)
            recognizer.config.pinchDeadZone = CGFloat(snapshot.pinchDeadZone)
            recognizer.config.mirrored = snapshot.mirrored
            relative.speed = CGFloat(snapshot.trackpadSpeed)
            relative.mirrored = snapshot.mirrored
            if !snapshot.momentumScroll { momentum.stop() }
        }
    }

    /// Starts the camera if needed, then records the hand for `Calibration.duration` seconds.
    /// No input is sent meanwhile. `completion` gets the measured box (Vision space) or nil.
    @MainActor
    func calibrate(completion: @escaping @MainActor (CGRect?) -> Void) async {
        if !state.isRunning { await start() }
        guard state.isRunning else { completion(nil); return }
        state.calibration = .running(secondsLeft: Int(Calibration.duration))
        let finish: (CGRect?) -> Void = { box in Task { @MainActor in completion(box) } }
        camera.queue.async { [self] in
            input.releaseAll()
            momentum.stop()
            calibrationSamples = []
            lastHandTime = CACurrentMediaTime() // full frame rate while calibrating
            calibrationEnd = CACurrentMediaTime() + Calibration.duration
            onCalibrated = finish
        }
    }

    /// One calibration frame. Returns true while calibrating, so the caller skips gesture handling.
    private func calibrationStep(hands: [HandPose], now: CFTimeInterval, fps: Double) -> Bool {
        guard let end = calibrationEnd else { return false }
        if let pointer = GestureRecognizer.primaryHand(hands, prefer: recognizer.config.mainHand)?.pointer {
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
        recognizer.reset()
        let done = onCalibrated
        onCalibrated = nil
        Task { @MainActor in
            self.state.calibration = result == nil ? .failed : .finished
            self.state.gestureLabel = result == nil ? "Calibration didn't see enough movement" : "Calibrated"
        }
        done?(result)
        return true
    }

    /// Recomputes the control box for the current target and camera. Camera queue only.
    private func relayoutBox() {
        if let calibrated = prefs.calibratedBox {
            // Stored in Vision space so it survives a change to the mirror setting.
            box = ScreenMapper.visionRect(forViewBox: calibrated, mirrored: prefs.mirrored)
            let published = box
            Task { @MainActor in self.state.controlBox = published }
            return
        }
        box = ControlBox.layout(ControlBox.Input(
            width: prefs.boxWidth, height: prefs.boxHeight, offsetY: prefs.boxOffsetY,
            matchShape: prefs.matchScreenShape, target: screen,
            cameraX: cameraMount.x, cameraDisplay: cameraMount.display))
        let published = box
        Task { @MainActor in self.state.controlBox = published }
    }

    /// Which rectangle the control box maps onto. `current` is kept in follow-cursor mode until the
    /// hand is lost and found again, so the target doesn't hop mid-gesture.
    static func targetScreen(mode: Preferences.DisplayMode, displays: [CGRect], current: CGRect,
                             cursor: CGPoint? = nil) -> CGRect {
        guard !displays.isEmpty else { return current }
        switch mode {
        case .all:
            return displays.dropFirst().reduce(displays[0]) { $0.union($1) }
        case .main:
            return displays.first { $0.origin == .zero } ?? displays[0]
        case .followCursor:
            guard let cursor else { return displays.contains(current) ? current : displays[0] }
            return displays.first { $0.contains(cursor) } ?? displays[0]
        }
    }

    /// Power saving: after this long with no hand, analyze only every `idleStride`th frame.
    private static let idleAfter: CFTimeInterval = 60
    private static let idleStride = 6

    /// Runs on the camera queue.
    private func process(_ buffer: CMSampleBuffer) {
        let now = CACurrentMediaTime()
        lastFrameTime = now
        frameCount += 1
        let idle = prefs.powerSaving && lastHandTime > 0 && now - lastHandTime > Self.idleAfter
        if idle, frameCount % Self.idleStride != 0 { return }

        if frameCount % 15 == 0, let pixels = CMSampleBufferGetImageBuffer(buffer),
           let luma = TrackingQuality.meanLuma(of: pixels) {
            quality.addBrightness(luma)
        }
        let hands = tracker.detect(in: buffer)
        if lastHandTime == 0 || !hands.isEmpty { lastHandTime = now }
        if let primary = GestureRecognizer.primaryHand(hands, prefer: recognizer.config.mainHand) {
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

        // On reacquiring the hand, follow-cursor mode re-targets the display the cursor is on.
        if !hands.isEmpty, wasIdle, prefs.displayMode == .followCursor, displays.count > 1 {
            let cursor = CGEvent(source: nil)?.location
            let next = Self.targetScreen(mode: .followCursor, displays: displays, current: screen, cursor: cursor)
            if next != screen {
                screen = next
                relayoutBox()
            }
        }
        let output = recognizer.update(hands: hands, at: now)
        wasIdle = output.mode == .idle
        let mapper = ScreenMapper(box: box, mirrored: prefs.mirrored, screen: screen)
        if let pointer = output.pointer {
            // Filter in normalized frame space, not pixels. The speed term in One Euro is tuned for
            // units where a fast hand moves about 1.0 per second; in pixels even tremor is hundreds
            // per second and the filter opens all the way up, which is exactly the jitter it exists
            // to remove.
            let smoothed = filter.filter(pointer, at: now)
            let target: CGPoint
            if prefs.pointerMode == .relative {
                if let delta = relative.delta(for: smoothed, at: now, screenWidth: screen.width) {
                    relativeCursor.x += delta.dx
                    relativeCursor.y += delta.dy
                } else {
                    // First frame after the hand (re)appears: start from wherever the cursor is.
                    relativeCursor = CGEvent(source: nil)?.location ?? relativeCursor
                }
                relativeCursor = DisplayLayout.snap(relativeCursor, to: displays)
                target = relativeCursor
            } else {
                target = DisplayLayout.snap(mapper.map(smoothed), to: displays)
            }
            if accessibilityOK, target.distance(to: lastPosted) >= Self.minimumMovePixels {
                input.move(to: target)
                lastPosted = target
            }
        } else {
            filter.reset()
            relative.reset()
        }
        if accessibilityOK {
            for action in output.actions { perform(action) }
            coast(after: output)
        }
        previousMode = output.mode
        let label = output.label
        let clicked = accessibilityOK && output.actions.contains {
            switch $0 {
            case .leftDown, .rightClick, .middleClick: return true
            default: return false
            }
        }

        Task { @MainActor in
            self.state.hands = hands
            self.state.fps = fps
            self.state.gestureLabel = idle ? "Idle: checking for your hand a few times a second" : label
            if self.state.warning != warning { self.state.warning = warning }
            if self.state.idle != idle { self.state.idle = idle }
            if self.state.mode != output.mode { self.state.mode = output.mode }
            if self.state.feedback != output.feedback { self.state.feedback = output.feedback }
            if clicked { self.state.clicks.send() }
            for event in output.events { self.state.events.send(event) }
        }
    }

    /// Speed coefficient for the One Euro filter in normalized units. At 8, a hand crossing the
    /// frame in a second raises the cutoff by about 8 Hz; resting tremor (~0.1/s) adds under 1 Hz.
    private static let filterBeta = 8.0
    /// Don't post moves smaller than this. Sub-pixel updates at 30 fps read as shimmer.
    private static let minimumMovePixels: CGFloat = 2

    /// Full-frame palm travel of 1.0 would scroll this many pixels. Tuned so a relaxed 10 cm hand
    /// move scrolls about a screen's worth.
    private static let scrollPixelsPerFrame: CGFloat = 4000
    private static let zoomPixelsPerFrame: CGFloat = 1500
    /// Hands must spread or close this far (normalized) to fire one cmd+= / cmd+- press.
    private static let zoomKeyStep: CGFloat = 0.04

    /// Momentum scrolling: when a scroll ends mid-flick, keep scrolling and slow down. Any click or
    /// new gesture stops it.
    private func coast(after output: GestureRecognizer.Output) {
        let interrupted = output.actions.contains {
            switch $0 {
            case .leftDown, .rightClick, .middleClick, .shortcut, .zoom: return true
            default: return false
            }
        }
        if interrupted || output.mode == .drag || output.mode == .zoom {
            momentum.stop()
            return
        }
        if previousMode == .scroll, output.mode != .scroll, prefs.momentumScroll {
            momentum.released()
        }
        if output.mode != .scroll, let step = momentum.tick() {
            input.scroll(dy: Int32(step.rounded()))
        }
    }

    private func perform(_ action: GestureRecognizer.Action) {
        switch action {
        case .leftDown(let count): input.leftDown(clickCount: count)
        case .leftUp(let count): input.leftUp(clickCount: count)
        case .rightClick: input.rightClick()
        case .middleClick: input.middleClick()
        case .shortcut(let s): input.keyPress(CGKeyCode(s.keyCode), flags: s.flags)
        case .keyDown(let s): input.keyDown(s)
        case .keyUp(let s): input.keyUp(s)
        case .scroll(let dy):
            // Natural scrolling: hand up means content moves up, which is a negative wheel delta.
            let pixels = -dy * Self.scrollPixelsPerFrame * CGFloat(prefs.scrollGain)
            input.scroll(dy: Int32(pixels.rounded()))
            momentum.scrolled(pixels)
        case .zoom(let delta):
            if prefs.zoomWithKeys {
                zoomAccumulator += delta
                while zoomAccumulator >= Self.zoomKeyStep {
                    input.keyPress(KeyCodes.equals, flags: .maskCommand)
                    zoomAccumulator -= Self.zoomKeyStep
                }
                while zoomAccumulator <= -Self.zoomKeyStep {
                    input.keyPress(KeyCodes.minus, flags: .maskCommand)
                    zoomAccumulator += Self.zoomKeyStep
                }
            } else {
                // Cmd+scroll zooms in browsers, Preview, Maps and most editors. Spreading the hands
                // is a positive delta, and scrolling up (positive wheel) zooms in.
                input.scroll(dy: Int32((delta * Self.zoomPixelsPerFrame).rounded()), flags: .maskCommand)
            }
        }
    }
}
