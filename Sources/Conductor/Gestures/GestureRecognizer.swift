import CoreGraphics
import Foundation

/// Turns a stream of hand poses into input actions through a user-editable GestureMap. Pure logic,
/// no camera or CGEvent, so the whole thing is unit tested with synthesized hands. Coordinates in
/// and out are normalized frame space.
///
/// Control has three states on top of the gesture logic:
/// - waiting: with the ready pose required, nothing moves until an open hand is held still.
/// - in control: gestures and the pointer work. Losing the hand for `releaseAfter` hands control back.
/// - paused: a trigger bound to "Pause / resume" stops all input; the same trigger resumes.
struct GestureRecognizer {
    enum Mode: String {
        case idle = "No hand"
        case waiting = "Hold an open hand still to take control"
        case paused = "Paused"
        case point = "Move"
        case drag = "Pinch"
        case scroll = "Scroll"
        case zoom = "Zoom"
        case swipe = "Two fingers: swipe left or right"
    }

    enum Action: Equatable {
        case leftDown(clickCount: Int)
        case leftUp(clickCount: Int)
        case rightClick
        case middleClick
        case shortcut(Shortcut)
        /// Vertical palm travel since the last frame, normalized frame units. Positive is up.
        case scroll(dy: CGFloat)
        /// Spread change since the last frame, normalized frame units. Positive zooms in.
        case zoom(delta: CGFloat)
    }

    /// State changes the UI cares about (sounds, VoiceOver, status text). Not input.
    enum Event: Equatable {
        case tookControl
        case releasedControl
        case paused
        case resumed
    }

    /// Progress values for the cursor ring, each 0...1.
    struct Feedback: Equatable {
        /// How close the nearest bound pinch is to clicking. 1 while a pinch is held.
        var pinch: CGFloat = 0
        /// How far along a dwell click is.
        var dwell: CGFloat = 0
        /// How far along the ready pose is.
        var ready: CGFloat = 0
    }

    struct Output {
        var mode: Mode
        /// Where the cursor should be, or nil to leave it alone.
        var pointer: CGPoint?
        var actions: [Action]
        /// Human-readable description for the preview, e.g. "Thumb + index pinch: Click / drag".
        var label: String
        var events: [Event] = []
        var feedback = Feedback()
    }

    enum MainHand: String, CaseIterable, Identifiable {
        case right, left, either
        var id: String { rawValue }
        var title: String {
            switch self {
            case .right: return "Right hand"
            case .left: return "Left hand"
            case .either: return "Whichever hand comes first"
            }
        }
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
        /// Which hand drives the cursor when two are visible.
        var mainHand: MainHand = .right
        /// Require an open hand held still before anything moves.
        var requireReadyPose = false
        var readyHold: TimeInterval = 0.5
        /// The ready pose resets if the pointer drifts farther than this while holding.
        var readyStillness: CGFloat = 0.03
        /// With the ready pose on, control is handed back after the hand is gone this long.
        var releaseAfter: TimeInterval = 1.5
        /// Click by holding the pointer still.
        var dwellClick = false
        var dwellTime: TimeInterval = 0.8
        /// Pointer must stay within this radius (frame units) for a dwell to count.
        var dwellRadius: CGFloat = 0.015
        /// Matches ScreenMapper: with mirroring, moving your hand to your left is "left".
        var mirrored = true
        /// A swipe is this much sideways palm travel (frame units) within `swipeWindow` seconds.
        var swipeDistance: CGFloat = 0.12
        var swipeWindow: TimeInterval = 0.3
    }

    var config: Config
    var map: GestureMap

    private(set) var mode: Mode = .idle
    private(set) var isPaused = false
    private var active: Trigger?
    private var lastLeftUpTime: TimeInterval = -1
    private var lastClickCount = 1
    private var frozenPointer: CGPoint?
    private var dragOffset: CGPoint = .zero
    private var lastPalmY: CGFloat?
    private var lastSpread: CGFloat?
    private var lostFrames = 0
    private var lastSeen: TimeInterval = -.infinity
    private var hasControl = false
    private var readyStart: TimeInterval?
    private var readyAnchor: CGPoint?
    /// While paused: the pause trigger that is still physically held. It must be let go and made
    /// again to resume, otherwise the pinch that paused would immediately resume.
    private var pauseHeld: Trigger?
    private var dwellAnchor: CGPoint?
    private var dwellStart: TimeInterval = 0
    /// Where the last click happened. Dwell stays disarmed until the pointer moves away from it.
    private var dwellBlockedAt: CGPoint?
    /// Set after a gesture or a change of control: the next open-hand frame becomes the block
    /// point. Using the pointer from that frame, not the pinched one, matters because opening the
    /// fingers shifts the thumb-index midpoint a little.
    private var dwellRearm = false
    private var events: [Event] = []
    /// Recent palm x positions while in the two-finger pose, oldest first.
    private var swipeTrail: [(time: TimeInterval, x: CGFloat)] = []
    /// One swipe per pose: set after a swipe fires, cleared when the pose ends.
    private var swipeFired = false

    init(config: Config = Config(), map: GestureMap = .standard) {
        self.config = config
        self.map = map
    }

    /// Back to a clean start: no control, not paused, nothing held.
    mutating func reset() {
        self = GestureRecognizer(config: config, map: map)
    }

    mutating func update(hands: [HandPose], at time: TimeInterval) -> Output {
        events.removeAll()
        guard let primary = Self.primaryHand(hands, prefer: config.mainHand) else {
            lostFrames += 1
            if config.requireReadyPose, hasControl, time - lastSeen > config.releaseAfter {
                hasControl = false
                events.append(.releasedControl)
            }
            if lostFrames < config.lostFrameTolerance, mode != .idle {
                // Brief dropout: hold state and the current button so a drag survives a flicker.
                return output(mode, pointer: nil, actions: [], label: label(for: mode))
            }
            return lose()
        }
        lostFrames = 0
        lastSeen = time

        let other = hands.count >= 2
            ? (hands.first { $0 != primary && $0.chirality != primary.chirality } ?? hands.first { $0 != primary })
            : nil

        if isPaused {
            return pausedUpdate(primary: primary, other: other, at: time)
        }
        if config.requireReadyPose, !hasControl {
            return waitingUpdate(primary: primary, at: time)
        }
        return controlUpdate(primary: primary, other: other, at: time)
    }

    // MARK: Control states

    private mutating func waitingUpdate(primary: HandPose, at time: TimeInterval) -> Output {
        let progress = readyProgress(primary, at: time)
        guard progress >= 1 else {
            mode = .waiting
            return output(.waiting, pointer: nil, actions: [], label: Mode.waiting.rawValue,
                          feedback: Feedback(ready: progress))
        }
        hasControl = true
        readyStart = nil
        events.append(.tookControl)
        // Don't let the hold that just took control count toward a dwell click.
        dwellRearm = true
        mode = .point
        return output(.point, pointer: primary.pointer, actions: [], label: Mode.point.rawValue,
                      feedback: Feedback(ready: 1))
    }

    private mutating func pausedUpdate(primary: HandPose, other: HandPose?, at time: TimeInterval) -> Output {
        // A swipe bound to pause can resume too.
        if Trigger.swipes.contains(where: { map[$0] == .pauseTracking }), primary.isTwoFingerPose {
            if let fired = detectSwipe(primary, at: time), map[fired] == .pauseTracking {
                isPaused = false
                hasControl = true
                events.append(.resumed)
                dwellRearm = true
                mode = .point
                return output(.point, pointer: nil, actions: [], label: "Resumed")
            }
        } else {
            resetSwipe()
        }
        if let held = pauseHeld {
            if !isEngaged(held, primary: primary, other: other, holding: true) { pauseHeld = nil }
        } else if let trigger = Trigger.allCases.first(where: {
            map[$0] == .pauseTracking && isEngaged($0, primary: primary, other: other, holding: false)
        }) {
            isPaused = false
            hasControl = true
            // Treat the resuming trigger as held so it doesn't pause again until released.
            active = trigger
            events.append(.resumed)
            dwellRearm = true
            mode = .point
            return output(.point, pointer: nil, actions: [], label: "Resumed")
        }
        mode = .paused
        let resumeHint = Trigger.allCases.first { map[$0] == .pauseTracking }.map { "\($0.title) to resume" }
        return output(.paused, pointer: nil, actions: [],
                      label: resumeHint.map { "Paused: \($0)" } ?? Mode.paused.rawValue)
    }

    private mutating func controlUpdate(primary: HandPose, other: HandPose?, at time: TimeInterval) -> Output {
        if active == nil, Trigger.swipes.contains(where: { map[$0] != .none }), primary.isTwoFingerPose {
            return swipeUpdate(primary: primary, at: time)
        }
        resetSwipe()
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
            if isPaused {
                mode = .paused
                return output(.paused, pointer: nil, actions: actions, label: "Paused: \(next.title) to resume")
            }
        }

        // Motion deltas start the frame after activation, when there is a previous sample.
        if let trigger = active, !justActivated {
            actions += motion(for: trigger, primary: primary, other: other)
        }

        let action = active.map { map[$0] } ?? .none
        let pointer = pointerOutput(primary: primary, action: action)
        var feedback = Feedback(pinch: pinchFeedback(primary))

        if config.dwellClick, active == nil, let live = primary.pointer {
            let (dwellActions, progress) = dwell(at: live, time: time)
            actions += dwellActions
            feedback.dwell = progress
        } else {
            dwellAnchor = nil
            if active != nil { dwellRearm = true }
        }

        mode = Self.mode(for: action)
        let label = active.map { "\($0.title): \(map[$0].title)" } ?? Mode.point.rawValue
        return output(mode, pointer: pointer, actions: actions, label: label, feedback: feedback)
    }

    // MARK: Swipes

    /// Two-finger pose: the cursor holds still, and a quick sideways flick fires a swipe trigger.
    private mutating func swipeUpdate(primary: HandPose, at time: TimeInterval) -> Output {
        dwellAnchor = nil
        dwellRearm = true
        mode = .swipe
        guard let trigger = detectSwipe(primary, at: time) else {
            return output(.swipe, pointer: nil, actions: [], label: Mode.swipe.rawValue)
        }
        return output(.swipe, pointer: nil, actions: tapActions(for: trigger), label: trigger.title)
    }

    /// Tracks the palm while in the two-finger pose and reports a swipe once per pose.
    private mutating func detectSwipe(_ hand: HandPose, at time: TimeInterval) -> Trigger? {
        guard let x = hand.palmCenter?.x else { return nil }
        swipeTrail.append((time, x))
        swipeTrail.removeAll { time - $0.time > config.swipeWindow }
        guard !swipeFired, let first = swipeTrail.first else { return nil }
        // Vision x grows to the camera's right. With mirroring that is the user's left.
        let travel = (x - first.x) * (config.mirrored ? -1 : 1)
        guard abs(travel) >= config.swipeDistance else { return nil }
        swipeFired = true
        return travel < 0 ? .swipeLeft : .swipeRight
    }

    private mutating func resetSwipe() {
        swipeTrail.removeAll()
        swipeFired = false
    }

    /// What a one-shot trigger does. Button actions become a full click; motion actions do nothing.
    private mutating func tapActions(for trigger: Trigger) -> [Action] {
        switch map[trigger] {
        case .leftButton: return [.leftDown(clickCount: 1), .leftUp(clickCount: 1)]
        case .rightClick: return [.rightClick]
        case .middleClick: return [.middleClick]
        case .shortcut(let s): return [.shortcut(s)]
        case .pauseTracking:
            isPaused = true
            events.append(.paused)
            return []
        case .scroll, .zoom, .none: return []
        }
    }

    // MARK: Ready pose and dwell

    private mutating func readyProgress(_ hand: HandPose, at time: TimeInterval) -> CGFloat {
        guard hand.isOpenHand, let p = hand.pointer else {
            readyStart = nil
            return 0
        }
        if let start = readyStart, let anchor = readyAnchor, p.distance(to: anchor) <= config.readyStillness {
            return min(1, CGFloat((time - start) / config.readyHold))
        }
        readyStart = time
        readyAnchor = p
        return 0
    }

    private mutating func dwell(at point: CGPoint, time: TimeInterval) -> ([Action], CGFloat) {
        if dwellRearm {
            dwellRearm = false
            dwellBlockedAt = point
            dwellAnchor = nil
            return ([], 0)
        }
        if let blocked = dwellBlockedAt {
            guard point.distance(to: blocked) > config.dwellRadius * 2 else { return ([], 0) }
            dwellBlockedAt = nil
        }
        if let anchor = dwellAnchor, point.distance(to: anchor) <= config.dwellRadius {
            let progress = CGFloat((time - dwellStart) / config.dwellTime)
            if progress >= 1 {
                dwellAnchor = nil
                dwellBlockedAt = point
                return ([.leftDown(clickCount: 1), .leftUp(clickCount: 1)], 1)
            }
            return ([], progress)
        }
        dwellAnchor = point
        dwellStart = time
        return ([], 0)
    }

    private func pinchFeedback(_ hand: HandPose) -> CGFloat {
        if let active, active.fingertip != nil, map[active].shape != .motion { return 1 }
        let distances = Trigger.pinches
            .filter { map[$0] != .none && map[$0].shape != .motion }
            .map { pinchDistance(hand, $0.fingertip!) }
        guard let nearest = distances.min(), config.pinchRelease > config.pinchEngage else { return 0 }
        return ((config.pinchRelease - nearest) / (config.pinchRelease - config.pinchEngage)).clamped(to: 0...1)
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
        case .swipeLeft, .swipeRight:
            // Swipes are momentary; they can't be "held" and can't resume a pause.
            return false
        case .indexPinch, .middlePinch, .ringPinch, .littlePinch:
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
        case .pauseTracking:
            isPaused = true
            pauseHeld = trigger
            active = nil
            events.append(.paused)
            return []
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

    /// Hand disappeared for good: let go of everything (but stay paused if paused).
    private mutating func lose() -> Output {
        let actions = deactivate(at: -1, asClick: false)
        pauseHeld = nil
        readyStart = nil
        dwellAnchor = nil
        mode = .idle
        return output(.idle, pointer: nil, actions: actions, label: isPaused ? "Paused" : Mode.idle.rawValue)
    }

    private func label(for mode: Mode) -> String { mode.rawValue }

    private func output(_ mode: Mode, pointer: CGPoint?, actions: [Action], label: String,
                        feedback: Feedback = Feedback()) -> Output {
        Output(mode: mode, pointer: pointer, actions: actions, label: label, events: events, feedback: feedback)
    }

    private static func mode(for action: GestureAction) -> Mode {
        switch action {
        case .leftButton: return .drag
        case .scroll: return .scroll
        case .zoom: return .zoom
        default: return .point
        }
    }

    /// The hand that drives the cursor. With two visible, prefer the chosen one; with one visible,
    /// use it whichever it is, since Vision sometimes reports chirality as unknown.
    static func primaryHand(_ hands: [HandPose], prefer main: MainHand = .right) -> HandPose? {
        switch main {
        case .right: return hands.first { $0.chirality == .right } ?? hands.first
        case .left: return hands.first { $0.chirality == .left } ?? hands.first
        case .either: return hands.first
        }
    }
}
