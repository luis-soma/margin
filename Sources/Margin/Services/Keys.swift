import AppKit
import Carbon
import CoreGraphics

/// Sends keyboard shortcuts to the app in front, like a person pressing
/// them. Needs Accessibility permission.
enum Keys {
    /// Waits until no modifier keys are held, so a shortcut Margin sends
    /// doesn't mix with the keys still down from Margin's own shortcut.
    /// (⌘⇧ held while sending ⌘L would be ⌘⇧L: "lock" in Figma.)
    static func waitForModifierRelease(timeout: TimeInterval = 1.2) async {
        let modifiers: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl, .maskSecondaryFn]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if CGEventSource.flagsState(.combinedSessionState).intersection(modifiers).isEmpty { return }
            try? await Task.sleep(nanoseconds: 15_000_000)
        }
    }

    /// Presses ⌘ plus the key that types `character` on the current layout.
    static func command(_ character: Character) {
        let code = keyCode(for: character) ?? ansiFallback[character] ?? CGKeyCode(kVK_ANSI_C)
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
            event.flags = .maskCommand
            event.post(tap: .cghidEventTap)
        }
    }

    /// Presses Escape, e.g. to close a browser's address bar popup.
    static func escape() {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Escape), keyDown: down) else { continue }
            event.flags = []
            event.post(tap: .cghidEventTap)
        }
    }

    private static let ansiFallback: [Character: CGKeyCode] = [
        "c": CGKeyCode(kVK_ANSI_C),
        "l": CGKeyCode(kVK_ANSI_L),
    ]

    /// The key that produces `character` on the active keyboard layout, so
    /// ⌘C still means copy on AZERTY or Dvorak.
    static func keyCode(for character: Character) -> CGKeyCode? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        let target = String(character).lowercased()
        return layoutData.withUnsafeBytes { raw -> CGKeyCode? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            for code in 0..<CGKeyCode(128) {
                var deadKeys: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(
                    layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0,
                    UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask),
                    &deadKeys, chars.count, &length, &chars
                )
                if status == OSStatus(noErr), length > 0, String(utf16CodeUnits: chars, count: length).lowercased() == target {
                    return code
                }
            }
            return nil
        }
    }
}
