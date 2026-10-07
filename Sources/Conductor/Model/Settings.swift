import CoreGraphics
import Foundation

/// Every user-tunable knob and its default. `Settings()` is the only place a default is written
/// down. Preferences stores one of these; the frame pipeline, the gesture check and the tests read
/// one directly.
struct Settings: Codable, Equatable, Sendable {
    var boxWidth = 0.6
    var boxHeight = 0.5
    var boxOffsetY = 0.05
    var mirrored = true
    var smoothing = 0.6
    /// Thumb-to-fingertip distances in hand widths. Change them with setPinchEngage and
    /// setPinchRelease, which keep release at least `minimumPinchGap` above engage.
    private(set) var pinchEngage = 0.35
    private(set) var pinchRelease = 0.55
    var scrollGain = 1.0
    var zoomWithKeys = false
    var displayMode = DisplayMode.all
    var gestureMap = GestureMap.standard
    var matchScreenShape = true
    var mainHand = MainHand.right
    var requireReadyPose = true
    var dwellClick = false
    var dwellTime = 0.8
    var showCursorRing = true
    var showHandMap = false
    /// Write every frame to a gesture log (see GestureLog).
    var recordGestureLog = false
    var soundCues = false
    var pointerMode = PointerMode.absolute
    var trackpadSpeed = 1.0
    /// How far slow moves carry the cursor in the absolute mode, as a fraction. 1 turns it off.
    var slowMoveSpeed = 0.35
    var momentumScroll = true
    var scrollStyle = ScrollStyle.lever
    /// Nil means automatic: see CameraCapture.preferredDevice.
    var cameraDeviceID: String?
    var powerSaving = true
    /// A box measured by calibration, in Vision space. Overrides the automatic layout when set.
    var calibratedBox: CGRect?
    var pinchDeadZone = 0.012
    var dwellRadius = 0.015
    /// Per-app gesture maps, keyed by bundle identifier.
    var appProfiles: [String: AppProfile] = [:]
    /// Nil means automatic: see CameraPlacement.resolve.
    var cameraPlacement: CameraPlacement?
    /// Head angles per display from look calibration. Nil until calibrated; `lookedAt` needs it.
    var lookModel: LookModel?

    /// Release below engage + this makes clicks chatter.
    static let minimumPinchGap = 0.1

    /// Moving engage up pushes release up with it.
    mutating func setPinchEngage(_ engage: Double) {
        pinchEngage = engage
        if pinchRelease < engage + Self.minimumPinchGap { pinchRelease = engage + Self.minimumPinchGap }
    }

    /// Moving release down pushes engage down with it.
    mutating func setPinchRelease(_ release: Double) {
        pinchRelease = release
        if pinchEngage > release - Self.minimumPinchGap { pinchEngage = release - Self.minimumPinchGap }
    }

    /// Repairs what a stored copy may get wrong: a pinch gap that's too small, and gesture maps
    /// saved before newer triggers existed (they get those triggers' defaults).
    func normalized() -> Settings {
        var settings = self
        settings.setPinchEngage(pinchEngage)
        settings.gestureMap.addMissingTriggers()
        for id in settings.appProfiles.keys { settings.appProfiles[id]?.map.addMissingTriggers() }
        return settings
    }

    /// Decodes stored settings over the defaults one key at a time. A key missing from the store
    /// keeps its default, so adding a setting doesn't reset the others. A value that no longer
    /// decodes, like a look model saved in an older format, also keeps its default. Nil if the
    /// data isn't a JSON object at all.
    init?(stored data: Data) {
        guard let stored = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let defaults = try? JSONEncoder().encode(Settings()),
              var merged = try? JSONSerialization.jsonObject(with: defaults) as? [String: Any] else { return nil }
        func decode(_ object: [String: Any]) -> Settings? {
            (try? JSONSerialization.data(withJSONObject: object)).flatMap { try? JSONDecoder().decode(Settings.self, from: $0) }
        }
        for (key, value) in stored {
            var candidate = merged
            candidate[key] = value
            if decode(candidate) != nil { merged = candidate }
        }
        guard let settings = decode(merged) else { return nil }
        self = settings
    }

    init() {}

    enum DisplayMode: String, CaseIterable, Identifiable, Codable, Sendable {
        /// The control box covers the union of every connected display.
        case all
        /// Each time the hand reappears, lock onto the display the cursor is on.
        case followCursor
        case main
        /// The whole box maps onto whichever display the head is turned toward (see LookPicker).
        case lookedAt

        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "All displays"
            case .followCursor: return "Display under the cursor"
            case .main: return "Main display only"
            case .lookedAt: return "Display you're looking at"
            }
        }
    }

    enum PointerMode: String, CaseIterable, Identifiable, Codable, Sendable {
        /// The cursor sits wherever the hand is inside the control box.
        case absolute
        /// The cursor moves by how far the hand moves, like a trackpad.
        case relative
        var id: String { rawValue }
        var title: String { self == .absolute ? "To where your hand is" : "Like a trackpad" }
    }

    /// How a held scroll trigger (fist, two fingers) turns the hand into scrolling.
    enum ScrollStyle: String, CaseIterable, Identifiable, Codable, Sendable {
        /// Hold the hand above or below where the trigger engaged; farther is faster. Letting go stops.
        case lever
        /// The page follows the hand's travel, and a flick can coast.
        case travel
        var id: String { rawValue }
        var title: String { self == .lever ? "Hold your hand off centre" : "Move your hand" }
    }

    /// Which hand drives the cursor when two are visible.
    enum MainHand: String, CaseIterable, Identifiable, Codable, Sendable {
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
}
