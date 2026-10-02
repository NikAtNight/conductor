import CoreGraphics
import Foundation

/// Turns a stream of hand poses into input actions through a user-editable GestureMap. Pure logic,
/// no camera or CGEvent, so the whole thing is unit tested with synthesized hands. Coordinates in
/// and out are normalized frame space.
struct GestureRecognizer {
    enum Mode: String {
        case idle = "No hand"
        case point = "Move"
        case drag = "Pinch"
        case scroll = "Scroll"
        case zoom = "Zoom"
    }

    enum Action: Equatable {
        case leftDown(clickCount: Int)
        case leftUp(clickCount: Int)
        case rightClick
        case middleClick
        case shortcut(Shortcut)
        case pauseTracking
        /// Vertical palm travel since the last frame, normalized frame units. Positive is up.
        case scroll(dy: CGFloat)
        /// Spread change since the last frame, normalized frame units. Positive zooms in.
        case zoom(delta: CGFloat)
    }

    struct Output {
        var mode: Mode
        /// Where the cursor should be, or nil to leave it alone.
        var pointer: CGPoint?
        var actions: [Action]
        /// Human-readable description for the preview, e.g. "Thumb + index pinch: Click / drag".
        var label: String
    }

    struct Config {
        /// Thumb-to-fingertip distance (in hand scales) below which a pinch engages.
        var pinchEngage: CGFloat = 0.35
        /// Distance above which it releases. Must exceed `pinchEngage` to give hysteresis.
        var pinchRelease: CGFloat = 0.55
        /// Two button presses this close together, in seconds, count as a double click.
        var doubleClickInterval: TimeInterval = 0.4
        /// Pointer stays frozen after a button engages until the hand moves this far (frame units).
        var pinchDeadZone: CGFloat = 0.012
        /// Frames of missing hand tolerated before buttons are released.
        var lostFrameTolerance: Int = 4
    }

    var config: Config
    var map: GestureMap

    private(set) var mode: Mode = .idle
    private var active: Trigger?
    private var lastLeftUpTime: TimeInterval = -1
    private var lastClickCount = 1
    private var frozenPointer: CGPoint?
    private var dragOffset: CGPoint = .zero
    private var lastPalmY: CGFloat?
    private var lastSpread: CGFloat?
    private var lostFrames = 0

    init(config: Config = Config(), map: GestureMap = .standard) {
        self.config = config
        self.map = map
    }

    mutating func update(hands: [HandPose], at time: TimeInterval) -> Output {
        guard let primary = Self.primaryHand(hands) else {
            lostFrames += 1
            if lostFrames < config.lostFrameTolerance, mode != .idle {
                // Brief dropout: hold state and the current button so a drag survives a flicker.
                return Output(mode: mode, pointer: nil, actions: [], label: mode.rawValue)
            }
            return lose()
        }
        lostFrames = 0

        let other = hands.count >= 2
            ? (hands.first { $0.chirality != primary.chirality } ?? hands.dropFirst().first)
            : nil
        var actions: [Action] = []

        // Does the current trigger still hold? Pinches release through hysteresis; the others are
        // plain predicates.
        if let current = active, !isEngaged(current, primary: primary, other: other, holding: true) {
            actions += deactivate(at: time, asClick: true)
        }

        // Pick a new trigger, or let a higher-priority one preempt. Order: two hands, fist, then the
        // pinch whose fingertip is closest to the thumb. A preempted button is released, not clicked.
        var justActivated = false
        if let next = chooseTrigger(primary: primary, other: other), next != active {
            if active != nil { actions += deactivate(at: time, asClick: false) }
            actions += activate(next, primary: primary, other: other, at: time)
            justActivated = true
        }

        // Motion deltas start the frame after activation, when there is a previous sample.
        if let trigger = active, !justActivated {
            actions += motion(for: trigger, primary: primary, other: other)
        }

        let action = active.map { map[$0] } ?? .none
        let pointer = pointerOutput(primary: primary, action: action)
        mode = Self.mode(for: action)
        let label = active.map { "\($0.title): \(map[$0].title)" } ?? Mode.point.rawValue
        return Output(mode: mode, pointer: pointer, actions: actions, label: label)
    }

    // MARK: Trigger detection

    private func isEngaged(_ trigger: Trigger, primary: HandPose, other: HandPose?, holding: Bool) -> Bool {
        let threshold = holding ? config.pinchRelease : config.pinchEngage
        switch trigger {
        case .fist:
            return primary.isFist
        case .twoHandPinch:
            guard let other else { return false }
            return pinchDistance(primary, .indexTip) < threshold && pinchDistance(other, .indexTip) < threshold
        default:
            return pinchDistance(primary, trigger.fingertip!) < threshold
        }
    }

    private func chooseTrigger(primary: HandPose, other: HandPose?) -> Trigger? {
        let bound: (Trigger) -> Bool = { self.map[$0] != .none }
        if bound(.twoHandPinch), isEngaged(.twoHandPinch, primary: primary, other: other, holding: active == .twoHandPinch) {
            return .twoHandPinch
        }
        if active == .twoHandPinch { return nil } // hold until it releases on its own
        if bound(.fist), primary.isFist { return .fist }
        if active == .fist { return nil }
        if active != nil { return nil } // a held pinch is never swapped for a sibling pinch
        let candidates = Trigger.pinches.filter(bound)
            .map { ($0, pinchDistance(primary, $0.fingertip!)) }
            .filter { $0.1 < config.pinchEngage }
        return candidates.min { $0.1 < $1.1 }?.0
    }

    private func pinchDistance(_ hand: HandPose, _ fingertip: HandJoint) -> CGFloat {
        hand.normalizedDistance(.thumbTip, fingertip) ?? .infinity
    }

    // MARK: Activation

    private mutating func activate(_ trigger: Trigger, primary: HandPose, other: HandPose?, at time: TimeInterval) -> [Action] {
        active = trigger
        lastPalmY = primary.palmCenter?.y
        lastSpread = spread(primary, other)
        switch map[trigger] {
        case .leftButton:
            let count = (time - lastLeftUpTime) < config.doubleClickInterval ? lastClickCount + 1 : 1
            lastClickCount = count
            frozenPointer = primary.pointer
            dragOffset = .zero
            return [.leftDown(clickCount: count)]
        case .rightClick: return [.rightClick]
        case .middleClick: return [.middleClick]
        case .shortcut(let s): return [.shortcut(s)]
        case .pauseTracking: return [.pauseTracking]
        case .scroll, .zoom, .none: return []
        }
    }

    /// Ends the active trigger. `asClick` arms double-click timing; preemption and hand loss don't.
    private mutating func deactivate(at time: TimeInterval, asClick: Bool) -> [Action] {
        guard let trigger = active else { return [] }
        active = nil
        frozenPointer = nil
        dragOffset = .zero
        lastPalmY = nil
        lastSpread = nil
        guard map[trigger] == .leftButton else { return [] }
        lastLeftUpTime = asClick ? time : -1
        return [.leftUp(clickCount: lastClickCount)]
    }

    private mutating func motion(for trigger: Trigger, primary: HandPose, other: HandPose?) -> [Action] {
        switch map[trigger] {
        case .scroll:
            guard let y = primary.palmCenter?.y else { return [] }
            defer { lastPalmY = y }
            guard let previous = lastPalmY else { return [] }
            return [.scroll(dy: y - previous)]
        case .zoom:
            // Two hands zoom by spread. A one-handed zoom trigger uses vertical palm travel instead.
            if trigger == .twoHandPinch {
                guard let s = spread(primary, other) else { return [] }
                defer { lastSpread = s }
                guard let previous = lastSpread else { return [] }
                return [.zoom(delta: s - previous)]
            }
            guard let y = primary.palmCenter?.y else { return [] }
            defer { lastPalmY = y }
            guard let previous = lastPalmY else { return [] }
            return [.zoom(delta: y - previous)]
        default:
            return []
        }
    }

    private func spread(_ primary: HandPose, _ other: HandPose?) -> CGFloat? {
        guard let a = primary.pointer, let b = other?.pointer else { return nil }
        return a.distance(to: b)
    }

    // MARK: Pointer

    private mutating func pointerOutput(primary: HandPose, action: GestureAction) -> CGPoint? {
        guard let live = primary.pointer else { return nil }
        switch action.shape {
        case .motion:
            return nil
        case .inert, .tap:
            return live
        case .button:
            if let frozen = frozenPointer, live.distance(to: frozen) < config.pinchDeadZone {
                return frozen
            }
            if let frozen = frozenPointer {
                // Hand escaped the dead zone: start dragging from where the cursor sat, not from
                // where the hand is now, so there is no visible jump.
                dragOffset = CGPoint(x: frozen.x - live.x, y: frozen.y - live.y)
                frozenPointer = nil
            }
            return CGPoint(x: live.x + dragOffset.x, y: live.y + dragOffset.y)
        }
    }

    /// Hand disappeared for good: let go of everything.
    private mutating func lose() -> Output {
        let actions = deactivate(at: -1, asClick: false)
        mode = .idle
        return Output(mode: .idle, pointer: nil, actions: actions, label: Mode.idle.rawValue)
    }

    private static func mode(for action: GestureAction) -> Mode {
        switch action {
        case .leftButton: return .drag
        case .scroll: return .scroll
        case .zoom: return .zoom
        default: return .point
        }
    }

    /// The hand that drives the cursor. With two visible, prefer the right one.
    static func primaryHand(_ hands: [HandPose]) -> HandPose? {
        hands.first { $0.chirality == .right } ?? hands.first
    }
}
