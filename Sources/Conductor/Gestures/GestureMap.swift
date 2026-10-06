import Foundation
import CoreGraphics

/// Something the hand can do that Conductor detects.
enum Trigger: String, CaseIterable, Codable, Identifiable {
    case indexPinch, middlePinch, ringPinch, littlePinch, fist, twoHandPinch, swipeLeft, swipeRight, twoFingers, crossedFingers

    var id: String { rawValue }

    var title: String {
        switch self {
        case .indexPinch: return "Thumb + index pinch"
        case .middlePinch: return "Thumb + middle pinch"
        case .ringPinch: return "Thumb + ring pinch"
        case .littlePinch: return "Thumb + little pinch"
        case .fist: return "Closed fist"
        case .twoHandPinch: return "Both hands pinched"
        case .swipeLeft: return "Two-finger swipe left"
        case .swipeRight: return "Two-finger swipe right"
        case .twoFingers: return "Two fingers, move up or down"
        case .crossedFingers: return "Index and middle crossed"
        }
    }

    /// The fingertip whose distance to the thumb defines the pinch, for pinch triggers.
    var fingertip: HandJoint? {
        switch self {
        case .indexPinch: return .indexTip
        case .middlePinch: return .middleTip
        case .ringPinch: return .ringTip
        case .littlePinch: return .littleTip
        case .fist, .twoHandPinch, .swipeLeft, .swipeRight, .twoFingers, .crossedFingers: return nil
        }
    }

    static let pinches: [Trigger] = [.indexPinch, .middlePinch, .ringPinch, .littlePinch]
    static let swipes: [Trigger] = [.swipeLeft, .swipeRight]
}

/// A key plus modifiers, stored as CGEvent values so posting is a direct pass-through.
struct Shortcut: Codable, Equatable, Hashable {
    var keyCode: UInt16
    var modifiers: UInt64

    var flags: CGEventFlags { CGEventFlags(rawValue: modifiers) }

    var display: String {
        var s = ""
        if flags.contains(.maskControl) { s += "⌃" }
        if flags.contains(.maskAlternate) { s += "⌥" }
        if flags.contains(.maskShift) { s += "⇧" }
        if flags.contains(.maskCommand) { s += "⌘" }
        return s + KeyNames.name(for: keyCode)
    }
}

/// What a trigger does. Three shapes: button actions follow the trigger down and up, tap actions
/// fire once when the trigger engages, motion actions turn hand travel into deltas while held.
enum GestureAction: Codable, Equatable, Hashable {
    case none
    case leftButton
    case rightClick
    case middleClick
    case scroll
    case zoom
    case shortcut(Shortcut)
    case pauseTracking
    /// Switches between pointing and scroll mode, where the relaxed hand scrolls from a neutral spot.
    case scrollMode
    /// Holds a key down for as long as the trigger is held: push-to-talk.
    case holdKey(Shortcut)
    /// Moves the control box to the next display, for when the head can't tell the screens apart.
    case switchDisplay

    enum Shape { case button, tap, motion, inert }

    var shape: Shape {
        switch self {
        case .none: return .inert
        case .leftButton, .holdKey: return .button
        case .rightClick, .middleClick, .shortcut, .pauseTracking, .scrollMode, .switchDisplay: return .tap
        case .scroll, .zoom: return .motion
        }
    }

    var title: String {
        switch self {
        case .none: return "Nothing"
        case .leftButton: return "Click / drag"
        case .rightClick: return "Right click"
        case .middleClick: return "Middle click"
        case .scroll: return "Scroll"
        case .zoom: return "Zoom"
        case .shortcut(let s): return "Shortcut \(s.display)"
        case .pauseTracking: return "Pause / resume"
        case .scrollMode: return "Scroll mode on / off"
        case .holdKey(let s): return "Hold \(s.display)"
        case .switchDisplay: return "Switch display"
        }
    }

    static let unsetKey = Shortcut(keyCode: 0, modifiers: 0)

    /// The pickable kinds. Key actions carry no key here; the UI fills it in with the recorder.
    static let menuChoices: [GestureAction] = [
        .leftButton, .rightClick, .middleClick, .scroll, .zoom, .shortcut(unsetKey), .holdKey(unsetKey), .switchDisplay, .scrollMode, .pauseTracking, .none,
    ]

    /// The key a shortcut or hold-key action carries.
    var recordedKey: Shortcut? {
        switch self {
        case .shortcut(let s), .holdKey(let s): return s
        default: return nil
        }
    }

    /// The same action with its key blanked, so the picker can treat every shortcut as one choice.
    var kind: GestureAction {
        switch self {
        case .shortcut: return .shortcut(Self.unsetKey)
        case .holdKey: return .holdKey(Self.unsetKey)
        default: return self
        }
    }

    var kindTitle: String {
        switch self {
        case .shortcut: return "Keyboard shortcut"
        case .holdKey: return "Hold a key"
        default: return title
        }
    }
}

/// Which trigger does what. Persisted as JSON in UserDefaults.
struct GestureMap: Codable, Equatable {
    var bindings: [Trigger: GestureAction]

    static let standard = GestureMap(bindings: [
        .indexPinch: .leftButton,
        .middlePinch: .rightClick,
        .ringPinch: .switchDisplay,
        .littlePinch: .none,
        .fist: .scroll,
        .twoHandPinch: .zoom,
        // Like a trackpad: swipe right goes back, swipe left goes forward.
        .swipeRight: .shortcut(Shortcut(keyCode: 33, modifiers: CGEventFlags.maskCommand.rawValue)), // ⌘[
        .swipeLeft: .shortcut(Shortcut(keyCode: 30, modifiers: CGEventFlags.maskCommand.rawValue)),  // ⌘]
        .twoFingers: .scroll,
        .crossedFingers: .none,
    ])

    subscript(_ trigger: Trigger) -> GestureAction {
        get { bindings[trigger] ?? .none }
        set { bindings[trigger] = newValue }
    }

    static func load(from defaults: UserDefaults) -> GestureMap {
        guard let data = defaults.data(forKey: "gestureMap"),
              var map = try? JSONDecoder().decode(GestureMap.self, from: data) else { return .standard }
        // Triggers added after the map was saved get their default binding.
        for trigger in Trigger.allCases where map.bindings[trigger] == nil {
            map.bindings[trigger] = GestureMap.standard[trigger]
        }
        return map
    }

    func save(to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: "gestureMap")
        }
    }
}

enum KeyNames {
    private static let table: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W",
        14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
        26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "↩", 37: "L",
        38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 48: "⇥", 49: "Space",
        50: "`", 51: "⌫", 53: "⎋", 54: "Right ⌘", 55: "Left ⌘", 56: "Left ⇧", 58: "Left ⌥", 59: "Left ⌃",
        60: "Right ⇧", 61: "Right ⌥", 62: "Right ⌃", 63: "fn", 96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
        109: "F10", 111: "F12", 118: "F4", 120: "F2", 122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "Home", 119: "End", 116: "PgUp", 121: "PgDn", 117: "⌦",
    ]

    static func name(for keyCode: UInt16) -> String {
        table[keyCode] ?? "key \(keyCode)"
    }
}
