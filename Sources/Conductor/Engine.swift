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

    // Pipeline state, touched only on the camera queue.
    private var filter = PointFilter()
    private var recognizer = GestureRecognizer()
    private var prefs: Preferences.Snapshot
    private var screen: CGRect = .zero
    private var accessibilityOK = false
    private var zoomAccumulator: CGFloat = 0

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
        refreshFromMainActor()
        state.error = accessibilityOK ? nil
            : "Accessibility not granted. Cursor won't move until you allow Conductor in System Settings."
        camera.start()
        state.isRunning = true
    }

    @MainActor
    func stop() {
        camera.stop()
        camera.queue.async { [input] in input.releaseAll() }
        state.isRunning = false
        state.hands = []
        state.gestureLabel = "Paused"
    }

    /// Snapshots main-actor-owned values for the camera queue. Called on start and whenever
    /// preferences change.
    @MainActor
    func refreshFromMainActor() {
        let snapshot = preferences.snapshot
        let screenFrame = Self.cgScreenBounds()
        let trusted = Permissions.accessibilityGranted(prompt: !accessibilityOK)
        camera.queue.async { [self] in
            prefs = snapshot
            screen = screenFrame
            accessibilityOK = trusted
            filter = PointFilter(minCutoff: snapshot.smoothing, beta: 0.4)
            recognizer.config.pinchEngage = snapshot.pinchEngage
            recognizer.config.pinchRelease = snapshot.pinchRelease
        }
    }

    /// Main display in CGEvent coordinates (origin top-left). AppKit's NSScreen uses bottom-left,
    /// so convert rather than pass its frame straight through.
    private static func cgScreenBounds() -> CGRect {
        CGDisplayBounds(CGMainDisplayID())
    }

    /// Runs on the camera queue.
    private func process(_ buffer: CMSampleBuffer) {
        let now = CACurrentMediaTime()
        let hands = tracker.detect(in: buffer)
        frameTimes.append(now)
        frameTimes.removeAll { now - $0 > 1 }
        let fps = Double(frameTimes.count)

        let output = recognizer.update(hands: hands, at: now)
        let mapper = ScreenMapper(boxWidth: prefs.boxWidth, boxHeight: prefs.boxHeight,
                                  boxOffsetY: prefs.boxOffsetY, mirrored: prefs.mirrored, screen: screen)
        if let pointer = output.pointer {
            let target = filter.filter(mapper.map(pointer), at: now)
            if accessibilityOK { input.move(to: target) }
        } else {
            filter.reset()
        }
        if accessibilityOK {
            for action in output.actions { perform(action) }
        }
        let label = output.mode.rawValue

        Task { @MainActor in
            self.state.hands = hands
            self.state.fps = fps
            self.state.gestureLabel = label
        }
    }

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
