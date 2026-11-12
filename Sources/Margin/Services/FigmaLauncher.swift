import AppKit
import ApplicationServices
import MarginKit

/// Starts Margin's Figma plugin when a capture needs it, by pressing its
/// item in Figma's menu bar (Plugins → Development → Margin) through
/// Accessibility. No keys are typed and the clipboard isn't touched. The
/// plugin exports and closes itself, so it never sits running in Figma.
enum FigmaLauncher {
    /// Presses the plugin's menu item. True if Figma accepted the press.
    @MainActor
    static func startPlugin(in app: NSRunningApplication) -> Bool {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let menuBar: AXUIElement = value(of: root, kAXMenuBarAttribute) else {
            MarginLog.info("Figma plugin start: no menu bar (Accessibility allowed: \(AXIsProcessTrusted()))")
            return false
        }
        let tops = children(of: menuBar)
        // The Plugins menu first; every other menu only if it isn't there.
        let ordered = tops.filter { title(of: $0) == "Plugins" } + tops.filter { title(of: $0) != "Plugins" }
        for top in ordered {
            if let item = find(in: top, path: [title(of: top) ?? ""], depth: 0) {
                let result = AXUIElementPerformAction(item, kAXPressAction as CFString)
                MarginLog.info("Figma plugin start via menu: \(result == .success ? "pressed" : "press failed (\(result.rawValue))")")
                return result == .success
            }
        }
        MarginLog.info("Figma plugin start: no Margin item in Figma's menus (\(tops.compactMap { title(of: $0) }.joined(separator: ", ")))")
        return false
    }

    /// The "Margin" item under a Plugins or Development menu.
    private static func find(in element: AXUIElement, path: [String], depth: Int) -> AXUIElement? {
        guard depth < 6 else { return nil }
        for child in children(of: element) {
            let name = title(of: child) ?? ""
            let role: String? = value(of: child, kAXRoleAttribute)
            if role == (kAXMenuItemRole as String), name == "Margin" || name.hasPrefix("Margin "),
               path.contains(where: { $0 == "Plugins" || $0 == "Development" }) {
                return child
            }
            let next = name.isEmpty ? path : path + [name]
            if let found = find(in: child, path: next, depth: depth + 1) { return found }
        }
        return nil
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        (value(of: element, kAXChildrenAttribute) as [AXUIElement]?) ?? []
    }

    private static func title(of element: AXUIElement) -> String? {
        value(of: element, kAXTitleAttribute)
    }

    private static func value<T>(of element: AXUIElement, _ attribute: String) -> T? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success, let raw else { return nil }
        return raw as? T
    }
}
