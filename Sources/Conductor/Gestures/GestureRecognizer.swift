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
/// - scroll mode: a trigger bound to "Scroll mode on / off" turns the relaxed hand into a scroll
///   lever. Where the hand settles becomes neutral; knuckles above it scroll down the page, below
///   it scroll up, faster the farther they go. Finger shapes do nothing until the same trigger
///   switches back.
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
        case scrollMode = "Scroll mode"
    }

    enum Action: Equatable {
        case leftDown(clickCount: Int)
        case leftUp(clickCount: Int)
        case rightClick
        case middleClick
        case shortcut(Shortcut)
        /// Press or release a held key (push-to-talk).
        case keyDown(Shortcut)
        case keyUp(Shortcut)
        /// Vertical palm travel since the last frame, normalized frame units. Positive is up.
        case scrollTravel(dy: CGFloat)
        /// The scroll lever: knuckle height from neutral beyond the dead zone, normalized frame
        /// units. Positive is above neutral, which scrolls down the page; 0 at rest. ScrollPolicy
        /// sets the rate.
        case scrollLever(offset: CGFloat)
        /// Spread change since the last frame, normalized frame units. Positive zooms in.
        case zoom(delta: CGFloat)
        /// Move the control box to the display in this direction, or with none, to the next one.
        case switchDisplay(toward: Direction?)
    }

    /// State changes the UI cares about (sounds, VoiceOver, status text). Not input.
    enum Event: Equatable {
        case tookControl
        case releasedControl
        case paused
        case resumed
        case scrollModeOn
        case scrollModeOff
    }

    /// Progress values for the cursor ring, each 0...1.
    struct Feedback: Equatable {
        /// How close the nearest bound pinch is to clicking. 1 while a pinch is held.
        var pinch: CGFloat = 0
        /// How far along a dwell click is.
        var dwell: CGFloat = 0
        /// How far along the ready pose is.
        var ready: CGFloat = 0
        /// In scroll mode: 1 scrolling down the page, -1 up, 0 at rest.
        var scrollDirection = 0
        /// How far along the pointing sign's hold is. 1 while the sign is held after firing.
        var point: CGFloat = 0
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
        /// The trigger held or forming this frame, for the preview's gesture panel.
        var trigger: Trigger?
        /// A button went down and the hand hasn't left the click dead zone yet, so `pointer` is
        /// pinned where it was. The pipeline holds the cursor still for as long as this lasts.
        var pointerFrozen = false
    }

    typealias MainHand = Settings.MainHand

    /// The fields without a default here come from Settings, through `init(_:)`.
    struct Config {
        /// Thumb-to-fingertip distance (in hand scales) below which a pinch engages.
        var pinchEngage: CGFloat
        /// Distance above which it releases. Must exceed `pinchEngage` to give hysteresis.
        var pinchRelease: CGFloat
        /// Two button presses this close together, in seconds, count as a double click.
        var doubleClickInterval: TimeInterval = 0.4
        /// Pointer stays frozen after a button engages until the hand moves this far (frame units).
        var pinchDeadZone: CGFloat
        /// Frames of missing hand tolerated before buttons are released. Vision drops a pinched hand
        /// for up to six frames at a time in recorded logs; releasing a held key or drag over that
        /// cancelled dictation mid-sentence.
        var lostFrameTolerance: Int = 12
        /// Two pinches this close in distance count as a tie, and the finger further along the
        /// hand wins: reaching the thumb to the ring finger drags it past the middle finger, so the
        /// middle looks pinched too. The index never loses a tie.
        var pinchTieMargin: CGFloat = 0.06
        /// Seconds a click may sit half open, its fingers back past `pinchEngage` but short of
        /// `pinchRelease`, before it lets go, as long as the hand hasn't started a drag. After a
        /// click Nikhil's fingers often rested 0.36 to 0.43 apart and stayed there, so the button
        /// stayed down for up to a second and the hand's drift turned the click into a drag.
        /// Drags in the same logs stayed under 0.3 for their whole hold.
        var halfOpenRelease: TimeInterval = 0.15
        /// Frames a held middle, ring or little pinch may be kept by a neighbouring fingertip alone
        /// (see isEngaged). Vision's swaps last a frame or two; a hand that really opened
        /// shouldn't be held longer than this.
        var neighbourSwapFrames = 3
        /// Which hand drives the cursor when two are visible.
        var mainHand: MainHand
        /// Require an open hand held still before anything moves.
        var requireReadyPose: Bool
        var readyHold: TimeInterval = 0.5
        /// The ready pose resets if the pointer drifts farther than this while holding.
        var readyStillness: CGFloat = 0.03
        /// With the ready pose on, control is handed back after the hand is gone this long.
        var releaseAfter: TimeInterval = 1.5
        /// Click by holding the pointer still.
        var dwellClick: Bool
        var dwellTime: TimeInterval
        /// Pointer must stay within this radius (frame units) for a dwell to count.
        var dwellRadius: CGFloat
        /// Matches ScreenMapper: with mirroring, moving your hand to your left is "left".
        var mirrored: Bool
        /// Sideways knuckle travel in frame units within `swipeWindow`. The wrist stays almost
        /// still during a flick, so including it in the average missed short wrist flicks.
        /// Travel must also be mostly horizontal (see swipeTravel).
        var swipeDistance: CGFloat = 0.035
        var swipeWindow: TimeInterval = 0.25
        /// Seconds a pinch must hold before it engages, so a fingertip passing the thumb doesn't
        /// click. 0.06 is the third frame at 30 fps.
        var pinchHold: TimeInterval = 0.06
        /// A pinch can't start while its finger looks shorter than this, in palm widths. Aimed at
        /// the lens, the camera can't tell whether the fingertip touches the thumb.
        var minimumFingerLength: CGFloat = 0.5
        /// Index and middle count as crossed past this (see HandPose.fingerCross), and uncrossed
        /// below `crossRelease`. Deliberate crosses in recorded logs read 0.4 to 0.7; two fingers
        /// held touching read up to 0.21, which at 0.2 switched scroll mode by accident.
        var crossEngage: CGFloat = 0.3
        var crossRelease: CGFloat = 0.15
        /// Seconds the fingers must stay crossed, so a hand passing through the shape doesn't fire.
        var crossHold: TimeInterval = 0.3
        /// Frames in a row reading uncrossed, or unreadable, that a held cross rides out. Vision
        /// drops the occluded index tip for a frame at a time while the fingers are crossed, and
        /// in recorded logs that restarted the hold on six attempts out of seven. The ridden-out
        /// frames don't count toward `crossHold`, so a borderline reading can't be padded into a switch.
        var crossDropFrames = 3
        /// Seconds the cross must hold to leave scroll mode. Shorter than `crossHold`: the finger
        /// underneath hides its tip, and Vision found it on about half the frames of a real cross in
        /// recorded logs, so holds of 0.6 s read as 0.27 s of crossing and never switched back. A
        /// switch out by mistake only brings the pointer back, where a switch in by mistake stops it.
        var crossExitHold: TimeInterval = 0.15
        /// Seconds a fist must hold in scroll mode to leave it, for when the cross won't read at
        /// all. A relaxed hand working the lever read as a fist on one frame in 415 in recorded
        /// logs; the fists Nikhil made when scrolling "stopped working" lasted 0.2 to 0.23 s.
        var fistExitHold: TimeInterval = 0.2
        /// Both hands' thumb-to-index distances must be under this to engage the two-hand pinch,
        /// and one over `twoHandPinchRelease` lets it go. Looser than a one-hand pinch: pinching
        /// both hands curls the other fingers into fists and the tips sit 0.4 to 0.5 apart in the
        /// picture, and two pinched hands are not a shape anything else is mistaken for.
        var twoHandPinchEngage: CGFloat = 0.5
        var twoHandPinchRelease: CGFloat = 0.7
        /// Seconds the pointing sign (index out, thumb out, others curled) must hold before it fires.
        var pointHold: TimeInterval = 0.3
        /// Scroll mode: after the switch gesture is let go, the hand has this long to settle, and
        /// where it is then becomes neutral. Uncrossing the fingers can't scroll.
        var neutralSettle: TimeInterval = 0.3
        /// Knuckle travel from neutral, in frame units, that scrolls nothing. A resting hand wobbles
        /// about 0.001; a relaxed wrist rock covers about 0.1. Tipping the fingers toward or away
        /// from the camera both lower the knuckles in the picture, so a rock scrolls both ways only
        /// from a neutral that is already tipped forward a little.
        var scrollDeadZone: CGFloat = 0.02
        /// A held scroll trigger (fist, two fingers) works as a lever too: where the knuckles were
        /// when it engaged is neutral, and holding them above or below it scrolls at a steady rate.
        /// Off, the page follows the hand's travel instead and a flick can coast.
        var scrollLever: Bool

        init(_ settings: Settings = Settings()) {
            pinchEngage = CGFloat(settings.pinchEngage)
            pinchRelease = CGFloat(settings.pinchRelease)
            pinchDeadZone = CGFloat(settings.pinchDeadZone)
            mainHand = settings.mainHand
            requireReadyPose = settings.requireReadyPose
            dwellClick = settings.dwellClick
            dwellTime = settings.dwellTime
            dwellRadius = CGFloat(settings.dwellRadius)
            mirrored = settings.mirrored
            scrollLever = settings.scrollStyle == .lever
        }
    }

    var config: Config
    var map: GestureMap

    private(set) var mode: Mode = .idle
    private(set) var isPaused = false
    private var active: Trigger?
    /// Whether a trigger (pinch, fist, two fingers, both hands) is held right now.
    var isHoldingTrigger: Bool { active != nil }
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
    /// Recent knuckle positions while in the two-finger pose, oldest first.
    private var swipeTrail: [(time: TimeInterval, point: CGPoint)] = []
    /// Blocks the return stroke until the hand rests or the pose ends.
    private var swipeFired = false
    /// The two-finger pose, debounced (see trackTwoFingerPose).
    private var twoFingersHeld = false
    private var posedFrames = 0
    private var unposedFrames = 0
    /// The pinch that's closed this frame and when it closed, whether or not it engaged.
    private var pinchSince: (trigger: Trigger, time: TimeInterval)?
    /// Fingertips seen clear of the thumb since the last trigger started or ended. Only these can
    /// pinch: opening a fist, or letting go of one pinch, swings fingertips past the thumb, and in
    /// recorded logs that clicked. Full to begin with, so a hand that arrives pinched still works.
    private var openedFingers: Set<HandJoint> = Set(Trigger.pinches.compactMap(\.fingertip))
    /// Frames in a row that the held pinch's own fingertip has read as open (see isEngaged).
    private var neighbourFrames = 0
    /// Since when a click has sat half open without dragging, and whether that's long enough to
    /// let go (see trackHalfOpen).
    private var halfOpenSince: TimeInterval?
    private var clickOpened = false
    /// Index and middle crossed this frame (with hysteresis), and since when.
    private var crossed = false
    private var crossedSince: TimeInterval?
    /// Frames in a row a held cross has read uncrossed or unreadable (see trackCrossed), the time
    /// those frames have taken since the cross formed, and when the cross was last tracked.
    private var uncrossedFrames = 0
    private var crossDropped: TimeInterval = 0
    private var lastCrossTime: TimeInterval?
    /// When the pointing sign formed with a readable direction, while it holds.
    private var pointingSince: TimeInterval?
    private(set) var inScrollMode = false
    /// In scroll mode: the trigger that switched in, still held. It must be let go and made again
    /// to switch back, like the pause trigger.
    private var switchHeld: Trigger?
    /// The resting knuckle height scroll mode measures from. It follows the hand until `lockedAt`.
    private var neutral: (y: CGFloat, lockedAt: TimeInterval)?
    /// In scroll mode: when the hand closed into a fist, while it stays one (see scrollModeUpdate).
    private var fistSince: TimeInterval?
    /// Consecutive frames needed to start or end the two-finger pose.
    static let poseFrames = 3

    init(config: Config = Config(), map: GestureMap = .standard) {
        self.config = config
        self.map = map
    }

    /// Swaps the bindings without touching control or pause state (switching apps shouldn't make
    /// you take control again). Anything held under the old bindings is let go first; the returned
    /// actions release it.
    mutating func replaceMap(_ newMap: GestureMap) -> [Action] {
        guard newMap != map else { return [] }
        let released = deactivate(at: -1, asClick: false)
        // A pause pinch still held across the swap keeps blocking resume, as long as it still pauses.
        if let held = pauseHeld, newMap[held] != .pauseTracking { pauseHeld = nil }
        if let held = switchHeld, newMap[held] != .scrollMode { switchHeld = nil }
        resetSwipe()
        map = newMap
        return released
    }

    /// Back to a clean start: no control, not paused, nothing held.
    mutating func reset() {
        self = GestureRecognizer(config: config, map: map)
    }

    /// Lets go of anything held, for when the real input was released behind our back (a camera
    /// stall), without giving up control or ending a pause. The returned actions mirror the release.
    mutating func releaseHeld() -> [Action] {
        resetSwipe()
        // Time kept passing during the stall; a dwell measured across it would click at once.
        dwellAnchor = nil
        dwellRearm = true
        // The hand may have moved during the stall; settle a new neutral.
        neutral = nil
        fistSince = nil
        // A trigger that is pausing or switching scroll mode, or just did, stays accounted for so the
        // stall can't flip it.
        if let held = active, map[held] == .pauseTracking || map[held] == .scrollMode { return [] }
        return deactivate(at: -1, asClick: false)
    }

    mutating func update(hands: [HandPose], at time: TimeInterval) -> Output {
        events.removeAll()
        guard let primary = Self.primaryHand(hands, prefer: config.mainHand) else {
            lostFrames += 1
            if config.requireReadyPose, hasControl, time - lastSeen > config.releaseAfter {
                hasControl = false
                events.append(.releasedControl)
            }
            // Gone long enough to give back control: back to pointing too, so the hand doesn't
            // return to a mode it forgot about.
            if inScrollMode, time - lastSeen > config.releaseAfter { leaveScrollMode() }
            if lostFrames < config.lostFrameTolerance, mode != .idle {
                // Brief dropout: hold state and the current button so a drag survives a flicker.
                return output(mode, pointer: nil, actions: [], label: label(for: mode))
            }
            return lose()
        }
        lostFrames = 0
        lastSeen = time
        trackPinch(primary, at: time)
        trackNeighbourHold(primary)
        trackHalfOpen(primary, at: time)
        trackCrossed(primary, at: time)
        trackPointing(primary, at: time)
        trackTwoFingerPose(primary)

        let other = Self.otherHand(hands, primary: primary)

        if isPaused {
            return pausedUpdate(primary: primary, other: other, at: time)
        }
        if config.requireReadyPose, !hasControl {
            return waitingUpdate(primary: primary, at: time)
        }
        if inScrollMode {
            return scrollModeUpdate(primary: primary, other: other, at: time)
        }
        return controlUpdate(primary: primary, other: other, at: time)
    }

    // MARK: Control states

    private mutating func waitingUpdate(primary: HandPose, at time: TimeInterval) -> Output {
        // Nothing may stay held while waiting for the ready pose.
        let released = deactivate(at: -1, asClick: false)
        let progress = readyProgress(primary, at: time)
        guard progress >= 1 else {
            mode = .waiting
            return output(.waiting, pointer: nil, actions: released, label: Mode.waiting.rawValue,
                          feedback: Feedback(ready: progress))
        }
        hasControl = true
        readyStart = nil
        events.append(.tookControl)
        // Don't let the hold that just took control count toward a dwell click.
        dwellRearm = true
        mode = .point
        return output(.point, pointer: primary.pointer, actions: released, label: Mode.point.rawValue,
                      feedback: Feedback(ready: 1))
    }

    private mutating func pausedUpdate(primary: HandPose, other: HandPose?, at time: TimeInterval) -> Output {
        // Bindings changed (another app's profile, or an edit) and nothing can resume any more:
        // resume now rather than leave the user stuck.
        if !Trigger.allCases.contains(where: { map[$0] == .pauseTracking }) {
            isPaused = false
            hasControl = true
            events.append(.resumed)
            dwellRearm = true
            mode = .point
            return output(.point, pointer: nil, actions: [], label: "Resumed")
        }
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
        }), heldLongEnough(trigger, at: time) {
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
        // Already in control, so turning the ready pose on later doesn't kick you out.
        if !config.requireReadyPose { hasControl = true }

        if twoFingersHeld, active == nil || active == .twoFingers {
            return twoFingerUpdate(primary: primary, other: other, posed: primary.isTwoFingerPose, at: time)
        }
        if twoFingerBound, primary.isTwoFingerPose, !crossIsForming, active == nil {
            // Keep the start of a flick while the pose is being confirmed, but don't fire yet.
            _ = detectSwipe(primary, at: time, canFire: false)
        } else {
            resetSwipe()
        }
        var actions: [Action] = []

        // Does the current trigger still hold? Pinches release through hysteresis; the others are
        // plain predicates.
        if let current = active, !isEngaged(current, primary: primary, other: other, holding: true) {
            actions += deactivate(at: time, asClick: true)
            // The fingers have to open before the next pinch. Note what's open right now, so a
            // hand that is already open can pinch again on the next frame.
            trackPinch(primary, at: time)
        }

        // Pick a new trigger, or let a higher-priority one preempt. Order: two hands, fist, then the
        // pinch whose fingertip is closest to the thumb. A preempted button is released, not clicked.
        var justActivated = false
        if let next = chooseTrigger(primary: primary, other: other, at: time), next != active {
            if active != nil { actions += deactivate(at: time, asClick: false) }
            actions += activate(next, primary: primary, other: other, at: time)
            justActivated = true
            if isPaused {
                mode = .paused
                return output(.paused, pointer: nil, actions: actions, label: "Paused: \(next.title) to resume")
            }
            if inScrollMode { return scrollModeEntered(actions: actions) }
        }

        // Motion deltas start the frame after activation, when there is a previous sample.
        if let trigger = active, !justActivated {
            actions += motion(for: trigger, primary: primary, other: other, at: time)
        }

        let action = active.map { map[$0] } ?? .none
        let pointer = pointerOutput(primary: primary, action: action)
        var feedback = Feedback(pinch: pinchFeedback(primary), scrollDirection: Self.scrollDirection(of: actions))
        if active == .indexPoint {
            feedback.point = 1
        } else if pointIsForming, let since = pointingSince {
            feedback.point = min(1, CGFloat((time - since) / config.pointHold))
        }

        if config.dwellClick, active == nil, !crossIsForming, !pointIsForming, let live = primary.pointer {
            let (dwellActions, progress) = dwell(at: live, time: time)
            actions += dwellActions
            feedback.dwell = progress
        } else {
            dwellAnchor = nil
            if active != nil { dwellRearm = true }
        }

        mode = Self.mode(for: action)
        let label = active.map { "\($0.title): \(map[$0].title)" }
            ?? (pointIsForming ? "\(Trigger.indexPoint.title): hold…" : Mode.point.rawValue)
        var out = output(mode, pointer: pointer, actions: actions, label: label, feedback: feedback)
        out.pointerFrozen = pointer != nil && frozenPointer != nil
        return out
    }

    // MARK: Two fingers

    /// Two-finger pose: the cursor holds still. Hand travel up and down drives the pose's own
    /// binding, scroll by default, and a quick sideways flick fires a swipe.
    private mutating func twoFingerUpdate(primary: HandPose, other: HandPose?, posed: Bool, at time: TimeInterval) -> Output {
        dwellAnchor = nil
        dwellRearm = true
        var actions: [Action] = []
        var justActivated = false
        if map[.twoFingers] != .none, active != .twoFingers {
            actions += activate(.twoFingers, primary: primary, other: other, at: time)
            justActivated = true
            if isPaused {
                mode = .paused
                return output(.paused, pointer: nil, actions: actions, label: "Paused: \(Trigger.twoFingers.title) to resume")
            }
            if inScrollMode { return scrollModeEntered(actions: actions) }
        }
        if posed, let swipe = detectSwipe(primary, at: time) {
            actions += tapActions(for: swipe)
            if isPaused {
                // Pausing can't leave the pose's own binding held.
                actions += deactivate(at: time, asClick: false)
                mode = .paused
                return output(.paused, pointer: nil, actions: actions, label: "Paused: \(swipe.title) to resume")
            }
            if inScrollMode {
                actions += deactivate(at: time, asClick: false)
                return scrollModeEntered(actions: actions)
            }
            mode = .swipe
            return output(.swipe, pointer: nil, actions: actions, label: swipe.title)
        }
        if active == .twoFingers, !justActivated {
            actions += motion(for: .twoFingers, primary: primary, other: other, at: time)
        }
        guard active == .twoFingers else {
            mode = .swipe
            return output(.swipe, pointer: nil, actions: actions, label: Mode.swipe.rawValue)
        }
        let action = map[.twoFingers]
        mode = Self.mode(for: action)
        return output(mode, pointer: nil, actions: actions, label: "\(Trigger.twoFingers.title): \(action.title)",
                      feedback: Feedback(scrollDirection: Self.scrollDirection(of: actions)))
    }

    /// For the cursor ring: 1 scrolling down the page, -1 up, 0 at rest or not scrolling.
    private static func scrollDirection(of actions: [Action]) -> Int {
        for action in actions {
            switch action {
            case .scrollTravel(let value), .scrollLever(let value):
                if value != 0 { return value > 0 ? 1 : -1 }
            default: break
            }
        }
        return 0
    }

    // MARK: Scroll mode

    /// The relaxed hand is a lever: knuckles above neutral scroll down the page, below it scroll
    /// up, faster the farther they go. Only the switch trigger is watched, plus a fist held for
    /// `fistExitHold` as the way out when the cross won't read; every other shape the fingers make
    /// while rocking does nothing.
    private mutating func scrollModeUpdate(primary: HandPose, other: HandPose?, at time: TimeInterval) -> Output {
        mode = .scrollMode
        dwellAnchor = nil
        dwellRearm = true
        var actions = deactivate(at: -1, asClick: false)
        let switches = Trigger.allCases.filter { map[$0] == .scrollMode }
        // Bindings changed (another app's profile, or an edit) and nothing can switch back: switch
        // back now rather than leave the user stuck.
        guard !switches.isEmpty else { return scrollModeLeft(actions: actions) }
        if Trigger.swipes.contains(where: { map[$0] == .scrollMode }), primary.isTwoFingerPose {
            if let fired = detectSwipe(primary, at: time), map[fired] == .scrollMode {
                return scrollModeLeft(actions: actions)
            }
        } else {
            resetSwipe()
        }
        var forming = false
        if let held = switchHeld {
            if !isEngaged(held, primary: primary, other: other, holding: true) {
                switchHeld = nil
                neutral = nil
            }
        } else if let trigger = switches.first(where: { isEngaged($0, primary: primary, other: other, holding: false) }) {
            if heldLongEnough(trigger, at: time) {
                // Treat the trigger as held so it doesn't switch straight back until released.
                active = trigger
                return scrollModeLeft(actions: actions)
            }
            // Making the switch gesture shouldn't scroll.
            forming = true
        }
        // A fist bound to scroll mode is a switch, handled above; any other fist held for a moment
        // leaves too, and carries on as whatever it's bound to without having to open first. It
        // must open before anything else can start, like the switch trigger. Closing the hand tips
        // the knuckles a little, so the lever waits while the fist forms.
        if primary.isFist, map[.fist] != .scrollMode {
            let since = fistSince ?? time
            fistSince = since
            if time - since >= config.fistExitHold {
                leaveScrollMode()
                actions += activate(.fist, primary: primary, other: other, at: time)
                return scrollModeLeft(actions: actions)
            }
            return output(.scrollMode, pointer: nil, actions: actions, label: "Scroll mode: hold the fist to leave")
        }
        fistSince = nil
        guard switchHeld == nil, !forming, let knuckles = primary.knuckleCenter else {
            return output(.scrollMode, pointer: nil, actions: actions, label: "Scroll mode: let go, then rest your hand")
        }
        // The hand just uncrossed its fingers; give it a moment to settle before neutral locks.
        guard let offset = leverOffset(knuckles: knuckles, settle: config.neutralSettle, at: time) else {
            return output(.scrollMode, pointer: nil, actions: actions, label: "Scroll mode: rest your hand")
        }
        actions.append(.scrollLever(offset: offset))
        let direction = Self.scrollDirection(of: actions)
        let label = ["Scroll mode: scrolling up", "Scroll mode: at rest", "Scroll mode: scrolling down"][direction + 1]
        return output(.scrollMode, pointer: nil, actions: actions, label: label,
                      feedback: Feedback(scrollDirection: direction))
    }

    /// The lever: knuckle height from neutral, less the dead zone, signed. Neutral follows the hand
    /// for `settle` seconds after the lever starts, then locks. Nil while it's settling. Positive is
    /// the hand above neutral, which ScrollPolicy turns into scrolling down the page at a rate set
    /// by the offset.
    private mutating func leverOffset(knuckles: CGPoint, settle: TimeInterval, at time: TimeInterval) -> CGFloat? {
        if neutral == nil { neutral = (knuckles.y, time + settle) }
        if let settling = neutral, time < settling.lockedAt {
            neutral = (knuckles.y, settling.lockedAt)
            return nil
        }
        let offset = knuckles.y - (neutral?.y ?? knuckles.y)
        let excess = max(0, abs(offset) - config.scrollDeadZone)
        return offset < 0 ? -excess : excess
    }

    private mutating func enterScrollMode(heldBy trigger: Trigger?) {
        inScrollMode = true
        switchHeld = trigger
        neutral = nil
        events.append(.scrollModeOn)
    }

    private mutating func leaveScrollMode() {
        guard inScrollMode else { return }
        inScrollMode = false
        switchHeld = nil
        neutral = nil
        fistSince = nil
        events.append(.scrollModeOff)
    }

    /// The output for the frame a trigger switched into scroll mode.
    private mutating func scrollModeEntered(actions: [Action]) -> Output {
        mode = .scrollMode
        return output(.scrollMode, pointer: nil, actions: actions, label: "Scroll mode: let go, then rest your hand")
    }

    private mutating func scrollModeLeft(actions: [Action]) -> Output {
        leaveScrollMode()
        dwellRearm = true
        mode = .point
        return output(.point, pointer: nil, actions: actions, label: "Pointer")
    }

    // MARK: Swipes

    /// Signed horizontal travel, rejecting vertical scrolling with a sideways component.
    /// Shared with the gesture check so its flick readings use the same direction guard.
    static func swipeTravel(from start: CGPoint, to end: CGPoint) -> CGFloat {
        let dx = end.x - start.x, dy = end.y - start.y
        return abs(dx) >= abs(dy) * 1.5 ? dx : 0
    }

    private mutating func detectSwipe(_ hand: HandPose, at time: TimeInterval, canFire: Bool = true) -> Trigger? {
        guard let point = hand.knuckleCenter else { return nil }
        swipeTrail.append((time, point))
        swipeTrail.removeAll { time - $0.time > max(config.swipeWindow, 0.3) }
        guard canFire, let first = swipeTrail.first else { return nil }
        if swipeFired {
            // A quarter second at rest rearms the gesture without lowering the fingers. A quick
            // return stroke or a single bad pose frame must not produce another swipe.
            if time - first.time >= 0.25,
               swipeTrail.allSatisfy({ $0.point.distance(to: point) < 0.008 }) {
                swipeFired = false
                swipeTrail = [(time, point)]
            }
            return nil
        }
        // Vision x grows to the camera's right. With mirroring that is the user's left.
        guard let start = swipeTrail.first(where: { time - $0.time <= config.swipeWindow }) else { return nil }
        let travel = Self.swipeTravel(from: start.point, to: point) * (config.mirrored ? -1 : 1)
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
        case .shortcut(let s): return s == GestureAction.unsetKey ? [] : [.shortcut(s)]
        case .holdKey(let s): return s == GestureAction.unsetKey ? [] : [.keyDown(s), .keyUp(s)]
        case .pauseTracking:
            isPaused = true
            events.append(.paused)
            return []
        case .scrollMode:
            enterScrollMode(heldBy: nil)
            return []
        case .switchDisplay: return [.switchDisplay(toward: nil)]
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
            .filter { map[$0] != .none && map[$0].shape != .motion
                && TriggerReading.pinchFingerClear(hand, $0.fingertip!, config: config) }
            .map { pinchDistance(hand, $0.fingertip!) }
        guard let nearest = distances.min(), config.pinchRelease > config.pinchEngage else { return 0 }
        return ((config.pinchRelease - nearest) / (config.pinchRelease - config.pinchEngage)).clamped(to: 0...1)
    }

    // MARK: Trigger detection

    /// Starting a trigger is TriggerReading's call. Holding one is decided here, with the release
    /// thresholds and the state the recognizer keeps.
    private func isEngaged(_ trigger: Trigger, primary: HandPose, other: HandPose?, holding: Bool) -> Bool {
        let canStart = { TriggerReading.of(trigger, primary: primary, other: other, config: self.config).canStart }
        switch trigger {
        case .fist:
            // The same shape starts and holds it.
            return canStart()
        case .twoHandPinch:
            guard holding else { return canStart() }
            guard let other else { return false }
            return pinchDistance(primary, .indexTip) < config.twoHandPinchRelease
                && pinchDistance(other, .indexTip) < config.twoHandPinchRelease
        case .swipeLeft, .swipeRight:
            // Swipes are momentary; they can't be "held" and can't resume a pause.
            return false
        case .twoFingers:
            return twoFingersHeld
        case .crossedFingers:
            return crossed
        case .indexPoint:
            // Starting needs a direction to act on; once held, the sign alone keeps it held, so a
            // finger drifting toward the lens doesn't drop it and fire again on the way back.
            return holding ? primary.isPointingSign : pointingSince != nil
        case .indexPinch, .middlePinch, .ringPinch, .littlePinch:
            // Only starting a pinch needs a clear view of the finger. A held one stays held.
            guard holding else { return canStart() }
            if trigger == active, clickOpened { return false }
            if pinchDistance(primary, trigger.fingertip!) < config.pinchRelease { return true }
            // Vision swaps neighbouring fingertips on a hand with the thumb across it, which made
            // the ring distance jump open for a frame while the little finger read as pinched. A
            // held middle, ring or little pinch stays held while a neighbouring tip is still at the
            // thumb. Not the index: a click must release the moment the index opens.
            return trigger != .indexPinch && neighbourFrames <= config.neighbourSwapFrames
                && Self.neighbours[trigger, default: []].contains { pinchDistance(primary, $0.fingertip!) < config.pinchRelease }
        }
    }

    /// Counts frames the held pinch's own fingertip has read as open, which is how long a
    /// neighbouring tip has been keeping it held. Runs every frame with a hand, before the hold is
    /// checked.
    private mutating func trackNeighbourHold(_ hand: HandPose) {
        guard let active, let tip = active.fingertip, pinchDistance(hand, tip) >= config.pinchRelease else {
            neighbourFrames = 0
            return
        }
        neighbourFrames += 1
    }

    /// Notes how long the click held now has sat half open: fingers past `pinchEngage` while the
    /// pointer is still pinned in the click dead zone. Runs every frame with a hand, before the
    /// hold is checked. A drag (the pointer has left the dead zone) keeps the full release.
    private mutating func trackHalfOpen(_ hand: HandPose, at time: TimeInterval) {
        guard let active, let tip = active.fingertip, frozenPointer != nil,
              pinchDistance(hand, tip) >= config.pinchEngage else {
            halfOpenSince = nil
            clickOpened = false
            return
        }
        let since = halfOpenSince ?? time
        halfOpenSince = since
        clickOpened = time - since >= config.halfOpenRelease
    }

    private static let neighbours: [Trigger: [Trigger]] = [
        .middlePinch: [.indexPinch, .ringPinch], .ringPinch: [.middlePinch, .littlePinch], .littlePinch: [.ringPinch],
    ]

    private func chooseTrigger(primary: HandPose, other: HandPose?, at time: TimeInterval) -> Trigger? {
        let bound: (Trigger) -> Bool = { self.map[$0] != .none }
        if bound(.twoHandPinch), isEngaged(.twoHandPinch, primary: primary, other: other, holding: active == .twoHandPinch) {
            return .twoHandPinch
        }
        if active == .twoHandPinch { return nil } // hold until it releases on its own
        if bound(.crossedFingers), crossed {
            // Still forming: nothing else starts, so crossing can't click or scroll on the way.
            return heldLongEnough(.crossedFingers, at: time) ? .crossedFingers : nil
        }
        if active == .crossedFingers { return nil }
        if bound(.fist), primary.isFist { return .fist }
        if active == .fist { return nil }
        if bound(.indexPoint), pointingSince != nil {
            // Forming: nothing else starts. The thumb is out, so no pinch could anyway.
            return heldLongEnough(.indexPoint, at: time) ? .indexPoint : nil
        }
        if active == .indexPoint { return nil }
        if active != nil { return nil } // a held pinch is never swapped for a sibling pinch
        guard let pinch = pinchSince?.trigger, heldLongEnough(pinch, at: time) else { return nil }
        return pinch
    }

    /// The bound pinch closed this frame: the one whose fingertip is nearest the thumb, except
    /// that on a tie (see `pinchTieMargin`) the finger further along the hand wins, unless the
    /// index is the nearest. Fingers that haven't opened since the last trigger don't count.
    private func closedPinch(_ hand: HandPose) -> Trigger? {
        // Reserve the pose from its first frame. Waiting for its debounce lets a folded thumb
        // start a ring pinch first, which then blocks scrolling for the rest of the hold.
        if (hand.isTwoFingerPose || twoFingersHeld), twoFingerBound { return nil }
        let closed = Trigger.pinches
            .filter { map[$0] != .none && openedFingers.contains($0.fingertip!) }
            .compactMap { pinch -> (Trigger, CGFloat)? in
                let reading = TriggerReading.of(pinch, primary: hand, other: nil, config: config)
                return reading.canStart ? reading.value.map { (pinch, $0) } : nil
            }
            .sorted { $0.1 < $1.1 }
        guard let nearest = closed.first else { return nil }
        if nearest.0 == .indexPinch { return .indexPinch }
        return closed.filter { $0.1 - nearest.1 <= config.pinchTieMargin }
            .max { Trigger.pinches.firstIndex(of: $0.0)! < Trigger.pinches.firstIndex(of: $1.0)! }?.0
    }

    /// Remembers when the closed pinch closed, and which fingertips have been clear of the thumb.
    /// Runs every frame with a hand, in every state, so a pinch that resumes from a pause waits
    /// just as long as one that engages.
    private mutating func trackPinch(_ hand: HandPose, at time: TimeInterval) {
        for tip in Trigger.pinches.compactMap(\.fingertip) where pinchDistance(hand, tip) > config.pinchRelease {
            openedFingers.insert(tip)
        }
        if let pinch = closedPinch(hand) {
            if pinchSince?.trigger != pinch { pinchSince = (pinch, time) }
        } else {
            pinchSince = nil
        }
    }

    /// Whether index and middle are crossed, and since when. Runs every frame with a hand, like
    /// trackPinch.
    private mutating func trackCrossed(_ hand: HandPose, at time: TimeInterval) {
        let sinceLast = lastCrossTime.map { time - $0 } ?? 0
        lastCrossTime = time
        let reads = crossed
            ? (hand.fingerCross(holding: true) ?? -.infinity) > config.crossRelease
            : TriggerReading.of(.crossedFingers, primary: hand, other: nil, config: config).canStart
        if reads {
            crossed = true
            uncrossedFrames = 0
        } else if crossed {
            // A held cross rides out a few frames of bad readings before it counts as uncrossed,
            // but they don't count as holding.
            uncrossedFrames += 1
            if uncrossedFrames > config.crossDropFrames {
                crossed = false
                uncrossedFrames = 0
            } else {
                crossDropped += sinceLast
            }
        }
        if !crossed {
            crossedSince = nil
            crossDropped = 0
        } else if crossedSince == nil {
            crossedSince = time
            crossDropped = 0
        }
    }

    /// Whether the pointing sign is up with a readable direction, and since when. Runs every frame
    /// with a hand, like trackPinch.
    private mutating func trackPointing(_ hand: HandPose, at time: TimeInterval) {
        guard pointDirection(hand) != nil else {
            pointingSince = nil
            return
        }
        if pointingSince == nil { pointingSince = time }
    }

    /// Which way the index finger points in the pointing sign, or nil when the sign can't start.
    private func pointDirection(_ hand: HandPose) -> Direction? {
        TriggerReading.of(.indexPoint, primary: hand, other: nil, config: config).direction
    }

    /// Crossed fingers that mean something. Crossed fingers also have index and middle up and the
    /// others curled, so while this holds they aren't the two-finger pose, and nothing else fires.
    private var crossIsForming: Bool { crossed && map[.crossedFingers] != .none }
    /// The pointing sign that means something, held still long enough to be a dwell otherwise.
    private var pointIsForming: Bool { pointingSince != nil && map[.indexPoint] != .none }

    /// Debounces the two-finger pose: a few frames to start and a few missing to end, so a loose
    /// hand passing through it doesn't scroll or swipe and a one-frame flicker can't fire twice.
    /// Runs in every state, so letting go of the pose while paused is noticed.
    private mutating func trackTwoFingerPose(_ hand: HandPose) {
        let posed = hand.isTwoFingerPose && !crossIsForming
        if posed { posedFrames += 1; unposedFrames = 0 } else { unposedFrames += 1; posedFrames = 0 }
        twoFingersHeld = twoFingerBound && (twoFingersHeld ? unposedFrames < Self.poseFrames : posedFrames >= Self.poseFrames)
    }

    private var twoFingerBound: Bool {
        map[.twoFingers] != .none || Trigger.swipes.contains { map[$0] != .none }
    }

    /// Whether a pinch has held `pinchHold`, or a shape its own hold. Other triggers don't wait.
    private func heldLongEnough(_ trigger: Trigger, at time: TimeInterval) -> Bool {
        if trigger == .crossedFingers {
            let hold = inScrollMode ? config.crossExitHold : config.crossHold
            return crossedSince.map { time - $0 - crossDropped >= hold } ?? false
        }
        if trigger == .indexPoint {
            return pointingSince.map { time - $0 >= config.pointHold } ?? false
        }
        guard Trigger.pinches.contains(trigger) else { return true }
        guard let since = pinchSince, since.trigger == trigger else { return false }
        return time - since.time >= config.pinchHold
    }

    private func pinchDistance(_ hand: HandPose, _ fingertip: HandJoint) -> CGFloat {
        hand.normalizedDistance(.thumbTip, fingertip) ?? .infinity
    }

    // MARK: Activation

    private mutating func activate(_ trigger: Trigger, primary: HandPose, other: HandPose?, at time: TimeInterval) -> [Action] {
        active = trigger
        lastPalmY = primary.palmCenter?.y
        lastSpread = spread(primary, other)
        // A scroll lever starts fresh from where this trigger engaged.
        neutral = nil
        // Whatever comes next, the fingers have to open first.
        openedFingers.removeAll()
        switch map[trigger] {
        case .leftButton:
            let count = (time - lastLeftUpTime) < config.doubleClickInterval ? lastClickCount + 1 : 1
            lastClickCount = count
            frozenPointer = primary.pointer
            dragOffset = .zero
            return [.leftDown(clickCount: count)]
        case .rightClick: return [.rightClick]
        case .middleClick: return [.middleClick]
        case .shortcut(let s): return s == GestureAction.unsetKey ? [] : [.shortcut(s)]
        case .holdKey(let s): return s == GestureAction.unsetKey ? [] : [.keyDown(s)]
        case .pauseTracking:
            isPaused = true
            pauseHeld = trigger
            active = nil
            events.append(.paused)
            return []
        case .scrollMode:
            enterScrollMode(heldBy: trigger)
            active = nil
            return []
        case .switchDisplay:
            return [.switchDisplay(toward: trigger == .indexPoint ? pointDirection(primary) : nil)]
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
        openedFingers.removeAll()
        neighbourFrames = 0
        halfOpenSince = nil
        clickOpened = false
        switch map[trigger] {
        case .leftButton:
            lastLeftUpTime = asClick ? time : -1
            return [.leftUp(clickCount: lastClickCount)]
        case .holdKey(let s):
            return s == GestureAction.unsetKey ? [] : [.keyUp(s)]
        default:
            return []
        }
    }

    private mutating func motion(for trigger: Trigger, primary: HandPose, other: HandPose?, at time: TimeInterval) -> [Action] {
        switch map[trigger] {
        case .scroll:
            if config.scrollLever {
                // Curling the fingers doesn't move the knuckles, so neutral can lock at once.
                guard let knuckles = primary.knuckleCenter,
                      let offset = leverOffset(knuckles: knuckles, settle: 0, at: time) else { return [] }
                return [.scrollLever(offset: offset)]
            }
            guard let y = primary.palmCenter?.y else { return [] }
            defer { lastPalmY = y }
            guard let previous = lastPalmY else { return [] }
            return [.scrollTravel(dy: y - previous)]
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
        pinchSince = nil
        twoFingersHeld = false
        posedFrames = 0
        unposedFrames = 0
        resetSwipe()
        readyStart = nil
        dwellAnchor = nil
        crossed = false
        crossedSince = nil
        uncrossedFrames = 0
        crossDropped = 0
        lastCrossTime = nil
        pointingSince = nil
        // switchHeld survives: a hand that comes back still crossed mustn't switch straight back out.
        neutral = nil
        fistSince = nil
        mode = .idle
        return output(.idle, pointer: nil, actions: actions, label: isPaused ? "Paused" : Mode.idle.rawValue)
    }

    private func label(for mode: Mode) -> String { mode.rawValue }

    private func output(_ mode: Mode, pointer: CGPoint?, actions: [Action], label: String,
                        feedback: Feedback = Feedback()) -> Output {
        Output(mode: mode, pointer: pointer, actions: actions, label: label, events: events, feedback: feedback,
               trigger: active ?? switchHeld ?? (pointIsForming ? .indexPoint : nil))
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

    /// The second hand, for the two-hand pinch: one Vision says is the other hand if there is one.
    static func otherHand(_ hands: [HandPose], primary: HandPose) -> HandPose? {
        guard hands.count >= 2 else { return nil }
        return hands.first { $0 != primary && $0.chirality != primary.chirality } ?? hands.first { $0 != primary }
    }
}
