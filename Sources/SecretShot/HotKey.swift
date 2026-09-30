import AppKit
import Carbon.HIToolbox

/// System-wide hotkey via Carbon's RegisterEventHotKey.
/// Deliberately not an NSEvent global monitor: that needs Accessibility
/// permission, this needs none.
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let id: UInt32
    private let action: () -> Void

    private static var registry: [UInt32: HotKey] = [:]
    private static var nextID: UInt32 = 1

    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.id = HotKey.nextID
        self.action = action
        HotKey.nextID += 1

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))

        let installStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            HotKey.registry[hkID.id]?.action()
            return noErr
        }, 1, &eventType, nil, &handler)

        guard installStatus == noErr else { return nil }

        let hotKeyID = EventHotKeyID(signature: OSType(0x53535354), id: id) // 'SSST'
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else { return nil }

        HotKey.registry[id] = self
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
        HotKey.registry[id] = nil
    }
}

enum HotKeyDefaults {
    /// ⌘⇧8 — free on a stock macOS install and next to the screenshot cluster.
    static let regionKeyCode = UInt32(kVK_ANSI_8)
    static let regionModifiers = UInt32(cmdKey | shiftKey)
    static let regionDisplay = "⌘⇧8"

    /// ⌘⇧9 — same capture, window picker instead of a drag selection.
    static let windowKeyCode = UInt32(kVK_ANSI_9)
    static let windowModifiers = UInt32(cmdKey | shiftKey)
    static let windowDisplay = "⌘⇧9"
}
