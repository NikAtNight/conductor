import CoreGraphics
import Foundation

/// What the pipeline asks the Engine to post. Plain data, so tests read the list instead of
/// watching CGEvents.
enum InputCommand: Equatable {
    case move(CGPoint)
    case leftDown(clickCount: Int)
    case leftUp(clickCount: Int)
    case rightClick
    case middleClick
    case keyPress(CGKeyCode, flags: CGEventFlags)
    case keyDown(Shortcut)
    case keyUp(Shortcut)
    case scroll(dy: Int32, flags: CGEventFlags)
    /// Let go of every button and key, whatever the pipeline believes is held.
    case releaseAll

    var isClick: Bool {
        switch self {
        case .leftDown, .rightClick, .middleClick: return true
        default: return false
        }
    }
}

/// Everything that happens to one camera frame after hand detection: recognition, smoothing,
/// pointer mapping, scrolling and zooming, and whether input may be posted at all. Hands and a
/// time go in, cursor and input commands come out. No queue, no clock, no CGEvent, so tests drive
/// it frame by frame with the production configuration.
struct FramePipeline {
    struct Output {
        var recognized: GestureRecognizer.Output
        /// Where the cursor was aimed this frame, posted or not.
        var cursor: CGPoint?
        var commands: [InputCommand]
    }

    /// The control box in view space (see ControlBox), for the preview and hand map.
    private(set) var box = CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.5)

    private var recognizer = GestureRecognizer()
    private var filter = PointFilter()
    private var relative = RelativePointer()
    private var precision = PrecisionPointer()
    private var scroll = ScrollPolicy()
    private var prefs: Settings
    private var displays: [CGRect] = []
    /// Display UUID to bounds, for the LookPicker's picks. Only used in look mode.
    private var lookDisplays: [String: CGRect] = [:]
    /// Alive only in look mode with a calibrated model; see apply.
    private var lookPicker: LookPicker?
    /// The rectangle the control box maps onto.
    private(set) var screen: CGRect = .zero
    private var cameraMount: (x: CGFloat, display: CGRect) = (0, .zero)
    private var inputAllowed = false
    private var wasIdle = true
    private var lastPosted: CGPoint?
    private var relativeCursor: CGPoint = .zero
    /// Where the cursor stays while a click's dead zone pins the pointer (see step).
    private var heldCursor: CGPoint?
    /// For the rest of a drag: how far the held spot sat from where the smoothing had got to when
    /// the hand left the dead zone, so the drag starts from the held spot instead of jumping.
    private var dragShift = CGVector.zero
    /// Hand scales from recent open-hand frames, for sizing the box to how far away the user sits.
    private var openHandScales: [CGFloat] = []
    /// The automatic box's size relative to the settings, from those scales; see measureReach.
    private var reach: CGFloat = 1
    private var zoomAccumulator: CGFloat = 0

    /// Speed coefficient for the One Euro filter in normalized units. At 20, a hand crossing the
    /// frame in a second raises the cutoff by about 20 Hz; resting tremor (~0.02/s) adds under
    /// 0.5 Hz. Replaying Nikhil's logs, 8 trailed a moving hand by about 45 ms (75 ms at the 90th
    /// percentile) and the cursor felt behind; 20 trails by about 30 ms (50 ms) and moves the cursor
    /// about 30% more unevenly frame to frame while moving. A still hand barely changes.
    static let filterBeta = 20.0
    /// Don't post moves smaller than this. Sub-pixel updates at 30 fps read as shimmer.
    static let minimumMovePixels: CGFloat = 2
    /// Hand scale (wrist to index knuckle, frame units) at which the automatic box is the size the
    /// settings say. Nikhil's hand measures about this at his usual distance. Sitting back makes the
    /// hand look smaller, and a box that stayed the same fraction of the frame then needed a longer
    /// reach: at 0.16 it was half as far again. The box shrinks and grows with the hand instead.
    static let referenceHandScale: CGFloat = 0.24
    /// How far the box may shrink or grow with distance.
    static let reachRange: ClosedRange<CGFloat> = 0.5...1.5
    /// Open-hand frames that measure the hand.
    static let reachSamples = 15
    static let zoomPixelsPerFrame: CGFloat = 1500
    /// Hands must spread or close this far (normalized) to fire one cmd+= / cmd+- press.
    static let zoomKeyStep: CGFloat = 0.04

    init(_ snapshot: Settings) {
        prefs = snapshot
        filter = PointFilter(minCutoff: snapshot.smoothing, beta: Self.filterBeta)
    }

    // MARK: Configuration

    /// Takes new settings. Rebinding mid-gesture could orphan a held button, so the returned
    /// commands let go of anything the old bindings held.
    mutating func apply(_ snapshot: Settings, map: GestureMap, displays: [CGRect],
                        cameraMount: (x: CGFloat, display: CGRect)?,
                        lookDisplays: [String: CGRect] = [:]) -> [InputCommand] {
        if snapshot.smoothing != prefs.smoothing {
            filter = PointFilter(minCutoff: snapshot.smoothing, beta: Self.filterBeta)
        }
        prefs = snapshot
        self.displays = displays
        self.lookDisplays = lookDisplays
        // The picker keeps its dwell state across unrelated settings changes; a new model starts over.
        if snapshot.displayMode == .lookedAt, let model = snapshot.lookModel {
            if lookPicker?.model != model { lookPicker = LookPicker(model: model) }
        } else {
            lookPicker = nil
        }
        screen = Self.targetScreen(mode: snapshot.displayMode, displays: displays, current: screen)
        if let cameraMount { self.cameraMount = cameraMount }
        relayoutBox()
        var commands: [InputCommand] = []
        for action in recognizer.replaceMap(map) { commands += self.commands(for: action) }
        recognizer.config = GestureRecognizer.Config(snapshot)
        relative.speed = CGFloat(snapshot.trackpadSpeed)
        relative.mirrored = snapshot.mirrored
        precision.slowGain = CGFloat(snapshot.slowMoveSpeed)
        scroll.apply(gain: CGFloat(snapshot.scrollGain), momentum: snapshot.momentumScroll)
        return commands
    }

    /// Whether input may be posted (the Accessibility grant). Losing it lets go of everything held,
    /// since the release events would otherwise be dropped too.
    mutating func setInputAllowed(_ allowed: Bool) -> [InputCommand] {
        defer { inputAllowed = allowed }
        return inputAllowed && !allowed ? releaseHeld() : []
    }

    /// Lets go of everything held without giving up control: the camera stalled, calibration is
    /// starting, or tracking is stopping.
    mutating func releaseHeld() -> [InputCommand] {
        var commands: [InputCommand] = []
        for action in recognizer.releaseHeld() { commands += self.commands(for: action) }
        scroll.stop()
        commands.append(.releaseAll)
        return commands
    }

    /// Back to a clean start: no control, not paused, nothing held, no stale motion samples.
    mutating func reset() {
        recognizer.reset()
        scroll.stop()
        zoomAccumulator = 0
        filter.reset()
        relative.reset()
        precision.reset()
        wasIdle = true
        lastPosted = nil
        heldCursor = nil
        dragShift = .zero
    }

    // MARK: Frames

    /// One frame. `face` matters only in look mode. `cursorLocation` is asked for the real cursor
    /// only when the pipeline needs it.
    mutating func step(hands: [HandPose], face: FacePose? = nil, at time: TimeInterval,
                       cursorLocation: () -> CGPoint?) -> Output {
        if lookPicker != nil { followLook(face, at: time) }
        // On reacquiring the hand, follow-cursor mode re-targets the display the cursor is on.
        if !hands.isEmpty, wasIdle, prefs.displayMode == .followCursor, displays.count > 1 {
            let next = Self.targetScreen(mode: .followCursor, displays: displays, current: screen, cursor: cursorLocation())
            if next != screen {
                screen = next
                relayoutBox()
            }
        }
        let reacquired = wasIdle && !hands.isEmpty
        let recognized = recognizer.update(hands: hands, at: time)
        wasIdle = recognized.mode == .idle
        measureReach(hands, recognized: recognized, reacquired: reacquired)
        // Before the pointer maps, so this frame's cursor already lands on the new display.
        if inputAllowed {
            for case .switchDisplay(let direction) in recognized.actions { switchDisplay(toward: direction) }
        }
        var commands: [InputCommand] = []
        var cursor: CGPoint?
        if let pointer = recognized.pointer {
            // Filter in normalized frame space, not pixels. The speed term in One Euro is tuned for
            // units where a fast hand moves about 1.0 per second; in pixels even tremor is hundreds
            // per second and the filter opens all the way up, which is exactly the jitter it exists
            // to remove.
            let smoothed = filter.filter(pointer, at: time)
            var target: CGPoint
            if prefs.pointerMode == .relative {
                if let delta = relative.delta(for: smoothed, at: time, screenWidth: screen.width) {
                    relativeCursor.x += delta.dx
                    relativeCursor.y += delta.dy
                } else {
                    // First frame after the hand (re)appears: start from wherever the cursor is.
                    relativeCursor = cursorLocation() ?? relativeCursor
                }
                relativeCursor = DisplayLayout.snap(relativeCursor, to: displays)
                target = relativeCursor
            } else {
                let mapper = ScreenMapper(box: box, mirrored: prefs.mirrored, screen: screen)
                target = DisplayLayout.snap(precision.position(for: smoothed, at: time, mapper: mapper), to: displays)
            }
            target = holdForClick(target, recognized: recognized)
            cursor = target
            if inputAllowed, lastPosted.map({ target.distance(to: $0) >= Self.minimumMovePixels }) ?? true {
                commands.append(.move(target))
                lastPosted = target
            }
        } else {
            filter.reset()
            relative.reset()
            precision.reset()
        }

        if recognized.mode != .zoom { zoomAccumulator = 0 }
        guard inputAllowed else {
            scroll.stop()
            return Output(recognized: recognized, cursor: cursor, commands: commands)
        }
        for action in recognized.actions { commands += self.commands(for: action) }
        // The recognizer reports .idle while paused once the hand is gone, so the pause goes in too.
        if let dy = scroll.pixels(for: recognized, paused: recognizer.isPaused, at: time) {
            commands.append(.scroll(dy: dy, flags: []))
        }
        return Output(recognized: recognized, cursor: cursor, commands: commands)
    }

    /// The click dead zone, for the cursor. The recognizer pins the pointer when a button goes
    /// down, but smoothing still trails the hand, so the cursor used to creep on toward it by 10 to
    /// 12 px after the press and every click became a small drag. Instead the cursor holds where it
    /// was last sent. If the hand then leaves the dead zone the drag carries on from there, shifted
    /// by whatever the smoothing still owed. The frame the button comes up keeps the same rule, since
    /// its move is posted before the release and would otherwise drag too.
    private mutating func holdForClick(_ target: CGPoint, recognized: GestureRecognizer.Output) -> CGPoint {
        let releasing = recognized.actions.contains { if case .leftUp = $0 { return true } else { return false } }
        guard recognized.mode == .drag || releasing else {
            heldCursor = nil
            dragShift = .zero
            return target
        }
        if recognized.pointerFrozen || (releasing && heldCursor != nil) {
            let held = heldCursor ?? lastPosted ?? target
            heldCursor = releasing ? nil : held
            return held
        }
        if let held = heldCursor {
            dragShift = CGVector(dx: held.x - target.x, dy: held.y - target.y)
            heldCursor = nil
        }
        let shifted = DisplayLayout.snap(CGPoint(x: target.x + dragShift.dx, y: target.y + dragShift.dy), to: displays)
        if releasing { dragShift = .zero }
        return shifted
    }

    /// Sizes the automatic box to the user's distance from the camera, by how big the open hand
    /// looks. Measured from recent open-hand frames, since a curled or tilted hand looks shorter,
    /// and applied only when control is taken (or, without the ready pose, when the hand comes
    /// back), so the box never changes size under a hand that's using it.
    private mutating func measureReach(_ hands: [HandPose], recognized: GestureRecognizer.Output, reacquired: Bool) {
        if let hand = GestureRecognizer.primaryHand(hands, prefer: prefs.mainHand), hand.isOpenHand, let scale = hand.scale {
            openHandScales.append(scale)
            if openHandScales.count > Self.reachSamples { openHandScales.removeFirst() }
        }
        let tookControl = recognized.events.contains(.tookControl) || (!prefs.requireReadyPose && reacquired)
        guard tookControl, openHandScales.count >= Self.reachSamples / 3 else { return }
        let median = openHandScales.sorted()[openHandScales.count / 2]
        let next = (median / Self.referenceHandScale).clamped(to: Self.reachRange)
        guard next != reach else { return }
        reach = next
        relayoutBox()
        // The next absolute sample lands where the hand maps in the resized box.
        precision.reset()
    }

    private mutating func commands(for action: GestureRecognizer.Action) -> [InputCommand] {
        switch action {
        case .leftDown(let count): return [.leftDown(clickCount: count)]
        case .leftUp(let count): return [.leftUp(clickCount: count)]
        case .rightClick: return [.rightClick]
        case .middleClick: return [.middleClick]
        case .shortcut(let s): return [.keyPress(CGKeyCode(s.keyCode), flags: s.flags)]
        case .keyDown(let s): return [.keyDown(s)]
        case .keyUp(let s): return [.keyUp(s)]
        case .scrollTravel, .scrollLever: return [] // ScrollPolicy turns these into pixels
        case .switchDisplay: return [] // step moves the target; nothing to post
        case .zoom(let delta):
            guard prefs.zoomWithKeys else {
                // Cmd+scroll zooms in browsers, Preview, Maps and most editors. Spreading the hands
                // is a positive delta, and scrolling up (positive wheel) zooms in.
                return [.scroll(dy: Int32((delta * Self.zoomPixelsPerFrame).rounded()), flags: .maskCommand)]
            }
            var commands: [InputCommand] = []
            zoomAccumulator += delta
            while zoomAccumulator >= Self.zoomKeyStep {
                commands.append(.keyPress(KeyCodes.equals, flags: .maskCommand))
                zoomAccumulator -= Self.zoomKeyStep
            }
            while zoomAccumulator <= -Self.zoomKeyStep {
                commands.append(.keyPress(KeyCodes.minus, flags: .maskCommand))
                zoomAccumulator += Self.zoomKeyStep
            }
            return commands
        }
    }

    // MARK: Screen and box

    /// Look mode: moves the target to the display the head points at. A switch mid-drag would carry
    /// the held button across screens, so the picker waits while a trigger is held.
    private mutating func followLook(_ face: FacePose?, at time: TimeInterval) {
        let locked = [.drag, .scroll, .scrollMode, .zoom].contains(recognizer.mode) || recognizer.isHoldingTrigger
        guard let uuid = lookPicker?.update(face, at: time, locked: locked),
              let next = lookDisplays[uuid], next != screen else { return }
        moveTarget(to: next)
    }

    /// The Switch display action. A pointed direction picks the nearest display that way; with no
    /// direction, or nothing there, the next display top to bottom, then left to right, wrapping
    /// around. Only the modes that target one display; in look mode the picker is told, so the
    /// head doesn't switch straight back.
    private mutating func switchDisplay(toward direction: Direction?) {
        guard prefs.displayMode == .lookedAt || prefs.displayMode == .followCursor else { return }
        let ordered = displays.sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
        guard ordered.count > 1 else { return }
        let next = direction.flatMap { Self.display(from: screen, toward: $0, in: displays) }
            ?? ordered[(ordered.firstIndex(of: screen).map { $0 + 1 } ?? 0) % ordered.count]
        if prefs.displayMode == .lookedAt, let uuid = lookDisplays.first(where: { $0.value == next })?.key {
            lookPicker?.override(to: uuid)
        }
        moveTarget(to: next)
    }

    /// The nearest other display whose centre lies in `direction` from `current`'s centre, judged
    /// by the larger axis. Screen coordinates: y grows downward.
    static func display(from current: CGRect, toward direction: Direction, in displays: [CGRect]) -> CGRect? {
        func offset(_ other: CGRect) -> (dx: CGFloat, dy: CGFloat) { (other.midX - current.midX, other.midY - current.midY) }
        return displays.filter { $0 != current }.filter { other in
            let (dx, dy) = offset(other)
            switch direction {
            case .up: return dy < 0 && abs(dy) >= abs(dx)
            case .down: return dy > 0 && abs(dy) >= abs(dx)
            case .left: return dx < 0 && abs(dx) > abs(dy)
            case .right: return dx > 0 && abs(dx) > abs(dy)
            }
        }.min { a, b in
            let (ax, ay) = offset(a), (bx, by) = offset(b)
            return ax * ax + ay * ay < bx * bx + by * by
        }
    }

    /// Retargets mid-session, keeping the cursor's place.
    private mutating func moveTarget(to next: CGRect) {
        if prefs.pointerMode == .relative, screen.width > 0, screen.height > 0 {
            // Same fractional spot on the new screen, so the cursor arrives rather than jumps to a corner.
            relativeCursor = CGPoint(
                x: next.minX + (relativeCursor.x - screen.minX) / screen.width * next.width,
                y: next.minY + (relativeCursor.y - screen.minY) / screen.height * next.height)
        }
        screen = next
        relayoutBox()
        // The next absolute sample lands exactly where the hand maps on the new display.
        precision.reset()
    }

    /// Recomputes the control box for the current target and camera.
    private mutating func relayoutBox() {
        if let calibrated = prefs.calibratedBox {
            // Stored in Vision space so it survives a change to the mirror setting.
            box = ScreenMapper.visionRect(forViewBox: calibrated, mirrored: prefs.mirrored)
            return
        }
        // The layout shifts the box toward the target so a hand reaching for a screen lands on it.
        // In look mode the head already chose the screen, so the hand shouldn't have to reach: lay
        // the box out as if the camera sat centred on the target, which keeps it at rest height
        // and centred no matter which display is picked.
        let looking = lookPicker != nil
        box = ControlBox.layout(ControlBox.Input(
            width: prefs.boxWidth * reach, height: prefs.boxHeight * reach, offsetY: prefs.boxOffsetY,
            matchShape: prefs.matchScreenShape, target: screen,
            cameraX: looking ? screen.midX : cameraMount.x,
            cameraDisplay: looking ? screen : cameraMount.display))
    }

    /// Which rectangle the control box maps onto. `current` is kept in follow-cursor mode until the
    /// hand is lost and found again, so the target doesn't hop mid-gesture.
    static func targetScreen(mode: Settings.DisplayMode, displays: [CGRect], current: CGRect,
                             cursor: CGPoint? = nil) -> CGRect {
        guard !displays.isEmpty else { return current }
        switch mode {
        case .all:
            return displays.dropFirst().reduce(displays[0]) { $0.union($1) }
        case .main:
            return displays.first { $0.origin == .zero } ?? displays[0]
        case .followCursor:
            guard let cursor else { return displays.contains(current) ? current : displays[0] }
            return displays.first { $0.contains(cursor) } ?? displays[0]
        case .lookedAt:
            // The LookPicker moves the target as the head turns; until it has seen a face, stay.
            return displays.contains(current) ? current : displays[0]
        }
    }
}
