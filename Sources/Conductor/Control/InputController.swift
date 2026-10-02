import CoreGraphics
import Carbon.HIToolbox

/// Posts synthetic input through CGEvent. All coordinates are global display points with a
/// top-left origin, which is what CGEvent uses (and not what AppKit uses).
final class InputController: @unchecked Sendable {
    private var position: CGPoint
    private var leftDown = false
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

    /// Lets go of anything held. Called when the hand disappears or tracking pauses so a drag
    /// never gets stuck on.
    func releaseAll() {
        if leftDown { leftUp() }
    }

    private func post(_ event: CGEvent?) {
        event?.post(tap: .cghidEventTap)
    }
}

enum KeyCodes {
    static let equals = CGKeyCode(kVK_ANSI_Equal)
    static let minus = CGKeyCode(kVK_ANSI_Minus)
}
