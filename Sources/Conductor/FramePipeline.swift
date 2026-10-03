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
    private var prefs: Preferences.Snapshot
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
    private var lastPosted = CGPoint(x: -1, y: -1)
    private var relativeCursor: CGPoint = .zero
    private var zoomAccumulator: CGFloat = 0

    /// Speed coefficient for the One Euro filter in normalized units. At 8, a hand crossing the
    /// frame in a second raises the cutoff by about 8 Hz; resting tremor (~0.1/s) adds under 1 Hz.
    static let filterBeta = 8.0
    /// Don't post moves smaller than this. Sub-pixel updates at 30 fps read as shimmer.
    static let minimumMovePixels: CGFloat = 2
    static let zoomPixelsPerFrame: CGFloat = 1500
    /// Hands must spread or close this far (normalized) to fire one cmd+= / cmd+- press.
    static let zoomKeyStep: CGFloat = 0.04

    init(_ snapshot: Preferences.Snapshot) {
        prefs = snapshot
        filter = PointFilter(minCutoff: snapshot.smoothing, beta: Self.filterBeta)
    }

    // MARK: Configuration

    /// Takes new settings. Rebinding mid-gesture could orphan a held button, so the returned
    /// commands let go of anything the old bindings held.
    mutating func apply(_ snapshot: Preferences.Snapshot, map: GestureMap, displays: [CGRect],
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
        recognizer.config.pinchEngage = snapshot.pinchEngage
        recognizer.config.pinchRelease = snapshot.pinchRelease
        recognizer.config.mainHand = snapshot.mainHand
        recognizer.config.requireReadyPose = snapshot.requireReadyPose
        recognizer.config.dwellClick = snapshot.dwellClick
        recognizer.config.dwellTime = snapshot.dwellTime
        recognizer.config.dwellRadius = CGFloat(snapshot.dwellRadius)
        recognizer.config.pinchDeadZone = CGFloat(snapshot.pinchDeadZone)
        recognizer.config.mirrored = snapshot.mirrored
        relative.speed = CGFloat(snapshot.trackpadSpeed)
        relative.mirrored = snapshot.mirrored
        precision.slowGain = CGFloat(snapshot.slowMoveSpeed)
        scroll.gain = CGFloat(snapshot.scrollGain)
        scroll.momentum = snapshot.momentumScroll
        if !snapshot.momentumScroll { scroll.stop() }
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
        lastPosted = CGPoint(x: -1, y: -1)
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
        let recognized = recognizer.update(hands: hands, at: time)
        wasIdle = recognized.mode == .idle
        var commands: [InputCommand] = []
        var cursor: CGPoint?
        if let pointer = recognized.pointer {
            // Filter in normalized frame space, not pixels. The speed term in One Euro is tuned for
            // units where a fast hand moves about 1.0 per second; in pixels even tremor is hundreds
            // per second and the filter opens all the way up, which is exactly the jitter it exists
            // to remove.
            let smoothed = filter.filter(pointer, at: time)
            let target: CGPoint
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
            cursor = target
            if inputAllowed, target.distance(to: lastPosted) >= Self.minimumMovePixels {
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
        var travel: CGFloat?
        for action in recognized.actions {
            if case .scroll(let dy) = action { travel = (travel ?? 0) + dy }
            commands += self.commands(for: action)
        }
        // Momentum: a scroll that ends mid-flick keeps going and slows down. A click, a new gesture,
        // or a pause stops it.
        let interrupted = recognized.actions.contains(where: \.interruptsScrolling)
            || recognized.mode == .drag || recognized.mode == .zoom || recognized.mode == .paused || recognizer.isPaused
        if let dy = scroll.pixels(travel: travel, scrolling: recognized.mode == .scroll, interrupted: interrupted, at: time) {
            commands.append(.scroll(dy: dy, flags: []))
        }
        return Output(recognized: recognized, cursor: cursor, commands: commands)
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
        case .scroll: return [] // ScrollPolicy turns travel into pixels
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
        let locked = [.drag, .scroll, .zoom].contains(recognizer.mode) || recognizer.isHoldingTrigger
        guard let uuid = lookPicker?.update(face, at: time, locked: locked),
              let next = lookDisplays[uuid], next != screen else { return }
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
            width: prefs.boxWidth, height: prefs.boxHeight, offsetY: prefs.boxOffsetY,
            matchShape: prefs.matchScreenShape, target: screen,
            cameraX: looking ? screen.midX : cameraMount.x,
            cameraDisplay: looking ? screen : cameraMount.display))
    }

    /// Which rectangle the control box maps onto. `current` is kept in follow-cursor mode until the
    /// hand is lost and found again, so the target doesn't hop mid-gesture.
    static func targetScreen(mode: Preferences.DisplayMode, displays: [CGRect], current: CGRect,
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

extension GestureRecognizer.Action {
    /// Whether this action ends a coasting scroll.
    var interruptsScrolling: Bool {
        switch self {
        case .leftDown, .rightClick, .middleClick, .shortcut, .zoom: return true
        case .leftUp, .keyDown, .keyUp, .scroll: return false
        }
    }
}
