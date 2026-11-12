import AppKit

/// A full copy of what's on a pasteboard, so Margin can borrow the clipboard
/// for a moment (to read Figma's ⌘L link or a ⌘C selection) and put back
/// exactly what was there.
public struct PasteboardSnapshot {
    let items: [[(NSPasteboard.PasteboardType, Data)]]

    /// Marks restored data as "not a new copy" for clipboard managers.
    /// See nspasteboard.org.
    static let restoredMarker = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    public init(_ pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            }
        }
    }

    public var isEmpty: Bool { items.isEmpty }

    public func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let restored: [NSPasteboardItem] = items.map { pairs in
            let item = NSPasteboardItem()
            for (type, data) in pairs { item.setData(data, forType: type) }
            item.setData(Data(), forType: Self.restoredMarker)
            return item
        }
        pasteboard.writeObjects(restored)
    }
}

public extension NSPasteboard {
    /// Waits until another app writes to the pasteboard. False on timeout.
    func waitForChange(from count: Int, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if changeCount != count { return true }
            try? await Task.sleep(nanoseconds: 15_000_000)
        }
        return changeCount != count
    }
}
