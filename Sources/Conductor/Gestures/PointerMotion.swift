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

/// The "to where your hand is" pointer, with fine control. A box small enough to reach comfortably
/// maps each camera pixel to many screen pixels, so slow aiming moves only cover `slowGain` of the
/// mapped distance. Quick moves cover all of it and pull the cursor back toward the hand's mapped
/// spot, so the offset built up while aiming doesn't stick around.
struct PrecisionPointer {
    /// Fraction of the mapped distance a slow move covers.
    var slowGain: CGFloat = 0.35
    private var last: (point: CGPoint, time: TimeInterval)?
    private var cursor: CGPoint = .zero

    /// Hand speeds (frame widths per second) where the gain starts rising, and where it reaches 1.
    static let slowSpeed: CGFloat = 0.08
    static let fastSpeed: CGFloat = 0.6
    /// Fraction of the cursor-to-hand offset removed per frame at full speed.
    static let catchUp: CGFloat = 0.15

    mutating func reset() { last = nil }

    /// Cursor position for a new normalized hand position, Vision space. The first sample after a
    /// reset lands exactly where the hand maps, so bringing the hand back into view re-syncs.
    /// With `slowGain` at 1 this is plain absolute mapping.
    mutating func position(for point: CGPoint, at time: TimeInterval, mapper: ScreenMapper) -> CGPoint {
        defer { last = (point, time) }
        let target = mapper.map(point)
        guard slowGain < 1, let last, time > last.time else {
            cursor = target
            return target
        }
        // Unclamped, so a slow move past the box edge still carries the cursor to the screen edge.
        let from = mapper.map(last.point, clamped: false)
        let to = mapper.map(point, clamped: false)
        let handSpeed = point.distance(to: last.point) / CGFloat(time - last.time)
        let t = ((handSpeed - Self.slowSpeed) / (Self.fastSpeed - Self.slowSpeed)).clamped(to: 0...1)
        let gain = slowGain + (1 - slowGain) * t
        let pull = Self.catchUp * t
        let screen = mapper.screen
        let x = cursor.x + (to.x - from.x) * gain
        let y = cursor.y + (to.y - from.y) * gain
        cursor.x = (x + (target.x - x) * pull).clamped(to: screen.minX...screen.maxX)
        cursor.y = (y + (target.y - y) * pull).clamped(to: screen.minY...screen.maxY)
        return cursor
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
