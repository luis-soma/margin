import AppKit
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Opens a moment in focus. The repo sets it; elsewhere a moment opens in its
/// own window instead.
private struct FocusMomentKey: EnvironmentKey {
    static let defaultValue: (Entry) -> Void = { _ in }
}

extension EnvironmentValues {
    var focusMoment: (Entry) -> Void {
        get { self[FocusMomentKey.self] }
        set { self[FocusMomentKey.self] = newValue }
    }
}

/// One moment in focus over the repo, like a block on Are.na: the repo stays
/// behind a dark tint, and a panel floats on top with the capture as large as
/// it fits and everything known about it beside it, with ways to keep a copy.
/// Esc or a click outside closes; ← and → step through what the repo shows.
struct FocusView: View {
    @EnvironmentObject private var store: EntryStore
    @EnvironmentObject private var coding: CodingSessions
    @State var entryID: UUID
    /// The moments in the order the repo shows them.
    let order: [UUID]
    let close: () -> Void

    @State private var title = ""
    @State private var why = ""
    @FocusState private var whyFocused: Bool
    @FocusState private var titleFocused: Bool
    @State private var flash: String?
    /// Watches clicks and arrows while the focus view is open (see `watchKeys`).
    @State private var monitors: [Any] = []
    /// What the arrow keys do. The key listener is set up once, so it calls
    /// through this, which every render points at the view as it is now
    /// (the current list of artifacts, not the one from when it opened).
    @State private var arrows = Arrows()

    final class Arrows {
        var step: (Int) -> Void = { _ in }
    }
    /// How far the picture is zoomed in; bumping the token sends it back to fit.
    @State private var zoom: CGFloat = 1
    @State private var resetToken = 0

    private var entry: Entry? { store.entry(id: entryID) }

    var body: some View {
        let _ = arrows.step = { offset in step(offset) }
        ZStack {
            // The repo shows through, softened under a pale veil.
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(Archive.paper.opacity(0.55))
                .contentShape(Rectangle())
                .onTapGesture(perform: close)
            if let entry {
                GeometryReader { geo in
                    // In a narrow window (about half a laptop screen or less),
                    // the details go under the media instead of beside it.
                    let stacked = geo.size.width < Self.stackBelow
                    let F = Archive.Focus.self
                    let inset = F.inset
                    let size = CGSize(width: max(0, geo.size.width - inset * 2), height: max(0, geo.size.height - F.insetTop - inset))
                    panel(entry, size: size, stacked: stacked)
                        .frame(width: size.width, height: size.height)
                        .offset(x: inset, y: F.insetTop)
                }
            }
            shortcuts
        }
        .ignoresSafeArea()
        .onAppear {
            loadEdits()
            watchKeys()
        }
        .onDisappear {
            saveEdits()
            monitors.forEach(NSEvent.removeMonitor)
            monitors = []
        }
        .onChange(of: store.entry(id: entryID) == nil) { gone in if gone { close() } }
    }

    /// Window width below which the details sit under the media: a bit over
    /// half of a 13–14" MacBook screen.
    static let stackBelow: CGFloat = 900

    /// The floating panel: the capture centered in its own space on the
    /// left, a hairline, and what's said about it on the right. In a narrow
    /// window the details go under the capture, under a horizontal hairline,
    /// and the capture's space stays the same from one artifact to the next.
    private func panel(_ entry: Entry, size: CGSize, stacked: Bool) -> some View {
        let F = Archive.Focus.self
        let shape = RoundedRectangle(cornerRadius: F.radius, style: .continuous)
        let aspect = store.aspectRatio(for: entry) ?? 1.5
        return ZStack(alignment: .topTrailing) {
            if stacked {
                let top = F.navTop + F.navSize + F.gap / 2
                let width = size.width - 2 * F.trailing
                let area = CGSize(width: width, height: max(80, size.height - top - F.trailing - F.stackedDetailsHeight - F.gap - 1))
                let picture = sharp(fitted(aspect, in: CGSize(width: area.width, height: area.height)), entry)
                VStack(spacing: 0) {
                    pictureColumn(entry, size: picture, area: area)
                    Rectangle()
                        .fill(Archive.rule)
                        .frame(height: 1)
                        .padding(.vertical, F.gap / 2)
                    ScrollView {
                        stackedDetails(entry)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: F.stackedDetailsHeight)
                }
                .padding(.horizontal, F.trailing)
                .padding(.top, top)
                .padding(.bottom, F.trailing)
            } else {
                let areaWidth = size.width - 1 - F.gap / 2 - F.sidebarWidth - F.trailing
                let room = CGSize(width: areaWidth - 2 * F.artMargin, height: size.height - 2 * F.verticalMargin)
                let picture = sharp(fitted(aspect, in: room), entry)
                HStack(alignment: .center, spacing: 0) {
                    // The capture, centered in the space that's its own.
                    pictureColumn(entry, size: picture, area: CGSize(width: areaWidth, height: size.height))
                    // A hairline between the capture and what's said about it.
                    Rectangle()
                        .fill(Archive.rule)
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                        .padding(.vertical, F.ruleInset)
                    sidebar(entry, minHeight: picture.height)
                        .frame(width: F.sidebarWidth)
                        .padding(.leading, F.gap / 2)
                }
                .padding(.trailing, F.trailing)
                .frame(width: size.width, height: size.height)
            }
            navigation
        }
        .frame(width: size.width, height: size.height)
        .background(Archive.paper, in: shape)
        .clipShape(shape)
        // The shadow from the panel's shape alone, not from everything on
        // it (that was redrawn whenever anything inside changed).
        .background(
            shape.fill(Archive.paper)
                .shadow(color: .black.opacity(0.05), radius: 1.5, y: 1)
                .shadow(color: .black.opacity(0.10), radius: 28, y: 10)
        )
        // What Download, ⌘S or ⌘C just did ("Saved to Downloads", "Copied"),
        // in the pill files dropped on the archive get.
        .overlay(alignment: .bottom) {
            if let flash {
                FloatingNote(text: flash)
                    .padding(.bottom, 22)
                    .transition(.opacity.combined(with: .offset(y: 8)).combined(with: .scale(scale: 0.96, anchor: .bottom)))
            }
        }
        .animation(Brand.motion, value: flash)
    }

    /// The largest size of that shape that fits in `room`.
    /// A small screenshot isn't blown up past what it has: at most a quarter
    /// over its real size on this screen, so it stays sharp instead of
    /// filling the panel blurred. Pinch or double-click still zooms in.
    private func sharp(_ fit: CGSize, _ entry: Entry) -> CGSize {
        guard zoomableURL(entry) != nil, let pixels = pixelSize(entry), pixels.width > 0, pixels.height > 0 else { return fit }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let most = CGSize(width: pixels.width / scale * 1.25, height: pixels.height / scale * 1.25)
        guard fit.width > most.width else { return fit }
        return CGSize(width: most.width.rounded(), height: (most.width * fit.height / max(fit.width, 1)).rounded())
    }

    private func fitted(_ aspect: CGFloat, in room: CGSize) -> CGSize {
        let a = min(max(aspect, 0.2), 6)
        var w = max(room.width, 40), h = w / a
        if h > room.height { h = max(room.height, 40); w = h * a }
        return CGSize(width: w.rounded(), height: h.rounded())
    }

    /// The picture.
    /// The capture, centered in `area` at `size`. A still picture is given
    /// the whole area, so zooming in lets it grow past its fitted size until
    /// it fills the space; anything else sits at its fitted size.
    @ViewBuilder
    private func pictureColumn(_ entry: Entry, size: CGSize, area: CGSize) -> some View {
        if let source = LiveSource.of(entry, coding: coding) {
            // A Claude Code prototype or a captured website: running, where
            // its picture would be, with the screenshot a click away.
            let shot = fitted(store.aspectRatio(for: entry) ?? 1.6, in: LiveLayout.room(in: area))
            LiveCapture(entry: entry, source: source, area: area, pictureSize: shot) {
                MomentMedia(entry: entry)
                    .onDrag { dragItem(entry) }
                    .frame(width: shot.width, height: shot.height)
            }
            .id(entry.id)
            .contextMenu { moreActions(entry) }
        } else if let frames = entry.frames, frames.count > 1 {
            // A stack (a slide deck): the slides as a carousel.
            DeckCarousel(frames: frames, area: area)
                .id(entry.id)
                .frame(width: area.width, height: area.height)
                .contextMenu { moreActions(entry) }
        } else if let url = zoomableURL(entry) {
            ZoomableImage(url: url, preview: entry.imageFile.flatMap { store.cachedThumbnail(forFile: $0) },
                          fit: size, zoom: $zoom, resetToken: resetToken)
                .id(entry.id)
                .frame(width: area.width, height: area.height)
                .contextMenu { moreActions(entry) }
        } else {
            MomentMedia(entry: entry)
                .onDrag { dragItem(entry) }
                .id(entry.id)
                .frame(width: size.width, height: size.height)
                .contextMenu { moreActions(entry) }
                .frame(width: area.width, height: area.height)
        }
    }

    /// Everything the old Actions menu held, on a right-click of the picture.
    @ViewBuilder
    private func moreActions(_ entry: Entry) -> some View {
        let file = sourceURL(entry)
        if why.trimmed.isEmpty {
            Button("Add Why") { whyFocused = true }
        }
        Button("Copy") { copy(entry) }
        Button("Show in Finder") { if let file { NSWorkspace.shared.activateFileViewerSelecting([file]) } }
            .disabled(file == nil)
        Button("Open in Default App") { if let file { NSWorkspace.shared.open(file) } }
            .disabled(file == nil)
        if !entry.link.isEmpty, let url = URL(string: entry.link) {
            Button(entry.link.contains("figma.com") ? "Open in Figma" : "Open Link") { NSWorkspace.shared.open(url) }
        }
        Divider()
        Button("Open in New Window") { AppModel.shared.open(entry) }
        Divider()
        Button("Delete", role: .destructive, action: deleteCurrent)
    }

    // MARK: Stage

    /// The capture. A single picture can be pinched to zoom (see ZoomableImage);
    /// recordings, text and frame sets show as they are.
    /// The picture file, when the capture is one still picture.
    private func zoomableURL(_ entry: Entry) -> URL? {
        guard (entry.frames?.count ?? 0) <= 1, store.mediaURL(for: entry) == nil else { return nil }
        return store.imageURL(for: entry)
    }

    private func resetZoom() {
        resetToken += 1
        zoom = 1
    }

    // MARK: Details

    /// Previous, next and close, top right of the panel.
    private var navigation: some View {
        HStack(spacing: 2) {
            navButton("chevron.left", help: "Previous (←)") { step(-1) }
                .disabled(neighbor(-1) == nil)
            navButton("chevron.right", help: "Next (→)") { step(1) }
                .disabled(neighbor(1) == nil)
            navButton("xmark", help: "Close (esc)", action: close)
        }
        .padding(.top, Archive.Focus.navTop)
        .padding(.trailing, Archive.Focus.navTrailing)
    }

    /// What's said about the capture: its title and description first and
    /// largest, then when it was captured, where from, its type and link,
    /// then share and save.
    private func sidebar(_ entry: Entry, minHeight: CGFloat) -> some View {
        let F = Archive.Focus.self
        return VStack(alignment: .leading, spacing: F.blockGap) {
            titleAndDescription(entry)
                // A little more room before the details than between the rest.
                .padding(.bottom, F.titleToDetails - F.blockGap)
            details(entry)
            fileTools(entry)
        }
        .frame(minHeight: max(0, minHeight - 2 * F.sidebarInset), alignment: .top)
        .padding(.vertical, F.sidebarInset)
    }

    /// The narrow layout's details, kept short: title and description on the
    /// left; the facts, then share and save, on the right.
    private func stackedDetails(_ entry: Entry) -> some View {
        let F = Archive.Focus.self
        return HStack(alignment: .top, spacing: F.gap) {
            titleAndDescription(entry)
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: F.blockGap / 2) {
                details(entry)
                fileTools(entry)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The largest words beside the capture: its title, then its description.
    private func titleAndDescription(_ entry: Entry) -> some View {
        let F = Archive.Focus.self
        return VStack(alignment: .leading, spacing: F.titleGap) {
                // Your own title; clear it to go back to the one Margin picked.
                // Sentence case, as you type it.
                TextField(entry.displayTitle, text: $title, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Archive.headline(F.titleSize))
                    .foregroundStyle(Archive.ink)
                    .lineLimit(1...4)
                    .focused($titleFocused)
                    .onSubmit { titleFocused = false }
                    .onChange(of: titleFocused) { focused in if !focused { saveEdits() } }
                    .help("Click to rename")
                TextField("Why this?", text: $why, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Archive.sans(F.noteSize))
                    .foregroundStyle(Archive.ink)
                    .lineSpacing(F.noteLineSpacing)
                    .lineLimit(1...12)
                    .focused($whyFocused)
                    .onSubmit { whyFocused = false }
                    .onChange(of: whyFocused) { focused in if !focused { saveEdits() } }
        }
    }

    private func details(_ entry: Entry) -> some View {
        let F = Archive.Focus.self
        let file = sourceURL(entry)
        var rows: [(label: String, value: String, link: URL?)] = [("Captured", Self.captured(entry.createdAt), nil)]
        let source = Self.source(of: entry)
        // Where it came from, as words; the arrow under the details opens it.
        if let source { rows.append(("Source", source.name, nil)) }
        if let file { rows.append(("Type", Self.fileSummary(file), nil)) }
        if entry.siteFolder != nil {
            rows.append(("Page", entry.sitePage ?? "index.html", nil))
        }
        if let pixels = pixelSize(entry) {
            rows.append(("Size", "\(Int(pixels.width)) × \(Int(pixels.height))", nil))
        }
        // A page the capture came from, when the source isn't already that page.
        if source?.link == nil, !entry.link.isEmpty, let url = URL(string: entry.link) {
            rows.append(("Link", Self.shortLink(url), nil))
        }
        return VStack(alignment: .leading, spacing: F.rowGap) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(row.label)
                        // The label sits back in color, not in capitals.
                        .foregroundStyle(Archive.faint)
                        .frame(width: F.labelWidth, alignment: .leading)
                    Group {
                        if let url = row.link {
                            Link(destination: url) {
                                HStack(spacing: 4) {
                                    Text(row.value)
                                        .underline()
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                    // Chain links: this goes somewhere.
                                    Image(systemName: "link")
                                        .font(.system(size: F.valueSize - 1, weight: .regular))
                                        .foregroundStyle(Archive.muted)
                                }
                            }
                            .linkCursor()
                            .help(url.absoluteString)
                        } else {
                            Text(row.value)
                                .textSelection(.enabled)
                                .help(row.value)
                        }
                    }
                    .font(Archive.sans(F.valueSize))
                    // Sizes and times line up: tabular figures.
                    .monospacedDigit()
                    .foregroundStyle(Archive.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                }
                .font(Archive.font(F.labelSize))
                .frame(height: F.rowHeight)
            }
        }
        .help(entry.createdAt.formatted(date: .complete, time: .shortened))
    }

    /// Where it came from: Figma (linking to the frame), the link itself when
    /// a link was what was captured, otherwise the app (a browser, Notes…).
    static func source(of entry: Entry) -> (name: String, link: URL?)? {
        let url = entry.link.isEmpty ? nil : URL(string: entry.link)
        if let url, url.host?.contains("figma.com") == true || entry.kind == .figma {
            return ("Figma", url)
        }
        // A conversation in the Claude app: open it there, not in a browser,
        // where Code sessions ("epitaxy/local_…") don't exist.
        if let url, url.host == "claude.ai", let inApp = claudeAppLink(url) {
            return ("Claude", inApp)
        }
        if entry.kind == .figma { return ("Figma", nil) }
        if entry.kind == .link, let url { return (shortLink(url), url) }
        if let app = entry.sourceApp?.trimmed, !app.isEmpty { return (app, nil) }
        return nil
    }

    /// claude.ai/… as the Claude app's own link (claude://claude.ai/…).
    static func claudeAppLink(_ url: URL) -> URL? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.scheme = "claude"
        return parts.url
    }

    /// The picture's size in pixels, when the capture is a picture.
    private func pixelSize(_ entry: Entry) -> CGSize? {
        guard store.mediaURL(for: entry) == nil || entry.kind == .capture,
              let url = store.mediaURL(for: entry) ?? store.imageURL(for: entry),
              // Only in iCloud: no size rather than a wait for the download.
              EntryStore.isOnThisMac(url),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return CGSize(width: width, height: height)
    }

    /// Under the details: download, then delete. Both at once, no question,
    /// and at the scale of the archive header's tools (search, hand off).
    private func fileTools(_ entry: Entry) -> some View {
        let live = LiveSource.of(entry, coding: coding)
        let link = entry.link.isEmpty ? nil : URL(string: entry.link)
        return HStack(spacing: 2) {
            if let live {
                HeaderTool(help: "Open in browser", action: { openInBrowser(entry) }) {
                    Image(systemName: "arrow.up.right").font(.system(size: 12.5, weight: .medium))
                }
            } else if let link {
                // The source itself: the frame in Figma, the page, the chat.
                HeaderTool(help: link.host?.contains("figma.com") == true ? "Open in Figma" : "Open link", action: { NSWorkspace.shared.open(link) }) {
                    Image(systemName: "arrow.up.right").font(.system(size: 12.5, weight: .medium))
                }
            }
            if let live, live.hasFiles {
                HeaderTool(help: "Show in Finder", action: { showFiles(entry) }) {
                    Image(systemName: "folder").font(.system(size: 13))
                }
            }
            HeaderTool(help: "Download to your Downloads folder", action: { download(entry) }) {
                // The arrow makes the symbol sit low in its box: up a point,
                // so it looks centred in the pill like the bin beside it.
                Image(systemName: "square.and.arrow.down").font(.system(size: 13.5))
                    .offset(y: -1)
            }
            .disabled(sourceURL(entry) == nil)
            HeaderTool(help: "Delete this artifact (⌘⌫)", action: deleteCurrent) {
                Image(systemName: "trash").font(.system(size: 13.5))
            }
        }
        // The icons line up with the labels above; their hover pill reaches out.
        .padding(.leading, -(RepoHeader.toolWidth - 14) / 2)
    }

    private func openInBrowser(_ entry: Entry) {
        if case .website(let url) = LiveSource.of(entry, coding: coding) {
            NSWorkspace.shared.open(url)
            return
        }
        if coding.siteFolder(entry) != nil {
            coding.openSite(entry)
            return
        }
        Task {
            do {
                try await coding.openVersion(entry)
            } catch {
                show((error as? LocalizedError)?.errorDescription ?? "Couldn't open: \(error.localizedDescription)")
            }
        }
    }

    private func showFiles(_ entry: Entry) {
        if let folder = coding.siteFolder(entry) {
            let page = folder.appendingPathComponent(entry.sitePage ?? "index.html")
            NSWorkspace.shared.activateFileViewerSelecting([FileManager.default.fileExists(atPath: page.path) ? page : folder])
            return
        }
        Task {
            do {
                let folder = try await coding.exportVersion(entry)
                NSWorkspace.shared.activateFileViewerSelecting([folder])
            } catch {
                show((error as? LocalizedError)?.errorDescription ?? "Couldn't show the files: \(error.localizedDescription)")
            }
        }
    }

    /// Straight into Downloads, named after the artifact, never over a file
    /// that's already there.
    private func download(_ entry: Entry) {
        guard let source = sourceURL(entry),
              let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return }
        let ext = source.pathExtension
        let base = Self.fileName(for: entry, extension: "")
        var destination = folder.appendingPathComponent(Self.fileName(for: entry, extension: ext))
        var copy = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(copy)" : "\(base) \(copy).\(ext)")
            copy += 1
        }
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            show("Saved to Downloads")
        } catch {
            show("Couldn't save: \(error.localizedDescription)")
        }
    }

    /// SwiftUI won't rewrite a field's text while you're typing in it, so the
    /// capitals go straight into the field being typed in, the caret kept
    /// where it was.
    static func capitalizeFieldEditor() {
        let typing = { (window: NSWindow?) in (window?.firstResponder as? NSTextView).flatMap { $0.isFieldEditor ? $0 : nil } }
        guard let editor = typing(NSApp.keyWindow) ?? NSApp.windows.lazy.compactMap(typing).first,
              !editor.hasMarkedText() else { return }
        let text = editor.string as NSString
        let upper = editor.string.uppercased()
        // Letters that grow when capitalized ("ß" to "SS") would move the caret; leave those.
        guard upper != editor.string, (upper as NSString).length == text.length else { return }
        let selection = editor.selectedRanges
        editor.replaceCharacters(in: NSRange(location: 0, length: text.length), with: upper)
        editor.selectedRanges = selection
    }

    /// When it was captured: minutes within the hour, hours within the day,
    /// days within the week, then the date itself ("Oct 17").
    static func captured(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "Just now" }
        if seconds < 3600 {
            let minutes = Int(seconds / 60)
            return minutes == 1 ? "1 minute ago" : "\(minutes) minutes ago"
        }
        if seconds < 86_400 {
            let hours = Int(seconds / 3600)
            return hours == 1 ? "1 hour ago" : "\(hours) hours ago"
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 8
        if days <= 7 { return days <= 1 ? "Yesterday" : "\(days) days ago" }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "MMM d" : "MMM d yyyy")
        return formatter.string(from: date)
    }

    /// A link as you'd say it: "figma.com/design/…", without the scheme or "www.".
    static func shortLink(_ url: URL) -> String {
        let host = (url.host ?? "").replacingOccurrences(of: "www.", with: "")
        let path = url.path == "/" ? "" : url.path
        return host.isEmpty ? url.absoluteString : host + path
    }

    // MARK: Keyboard

    /// Esc, arrows, ⌘S and ⌘C, but not while you're typing a note.
    private var shortcuts: some View {
        ZStack {
            Button("", action: close).keyboardShortcut(.cancelAction)
            Button("") { if let entry { save(entry) } }.keyboardShortcut("s", modifiers: .command)
            Button("") { if let entry { copy(entry) } }.keyboardShortcut("c", modifiers: .command)
            Button("", action: deleteCurrent).keyboardShortcut(.delete, modifiers: .command)
            Button("", action: resetZoom).keyboardShortcut("0", modifiers: .command)
        }
        .disabled(whyFocused || titleFocused)
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    /// ← and → step through the artifacts unless you're typing in the title
    /// or description; a click anywhere outside those fields stops typing, so
    /// the arrows step again (a field otherwise keeps the keyboard after you
    /// click away from it).
    private func watchKeys() {
        guard monitors.isEmpty else { return }
        func typing(in window: NSWindow?) -> Bool {
            guard let responder = window?.firstResponder else { return false }
            // Typing in a field, or using a live page (its arrows scroll it).
            return responder is NSText || (responder as? NSView)?.isInWebView == true
        }
        let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let plain = event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
            guard plain, [123, 124].contains(event.keyCode), event.window?.isMainWindow == true,
                  !typing(in: event.window) else { return event }
            arrows.step(event.keyCode == 123 ? -1 : 1)
            return nil
        }
        let clicks = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            guard let window = event.window, window.isMainWindow, typing(in: window),
                  let content = window.contentView else { return event }
            let hit = content.hitTest(content.convert(event.locationInWindow, from: nil))
            // A click in a text field or a live page keeps the keyboard there;
            // anywhere else ends it.
            if !(hit is NSText || hit is NSTextField || hit?.isInWebView == true) {
                window.makeFirstResponder(nil)
                titleFocused = false
                whyFocused = false
            }
            return event
        }
        monitors = [keys, clicks].compactMap { $0 }
        // Opening on an artifact doesn't start typing in its title.
        DispatchQueue.main.async { stopTyping() }
    }

    private func stopTyping() {
        if let window = NSApp.mainWindow, window.firstResponder is NSText {
            window.makeFirstResponder(nil)
        }
        titleFocused = false
        whyFocused = false
    }

    // MARK: Pieces

    private func navButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        NavIcon(symbol: symbol, action: action)
            .pointingHand()
            .help(help)
    }

    // MARK: Stepping

    /// The artifact `offset` steps away in the archive's order, skipping any
    /// that no longer exist (just deleted).
    private func neighbor(_ offset: Int) -> UUID? {
        let live = order.filter { $0 == entryID || store.entry(id: $0) != nil }
        guard let index = live.firstIndex(of: entryID) else { return nil }
        let next = index + offset
        return live.indices.contains(next) ? live[next] : nil
    }

    /// Deletes the capture in focus and moves on to the next one (or the
    /// previous, at the end); closes when there's nothing left.
    private func deleteCurrent() {
        guard let entry else { return }
        let next = neighbor(1) ?? neighbor(-1)
        if let next {
            entryID = next
            loadEdits()
            resetZoom()
        }
        withAnimation(Brand.motion) { store.delete(entry) }
        if next == nil { close() }
    }

    private func step(_ offset: Int) {
        guard let next = neighbor(offset) else { return }
        stopTyping()
        saveEdits()
        resetZoom()
        entryID = next
        loadEdits()
        flash = nil
    }

    private func loadEdits() {
        let entry = store.entry(id: entryID)
        title = entry?.displayTitle ?? ""
        why = entry?.rationale ?? ""
    }

    /// Saves the title and the why. A title left as Margin's own isn't stored,
    /// so it keeps following the capture; an empty one goes back to Margin's.
    private func saveEdits() {
        guard let entry else { return }
        let newTitle = title.trimmed
        let titleChanged = newTitle != entry.displayTitle
        let whyChanged = why.trimmed != entry.rationale.trimmed
        guard titleChanged || whyChanged else { return }
        store.modify(entry.id) { saved in
            if titleChanged { saved.title = newTitle }
            if whyChanged { saved.rationale = why.trimmed }
        }
        if newTitle.isEmpty, let updated = store.entry(id: entry.id) { title = updated.displayTitle }
    }

    // MARK: Keeping a copy

    /// The captured file: a recording or formatted text if there is one, else the image.
    private func sourceURL(_ entry: Entry) -> URL? {
        store.mediaURL(for: entry) ?? store.imageURL(for: entry)
    }

    private func save(_ entry: Entry) {
        guard let source = sourceURL(entry) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = Self.fileName(for: entry, extension: source.pathExtension)
        panel.canCreateDirectories = true
        if let type = UTType(filenameExtension: source.pathExtension) { panel.allowedContentTypes = [type] }
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: source, to: destination)
                show("Saved to \(destination.deletingLastPathComponent().lastPathComponent)")
            } catch {
                show("Couldn't save: \(error.localizedDescription)")
            }
        }
    }

    /// Puts the capture on the clipboard in every form apps understand:
    /// image data for design tools, the file for Finder, text with its formatting.
    private func copy(_ entry: Entry) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        if let media = store.mediaURL(for: entry), let data = try? Data(contentsOf: media) {
            switch media.pathExtension.lowercased() {
            case "rtf": item.setData(data, forType: .rtf)
            case "html": item.setData(data, forType: .html)
            default: break
            }
        }
        if !entry.body.isEmpty, entry.kind == .text {
            item.setString(entry.body, forType: .string)
        }
        if let image = store.imageURL(for: entry).flatMap(NSImage.init(contentsOf:)),
           let tiff = image.tiffRepresentation {
            item.setData(tiff, forType: .tiff)
            if let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                item.setData(png, forType: .png)
            }
        }
        if let file = sourceURL(entry) {
            item.setString(file.absoluteString, forType: .fileURL)
        }
        pasteboard.writeObjects([item])
        show("Copied")
    }

    private func dragItem(_ entry: Entry) -> NSItemProvider {
        guard let file = sourceURL(entry), let provider = NSItemProvider(contentsOf: file) else { return NSItemProvider() }
        provider.suggestedName = Self.fileName(for: entry, extension: "")
        return provider
    }

    private func show(_ message: String) {
        flash = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            if flash == message { flash = nil }
        }
    }

    // MARK: Helpers

    /// A file name from the moment's title, safe for Finder.
    static func fileName(for entry: Entry, extension ext: String) -> String {
        var base = entry.displayTitle.trimmed
        if base.isEmpty { base = "Margin \(entry.createdAt.formatted(date: .numeric, time: .shortened))" }
        base = base.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
        if base.count > 80 { base = String(base.prefix(80)).trimmed }
        return ext.isEmpty ? base : "\(base).\(ext)"
    }

    static func fileSummary(_ url: URL) -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }
        let kind = url.pathExtension.uppercased()
        guard let size else { return kind }
        let bytes = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file).replacingOccurrences(of: " ", with: "")
        return "\(kind) \(bytes)"
    }
}

// MARK: - Focus pieces

/// Two blocks, one at the top and one at the bottom, at least `minHeight`
/// apart; taller only when they need the room.
private struct TopAndBottom: Layout {
    var minHeight: CGFloat
    var gap: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? Archive.Focus.sidebarWidth
        let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        return CGSize(width: width, height: max(minHeight, heights.reduce(0, +) + gap * CGFloat(max(heights.count - 1, 0))))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let child = ProposedViewSize(width: bounds.width, height: nil)
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: child)
        if subviews.count > 1 {
            subviews[subviews.count - 1].place(at: CGPoint(x: bounds.minX, y: bounds.maxY), anchor: .bottomLeading, proposal: child)
        }
    }
}

/// Your note in Helvetica Neue, as you wrote it. Click it to edit.
private struct EditableNote: View {
    @Binding var text: String
    /// Open for typing straight away (a new note).
    var startEditing = false
    var focus: FocusState<Bool>.Binding
    let commit: () -> Void
    @State private var editing = false

    var body: some View {
        Group {
            if editing {
                TextField("Add an annotation...", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...12)
                    .focused(focus)
                    .onSubmit { focus.wrappedValue = false }
                    .onAppear { focus.wrappedValue = true }
                    .onChange(of: focus.wrappedValue) { focused in
                        if !focused {
                            editing = false
                            commit()
                        }
                    }
            } else {
                Text(text.trimmed)
                    .lineLimit(12)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { editing = true }
                    .help("Click to edit")
            }
        }
        .font(Archive.sans(Archive.Focus.noteSize))
        .foregroundStyle(Archive.ink)
        .lineSpacing(Archive.Focus.noteLineSpacing)
        .onAppear { if startEditing { editing = true } }
    }
}

/// Previous, next or close: ink, faint when there's nowhere to go.
private struct NavIcon: View {
    let symbol: String
    var tint = Archive.ink
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(enabled ? tint : Archive.faint)
                .frame(width: Archive.Focus.navSize, height: Archive.Focus.navSize)
                // A soft grey fill on hover, like the archive header's tools.
                .background(
                    RoundedRectangle(cornerRadius: RepoHeader.toolRadius, style: .continuous)
                        .fill(Color.primary.opacity(enabled && hovering ? 0.055 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hovering = inside } }
    }
}

/// A small rounded rectangle with a word in it.
struct Tooltip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Archive.font(Archive.Size.meta))
            .foregroundStyle(Archive.paper)
            .lineLimit(1)
            .padding(.horizontal, Archive.Space.x2)
            .padding(.vertical, Archive.Space.x1)
            .background(Archive.ink, in: RoundedRectangle(cornerRadius: Archive.Space.x1, style: .continuous))
    }
}

// MARK: - Zoom

/// A picture you can zoom, like in Lightroom and Preview: click to zoom in
/// 3.5× around that point (click again for fit), pinch for anything up to 8×,
/// drag or scroll to look around. At fit, dragging the picture out saves a
/// copy of the file.
private struct ZoomableImage: NSViewRepresentable {
    let url: URL
    /// The thumbnail already in memory: shown the moment the view opens,
    /// while the full picture is read off the main thread.
    let preview: NSImage?
    /// The picture's size at fit; the view itself is the whole space it can grow into.
    let fit: CGSize
    @Binding var zoom: CGFloat
    let resetToken: Int

    final class Coordinator {
        var resetToken = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ZoomScrollView {
        let scroll = ZoomScrollView()
        let picture = PictureView()
        picture.image = preview
        picture.fileURL = url
        // The full picture can take a moment (a large screenshot is read and
        // its corners squared pixel by pixel), so it never holds the window.
        let source = url
        DispatchQueue.global(qos: .userInitiated).async {
            let full = ImageTools.picture(at: source)
            DispatchQueue.main.async { [weak picture] in
                if let full { picture?.image = full }
            }
        }
        let stage = FitStage(picture: picture)
        stage.fit = fit
        scroll.documentView = stage
        context.coordinator.resetToken = resetToken
        return scroll
    }

    func updateNSView(_ scroll: ZoomScrollView, context: Context) {
        if let stage = scroll.documentView as? FitStage, stage.fit != fit {
            stage.fit = fit
        }
        scroll.onZoom = { value in
            if abs(zoom - value) > 0.001 { zoom = value }
        }
        if context.coordinator.resetToken != resetToken {
            context.coordinator.resetToken = resetToken
            scroll.zoomToFit()
        }
    }
}

final class ZoomScrollView: NSScrollView {
    var onZoom: ((CGFloat) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        drawsBackground = false
        hasHorizontalScroller = false
        hasVerticalScroller = false
        allowsMagnification = true
        minMagnification = 1
        maxMagnification = 8
        NotificationCenter.default.addObserver(self, selector: #selector(magnified), name: NSScrollView.didEndLiveMagnifyNotification, object: self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// At fit, the stage is the space it's given, so it resizes with the window.
    override func layout() {
        super.layout()
        if magnification <= 1.0001, let stage = documentView {
            stage.frame = NSRect(origin: .zero, size: contentView.bounds.size)
        }
    }

    /// Two-finger double-tap, the trackpad's own zoom gesture.
    override func smartMagnify(with event: NSEvent) {
        let point = documentView?.convert(event.locationInWindow, from: nil) ?? .zero
        toggleZoom(at: point)
    }

    /// How far a click zooms in.
    static let clickZoom: CGFloat = 3.5

    /// Zooms in around `point`, or back to fit when already zoomed. Quick and
    /// eased, so you see where you're going instead of jumping there.
    func toggleZoom(at point: NSPoint, then done: (() -> Void)? = nil) {
        if magnification > 1.01 {
            zoomToFit(then: done)
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().setMagnification(Self.clickZoom, centeredAt: point)
            } completionHandler: { [weak self] in
                self?.magnified()
                done?()
            }
        }
    }

    func zoomToFit(then done: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().magnification = 1
        } completionHandler: { [weak self] in
            self?.needsLayout = true
            self?.magnified()
            done?()
        }
    }

    @objc func magnified() {
        onZoom?(magnification)
    }
}

/// The whole space a picture can grow into, with the picture centered at its
/// fitted size. Zooming scales the stage, so the picture grows past its
/// fitted size until it fills the space, and on from there.
final class FitStage: NSView {
    let picture: PictureView
    var fit: CGSize = .zero {
        didSet { needsLayout = true }
    }

    init(picture: PictureView) {
        self.picture = picture
        super.init(frame: .zero)
        addSubview(picture)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let width = min(fit.width > 0 ? fit.width : bounds.width, bounds.width)
        let height = min(fit.height > 0 ? fit.height : bounds.height, bounds.height)
        picture.frame = NSRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height)
    }
}

/// The picture inside the zoom view. Click to zoom in or back to fit. Drag
/// to look around when zoomed in; at fit, drag it out of Margin to save a copy.
/// Over the picture the pointer is a magnifying glass, so it's clear it zooms.
final class PictureView: NSImageView, NSDraggingSource {
    var fileURL: URL?
    private var dragStart: NSPoint?
    /// The pointer moved since mouse down, so this isn't a click.
    private var moved = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        imageScaling = .scaleProportionallyUpOrDown
        animates = true
        isEditable = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var scroll: ZoomScrollView? { enclosingScrollView as? ZoomScrollView }
    private var isZoomed: Bool { (scroll?.magnification ?? 1) > 1.01 }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func cursorUpdate(with event: NSEvent) { updateCursor(event) }
    override func mouseMoved(with event: NSEvent) { updateCursor(event) }
    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }

    /// Where the picture is drawn: fitted inside the view, the rest is empty.
    private var pictureRect: NSRect {
        guard let size = image?.size, size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let fitted = NSSize(width: size.width * scale, height: size.height * scale)
        return NSRect(x: bounds.midX - fitted.width / 2, y: bounds.midY - fitted.height / 2, width: fitted.width, height: fitted.height)
    }

    private func isOverPicture(_ event: NSEvent) -> Bool {
        pictureRect.contains(convert(event.locationInWindow, from: nil))
    }

    /// A magnifying glass over the picture, an arrow around it.
    func updateCursor(_ event: NSEvent? = nil) {
        if let event, !isOverPicture(event) {
            NSCursor.arrow.set()
        } else {
            MagnifierCursor.glass.set()
        }
    }

    // MARK: Clicks and drags

    override func mouseDown(with event: NSEvent) {
        // Only the picture itself zooms or drags; the empty space around it doesn't.
        guard isZoomed || isOverPicture(event) else { dragStart = nil; return }
        dragStart = event.locationInWindow
        moved = false
    }

    override func mouseUp(with event: NSEvent) {
        // A click, not a drag: zoom in around it, or back to fit.
        if !moved, dragStart != nil {
            scroll?.toggleZoom(at: convert(event.locationInWindow, from: nil)) { [weak self] in
                self?.updateCursor()
            }
        } else {
            updateCursor(event)
        }
        dragStart = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let scroll, let start = dragStart else { return }
        if hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) > 3 {
            moved = true
        }
        if isZoomed {
            // Grab and move: the picture follows the pointer.
            NSCursor.closedHand.set()
            let clip = scroll.contentView
            var origin = clip.bounds.origin
            origin.x -= event.deltaX / scroll.magnification
            origin.y += event.deltaY / scroll.magnification
            clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
            scroll.reflectScrolledClipView(clip)
        } else if let fileURL, moved {
            dragStart = nil
            let item = NSDraggingItem(pasteboardWriter: fileURL as NSURL)
            item.setDraggingFrame(pictureRect, contents: image)
            beginDraggingSession(with: [item], event: event, source: self)
        }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}

/// A magnifying glass pointer, drawn in the mode-neutral way macOS draws its
/// own: a black glass and handle with a white edge and a soft shadow, so it
/// reads on light and dark pictures.
enum MagnifierCursor {
    static let glass = make()

    /// Drawn at 70% of the original 28 pt design, about 19.5 pt.
    private static let k: CGFloat = 0.7

    private static func make() -> NSCursor {
        let size = NSSize(width: 28 * k, height: 28 * k)
        let center = NSPoint(x: 11 * k, y: 11 * k)
        let radius: CGFloat = 7.5 * k
        let image = NSImage(size: size, flipped: true) { _ in
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.shadowBlurRadius = 1.6
            shadow.shadowOffset = NSSize(width: 0, height: -1)

            let lens = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            let handle = NSBezierPath()
            handle.move(to: NSPoint(x: center.x + radius * 0.72, y: center.y + radius * 0.72))
            handle.line(to: NSPoint(x: 24.5 * k, y: 24.5 * k))
            handle.lineCapStyle = .round

            // White edge, with the shadow under it.
            NSGraphicsContext.saveGraphicsState()
            shadow.set()
            NSColor.white.setStroke()
            lens.lineWidth = 3.6
            lens.stroke()
            handle.lineWidth = 5
            handle.stroke()
            NSGraphicsContext.restoreGraphicsState()

            // A pale glass.
            NSColor.white.withAlphaComponent(0.92).setFill()
            lens.fill()

            // The black ring and handle.
            NSColor.black.setStroke()
            lens.lineWidth = 1.6
            lens.stroke()
            handle.lineWidth = 2.6
            handle.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: center)
    }
}

// MARK: - Deck carousel

/// A stack's media (a slide deck's slides), one at a time: the slide large,
/// and a row of thumbnails under it. The one showing is at full strength,
/// the rest at half. Click a thumbnail to move. Arrows show only
/// when there are cards out of view on that side: when the whole row fits,
/// there are none.
private struct DeckCarousel: View {
    @EnvironmentObject private var store: EntryStore
    let frames: [FrameRef]
    let area: CGSize
    @State private var selected = 0
    /// The first thumbnail in view.
    @State private var first = 0

    static let thumb = CGSize(width: 104, height: 70)
    static let thumbGap: CGFloat = 12
    static let stripGap: CGFloat = 24
    static let arrowWidth: CGFloat = 28
    static let margin: CGFloat = 32

    private var stripWidth: CGFloat {
        let room = area.width - 2 * Self.margin - 2 * (Self.arrowWidth + Self.thumbGap)
        let fits = max(1, Int((room + Self.thumbGap) / (Self.thumb.width + Self.thumbGap)))
        return CGFloat(min(fits, frames.count)) * (Self.thumb.width + Self.thumbGap) - Self.thumbGap
    }

    private var visible: Int {
        max(1, Int((stripWidth + Self.thumbGap) / (Self.thumb.width + Self.thumbGap)))
    }

    var body: some View {
        VStack(spacing: Self.stripGap) {
            slide
                .frame(maxWidth: area.width - 2 * Self.margin, maxHeight: max(80, area.height - Self.thumb.height - Self.stripGap - 2 * Self.margin))
            strip
        }
        .frame(width: area.width, height: area.height)
    }

    @ViewBuilder
    private var slide: some View {
        if let file = frames[selected].imageFile, let image = NSImage(contentsOf: store.imageURL(forFile: file)) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .id(selected)
                .transition(.opacity)
        } else {
            Brand.fill
        }
    }

    private var strip: some View {
        HStack(spacing: Self.thumbGap) {
            // Each arrow brings in the next card hidden on its side.
            arrow("chevron.left", shown: first > 0) { select(first - 1) }
            HStack(spacing: Self.thumbGap) {
                ForEach(Array(frames.enumerated()), id: \.offset) { index, frame in
                    thumbnail(frame, index: index)
                }
            }
            .offset(x: -CGFloat(first) * (Self.thumb.width + Self.thumbGap))
            .frame(width: stripWidth, height: Self.thumb.height, alignment: .leading)
            .clipped()
            arrow("chevron.right", shown: first + visible < frames.count) { select(first + visible) }
        }
    }

    private func thumbnail(_ frame: FrameRef, index: Int) -> some View {
        Group {
            if let file = frame.imageFile, let image = store.thumbnail(forFile: file) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Brand.fill
            }
        }
        .frame(width: Self.thumb.width, height: Self.thumb.height)
        .clipped()
        // The one showing at full strength, the rest at half.
        .opacity(index == selected ? 1 : 0.5)
        .contentShape(Rectangle())
        .onTapGesture { select(index) }
        .pointingHand()
        .help(frame.name ?? "Slide \(index + 1)")
    }

    private func arrow(_ symbol: String, shown: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(Archive.ink)
                .frame(width: Self.arrowWidth, height: Self.thumb.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHand()
        .opacity(shown ? 1 : 0)
        .allowsHitTesting(shown)
        .animation(.easeOut(duration: 0.2), value: shown)
    }

    /// Shows slide `index`, moving the row only when it's out of view.
    private func select(_ index: Int) {
        guard frames.indices.contains(index) else { return }
        withAnimation(Brand.motion) {
            selected = index
            if index >= first + visible { first = index - visible + 1 }
            if index < first { first = index }
        }
    }
}
