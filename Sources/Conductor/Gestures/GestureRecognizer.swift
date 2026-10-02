import CoreGraphics
import Foundation

/// Turns a stream of hand poses into input actions. Pure logic, no camera or CGEvent, so the whole
/// thing is unit tested with synthesized hands. Coordinates in and out are normalized frame space.
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
        /// Vertical palm travel since the last frame, normalized frame units. Positive is up.
        case scroll(dy: CGFloat)
        /// Change in distance between the two pinching hands, normalized frame units. Positive spreads.
        case zoom(delta: CGFloat)
    }

    struct Output {
        var mode: Mode
        /// Where the cursor should be, or nil to leave it alone.
        var pointer: CGPoint?
        var actions: [Action]
    }

    struct Config {
        /// Thumb-to-index distance (in hand scales) below which a pinch engages.
        var pinchEngage: CGFloat = 0.35
        /// Distance above which it releases. Must exceed `pinchEngage` to give hysteresis.
        var pinchRelease: CGFloat = 0.55
        /// Two pinches this close together, in seconds, count as a double click.
        var doubleClickInterval: TimeInterval = 0.4
        /// Pointer stays frozen after pinch start until the hand moves this far (frame units).
        var pinchDeadZone: CGFloat = 0.012
        /// Frames of missing hand tolerated before buttons are released.
        var lostFrameTolerance: Int = 4
    }

    var config: Config

    private(set) var mode: Mode = .idle
    private var indexPinched = false
    private var middlePinched = false
    private var lastLeftUpTime: TimeInterval = -1
    private var lastClickCount = 1
    private var frozenPointer: CGPoint?
    private var dragOffset: CGPoint = .zero
    private var lastPalmY: CGFloat?
    private var lastZoomDistance: CGFloat?
    private var lostFrames = 0

    init(config: Config = Config()) {
        self.config = config
    }

    mutating func update(hands: [HandPose], at time: TimeInterval) -> Output {
        guard let primary = Self.primaryHand(hands) else {
            lostFrames += 1
            if lostFrames < config.lostFrameTolerance, mode != .idle {
                // Brief dropout: hold state and the current button so a drag survives a flicker.
                return Output(mode: mode, pointer: nil, actions: [])
            }
            return lose()
        }
        lostFrames = 0

        // Two pinched hands means zoom, and takes priority over everything else.
        if hands.count >= 2, let other = hands.first(where: { $0.chirality != primary.chirality }) ?? hands.dropFirst().first,
           isPinching(primary, engaged: indexPinched), isPinching(other, engaged: mode == .zoom),
           let a = primary.pointer, let b = other.pointer {
            var actions = releaseLeftIfNeeded()
            let distance = a.distance(to: b)
            if mode == .zoom, let previous = lastZoomDistance {
                actions.append(.zoom(delta: distance - previous))
            }
            lastZoomDistance = distance
            lastPalmY = nil
            mode = .zoom
            return Output(mode: .zoom, pointer: nil, actions: actions)
        }
        lastZoomDistance = nil

        if primary.isFist, let palm = primary.palmCenter {
            var actions = releaseLeftIfNeeded()
            if mode == .scroll, let previous = lastPalmY {
                actions.append(.scroll(dy: palm.y - previous))
            }
            lastPalmY = palm.y
            mode = .scroll
            return Output(mode: .scroll, pointer: nil, actions: actions)
        }
        lastPalmY = nil

        guard let livePointer = primary.pointer else {
            return Output(mode: mode, pointer: nil, actions: [])
        }

        var actions: [Action] = []

        // Right click on the thumb/middle pinch edge. Suppressed while the index pinch is held
        // because the middle finger drifts toward the thumb during a drag.
        let middleDistance = primary.normalizedDistance(.thumbTip, .middleTip) ?? .infinity
        if !indexPinched {
            if !middlePinched, middleDistance < config.pinchEngage {
                middlePinched = true
                actions.append(.rightClick)
            } else if middlePinched, middleDistance > config.pinchRelease {
                middlePinched = false
            }
        }

        let indexDistance = primary.normalizedDistance(.thumbTip, .indexTip) ?? .infinity
        if !indexPinched, !middlePinched, indexDistance < config.pinchEngage {
            indexPinched = true
            let count = (time - lastLeftUpTime) < config.doubleClickInterval ? lastClickCount + 1 : 1
            lastClickCount = count
            frozenPointer = livePointer
            dragOffset = .zero
            actions.append(.leftDown(clickCount: count))
        } else if indexPinched, indexDistance > config.pinchRelease {
            indexPinched = false
            lastLeftUpTime = time
            frozenPointer = nil
            dragOffset = .zero
            actions.append(.leftUp(clickCount: lastClickCount))
        }

        var pointer = livePointer
        if indexPinched {
            if let frozen = frozenPointer, livePointer.distance(to: frozen) < config.pinchDeadZone {
                pointer = frozen
            } else {
                if let frozen = frozenPointer {
                    // Hand escaped the dead zone: start dragging from where the cursor sat, not
                    // from where the hand is now, so there is no visible jump.
                    dragOffset = CGPoint(x: frozen.x - livePointer.x, y: frozen.y - livePointer.y)
                    frozenPointer = nil
                }
                pointer = CGPoint(x: livePointer.x + dragOffset.x, y: livePointer.y + dragOffset.y)
            }
        }

        mode = indexPinched ? .drag : .point
        return Output(mode: mode, pointer: pointer, actions: actions)
    }

    /// Hand disappeared for good: let go of everything.
    private mutating func lose() -> Output {
        let actions = releaseLeftIfNeeded()
        mode = .idle
        middlePinched = false
        frozenPointer = nil
        lastPalmY = nil
        lastZoomDistance = nil
        return Output(mode: .idle, pointer: nil, actions: actions)
    }

    private mutating func releaseLeftIfNeeded() -> [Action] {
        guard indexPinched else { return [] }
        indexPinched = false
        frozenPointer = nil
        dragOffset = .zero
        // Not a click, so don't arm double-click timing.
        lastLeftUpTime = -1
        return [.leftUp(clickCount: 1)]
    }

    private func isPinching(_ hand: HandPose, engaged: Bool) -> Bool {
        guard let d = hand.normalizedDistance(.thumbTip, .indexTip) else { return false }
        return d < (engaged ? config.pinchRelease : config.pinchEngage)
    }

    /// The hand that drives the cursor. With two visible, prefer the right one.
    static func primaryHand(_ hands: [HandPose]) -> HandPose? {
        hands.first { $0.chirality == .right } ?? hands.first
    }
}
