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
            try camera.configure()
        } catch {
            state.error = "Camera setup failed: \(error)"
            return
        }
        refreshFromMainActor(promptForAccessibility: true)
        state.error = accessibilityOK ? nil
            : "Accessibility not granted. Cursor won't move until you allow Conductor in System Settings."
        camera.queue.async { [self] in recognizer.reset() }
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
        camera.queue.async { [self] in accessibilityOK = trusted }
        state.error = trusted ? nil
            : "Accessibility not granted. Cursor won't move until you allow Conductor in System Settings."
    }

    @MainActor
    func stop() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        camera.stop()
        camera.queue.async { [input] in input.releaseAll() }
        state.isRunning = false
        state.hands = []
        state.gestureLabel = "Paused"
    }

    /// Snapshots main-actor-owned values for the camera queue. Called on start and whenever
    /// preferences change.
    @MainActor
    func refreshFromMainActor(promptForAccessibility: Bool = false) {
        let snapshot = preferences.snapshot
        let layout = DisplayLayout.current()
        let bounds = layout.map(\.bounds)
        let resolved = CameraPlacement.resolve(snapshot.cameraPlacement, displays: layout,
                                               builtInCamera: CameraCapture.preferredDeviceIsBuiltIn)
        let trusted = Permissions.accessibilityGranted(prompt: promptForAccessibility)
        camera.queue.async { [self] in
            prefs = snapshot
            displays = bounds
            screen = Self.targetScreen(mode: snapshot.displayMode, displays: bounds, current: screen)
            if let resolved { cameraMount = (resolved.x, resolved.display.bounds) }
            relayoutBox()
            accessibilityOK = trusted
            if recognizer.map != snapshot.gestureMap {
                // Rebinding mid-gesture could orphan a held button, so let go and start clean.
                input.releaseAll()
                recognizer = GestureRecognizer(config: recognizer.config, map: snapshot.gestureMap)
            }
            filter = PointFilter(minCutoff: snapshot.smoothing, beta: Self.filterBeta)
            recognizer.config.pinchEngage = snapshot.pinchEngage
            recognizer.config.pinchRelease = snapshot.pinchRelease
            recognizer.config.mainHand = snapshot.mainHand
            recognizer.config.requireReadyPose = snapshot.requireReadyPose
            recognizer.config.dwellClick = snapshot.dwellClick
            recognizer.config.dwellTime = snapshot.dwellTime
        }
    }

    /// Recomputes the control box for the current target and camera. Camera queue only.
    private func relayoutBox() {
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

    /// Runs on the camera queue.
    private func process(_ buffer: CMSampleBuffer) {
        let now = CACurrentMediaTime()
        let hands = tracker.detect(in: buffer)
        frameTimes.append(now)
        frameTimes.removeAll { now - $0 > 1 }
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
            let target = DisplayLayout.snap(mapper.map(filter.filter(pointer, at: now)), to: displays)
            if accessibilityOK, target.distance(to: lastPosted) >= Self.minimumMovePixels {
                input.move(to: target)
                lastPosted = target
            }
        } else {
            filter.reset()
        }
        if accessibilityOK {
            for action in output.actions { perform(action) }
        }
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
            self.state.gestureLabel = label
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

    private func perform(_ action: GestureRecognizer.Action) {
        switch action {
        case .leftDown(let count): input.leftDown(clickCount: count)
        case .leftUp(let count): input.leftUp(clickCount: count)
        case .rightClick: input.rightClick()
        case .middleClick: input.middleClick()
        case .shortcut(let s): input.keyPress(CGKeyCode(s.keyCode), flags: s.flags)
        case .scroll(let dy):
            // Natural scrolling: hand up means content moves up, which is a negative wheel delta.
            let pixels = -dy * Self.scrollPixelsPerFrame * CGFloat(prefs.scrollGain)
            input.scroll(dy: Int32(pixels.rounded()))
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
