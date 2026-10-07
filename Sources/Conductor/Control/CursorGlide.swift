import CoreGraphics
import Foundation

/// Carries the cursor from where it is to each new target over the time until the next target is
/// due, so a 30 fps camera doesn't show as 30 jumps a second. A trackpad reports over a hundred
/// times a second; the camera can't, but the cursor can still move that often. Pure: the Engine
/// feeds it targets as the pipeline posts them and asks for the position from a timer.
struct CursorGlide {
    /// Positions per second the Engine asks for.
    static let rate: Double = 120
    /// How long a glide takes when there's no previous target to measure the frame gap from.
    static let defaultFrame: TimeInterval = 1.0 / 30
    /// A glide never takes longer than this, so a dropped frame, a stall, or the hand coming back
    /// after a while doesn't turn into a slow drift across the screen.
    static let longestFrame: TimeInterval = 0.1

    private var from = CGPoint.zero
    private var to: CGPoint?
    private var startTime: TimeInterval = 0
    private var duration: TimeInterval = CursorGlide.defaultFrame
    private var lastTargetTime: TimeInterval?

    /// Whether there is still ground to cover.
    var isGliding: Bool { to != nil }

    /// A new target. `current` is where the cursor is now, so a target arriving mid-glide carries
    /// on from there with no jump. The glide takes as long as the gap since the previous target,
    /// which lands the cursor on it just as the next one is due.
    mutating func aim(at target: CGPoint, from current: CGPoint, at time: TimeInterval) {
        from = current
        to = target
        startTime = time
        duration = min(lastTargetTime.map { max(time - $0, 1 / Self.rate) } ?? Self.defaultFrame, Self.longestFrame)
        lastTargetTime = time
    }

    /// Where the cursor should be now, or nil when there's nothing left to move. The target itself
    /// is returned once, on the tick that reaches it.
    mutating func position(at time: TimeInterval) -> CGPoint? {
        guard let to else { return nil }
        let progress = (time - startTime) / duration
        guard progress < 1 else {
            self.to = nil
            return to
        }
        let t = CGFloat(max(0, progress))
        return CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
    }

    /// Forgets the target. The cursor stays where it is.
    mutating func stop() {
        to = nil
    }
}
