import AppKit
import Carbon

/// System-wide shortcut (⌃⌥W) for Writing Tools. Carbon hot keys work in every app and
/// don't need Accessibility permission.
public enum AIHotKey {
    private static var handler: (() -> Void)?
    private static var reference: EventHotKeyRef?

    public static func register(_ action: @escaping () -> Void) {
        handler = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            AIHotKey.handler?()
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x504B_4149), id: 1)   // "PKAI"
        RegisterEventHotKey(UInt32(kVK_ANSI_W), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &reference)
    }
}
