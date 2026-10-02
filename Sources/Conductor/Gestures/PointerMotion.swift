import CoreGraphics
import Foundation

/// Trackpad-style pointer: the cursor moves by how far the hand moved, not to where the hand is.
/// Slow movements get a low gain for precision and fast ones a high gain to cross the screen, the
/// same idea as macOS pointer acceleration.
struct RelativePointer {
    /// User speed multiplier.
    var speed: CGFloat = 1
    var mirrored = true
    private var last: (point: CGPoint, time: TimeInterval)?

    /// Gain at rest and at full speed, in screen widths per frame width of hand travel.
    static let slowGain: CGFloat = 0.6
    static let fastGain: CGFloat = 3.0
    /// Hand speed (frame widths per second) at which the gain reaches `fastGain`.
    static let fastSpeed: CGFloat = 1.2

    mutating func reset() { last = nil }

    /// Cursor movement in pixels for a new normalized hand position, Vision space. Returns nil for
    /// the first sample after a reset, since there is nothing to move relative to.
    mutating func delta(for point: CGPoint, at time: TimeInterval, screenWidth: CGFloat) -> CGVector? {
        defer { last = (point, time) }
        guard let last, time > last.time else { return nil }
        let dx = (point.x - last.point.x) * (mirrored ? -1 : 1)
        let dy = -(point.y - last.point.y) // Vision y grows upward; screen y grows downward.
        let handSpeed = (dx * dx + dy * dy).squareRoot() / CGFloat(time - last.time)
        let t = min(1, handSpeed / Self.fastSpeed)
        let gain = (Self.slowGain + (Self.fastGain - Self.slowGain) * t) * speed * screenWidth
        return CGVector(dx: dx * gain, dy: dy * gain)
    }
}

/// Keeps a fist scroll going after the hand lets go mid-flick, slowing to a stop like a trackpad.
struct MomentumScroller {
    /// Fraction of speed kept per frame at 30 fps.
    static let decay: CGFloat = 0.9
    /// Below this many pixels per frame, coasting stops.
    static let stopBelow: CGFloat = 1
    /// A flick must be at least this fast (pixels per frame) to coast at all.
    static let startAbove: CGFloat = 6

    private var recent: [CGFloat] = []
    private(set) var velocity: CGFloat = 0

    /// Record one frame of live scrolling.
    mutating func scrolled(_ pixels: CGFloat) {
        velocity = 0
        recent.append(pixels)
        if recent.count > 4 { recent.removeFirst() }
    }

    /// The hand stopped scrolling. Start coasting if the last few frames were a flick.
    mutating func released() {
        guard !recent.isEmpty else { return }
        let average = recent.reduce(0, +) / CGFloat(recent.count)
        recent.removeAll()
        velocity = abs(average) >= Self.startAbove ? average : 0
    }

    /// Pixels to scroll this frame while coasting, or nil when there is nothing to do.
    mutating func tick() -> CGFloat? {
        guard abs(velocity) >= Self.stopBelow else {
            velocity = 0
            return nil
        }
        let step = velocity
        velocity *= Self.decay
        return step
    }

    mutating func stop() {
        velocity = 0
        recent.removeAll()
    }
}
