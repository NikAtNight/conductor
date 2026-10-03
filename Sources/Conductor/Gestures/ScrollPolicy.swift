import CoreGraphics
import Foundation

/// Turns scroll gestures into wheel pixels and keeps a flick going after the hand lets go, slowing
/// to a stop like a trackpad. One owner for live scrolling, coasting, and everything that ends a
/// coast: a click, another gesture, a pause, a stall.
struct ScrollPolicy {
    /// User speed multiplier.
    var gain: CGFloat = 1
    /// Coast after a flick. Off means the page stops with the hand.
    var momentum = true

    /// Full-frame palm travel of 1.0 scrolls this many pixels. Tuned so a relaxed 10 cm hand
    /// move scrolls about a screen's worth.
    static let pixelsPerFrame: CGFloat = 4000
    /// Coasting keeps this fraction of its speed per second: 0.9 per frame at 30 fps.
    static let decayPerSecond: CGFloat = 0.042
    /// Below this many pixels per frame, coasting stops.
    static let stopBelow: CGFloat = 1
    /// A flick must be at least this fast (pixels per frame) to coast at all.
    static let startAbove: CGFloat = 6
    /// Speeds are kept per frame at this rate; other frame rates are scaled to it.
    static let referenceFrame: TimeInterval = 1.0 / 30

    private var recent: [CGFloat] = []
    /// Pixels per reference frame while coasting.
    private var velocity: CGFloat = 0
    private var wasScrolling = false
    private var lastTime: TimeInterval?

    /// Pixels to post this frame, or nil. `travel` is the hand's vertical travel since the last
    /// frame (normalized, positive up) while a scroll gesture is held, `scrolling` whether one is
    /// held, and `interrupted` whether something happened that must stop a coast.
    mutating func pixels(travel: CGFloat?, scrolling: Bool, interrupted: Bool, at time: TimeInterval) -> Int32? {
        defer {
            wasScrolling = scrolling
            lastTime = time
        }
        if interrupted {
            stop()
            return nil
        }
        let dt = min(lastTime.map { time - $0 } ?? Self.referenceFrame, 0.1)
        if let travel {
            // Natural scrolling: hand up means content moves up, which is a negative wheel delta.
            let pixels = -travel * Self.pixelsPerFrame * gain
            velocity = 0
            // Kept per reference frame, so a faster camera doesn't read as a slower flick.
            recent.append(pixels * CGFloat(Self.referenceFrame / max(dt, 0.001)))
            if recent.count > 4 { recent.removeFirst() }
            // A hand held still (or scroll mode at rest) posts nothing rather than empty wheel events.
            let step = Int32(pixels.rounded())
            return step == 0 ? nil : step
        }
        if wasScrolling, !scrolling {
            if momentum { release() } else { recent.removeAll() }
        }
        guard !scrolling, abs(velocity) >= Self.stopBelow else {
            if !scrolling { velocity = 0 }
            return nil
        }
        // dt is capped above, so a stall or a dropped frame can't become one giant step.
        let step = Int32((velocity * CGFloat(dt / Self.referenceFrame)).rounded())
        velocity *= pow(Self.decayPerSecond, CGFloat(dt))
        return step == 0 ? nil : step
    }

    mutating func stop() {
        velocity = 0
        recent.removeAll()
    }

    /// The hand stopped scrolling. Start coasting if the last few frames were a flick.
    private mutating func release() {
        guard !recent.isEmpty else { return }
        let average = recent.reduce(0, +) / CGFloat(recent.count)
        recent.removeAll()
        velocity = abs(average) >= Self.startAbove ? average : 0
    }
}
