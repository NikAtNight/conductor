import Foundation

/// Reach calibration, look calibration and gesture checks share one camera consumer.
/// A stale caller can release only its own token, including across cancellation and restart.
final class SamplingOwnership: @unchecked Sendable {
    enum Kind { case reach, look, gestureCheck }
    private let lock = NSLock()
    private var owner: (token: UUID, kind: Kind, cancelled: () -> Void)?

    func claim(_ kind: Kind, cancelled: @escaping () -> Void) -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        guard owner == nil else { return nil }
        let token = UUID()
        owner = (token, kind, cancelled)
        return token
    }

    var isOccupied: Bool {
        lock.lock()
        defer { lock.unlock() }
        return owner != nil
    }

    func contains(_ token: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return owner?.token == token
    }

    @discardableResult
    func release(_ token: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard owner?.token == token else { return false }
        owner = nil
        return true
    }

    func cancel() {
        lock.lock()
        let callback = owner?.cancelled
        owner = nil
        lock.unlock()
        callback?()
    }
}
