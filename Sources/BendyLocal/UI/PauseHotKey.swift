import Carbon
import AppKit

/// A system-wide ⌃⌥⌘B toggle, independent of any window having focus. Mirrors
/// EscapeHotKey's Carbon hot-key mechanics, but this one is armed once at
/// launch and stays armed for the app's lifetime instead of only while the
/// overlay is showing.
final class PauseHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var onPress: (() -> Void)?

    private static var active: PauseHotKey?

    private static let signature = OSType(0x424C4B32)
    private static let keyCode: UInt32 = UInt32(kVK_ANSI_B)
    private static let modifiers: UInt32 = UInt32(controlKey | optionKey | cmdKey)

    static let displayString = "⌃⌥⌘B"

    func arm(onPress: @escaping () -> Void) {
        guard hotKeyRef == nil else { return }
        self.onPress = onPress
        Self.active = self

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard id.signature == PauseHotKey.signature else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async { PauseHotKey.active?.onPress?() }
            return noErr
        }, 1, &spec, nil, &handlerRef)

        let id = EventHotKeyID(signature: Self.signature, id: 1)
        RegisterEventHotKey(Self.keyCode, Self.modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func disarm() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        if let handlerRef { RemoveEventHandler(handlerRef) }
        handlerRef = nil
        onPress = nil
        if Self.active === self { Self.active = nil }
    }

    deinit { disarm() }
}
