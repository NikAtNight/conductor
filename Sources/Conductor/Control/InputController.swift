import CoreGraphics
import Carbon.HIToolbox

/// Posts synthetic input through CGEvent. All coordinates are global display points with a
/// top-left origin, which is what CGEvent uses (and not what AppKit uses).
final class InputController: @unchecked Sendable {
    private var position: CGPoint
    private var leftDown = false
    /// Keys held by "Hold a key" bindings, so they can always be let go.
    private var heldKeys: [UInt16: Shortcut] = [:]
    private let source = CGEventSource(stateID: .combinedSessionState)

    init() {
        position = CGEvent(source: nil)?.location ?? .zero
    }

    var isLeftButtonDown: Bool { leftDown }

    func move(to point: CGPoint) {
        position = point
        let type: CGEventType = leftDown ? .leftMouseDragged : .mouseMoved
        post(CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left))
    }

    func leftDown(clickCount: Int = 1) {
        guard !leftDown else { return }
        leftDown = true
        let event = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: position, mouseButton: .left)
        event?.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        post(event)
    }

    func leftUp(clickCount: Int = 1) {
        guard leftDown else { return }
        leftDown = false
        let event = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: position, mouseButton: .left)
        event?.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        post(event)
    }

    func rightClick() {
        post(CGEvent(mouseEventSource: source, mouseType: .rightMouseDown, mouseCursorPosition: position, mouseButton: .right))
        post(CGEvent(mouseEventSource: source, mouseType: .rightMouseUp, mouseCursorPosition: position, mouseButton: .right))
    }

    func middleClick() {
        post(CGEvent(mouseEventSource: source, mouseType: .otherMouseDown, mouseCursorPosition: position, mouseButton: .center))
        post(CGEvent(mouseEventSource: source, mouseType: .otherMouseUp, mouseCursorPosition: position, mouseButton: .center))
    }

    /// Positive dy scrolls content up (same sign as a trackpad swipe up with natural scrolling).
    func scroll(dy: Int32, dx: Int32 = 0, flags: CGEventFlags = []) {
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else { return }
        event.flags = flags
        post(event)
    }

    func keyPress(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        post(down)
        post(up)
    }

    /// Presses a key and leaves it down until `keyUp`. Modifier keys go out as flagsChanged events
    /// with the left/right device bit set, which is how apps (Walkie included) tell Right ⌘
    /// from Left ⌘.
    func keyDown(_ key: Shortcut) {
        guard heldKeys[key.keyCode] == nil else { return }
        heldKeys[key.keyCode] = key
        post(Self.keyEvent(key, down: true, source: source))
    }

    func keyUp(_ key: Shortcut) {
        guard heldKeys.removeValue(forKey: key.keyCode) != nil else { return }
        post(Self.keyEvent(key, down: false, source: source))
    }

    /// Modifier flag and NX device bit for each modifier key code.
    static func modifier(for keyCode: UInt16) -> (flag: CGEventFlags, device: UInt64)? {
        switch keyCode {
        case 55: return (.maskCommand, 0x08)     // left command
        case 54: return (.maskCommand, 0x10)     // right command
        case 56: return (.maskShift, 0x02)
        case 60: return (.maskShift, 0x04)
        case 58: return (.maskAlternate, 0x20)
        case 61: return (.maskAlternate, 0x40)
        case 59: return (.maskControl, 0x01)
        case 62: return (.maskControl, 0x2000)
        case 63: return (.maskSecondaryFn, 0)
        default: return nil
        }
    }

    /// The flags a hold-key event carries: the binding's own modifiers, plus the key's own flag and
    /// device bit while a modifier key is down.
    static func flags(for key: Shortcut, down: Bool) -> CGEventFlags {
        var flags = key.flags
        if down, let modifier = modifier(for: key.keyCode) {
            flags.insert(modifier.flag)
            flags.insert(CGEventFlags(rawValue: modifier.device))
        }
        return flags
    }

    private static func keyEvent(_ key: Shortcut, down: Bool, source: CGEventSource?) -> CGEvent? {
        let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key.keyCode), keyDown: down)
        if modifier(for: key.keyCode) != nil { event?.type = .flagsChanged }
        event?.flags = flags(for: key, down: down)
        return event
    }

    /// Lets go of anything held. Called when the hand disappears or tracking pauses so a drag
    /// never gets stuck on.
    func releaseAll() {
        if leftDown { leftUp() }
        for key in heldKeys.values { keyUp(key) }
    }

    private func post(_ event: CGEvent?) {
        event?.post(tap: .cghidEventTap)
    }
}

enum KeyCodes {
    static let equals = CGKeyCode(kVK_ANSI_Equal)
    static let minus = CGKeyCode(kVK_ANSI_Minus)
}
