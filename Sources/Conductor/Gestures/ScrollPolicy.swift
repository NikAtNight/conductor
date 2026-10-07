import CoreGraphics
import Foundation

/// Turns what the recognizer measured for scrolling into wheel pixels, and keeps a flick going
/// after the hand lets go, slowing to a stop like a trackpad. One owner for live scrolling, the
/// lever's rate, coasting, and everything that ends a coast: a click, another gesture, a pause,
/// leaving scroll mode, a stall. It decides all of that from the recognizer's output alone.
struct ScrollPolicy {
    /// User speed multiplier.
    private(set) var gain: CGFloat = 1
    /// Coast after a flick. Off means the page stops with the hand. Only palm travel can flick: a
    /// lever has nothing to coast from, so letting go of it always stops the page.
    private(set) var momentum = true

    /// Full-frame palm travel of 1.0 scrolls this many pixels. Tuned so a relaxed 10 cm hand
    /// move scrolls about a screen's worth.
    static let pixelsPerFrame: CGFloat = 4000
    /// Lever speed: frame units of travel per second for each unit of knuckle offset past the dead
    /// zone. At 4, an offset 0.05 past the dead zone scrolls 800 px/s at the default speed.
    static let leverRate: CGFloat = 4
    /// Coasting keeps this fraction of its speed per second: 0.9 per frame at 30 fps.
    static let decayPerSecond: CGFloat = 0.042
    /// Below this many pixels per frame, coasting stops.
    static let stopBelow: CGFloat = 1
    /// A flick must be at least this fast (pixels per frame) to coast at all.
    static let startAbove: CGFloat = 6
    /// Speeds are kept per frame at this rate; other frame rates are scaled to it.
    static let referenceFrame: TimeInterval = 1.0 / 30
    /// The longest gap one frame may cover, so a stall or a dropped frame can't become one giant step.
    static let longestFrame: TimeInterval = 0.1

    private var recent: [CGFloat] = []
    /// Pixels per reference frame while coasting.
    private var velocity: CGFloat = 0
    private var wasScrolling = false
    private var wasScrollMode = false
    private var lastTime: TimeInterval?
    /// When the last lever reading came in. Nil after a frame without one, so the lever starts over.
    private var lastLeverTime: TimeInterval?

    /// Takes new settings. Turning momentum off ends a coast in progress. Nothing else resets:
    /// settings arrive on every refresh (a slider drag, an app switch), and the lever must not
    /// skip a frame for that.
    mutating func apply(gain: CGFloat, momentum: Bool) {
        self.gain = gain
        if self.momentum, !momentum { stop() }
        self.momentum = momentum
    }

    /// Pixels to post this frame, or nil. `paused` is whether tracking is paused, which the output
    /// doesn't show once the hand is gone.
    mutating func pixels(for recognized: GestureRecognizer.Output, paused: Bool, at time: TimeInterval) -> Int32? {
        let inScrollMode = recognized.mode == .scrollMode
        let scrolling = recognized.mode == .scroll || inScrollMode
        var travel: CGFloat?
        var lever: CGFloat?
        for action in recognized.actions {
            switch action {
            case .scrollTravel(let dy): travel = (travel ?? 0) + dy
            case .scrollLever(let offset): lever = offset
            default: break
            }
        }
        defer {
            wasScrolling = scrolling
            wasScrollMode = inScrollMode
            lastTime = time
        }
        // A click, a new gesture, or a pause stops a coast. Scroll mode never coasts: the page
        // stops when it ends, hand or not.
        let interrupted = paused || [.drag, .zoom, .paused].contains(recognized.mode)
            || recognized.actions.contains(where: Self.endsCoast)
            || (wasScrollMode && !inScrollMode)
        if interrupted {
            stop()
            return nil
        }
        if let lever {
            // The first reading, or the first after a gap, only starts the clock.
            let held = lastLeverTime.map { min(time - $0, Self.longestFrame) } ?? 0
            // Nothing coasts from a lever.
            stop()
            lastLeverTime = time
            return Self.wheel(pixels(forTravel: lever * Self.leverRate * CGFloat(held)))
        }
        lastLeverTime = nil
        let dt = min(lastTime.map { time - $0 } ?? Self.referenceFrame, Self.longestFrame)
        if let travel {
            let live = pixels(forTravel: travel)
            velocity = 0
            // Kept per reference frame, so a faster camera doesn't read as a slower flick.
            recent.append(live * CGFloat(Self.referenceFrame / max(dt, 0.001)))
            if recent.count > 4 { recent.removeFirst() }
            return Self.wheel(live)
        }
        if wasScrolling, !scrolling {
            if momentum { release() } else { recent.removeAll() }
        }
        guard !scrolling, abs(velocity) >= Self.stopBelow else {
            if !scrolling { velocity = 0 }
            return nil
        }
        let step = velocity * CGFloat(dt / Self.referenceFrame)
        velocity *= pow(Self.decayPerSecond, CGFloat(dt))
        return Self.wheel(step)
    }

    /// Forgets all motion: no coast, no flick samples, and the lever starts over.
    mutating func stop() {
        velocity = 0
        recent.removeAll()
        lastLeverTime = nil
    }

    /// The hand stopped scrolling. Start coasting if the last few frames were a flick.
    private mutating func release() {
        guard !recent.isEmpty else { return }
        let average = recent.reduce(0, +) / CGFloat(recent.count)
        recent.removeAll()
        velocity = abs(average) >= Self.startAbove ? average : 0
    }

    /// Natural scrolling: hand up means content moves up, which is a negative wheel delta.
    private func pixels(forTravel travel: CGFloat) -> CGFloat {
        -travel * Self.pixelsPerFrame * gain
    }

    /// Whole wheel pixels. A hand held still (or a lever at rest) posts nothing rather than empty
    /// wheel events.
    private static func wheel(_ pixels: CGFloat) -> Int32? {
        let step = Int32(pixels.rounded())
        return step == 0 ? nil : step
    }

    /// Whether this action ends a coasting scroll.
    private static func endsCoast(_ action: GestureRecognizer.Action) -> Bool {
        switch action {
        case .leftDown, .rightClick, .middleClick, .shortcut, .zoom, .switchDisplay: return true
        case .leftUp, .keyDown, .keyUp, .scrollTravel, .scrollLever: return false
        }
    }
}
