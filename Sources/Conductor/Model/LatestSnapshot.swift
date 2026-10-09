import Foundation

/// One pending preview value, replaced by newer frames until the UI takes it.
/// Tokens prevent an old frame from repopulating the mailbox after pause or restart.
final class LatestSnapshot<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var token: UUID?
    private var pending: Value?

    @discardableResult
    func start() -> UUID {
        lock.lock()
        defer { lock.unlock() }
        let token = UUID()
        self.token = token
        pending = nil
        return token
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        token = nil
        pending = nil
    }

    var currentToken: UUID? {
        lock.lock()
        defer { lock.unlock() }
        return token
    }

    func offer(_ value: Value, token: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard self.token == token else { return }
        pending = value
    }

    func take() -> Value? {
        lock.lock()
        defer { lock.unlock() }
        defer { pending = nil }
        return pending
    }
}

/// Per-frame preview only. Input events and calibration samples use their own lossless path.
struct TrackingSnapshot {
    var hands: [HandPose]
    var face: FacePose?
    var fps: Double
    var label: String
    var warning: String?
    var idle = false
    var mode: GestureRecognizer.Mode = .idle
    var feedback = GestureRecognizer.Feedback()
    var trigger: Trigger?
    var calibration: TrackingState.CalibrationStatus?
    var box: CGRect
    var targetName: String?

    @MainActor
    func publish(to state: TrackingState) {
        if state.hands != hands { state.hands = hands }
        if state.face != face { state.face = face }
        if state.fps != fps { state.fps = fps }
        if state.gestureLabel != label { state.gestureLabel = label }
        if state.warning != warning { state.warning = warning }
        if state.idle != idle { state.idle = idle }
        if state.mode != mode { state.mode = mode }
        if state.feedback != feedback { state.feedback = feedback }
        if state.activeTrigger != trigger { state.activeTrigger = trigger }
        if let calibration, state.calibration != calibration { state.calibration = calibration }
        if state.controlBox != box { state.controlBox = box }
        if state.targetDisplayName != targetName { state.targetDisplayName = targetName }
    }
}
