import AppKit
import ApplicationServices

/// Asks the app in front, through Accessibility, what's selected and which
/// page or document it's showing. Many apps answer; some (Electron editors,
/// some browsers) don't, which is why Margin also tries ⌘C.
enum SelectionReader {
    struct Result {
        /// Selected text, if the focused element reports it.
        var text: String?
        /// The focused element is a text element that reports its selection,
        /// so an empty `text` really means nothing is selected.
        var reportsSelection = false
        /// The web page or document in front, if the app says.
        var url: URL?
        /// Role of the focused element, e.g. "AXTextField" for an address bar.
        var role: String?
        /// Full text of the focused field, e.g. the address bar's URL.
        var value: String?

        /// The focus is in a single-line field (address bar, search field),
        /// not in a page or document.
        var isInField: Bool {
            ["AXTextField", "AXComboBox", "AXSearchField"].contains(role ?? "")
        }
    }

    static func read(pid: pid_t) -> Result {
        var result = Result()
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)

        if let focused: AXUIElement = attribute(app, kAXFocusedUIElementAttribute) {
            AXUIElementSetMessagingTimeout(focused, 0.25)
            result.role = attribute(focused, kAXRoleAttribute)
            result.value = attribute(focused, kAXValueAttribute)
            if let text: String = attribute(focused, kAXSelectedTextAttribute) {
                result.text = text
                result.reportsSelection = true
            } else if let range: AXValue = attribute(focused, kAXSelectedTextRangeAttribute) {
                var cfRange = CFRange()
                if AXValueGetValue(range, .cfRange, &cfRange) {
                    result.reportsSelection = true
                    if cfRange.length == 0 { result.text = "" }
                }
            }
            result.url = url(around: focused)
        }
        if result.url == nil, let window: AXUIElement = attribute(app, kAXFocusedWindowAttribute) {
            result.url = documentURL(of: window)
        }
        return result
    }

    /// The page URL for browsers (Safari, Chrome expose AXURL on the web
    /// area), found by walking up from the focused element.
    private static func url(around element: AXUIElement) -> URL? {
        var current: AXUIElement? = element
        for _ in 0..<40 {
            guard let node = current else { return nil }
            if let url: URL = attribute(node, "AXURL"), url.scheme?.hasPrefix("http") == true { return url }
            current = attribute(node, kAXParentAttribute)
        }
        return nil
    }

    /// Where the web page is drawn in the front window, in screen points
    /// (Core Graphics coordinates), so a screenshot can leave out the tabs
    /// and toolbar. Nil if the browser doesn't say.
    static func webAreaFrame(pid: pid_t) -> CGRect? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        guard let window: AXUIElement = attribute(app, kAXFocusedWindowAttribute) else { return nil }
        // Breadth first: the web area sits a few levels under the window.
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0
        var best: CGRect?
        while !queue.isEmpty, visited < 600 {
            let (element, depth) = queue.removeFirst()
            visited += 1
            if let role: String = attribute(element, kAXRoleAttribute), role == "AXWebArea",
               let frame = frame(of: element), frame.width > 100, frame.height > 100 {
                // Prefer the biggest (the page, not a small embedded frame).
                if best == nil || frame.width * frame.height > best!.width * best!.height { best = frame }
                continue
            }
            guard depth < 14, let children: [AXUIElement] = attribute(element, kAXChildrenAttribute) else { continue }
            queue.append(contentsOf: children.map { ($0, depth + 1) })
        }
        return best
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let positionValue: AXValue = attribute(element, kAXPositionAttribute),
              let sizeValue: AXValue = attribute(element, kAXSizeAttribute) else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &point), AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    /// The title of the front window, e.g. the page title in a browser.
    static func windowTitle(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let window: AXUIElement = attribute(app, kAXFocusedWindowAttribute) else { return nil }
        return attribute(window, kAXTitleAttribute)
    }

    private static func documentURL(of window: AXUIElement) -> URL? {
        guard let string: String = attribute(window, kAXDocumentAttribute), let url = URL(string: string) else { return nil }
        return url.scheme == nil ? nil : url
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else { return nil }
        if T.self == AXUIElement.self {
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! T)
        }
        if T.self == AXValue.self {
            guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
            return (value as! T)
        }
        if T.self == URL.self {
            if let url = value as? URL { return url as? T }
            if let string = value as? String { return URL(string: string) as? T }
            return nil
        }
        return value as? T
    }
}
