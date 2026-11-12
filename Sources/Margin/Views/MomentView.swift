import AVKit
import AppKit
import MarginKit
import SwiftUI

/// One moment, large: the frame, recording or text as it was captured, where
/// it came from, and the designer's why. ⌘← and ⌘→ step through the project.
struct MomentView: View {
    @EnvironmentObject private var store: EntryStore
    @EnvironmentObject private var coding: CodingSessions
    @State var entryID: UUID
    @State private var why = ""
    @FocusState private var whyFocused: Bool
    @State private var showingChanges = false
    @State private var diffText: String?
    @State private var versionState: VersionState = .idle

    enum VersionState: Equatable {
        case idle, starting, failed(String)
    }

    private var entry: Entry? { store.entry(id: entryID) }

    var body: some View {
        Group {
            if let entry {
                VStack(spacing: 0) {
                    header(entry)
                    Group {
                        if showingChanges {
                            DiffView(text: diffText)
                                .overlay(Rectangle().strokeBorder(Brand.hairline, lineWidth: 1))
                        } else {
                            MomentMedia(entry: entry)
                        }
                    }
                        .id(entry.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 16)
                    Rectangle().fill(Brand.hairline).frame(height: 1)
                    footer(entry)
                }
            } else {
                VStack(spacing: 12) {
                    Mark(size: 32, dot: 0).opacity(0.4)
                    Text("This moment was deleted.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        .background(Brand.background)
        .ignoresSafeArea()
        .onAppear { why = entry?.rationale ?? "" }
        .onDisappear(perform: saveWhy)
    }

    // MARK: Pieces

    private func header(_ entry: Entry) -> some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: 64) // traffic lights
            Image(systemName: entry.kind.symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text(entry.kind.label)
                .font(Theme.Typography.ui(12, .medium))
            Text(meta(entry))
                .font(Theme.Typography.ui(12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button { step(-1) } label: {
                Image(systemName: "chevron.left").frame(width: 26, height: 22)
            }
            .buttonStyle(SoftButtonStyle())
            .keyboardShortcut(.leftArrow, modifiers: .command)
            .disabled(neighbor(-1) == nil)
            .help("Earlier moment (⌘←)")
            Button { step(1) } label: {
                Image(systemName: "chevron.right").frame(width: 26, height: 22)
            }
            .buttonStyle(SoftButtonStyle())
            .keyboardShortcut(.rightArrow, modifiers: .command)
            .disabled(neighbor(1) == nil)
            .help("Later moment (⌘→)")
        }
        .font(.system(size: 11, weight: .semibold))
        .padding(.leading, 12)
        .padding(.trailing, 14)
        .frame(height: 40)
    }

    private func footer(_ entry: Entry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if entry.kind == .iteration {
                iterationDetails(entry)
            } else if !entry.displayTitle.isEmpty, entry.displayTitle != entry.kind.label {
                Text(entry.displayTitle)
                    .font(Theme.Typography.ui(15, .medium))
                    .lineLimit(2)
            }
            MarginNote(entry: entry)
            TextField("Why this?", text: $why, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.Typography.ui(13))
                .lineLimit(1...4)
                .focused($whyFocused)
                .onSubmit(saveWhy)
                .onChange(of: whyFocused) { focused in if !focused { saveWhy() } }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: Brand.smallRadius, style: .continuous).fill(Brand.fill))
            HStack(spacing: 8) {
                if entry.siteFolder != nil {
                    siteActions(entry)
                } else if entry.kind == .iteration {
                    iterationActions(entry)
                }
                if let url = URL(string: entry.link), !entry.link.isEmpty {
                    Button { NSWorkspace.shared.open(url) } label: {
                        Label(entry.link.contains("figma.com") ? "Open in Figma" : (url.host ?? "Open link"), systemImage: "arrow.up.right")
                            .font(Theme.Typography.ui(12, .medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                    }
                    .buttonStyle(SoftButtonStyle())
                    .help(entry.link)
                }
                if entry.kind == .text {
                    Button { copyText(entry) } label: {
                        Label("Copy text", systemImage: "doc.on.doc")
                            .font(Theme.Typography.ui(12, .medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                    }
                    .buttonStyle(SoftButtonStyle())
                }
                if entry.kind != .iteration, let url = store.mediaURL(for: entry) ?? store.imageURL(for: entry) {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                        Label("Show in Finder", systemImage: "folder")
                            .font(Theme.Typography.ui(12, .medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                    }
                    .buttonStyle(SoftButtonStyle())
                }
                Spacer()
                tabMenu(entry)
                Menu {
                    ForEach(store.projects, id: \.self) { name in
                        Button(name) { store.modify(entry.id) { $0.project = name } }
                    }
                } label: {
                    Text(entry.project)
                        .font(Theme.Typography.ui(12))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Move to another project")
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    /// File this moment under a tab: one you have, or the one Margin suggests.
    private func tabMenu(_ entry: Entry) -> some View {
        let tabs = Array(Set(store.entries(in: entry.project).compactMap(\.tab))).sorted()
        return Menu {
            Button("No tab") { store.modify(entry.id) { $0.tab = nil } }
            if !tabs.isEmpty { Divider() }
            ForEach(tabs, id: \.self) { name in
                Button(name) { store.modify(entry.id) { $0.tab = name } }
            }
            if let topic = entry.ai?.topic, !tabs.contains(topic) {
                Divider()
                Button("New tab: \(topic)") { store.modify(entry.id) { $0.tab = topic } }
            }
        } label: {
            Label(entry.tab ?? "No tab", systemImage: "rectangle.stack")
                .font(Theme.Typography.ui(12))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Tab")
    }

    // MARK: Iterations

    @ViewBuilder
    private func iterationDetails(_ entry: Entry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let prompt = entry.prompt {
                labeled("You asked") {
                    Text(prompt)
                        .font(Theme.Typography.ui(14, .medium))
                        .lineLimit(4)
                        .textSelection(.enabled)
                }
            }
            if let expectation = entry.expectation, !expectation.isEmpty {
                labeled("You expected") {
                    Text(expectation).font(Theme.Typography.ui(13))
                }
            }
            labeled("Result") {
                HStack(spacing: 6) {
                    ForEach(Entry.verdicts, id: \.id) { option in
                        Button {
                            store.modify(entry.id) { $0.verdict = $0.verdict == option.id ? nil : option.id }
                        } label: {
                            Text(option.label)
                                .font(Theme.Typography.ui(11, .medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(entry.verdict == option.id ? Color.primary.opacity(0.85) : Brand.fill))
                                .foregroundStyle(entry.verdict == option.id ? Brand.background : Color.primary)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    if let stat = entry.diffStat {
                        Text(stat)
                            .font(Theme.Typography.ui(11).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.leading, 6)
                    }
                }
            }
            if let summary = entry.summary, !summary.isEmpty {
                labeled(entry.agent ?? "Agent") {
                    Text(summary)
                        .font(Theme.Typography.ui(12))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .help(summary)
                }
            }
        }
    }

    private func labeled<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(Theme.Typography.ui(11))
                .foregroundStyle(.tertiary)
                .frame(width: 84, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    /// An HTML capture: its copy opens in the browser, served by Margin.
    @ViewBuilder
    private func siteActions(_ entry: Entry) -> some View {
        Button { coding.openSite(entry) } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .semibold))
                Text("Open in browser")
                    .font(Theme.Typography.ui(12, .medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        .buttonStyle(SoftButtonStyle())
        .disabled(coding.siteFolder(entry) == nil)
        .help("Opens this version of the page, as it was when you captured it")
        if let folder = coding.siteFolder(entry) {
            Button { NSWorkspace.shared.activateFileViewerSelecting([folder]) } label: {
                Text("Show files").font(Theme.Typography.ui(12)).padding(.horizontal, 10).padding(.vertical, 5)
            }
            .buttonStyle(SoftButtonStyle())
        }
    }

    @ViewBuilder
    private func iterationActions(_ entry: Entry) -> some View {
        let running = coding.runningVersions[entry.id]
        Button {
            if let running {
                NSWorkspace.shared.open(running)
            } else {
                versionState = .starting
                Task {
                    do {
                        try await coding.openVersion(entry)
                        versionState = .idle
                    } catch {
                        versionState = .failed((error as? LocalizedError)?.errorDescription ?? "\(error)")
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: running == nil ? "play.fill" : "arrow.up.right")
                    .font(.system(size: 10, weight: .semibold))
                Text(running == nil ? (versionState == .starting ? "Starting" : "Open this version") : "Open in browser")
                    .font(Theme.Typography.ui(12, .medium))
            }
            .shimmer(versionState == .starting)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        .buttonStyle(SoftButtonStyle())
        .disabled(versionState == .starting || entry.snapshot == nil)
        .help("Runs the code exactly as it was after this iteration, on localhost")
        if running != nil {
            Button { coding.stopVersion(entry) } label: {
                Text("Stop").font(Theme.Typography.ui(12)).padding(.horizontal, 10).padding(.vertical, 5)
            }
            .buttonStyle(SoftButtonStyle())
        }
        Button {
            showingChanges.toggle()
            if showingChanges, diffText == nil {
                Task { diffText = await coding.diff(for: entry) }
            }
        } label: {
            Label(showingChanges ? "Show picture" : "Show changes", systemImage: showingChanges ? "photo" : "plusminus")
                .font(Theme.Typography.ui(12, .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
        }
        .buttonStyle(SoftButtonStyle())
        Button {
            Task {
                if let folder = try? await coding.exportVersion(entry) {
                    NSWorkspace.shared.activateFileViewerSelecting([folder])
                }
            }
        } label: {
            Label("Code", systemImage: "folder")
                .font(Theme.Typography.ui(12, .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
        }
        .buttonStyle(SoftButtonStyle())
        .help("Show this version's files in Finder")
        if case .failed(let message) = versionState {
            Text(message)
                .font(Theme.Typography.ui(11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .help(message)
        }
    }

    // MARK: Helpers

    private func meta(_ entry: Entry) -> String {
        var parts = [entry.createdAt.formatted(date: .abbreviated, time: .shortened)]
        if let app = entry.sourceApp { parts.append(app) }
        if let window = entry.windowTitle, !window.isEmpty, window != entry.displayTitle { parts.append(window) }
        return parts.joined(separator: " · ")
    }

    private func neighbor(_ offset: Int) -> Entry? {
        guard let entry else { return nil }
        let list = store.chronological(in: entry.project)
        guard let index = list.firstIndex(where: { $0.id == entry.id }) else { return nil }
        let next = index + offset
        return list.indices.contains(next) ? list[next] : nil
    }

    private func step(_ offset: Int) {
        guard let next = neighbor(offset) else { return }
        saveWhy()
        entryID = next.id
        why = next.rationale
        showingChanges = false
        diffText = nil
        versionState = .idle
    }

    private func saveWhy() {
        guard let entry, why.trimmed != entry.rationale.trimmed else { return }
        store.modify(entry.id) { $0.rationale = why.trimmed }
    }

    private func copyText(_ entry: Entry) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let url = store.mediaURL(for: entry), let data = try? Data(contentsOf: url) {
            switch url.pathExtension.lowercased() {
            case "rtf": pasteboard.setData(data, forType: .rtf)
            case "html": pasteboard.setData(data, forType: .html)
            default: break
            }
        }
        pasteboard.setString(entry.body, forType: .string)
    }
}

/// The capture itself, as large as the space allows, in its own shape:
/// nothing is clipped or framed, so a window keeps its rounded corners, a
/// round Figma frame stays round and a dragged-out area stays square.
struct MomentMedia: View {
    @EnvironmentObject private var store: EntryStore
    let entry: Entry

    var body: some View {
        if let frames = entry.frames, frames.count > 1 {
            FrameGallery(frames: frames)
        } else if let url = store.mediaURL(for: entry), ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()) {
            LoopingPlayer(url: url)
        } else if entry.kind == .text, let url = store.mediaURL(for: entry) {
            // Captured content keeps square corners, text included.
            RichTextPaper(url: url)
                .overlay(Rectangle().strokeBorder(Brand.hairline, lineWidth: 1))
        } else if let url = store.imageURL(for: entry), let image = ImageTools.picture(at: url) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
                .help("Double-click to open in Preview")
        } else {
            // No picture: the words themselves, no icon. A quote reads as
            // the captured text, set like the capture card's.
            let words = WordsThumb.words(entry)
            VStack(alignment: .leading, spacing: 10) {
                Text(words.lead)
                    .font(Archive.sans(entry.kind == .text ? Archive.Focus.noteSize + 2 : Archive.Focus.noteSize))
                    .foregroundStyle(Archive.ink)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                if let rest = words.rest {
                    Text(rest)
                        .font(Archive.sans(Archive.Focus.noteSize - 1))
                        .foregroundStyle(Archive.muted)
                        .lineSpacing(3)
                }
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: 520, alignment: .leading)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Frames captured together: one large, the others in a row to switch.
private struct FrameGallery: View {
    @EnvironmentObject private var store: EntryStore
    let frames: [FrameRef]
    @State private var index = 0

    var body: some View {
        let frame = frames[min(index, frames.count - 1)]
        VStack(spacing: 12) {
            Group {
                if let file = frame.mediaFile {
                    LoopingPlayer(url: store.imageURL(forFile: file))
                        .id(file)
                } else if let file = frame.imageFile, let image = ImageTools.picture(at: store.imageURL(forFile: file)) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                } else {
                    Brand.fill
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 10) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(frames.enumerated()), id: \.offset) { position, item in
                            Button { withAnimation(Brand.quick) { index = position } } label: {
                                VStack(spacing: 4) {
                                    Brand.fill
                                        .frame(width: 84, height: 54)
                                        .overlay {
                                            if let file = item.imageFile, let image = store.thumbnail(forFile: file) {
                                                Image(nsImage: image).resizable().scaledToFill()
                                            }
                                        }
                                        .clipped()
                                        .overlay(
                                            Rectangle()
                                                .strokeBorder(position == index ? Color.primary.opacity(0.8) : Brand.hairline, lineWidth: position == index ? 2 : 1)
                                        )
                                    Text(item.name ?? "Frame \(position + 1)")
                                        .font(Theme.Typography.ui(10))
                                        .foregroundStyle(position == index ? .primary : .secondary)
                                        .lineLimit(1)
                                        .frame(width: 84)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(2)
                }
                if let link = frame.link, let url = URL(string: link) {
                    Button { NSWorkspace.shared.open(url) } label: {
                        Label("Open \(frame.name ?? "frame")", systemImage: "arrow.up.right")
                            .font(Theme.Typography.ui(11, .medium))
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                    }
                    .buttonStyle(SoftButtonStyle())
                }
            }
        }
    }
}

/// Plays a recording on a loop, with the standard controls, sized to the
/// recording's own proportions so there's no black around it.
private struct LoopingPlayer: View {
    let url: URL
    @State private var aspect: CGFloat?

    var body: some View {
        Group {
            if let aspect {
                PlayerView(url: url).aspectRatio(aspect, contentMode: .fit)
            } else {
                Color.clear // a moment, while the recording's size is read
            }
        }
        .task(id: url) { aspect = await Self.aspectRatio(of: url) }
    }

    /// Width over height as the recording plays (its rotation applied).
    static func aspectRatio(of url: URL) async -> CGFloat {
        guard let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
              let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) else { return 16 / 9 }
        let shown = size.applying(transform)
        let width = abs(shown.width), height = abs(shown.height)
        return height > 0 ? width / height : 16 / 9
    }
}

private struct PlayerView: NSViewRepresentable {
    let url: URL

    final class Coordinator {
        var looper: AVPlayerLooper?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        // No black behind the picture.
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        let player = AVQueuePlayer()
        context.coordinator.looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        player.isMuted = true
        view.player = player
        player.play()
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {}

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) {
        view.player?.pause()
        coordinator.looper = nil
    }
}

/// Captured text in its own formatting, selectable, on paper that keeps it
/// legible (dark paper for text from dark editors).
private struct RichTextPaper: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        if let text = scroll.documentView as? NSTextView {
            text.isEditable = false
            text.isSelectable = true
            text.isRichText = true
            text.textContainerInset = NSSize(width: 28, height: 24)
            text.drawsBackground = true
            if let source = RichText.load(contentsOf: url) {
                let paper = RichText.paper(for: source, minSize: 11, maxSize: 40)
                text.textStorage?.setAttributedString(paper.text)
                text.backgroundColor = paper.background
                scroll.backgroundColor = paper.background
            }
        }
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {}
}

/// A unified diff, colored like a code review.
private struct DiffView: View {
    let text: String?

    var body: some View {
        if let text {
            DiffTextView(text: text.isEmpty ? "No changes." : text)
        } else {
            ThinkingPill(text: "Reading the code")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct DiffTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasHorizontalScroller = true
        if let view = scroll.documentView as? NSTextView {
            view.isEditable = false
            view.isSelectable = true
            view.textContainerInset = NSSize(width: 16, height: 14)
            view.backgroundColor = .textBackgroundColor
            view.textStorage?.setAttributedString(Self.colored(text))
        }
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {}

    static func colored(_ text: String) -> NSAttributedString {
        let font = Theme.Typography.nsMono(11.5)
        let bold = Theme.Typography.nsMono(11.5, .medium)
        let result = NSMutableAttributedString()
        for line in text.components(separatedBy: "\n") {
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
            if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff --git") || line.hasPrefix("index ") {
                attributes[.font] = bold
                attributes[.foregroundColor] = NSColor.secondaryLabelColor
            } else if line.hasPrefix("@@") {
                attributes[.foregroundColor] = NSColor.systemPurple
            } else if line.hasPrefix("+") {
                attributes[.backgroundColor] = NSColor.systemGreen.withAlphaComponent(0.14)
            } else if line.hasPrefix("-") {
                attributes[.backgroundColor] = NSColor.systemRed.withAlphaComponent(0.14)
            }
            result.append(NSAttributedString(string: line + "\n", attributes: attributes))
        }
        return result
    }
}
