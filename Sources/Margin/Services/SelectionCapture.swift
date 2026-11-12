import AppKit
import MarginKit

/// Takes whatever is selected in the app in front: text (in its original
/// formatting) or an image. Borrows the clipboard for a moment and puts
/// back exactly what was there.
@MainActor
final class SelectionCapture {
    enum Clip {
        case text(RichClip)
        case image(Data, sourceURL: URL?)
        /// A web address. `isCurrentPage`: it came from the address bar, so
        /// the page is what's on screen right now.
        case link(URL, isCurrentPage: Bool)
    }

    /// Browsers, where a selected address means "this page".
    static let browsers: Set<String> = [
        "company.thebrowser.Browser", // Arc
        "company.thebrowser.dia",
        "com.google.Chrome", "com.google.Chrome.canary", "com.google.Chrome.beta",
        "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "com.brave.Browser", "com.microsoft.edgemac", "org.mozilla.firefox",
        "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "com.kagi.kagimacOS",
        "app.zen-browser.zen", "org.chromium.Chromium", "com.openai.atlas",
    ]

    /// Editors that copy the whole line when nothing is selected. For them a
    /// copied single line only counts if Accessibility confirmed a selection.
    static let lineCopyingEditors: Set<String> = [
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.exafunction.windsurf",
        "dev.zed.Zed",
        "com.sublimetext.4",
        "com.apple.dt.Xcode",
    ]

    /// Apps where ⌘C never means "copy selected text" in a useful way.
    static let skipCopy: Set<String> = [
        "com.apple.finder",
        "com.figma.Desktop",
    ]

    func capture(from app: NSRunningApplication) async -> Clip? {
        let pid = app.processIdentifier
        let bundleID = app.bundleIdentifier ?? ""
        let ax = await Task.detached { SelectionReader.read(pid: pid) }.value
        let axText = ax.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        MarginLog.info("Selection in \(app.localizedName ?? bundleID): AX reports \(ax.reportsSelection ? "\(axText.count) chars" : "nothing"), url \(ax.url?.absoluteString ?? "none")")

        // Google Docs, Sheets and Slides draw their text on a canvas and keep
        // an empty hidden field for the cursor, so Accessibility always says
        // nothing is selected. Only ⌘C knows; it copies nothing if that's so.
        let canvasEditor = ax.url?.host == "docs.google.com"
        // A text field that reports an empty selection: nothing to take.
        if ax.reportsSelection, axText.isEmpty, !canvasEditor { return nil }
        if Self.skipCopy.contains(bundleID) { return nil }

        // ⌘C gets the formatting; Accessibility only gives plain text.
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard)
        let before = pasteboard.changeCount
        Keys.command("c")
        // Docs copies from script, which takes a moment longer.
        let changed = await pasteboard.waitForChange(from: before, timeout: axText.isEmpty && !canvasEditor ? 0.35 : 0.9)
        guard changed else {
            if let url = LinkDetector.url(in: axText) {
                return .link(url, isCurrentPage: Self.browsers.contains(bundleID) && ax.isInField)
            }
            return axText.isEmpty ? nil : .text(.plain(ax.text ?? axText, sourceURL: ax.url))
        }
        // Some apps clear the pasteboard first and fill it a moment later.
        try? await Task.sleep(nanoseconds: 60_000_000)

        let clip = read(pasteboard, fallbackURL: ax.url)
        // Some browsers copy an address as a URL only, without text.
        let linkURL = pasteboard.string(forType: .URL).flatMap(LinkDetector.url(in:))
        snapshot.restore(to: pasteboard)

        // Editors copy the whole line when nothing is selected: that's no selection.
        if case .text(let rich)? = clip, axText.isEmpty,
           Self.lineCopyingEditors.contains(bundleID) || bundleID.hasPrefix("com.jetbrains."),
           rich.plain.hasSuffix("\n"), rich.plain.dropLast().split(separator: "\n", omittingEmptySubsequences: false).count == 1 {
            MarginLog.info("Ignored a whole-line copy from an editor with nothing selected")
            return nil
        }

        // A single web address: a website capture, not text.
        let isCurrentPage = Self.browsers.contains(bundleID) && ax.isInField
        if case .text(let rich)? = clip, let url = LinkDetector.url(in: rich.plain) {
            return .link(url, isCurrentPage: isCurrentPage)
        }
        if clip == nil, let url = linkURL {
            return .link(url, isCurrentPage: isCurrentPage)
        }

        switch clip {
        case .text(let rich)?:
            let plain = rich.plain
            if plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return axText.isEmpty ? nil : .text(.plain(ax.text ?? axText, sourceURL: ax.url))
            }
            return clip
        case .image?, .link?:
            return clip
        case nil:
            return axText.isEmpty ? nil : .text(.plain(ax.text ?? axText, sourceURL: ax.url))
        }
    }

    private func read(_ pasteboard: NSPasteboard, fallbackURL: URL?) -> Clip? {
        let types = pasteboard.types ?? []
        // Files copied in Finder or an editor's sidebar aren't a selection to keep.
        let onlyFiles = types.contains(.fileURL) && !types.contains(.rtf) && !types.contains(.html)
        if onlyFiles { return nil }

        if var rich = RichText.read(from: pasteboard) {
            if rich.sourceURL == nil { rich.sourceURL = fallbackURL }
            return .text(rich)
        }
        if let png = pasteboard.data(forType: .png) {
            return .image(png, sourceURL: fallbackURL)
        }
        if let tiff = pasteboard.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return .image(png, sourceURL: fallbackURL)
        }
        return nil
    }
}
