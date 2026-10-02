import Carbon.HIToolbox
import AppKit

/// One global hotkey through Carbon's RegisterEventHotKey. Unlike an NSEvent global monitor this
/// fires even while another app has focus and swallows the keystroke, so it doesn't type anything.
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    /// Default binding: control + option + command + H.
    init(keyCode: UInt32 = UInt32(kVK_ANSI_H),
         modifiers: UInt32 = UInt32(controlKey | optionKey | cmdKey),
         action: @escaping () -> Void) {
        self.action = action
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue().action()
            return noErr
        }, 1, &eventType, selfPointer, &handler)
        let id = EventHotKeyID(signature: OSType(0x434E4454), id: 1) // "CNDT"
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}
