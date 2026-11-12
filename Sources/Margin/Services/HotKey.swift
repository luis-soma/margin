import Carbon
import Foundation

/// A system-wide keyboard shortcut. Uses Carbon's hot key API, which needs no
/// Accessibility permission.
final class HotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var handlerInstalled = false

    private var reference: EventHotKeyRef?

    /// - Parameters:
    ///   - keyCode: a virtual key code, e.g. `UInt32(kVK_ANSI_M)`.
    ///   - modifiers: Carbon modifiers, e.g. `UInt32(cmdKey | shiftKey)`.
    init(keyCode: UInt32, modifiers: UInt32, id: UInt32, action: @escaping () -> Void) {
        Self.handlers[id] = action
        Self.installHandlerIfNeeded()
        let hotKeyID = EventHotKeyID(signature: OSType(0x4D52_474E), id: id) // "MRGN"
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &reference)
    }

    deinit {
        if let reference { UnregisterEventHotKey(reference) }
    }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            let id = hotKeyID.id
            DispatchQueue.main.async { HotKey.handlers[id]?() }
            return OSStatus(noErr)
        }, 1, &eventType, nil, nil)
    }
}
