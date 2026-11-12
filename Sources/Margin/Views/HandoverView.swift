import AppKit
import MarginKit
import SwiftUI

/// Packs the project into a folder as the window opens, shows what's in it
/// (the project at a glance, its decisions, its captures) and hands the
/// folder to Claude Code in one click.
@MainActor
final class HandoverModel: ObservableObject {
    enum Phase: Equatable { case packing, ready, handing, handed, noClaude, failed }

    @Published private(set) var phase: Phase = .packing
    /// Where the folder goes; Claude Code unless you picked another.
    @Published var agent: HandoverExporter.Agent = HandoverExporter.Agent.available
        .first { $0.id == UserDefaults.standard.string(forKey: "handoffAgent") } ?? .claude {
        didSet { UserDefaults.standard.set(agent.id, forKey: "handoffAgent") }
    }
    @Published private(set) var copied = 0
    @Published private(set) var total = 0
    /// Share only what's new since the last hand off (the folder always
    /// holds everything; the prompt points at what changed).
    @Published var onlyNew = false
    /// When this project was last handed off or its prompt copied.
    @Published private(set) var lastHandoff: Date?
    let project: String
    let folder: URL
    private var started = false

    init(project: String) {
        self.project = project
        folder = HandoverExporter.folder(for: project)
        lastHandoff = UserDefaults.standard.object(forKey: Self.lastKey(project)) as? Date
    }

    private static func lastKey(_ project: String) -> String { "handoffAt.\(project)" }

    /// What the prompt points at: everything, or what's new since last time.
    var since: Date? { onlyNew ? lastHandoff : nil }

    private func remember() {
        lastHandoff = Date()
        UserDefaults.standard.set(lastHandoff, forKey: Self.lastKey(project))
    }

    /// Packing is past copying files and Margin is describing the project's look.
    @Published private(set) var writingTaste = false

    func pack(entries: [Entry], store: EntryStore, summary: ChapterSummary?, config: AIConfig) {
        guard !started else { return }
        started = true
        let plan = HandoverExporter.plan(project: project, entries: entries, store: store, summary: summary)
        total = plan.copies.count
        let model = self, project = project, folder = folder
        Task.detached(priority: .userInitiated) {
            do {
                try await HandoverExporter.write(plan) { done in
                    await MainActor.run { model.copied = done }
                }
                await MainActor.run { withAnimation(Brand.motion) { model.phase = .ready } }
                // TASTE.md is usually written already (when you opened the
                // project); if not, it's written now without holding up the handoff.
                let missing = !FileManager.default.fileExists(atPath: folder.appendingPathComponent("TASTE.md").path)
                if missing { await MainActor.run { model.writingTaste = true } }
                await TasteWriter.writeIfNeeded(project: project, entries: entries, store: store, config: config, folder: folder)
                await MainActor.run { model.writingTaste = false }
            } catch {
                MarginLog.info("Handover failed: \(error)")
                await MainActor.run { model.phase = .failed }
            }
        }
    }

    /// Writes the hand-off's texts again (HANDOFF.md with your description,
    /// say), leaving the captures already copied alone.
    func rewriteTexts(entries: [Entry], store: EntryStore, summary: ChapterSummary?) {
        let plan = HandoverExporter.plan(project: project, entries: entries, store: store, summary: summary)
        for text in plan.texts {
            try? text.contents.write(to: plan.folder.appendingPathComponent(text.name), atomically: true, encoding: .utf8)
        }
    }

    /// The fill runs, the captures gather into the button, then Claude opens.
    func handOver() {
        guard phase == .ready || phase == .handed || phase == .noClaude else { return }
        withAnimation(.easeInOut(duration: HandoverView.handTime)) { phase = .handing }
        DispatchQueue.main.asyncAfter(deadline: .now() + HandoverView.handTime + 0.05) { [weak self] in
            guard let self else { return }
            let opened = HandoverExporter.handOff(folder: self.folder, project: self.project, to: self.agent, since: self.since)
            if opened { self.remember() }
            withAnimation(Brand.motion) { self.phase = opened ? .handed : .noClaude }
        }
    }

    /// Copies the prompt with the folder path, for any other tool.
    func copyPrompt() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(HandoverExporter.portablePrompt(folder: folder, project: project, since: since), forType: .string)
        remember()
    }

    func showFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }
}

struct HandoverView: View {
    @EnvironmentObject private var store: EntryStore
    @EnvironmentObject private var intelligence: Intelligence
    @StateObject private var model: HandoverModel
    let back: () -> Void
    /// In the side panel beside the project: tighter margins.
    var compact = false
    /// Your own description of the project, in place of Margin's summary.
    @State private var about = ""
    @FocusState private var aboutFocused: Bool
    /// The description runs past six lines (it then folds, with "See more…").
    @State private var aboutRunsLong = false
    @State private var aboutExpanded = false

    static let handTime: Double = 0.75

    init(project: String, back: @escaping () -> Void, compact: Bool = false) {
        _model = StateObject(wrappedValue: HandoverModel(project: project))
        self.back = back
        self.compact = compact
    }

    /// Left and right of the page, and above its first line.
    private var margin: CGFloat { compact ? Archive.Space.x6 : Archive.Page.margin }
    private var top: CGFloat { compact ? Archive.Space.x6 : Archive.Page.top }

    private var entries: [Entry] { store.chronological(in: model.project) }

    /// Moments with the designer's reasons, newest first: decisions, then
    /// anything with a "why".
    private var decisions: [Entry] {
        entries.reversed().filter { $0.kind == .decision || !$0.rationale.trimmed.isEmpty }
    }

    private var pictures: [Entry] {
        Array(entries.reversed().filter { $0.imageFile != nil && $0.kind != .text }.prefix(24))
    }

    var body: some View {
        if compact { panel } else { page }
    }

    private var page: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                let P = Archive.Page.self
                let stripWidth = geo.size.width - 2 * margin - P.indent
                // Everything on one page: as many decisions as fit (up to
                // three), scrolling only when even one doesn't.
                ViewThatFits(in: .vertical) {
                    page(decisionCount: 3, stripWidth: stripWidth)
                    page(decisionCount: 2, stripWidth: stripWidth)
                    page(decisionCount: 1, stripWidth: stripWidth)
                    ScrollView { page(decisionCount: 3, stripWidth: stripWidth) }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            }
            footer
        }
        .background(Brand.background)
        .onExitCommand(perform: back)
        .task {
            let all = entries
            intelligence.requestSummary(for: all)
            loadAbout()
            model.pack(entries: all, store: store, summary: packedSummary(for: all), config: intelligence.config)
        }
    }

    // MARK: The hand-off window

    /// The narrow window beside the repo: HAND OFF level with the repo's
    /// breadcrumb, the project's title and description, the files it hands
    /// over, one row of artifacts (the caret shows them all), then the
    /// folder and copy tools on the left and Send on the right.
    @State private var showsAll = false
    @State private var agentsOpen = false
    @Environment(\.handoffWide) private var wide

    private var allPictures: [Entry] {
        entries.reversed().filter { $0.imageFile != nil && $0.kind != .text }
    }

    @State private var helpOpen = false
    @State private var folderOpen = false
    @State private var promptCopied = false

    /// Captures since the last hand off (all of them if there wasn't one).
    private var newCount: Int {
        guard let last = model.lastHandoff else { return entries.count }
        return entries.filter { $0.createdAt > last }.count
    }

    private var scopeLine: String {
        if model.onlyNew {
            guard let last = model.lastHandoff else { return "Nothing handed off yet, so that's everything." }
            let day = last.formatted(date: .abbreviated, time: .omitted)
            return newCount == 0
                ? "Nothing new since you handed it off on \(day)."
                : "\(newCount) new since \(day). Your agent starts there; the rest stays in the folder for context."
        }
        return "All \(entries.count) captures, your decisions and the project's look."
    }

    /// The hand off, beside the archive: what it is, what to share, how to
    /// share it, and what's in the folder (folded). Send sits at the bottom.
    private var panel: some View {
        let side = Archive.Space.x6
        return VStack(alignment: .leading, spacing: 0) {
            // Level with the archive's bar: help and close.
            HStack(spacing: Theme.Space.x1) {
                Spacer()
                HeaderTool(help: "How it works", active: helpOpen, action: {
                    withAnimation(helpOpen ? Theme.Motion.exit : Theme.Motion.enter) { helpOpen.toggle() }
                }) {
                    QuestionGlyph().frame(width: 16, height: 16)
                }
                HeaderTool(help: "Close", action: back) {
                    Image(systemName: "xmark").font(.system(size: 12.5, weight: .regular))
                }
            }
            .padding(.horizontal, side - Theme.Space.x2)
            .frame(height: RepoHeader.height)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: Theme.Space.x8) {
                    // What it is.
                    VStack(alignment: .leading, spacing: Theme.Space.x2) {
                        Text("Hand off")
                            .font(Theme.Typography.ui(Theme.Typography.title, .medium))
                            .foregroundStyle(Theme.Palette.ink)
                        Text("Give your coding agent the whole story of \(model.project): what you made, when and why, as a folder it can read.")
                            .font(Theme.Typography.ui(Theme.Typography.body))
                            .foregroundStyle(Theme.Palette.ink2)
                            .lineSpacing(Theme.Space.x1)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // What to share.
                    VStack(alignment: .leading, spacing: Theme.Space.x2) {
                        label("What to share")
                        ScopeSwitch(onlyNew: $model.onlyNew, all: entries.count, new: newCount)
                        ZStack(alignment: .topLeading) {
                            Text(scopeLine)
                                .font(Theme.Typography.ui(Theme.Typography.control))
                                .foregroundStyle(Theme.Palette.ink3)
                                .fixedSize(horizontal: false, vertical: true)
                                .id(scopeLine)
                                .transition(.blurFade)
                        }
                        .animation(Theme.Motion.snappy, value: scopeLine)
                    }

                    // Other ways to use it.
                    VStack(alignment: .leading, spacing: Theme.Space.x2) {
                        label("Or use it yourself")
                        VStack(spacing: 0) {
                            HandoffAction(title: "Look through the files", detail: "Open the folder in Finder") {
                                Image(systemName: "folder").font(.system(size: 13))
                            } action: { model.showFolder() }
                            Rectangle().fill(Theme.Palette.hairline).frame(height: 1).padding(.horizontal, Theme.Space.x3)
                            HandoffAction(title: promptCopied ? "Copied" : "Copy the prompt", detail: "Paste it into a session you're already in") {
                                Image(systemName: promptCopied ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 13))
                                    .contentTransition(.opacity)
                            } action: {
                                model.copyPrompt()
                                withAnimation(Theme.Motion.snappy) { promptCopied = true }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                                    withAnimation(Theme.Motion.snappy) { promptCopied = false }
                                }
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.Palette.raised))
                        .disabled(model.phase == .packing || model.phase == .failed)
                    }

                    // What's in the folder, folded.
                    VStack(alignment: .leading, spacing: Theme.Space.x3) {
                        Button {
                            withAnimation(Theme.Motion.snappy) { folderOpen.toggle() }
                        } label: {
                            HStack(spacing: Theme.Space.x1) {
                                label("In the folder")
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(Theme.Palette.ink3)
                                    .rotationEffect(.degrees(folderOpen ? 180 : 0))
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressStyle())
                        if folderOpen {
                            VStack(alignment: .leading, spacing: Theme.Space.x2) {
                                folderFile("HANDOFF.md", "The story and your decisions, by day")
                                folderFile("TASTE.md", model.writingTaste ? "Describing the project's look…" : "Palette, type, layout, voice")
                                folderFile("captures/", "\(model.total) pictures, recordings and texts")
                                folderFile("moments.json", "Every moment, raw")
                                folderFile("CLAUDE.md", "How your agent should read it")
                            }
                            .transition(.blurFade)
                        }
                    }
                }
                .padding(.horizontal, side)
                .padding(.top, Theme.Space.x2)
                .padding(.bottom, side)
            }

            // Send: who it goes to, then the one ink button.
            HStack(spacing: Theme.Space.x2) {
                Text("Send to")
                    .font(Theme.Typography.ui(Theme.Typography.control))
                    .foregroundStyle(Theme.Palette.ink3)
                AgentSwitch(selected: $model.agent)
                Spacer(minLength: Theme.Space.x3)
                SendButton(model: model, agentsOpen: $agentsOpen)
            }
            .padding(.horizontal, side)
            .padding(.vertical, Theme.Space.x4)
            .overlay(alignment: .top) { Rectangle().fill(Theme.Palette.hairline).frame(height: 1) }
        }
        .background(Brand.background)
        // How it works: a card under the question mark.
        .overlay(alignment: .topTrailing) {
            if helpOpen {
                ZStack(alignment: .topTrailing) {
                    Color.black.opacity(0.0001)
                        .onTapGesture { withAnimation(Theme.Motion.exit) { helpOpen = false } }
                    HandoffHelp()
                        .padding(.top, RepoHeader.height - 4)
                        .padding(.trailing, side - Theme.Space.x2 + RepoHeader.toolWidth + Theme.Space.x1)
                        .transition(.pop(from: .topTrailing))
                }
            }
        }
        .onExitCommand { if helpOpen { withAnimation(Theme.Motion.exit) { helpOpen = false } } else { back() } }
        .task {
            let all = entries
            intelligence.requestSummary(for: all)
            loadAbout()
            model.pack(entries: all, store: store, summary: packedSummary(for: all), config: intelligence.config)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typography.ui(Theme.Typography.caption))
            .foregroundStyle(Theme.Palette.ink3)
    }

    private func folderFile(_ name: String, _ about: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.x3) {
            Text(name)
                .font(Theme.Typography.mono(Theme.Typography.label))
                .foregroundStyle(Theme.Palette.ink2)
                .frame(width: 96, alignment: .leading)
            Text(about)
                .font(Theme.Typography.ui(Theme.Typography.control))
                .foregroundStyle(Theme.Palette.ink3)
                .lineLimit(1)
        }
    }

    /// The project's name and description, set like an artifact's title and
    /// description; the description is yours to edit, starting from Margin's
    /// summary when there is one.
    private var projectBlock: some View {
        let F = Archive.Focus.self
        return VStack(alignment: .leading, spacing: F.titleGap) {
            Text(model.project)
                .font(Archive.headline(F.titleSize))
                .foregroundStyle(Archive.ink)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            // All of it, always: up to six lines as they are, longer folded
            // to six with "See more…". Editing shows the whole thing.
            if aboutRunsLong && !aboutExpanded && !aboutFocused {
                Text(about)
                    .font(Archive.sans(Self.aboutSize))
                    .foregroundStyle(Archive.ink)
                    .lineLimit(Self.aboutLines)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        aboutExpanded = true
                        DispatchQueue.main.async { aboutFocused = true }
                    }
                    .help("Click to edit")
            } else {
                TextField("Add an annotation...", text: $about, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Archive.sans(Self.aboutSize))
                    .foregroundStyle(Archive.ink)
                    .lineSpacing(Self.aboutLineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
                    .focused($aboutFocused)
                    .onChange(of: aboutFocused) { focused in if !focused { saveAbout() } }
                    .help("Click to edit")
            }
            if aboutRunsLong && !aboutFocused {
                Button(aboutExpanded ? "See less" : "See more…") {
                    withAnimation(Brand.quick) { aboutExpanded.toggle() }
                }
                .buttonStyle(.plain)
                .font(Archive.sans(F.valueSize))
                .foregroundStyle(Archive.muted)
                .pointingHand()
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        // How tall all of the description would be at this width, to know
        // whether it runs past six lines.
        .background(alignment: .topLeading) {
            Text(about)
                .font(Archive.sans(Self.aboutSize))
                .fixedSize(horizontal: false, vertical: true)
                .hidden()
                .background(GeometryReader { geo in
                    Color.clear
                        .onAppear { aboutRunsLong = geo.size.height > Self.aboutFoldHeight + 1 }
                        .onChange(of: geo.size.height) { aboutRunsLong = $0 > Self.aboutFoldHeight + 1 }
                })
        }
        // Margin's summary arriving while you haven't written your own.
        .onChange(of: intelligence.summary(for: entries)?.summary) { _ in if !aboutFocused { loadAbout() } }
    }

    /// Past this many lines the description folds.
    static let aboutLines = 6
    /// The description: body text, so the project's name leads.
    static let aboutSize = Theme.Typography.body
    static let aboutLineSpacing = Theme.Space.x1
    /// Six lines of the description, set like the field you type it in.
    static var aboutFoldHeight: CGFloat {
        let font = Theme.Typography.nsUI(aboutSize)
        return (ceil(font.ascender - font.descender + font.leading) + aboutLineSpacing) * CGFloat(aboutLines)
    }

    private var aboutKey: String { "handoffDescription.\(model.project)" }

    /// Margin's summary of the project, unless it was hidden.
    private var marginSummary: String? {
        intelligence.summary(for: entries).flatMap { $0.hidden ? nil : $0.summary }
    }

    /// Your description if you wrote one, otherwise Margin's summary.
    private func loadAbout() {
        about = UserDefaults.standard.string(forKey: aboutKey) ?? marginSummary ?? ""
    }

    /// Keeps your description (Margin's own, untouched, isn't stored, so it
    /// keeps following the project) and packs it into the hand-off.
    private func saveAbout() {
        let text = about.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text == marginSummary {
            UserDefaults.standard.removeObject(forKey: aboutKey)
        } else {
            UserDefaults.standard.set(text, forKey: aboutKey)
        }
        if text.isEmpty { about = marginSummary ?? "" }
        let all = entries
        model.rewriteTexts(entries: all, store: store, summary: packedSummary(for: all))
    }

    /// What the hand-off says about the project: your description in place
    /// of Margin's summary when you wrote one.
    private func packedSummary(for all: [Entry]) -> ChapterSummary? {
        let summary = intelligence.summary(for: all)
        guard let mine = UserDefaults.standard.string(forKey: aboutKey), !mine.isEmpty else { return summary }
        var edited = summary ?? ChapterSummary(title: model.project, summary: mine)
        edited.summary = mine
        edited.hidden = false
        edited.accepted = true
        return edited
    }

    private var filesBlock: some View {
        panelSection("In the folder") {
                    VStack(alignment: .leading, spacing: Archive.Focus.rowGap) {
                        panelFile("CLAUDE.md", "How to read all of this")
                        panelFile("HANDOFF.md", "The story and decisions, by day")
                        panelFile("TASTE.md", model.writingTaste ? "Describing the project's look…" : "Palette, type, layout, voice")
                        panelFile("captures/", "\(model.total) pictures, recordings and texts")
                        panelFile("moments.json", "Every moment, raw")
                    }
                }
    }

    private func panelSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Archive.Space.x3) {
            Text(title)
                .font(Archive.font(Archive.Size.title))
                .foregroundStyle(Archive.faint)
            content()
        }
    }

    /// One file, set like an artifact's details: the name as the label,
    /// what's in it as the value.
    private func panelFile(_ name: String, _ about: String) -> some View {
        let F = Archive.Focus.self
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(name)
                .font(Archive.font(F.labelSize))
                .foregroundStyle(Archive.muted)
                // Wider than the details' label column: file names run longer.
                .frame(width: 112, alignment: .leading)
            Text(about)
                .font(Archive.sans(F.valueSize))
                .foregroundStyle(Archive.ink)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(height: F.rowHeight)
    }

    private func toggleAll() {
        withAnimation(.timingCurve(0.3, 0, 0.2, 1, duration: 0.3)) { showsAll.toggle() }
    }

    private var artifactsHeader: some View {
        Button(action: toggleAll) {
            HStack(spacing: 5) {
                // "68 ARTIFACTS": the number set like the word.
                Text(Archive.count(allPictures.count))
                    .font(Archive.mono(Archive.Size.title))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .rotationEffect(.degrees(showsAll ? 180 : 0))
            }
            .foregroundStyle(Archive.muted)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHand()
        .help(showsAll ? "Show one row" : "Show all")
    }

    /// Folded: one row, the last cell counting the rest. Open: every picture.
    /// A click on the row (or the count) opens it; the caret folds it back.
    private func artifacts(width: CGFloat) -> some View {
        let gap = Archive.Space.x1
        let columns = max(3, Int((width + gap) / (96 + gap)))
        let cell = ((width - gap * CGFloat(columns - 1)) / CGFloat(columns)).rounded(.down)
        let all = allPictures
        let more = max(0, all.count - (columns - 1))
        let row = Array(all.prefix(all.count > columns ? columns - 1 : columns))
        return Group {
            if all.isEmpty {
                Text("No pictures yet").font(Archive.sans(11)).foregroundStyle(Archive.faint)
            } else if showsAll {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(cell), spacing: gap), count: columns), alignment: .leading, spacing: gap) {
                    ForEach(all) { entry in
                        thumbnail(entry).frame(width: cell, height: cell * 0.62)
                    }
                }
                .transition(.opacity)
            } else {
                HStack(spacing: gap) {
                    ForEach(Array(row.enumerated()), id: \.element.id) { index, entry in
                        thumbnail(entry)
                            .frame(width: cell, height: cell * 0.62)
                            .gather(model.phase == .handing, index: index, count: row.count)
                    }
                    if all.count > columns {
                        Text("\(more)+")
                            .font(Archive.mono(16))
                            .foregroundStyle(Archive.muted)
                            .frame(width: cell, height: cell * 0.62)
                            .background(Brand.fill)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: toggleAll)
                .pointingHand()
                .help("Show all")
                .transition(.opacity)
            }
        }
    }

    private func page(decisionCount: Int, stripWidth: CGFloat) -> some View {
        let P = Archive.Page.self
        return VStack(alignment: .leading, spacing: P.sectionGap) {
            if compact {
                // In the side panel: the project, then what's in the folder.
                hero
                files
            } else {
                // The project on the left, what's in the folder on the right.
                HStack(alignment: .top, spacing: 0) {
                    hero
                        .frame(maxWidth: 440, alignment: .leading)
                    Spacer(minLength: P.cardGap)
                    files
                        .padding(.top, Archive.Space.x2)
                }
            }
            strip(width: stripWidth)
            if !decisions.isEmpty { decisionList(Array(decisions.prefix(decisionCount))) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, margin)
        .padding(.top, top)
        .padding(.bottom, P.labelGap)
    }

    // MARK: Project at a glance

    /// The project's name, its dates and size, and Margin's summary.
    private var hero: some View {
        let P = Archive.Page.self
        return VStack(alignment: .leading, spacing: 0) {
            Text(model.project)
                .font(Archive.headline(Archive.Size.pageTitle))
                .foregroundStyle(Archive.ink)
                .lineLimit(2)
            Spacer().frame(height: Archive.Timeline.metaGap)
            HStack(spacing: P.metaGap) {
                if let range { Text(range) }
                Rectangle().fill(Archive.faint).frame(width: P.ruleWidth, height: 1)
                Text(Archive.count(entries.count))
            }
            .font(Archive.font(Archive.Size.title))
            .foregroundStyle(Archive.faint)
            if let summary = intelligence.summary(for: entries), !summary.hidden {
                Spacer().frame(height: P.labelGap)
                Text(summary.summary)
                    .font(Archive.sans(P.summarySize))
                    .foregroundStyle(Archive.ink)
                    .lineSpacing(P.summaryLineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            } else if intelligence.isSummarizing(entries) {
                ThinkingPill(text: "Summarizing")
                    .padding(.top, P.labelGap)
            }
        }
        .animation(Brand.motion, value: intelligence.summary(for: entries)?.summary)
    }

    /// "MAR 3 - OCT 18".
    private var range: String? {
        guard let first = entries.first?.createdAt, let last = entries.last?.createdAt else { return nil }
        let calendar = Calendar.current
        func day(_ date: Date) -> String { "\(Archive.month(date, calendar: calendar)) \(calendar.component(.day, from: date))" }
        return calendar.isDate(first, inSameDayAs: last) ? day(first) : "\(day(first)) - \(day(last))"
    }

    // MARK: The folder

    private var files: some View {
        section("Files") {
            VStack(alignment: .leading, spacing: Archive.Page.rowGap) {
                file("CLAUDE.md", "How to read all of this. Claude Code reads this first.")
                file("HANDOFF.md", "The stories and decisions. Every moment by day.")
                file("TASTE.md", model.writingTaste ? "Describing the project's look…" : "The design language: palette, type, layout, voice.")
                file("captures/", "\(model.total) recordings, pictures, and text.")
                file("moments.json", "Every moment, raw.")
            }
        }
    }

    private func file(_ name: String, _ about: String) -> some View {
        let P = Archive.Page.self
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(name)
                .font(Archive.mono(P.fileNameSize))
                .foregroundStyle(Archive.ink)
                .frame(width: P.fileNameWidth, alignment: .leading)
            Text(about)
                .font(Archive.sans(P.detailSize))
                .foregroundStyle(Archive.muted)
                .lineLimit(1)
        }
        .frame(height: P.rowHeight)
    }

    // MARK: Artifacts

    /// One row of the latest captures, as many as fit.
    private func strip(width: CGFloat) -> some View {
        let P = Archive.Page.self
        let fits = max(1, Int((width + P.thumbGap) / (P.thumb.width + P.thumbGap)))
        let shown = Array(pictures.prefix(fits))
        return section("Artifacts") {
            if shown.isEmpty {
                Text("No pictures yet")
                    .font(Archive.sans(P.detailSize))
                    .foregroundStyle(Archive.faint)
            } else {
                HStack(spacing: P.thumbGap) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, entry in
                        thumbnail(entry)
                            .frame(width: P.thumb.width, height: P.thumb.height)
                            .gather(model.phase == .handing, index: index, count: shown.count)
                    }
                }
            }
        }
    }

    // MARK: Decisions

    private func decisionList(_ shown: [Entry]) -> some View {
        let P = Archive.Page.self
        return section("Decisions") {
            HStack(alignment: .center, spacing: P.cardGap) {
            VStack(alignment: .leading, spacing: P.decisionGap) {
                ForEach(shown) { entry in
                    HStack(alignment: .bottom, spacing: P.decisionGap) {
                        thumbnail(entry)
                            .frame(width: P.decisionThumb.width, height: P.decisionThumb.height)
                        Text(entry.rationale.trimmed.isEmpty ? entry.displayTitle : entry.rationale.trimmed)
                            .font(Archive.sans(P.detailSize))
                            .foregroundStyle(Archive.muted)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                    }
                }
            }
            Spacer(minLength: 0)
            TextAction(title: "See all", help: "Back to the timeline", enabled: true, action: back)
            }
        }
    }

    // MARK: Footer

    /// The page's last line, on its margins: where the folder is on the
    /// left; on the right, quiet actions and the hand off.
    private var footer: some View {
        let note = Text(footerNote)
            .font(Archive.font(Archive.Size.meta))
            .foregroundStyle(Archive.faint)
            .lineLimit(1)
            .truncationMode(.middle)
        let actions = HStack(alignment: .center, spacing: Archive.Space.x7) {
            TextAction(title: "Show folder", help: "Show the folder in Finder", enabled: model.phase != .packing) {
                model.showFolder()
            }
            TextAction(title: "Copy prompt", done: "Copied", help: "Copy the prompt with the folder path, to paste into any chat, Codex or Cursor",
                       enabled: model.phase != .packing && model.phase != .failed) {
                model.copyPrompt()
            }
        }
        return Group {
            if compact {
                // In the side panel there's no room for one line: the folder,
                // then the quiet actions, then the hand off.
                VStack(alignment: .leading, spacing: Archive.Space.x3) {
                    note
                    actions
                    HandoverButton(model: model)
                }
            } else {
                HStack(alignment: .center, spacing: Archive.Space.x7) {
                    note
                    Spacer(minLength: Archive.Space.x4)
                    actions
                    HandoverButton(model: model)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, margin)
        .padding(.bottom, compact ? Archive.Space.x6 : Archive.Space.x7)
        .padding(.top, Archive.Space.x4)
    }

    private var footerNote: String {
        switch model.phase {
        case .noClaude: return "\(model.agent.name) isn't installed. The prompt is on your clipboard."
        case .handed where model.agent != .claude: return "The prompt is on your clipboard. Paste it into \(model.agent.name)."
        case .failed: return "Couldn't write the folder"
        default: return "Documents / Margin Handoff / \(HandoverExporter.safe(model.project))"
        }
    }

    // MARK: Pieces

    /// A section: its label, then what's in it, indented.
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        let P = Archive.Page.self
        return VStack(alignment: .leading, spacing: P.labelGap) {
            Text(title)
                .font(Archive.font(Archive.Size.title))
                .foregroundStyle(Archive.faint)
            content()
                .padding(.leading, P.indent)
        }
    }

    private func thumbnail(_ entry: Entry) -> some View {
        Rectangle()
            .fill(Brand.fill)
            .overlay {
                if let image = store.thumbnail(for: entry) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.medium)
                        .scaledToFill()
                } else {
                    // No picture: its words, as in the archive.
                    GeometryReader { geo in WordsThumb(entry: entry, size: geo.size) }
                }
            }
            .clipped()
    }
}

/// Copy the prompt, as a tool like the repo header's: the icon becomes a
/// check for a moment.
private extension View {
    /// No scrolling or bounce while everything fits.
    @ViewBuilder
    func scrollsOnlyWhenClipped() -> some View {
        if #available(macOS 13.3, *) {
            scrollBounceBehavior(.basedOnSize)
        } else {
            self
        }
    }
}

private struct CopyTool: View {
    @ObservedObject var model: HandoverModel
    @State private var copied = false

    var body: some View {
        HeaderTool(help: "Copy the prompt with the folder path, for any chat, Codex or Cursor", action: {
            model.copyPrompt()
            withAnimation(Brand.quick) { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { withAnimation(Brand.quick) { copied = false } }
        }) {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 13))
                .contentTransition(.opacity)
        }
        .disabled(model.phase == .packing || model.phase == .failed)
    }
}

/// Send: the hand-off's one action. Light, in the archive's greys with a
/// hairline, the agent's icon and a caret to pick another. While packing
/// and sending it fills from the left the way the capture card's loading
/// pill does: real progress where Margin has it, an estimate otherwise,
/// one smooth glide, never backward.
private struct SendButton: View {
    @ObservedObject var model: HandoverModel
    @Binding var agentsOpen: Bool
    @State private var hovering = false
    @State private var pickerHovering = false
    @State private var fill: Double = 0
    @State private var sendingSince: Date?
    private let frame = Timer.publish(every: 1.0 / 60, on: .main, in: .common).autoconnect()

    private var busy: Bool { model.phase == .packing || model.phase == .handing }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous) }

    var body: some View {
        Button(action: send) {
            HStack(spacing: 6) {
                if model.phase == .handed {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .medium))
                        .transition(.iconSwap)
                }
                Text(title)
                    .font(Theme.Typography.ui(Theme.Typography.control, .medium))
                    .lineLimit(1)
                    .contentTransition(.opacity)
            }
            .foregroundStyle(Theme.Palette.paper)
            .padding(.horizontal, Theme.Space.x3)
            .frame(height: RepoHeader.toolHeight)
            // Packing and sending: a lighter band fills the button.
            .background(alignment: .leading) {
                GeometryReader { geo in
                    Rectangle()
                        .fill(Color.white.opacity(0.18))
                        .frame(width: geo.size.width * CGFloat(fill))
                }
            }
            .background(Theme.Palette.ink.opacity(busy ? 0.7 : hovering ? 0.86 : 1))
            .clipShape(shape)
            .contentShape(shape)
        }
        .buttonStyle(PressStyle())
        .disabled(busy || model.phase == .failed)
        .onHover { inside in withAnimation(Theme.Motion.hover) { hovering = inside } }
        .toolTip("Hand off to \(model.agent.name)", "Opens the folder in it, with the prompt ready", edge: .above)
        .animation(.timingCurve(0.3, 0, 0.2, 1, duration: 0.3), value: model.phase)
        .onReceive(frame) { now in glide(now) }
        .onChange(of: model.phase) { phase in
            if phase == .handing { sendingSince = Date() }
            if phase == .handed || phase == .ready || phase == .noClaude {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    withAnimation(.easeOut(duration: 0.3)) { fill = 0 }
                    sendingSince = nil
                }
            }
        }
    }

    private var title: String {
        switch model.phase {
        case .packing: return model.writingTaste ? "Packing" : "Packing \(model.copied) of \(model.total)"
        case .handing: return "Sending"
        case .handed: return "Sent"
        case .failed: return "Couldn't pack"
        default: return "Send"
        }
    }

    private func send() {
        guard !busy else { return }
        model.handOver()
    }

    private func glide(_ now: Date) {
        var target: Double = 0
        switch model.phase {
        case .packing:
            let real = model.total == 0 ? 0 : Double(model.copied) / Double(model.total)
            target = max(real * 0.9, 0.3)
        case .handing:
            let t = sendingSince.map { now.timeIntervalSince($0) } ?? 0
            target = min(1, 0.9 + t / HandoverView.handTime * 0.1)
        case .handed:
            target = 1
        default:
            return
        }
        guard target > fill else { return }
        fill += (target - fill) * 0.08
    }
}

/// Everything, or only what's new since the last hand off: a white thumb
/// sliding between the two, each with its count.
private struct ScopeSwitch: View {
    @Binding var onlyNew: Bool
    let all: Int
    let new: Int
    @Namespace private var thumb

    var body: some View {
        HStack(spacing: 0) {
            segment(false, "Everything", all)
            segment(true, "What's new", new)
        }
        .padding(Theme.Segmented.padding)
        .background(SegmentTrack())
    }

    private func segment(_ value: Bool, _ title: String, _ count: Int) -> some View {
        let selected = onlyNew == value
        return Button {
            guard !selected else { return }
            withAnimation(Theme.Motion.snappy) { onlyNew = value }
        } label: {
            HStack(spacing: 6) {
                Text(title).font(Theme.Typography.ui(Theme.Typography.control))
                Text("\(count)")
                    .font(Theme.Typography.mono(Theme.Typography.label))
                    // Quieter than the words, on either thumb.
                    .opacity(0.55)
                    .contentTransition(.numericText())
            }
            .foregroundStyle(Theme.Segmented.label(selected))
            .frame(maxWidth: .infinity)
            .frame(height: Theme.Segmented.segment)
            .background {
                if selected {
                    SegmentThumb().matchedGeometryEffect(id: "thumb", in: thumb)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }
}

/// One way to use the folder yourself: an icon, what it does, a line under.
private struct HandoffAction<Icon: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let icon: () -> Icon
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.x3) {
                icon()
                    .foregroundStyle(Theme.Palette.ink2)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Theme.Typography.ui(Theme.Typography.body))
                        .foregroundStyle(Theme.Palette.ink)
                        .contentTransition(.opacity)
                    Text(detail)
                        .font(Theme.Typography.ui(Theme.Typography.control))
                        .foregroundStyle(Theme.Palette.ink3)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.Palette.ink3)
                    .opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, Theme.Space.x3)
            .padding(.vertical, Theme.Space.x3 - 2)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(hovering ? Theme.Palette.fill : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(scale: 0.99))
        .onHover { inside in withAnimation(Theme.Motion.hover) { hovering = inside } }
    }
}

/// How hand off works, in three lines, under the question mark.
private struct HandoffHelp: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        VStack(alignment: .leading, spacing: Theme.Space.x3) {
            Text("How hand off works")
                .font(Theme.Typography.ui(Theme.Typography.body, .medium))
                .foregroundStyle(Theme.Palette.ink)
            step(1, "Margin writes the project into a folder: the story by day, your decisions, its look and every capture.")
            step(2, "Send opens your agent in that folder with a first prompt. Or copy the prompt into a session you're in.")
            step(3, "Later, hand off What's new: your agent starts from what changed since last time.")
        }
        .padding(Theme.Space.x4)
        .frame(width: 300)
        .background(FloatingSurface(shape: shape))
        .overlay(shape.strokeBorder(Theme.Palette.hairline, lineWidth: 1))
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.x2) {
            Text("\(number)")
                .font(Theme.Typography.mono(Theme.Typography.caption))
                .foregroundStyle(Theme.Palette.ink3)
            Text(text)
                .font(Theme.Typography.ui(Theme.Typography.caption))
                .foregroundStyle(Theme.Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A question mark in a circle, on the icons' 16 grid.
private struct QuestionGlyph: View {
    var body: some View {
        ZStack {
            Circle().stroke(lineWidth: 1.25).padding(1.5)
            Text("?")
                .font(Theme.Typography.ui(10, .medium))
                .offset(y: -0.5)
        }
    }
}

/// Which agent it goes to: their icons in a track, a white thumb sliding
/// to the one picked, like Timeline / Themes and Reminder / Automatic.
private struct AgentSwitch: View {
    @Binding var selected: HandoverExporter.Agent
    @Namespace private var thumb

    var body: some View {
        HStack(spacing: 0) {
            ForEach(HandoverExporter.Agent.available) { agent in
                let on = agent == selected
                Button {
                    guard !on else { return }
                    withAnimation(Theme.Motion.snappy) { selected = agent }
                } label: {
                    AgentIcon(agent: agent, size: 16)
                        .saturation(on ? 1 : 0)
                        .opacity(on ? 1 : 0.6)
                        .frame(width: RepoHeader.toolWidth, height: Theme.Segmented.segment)
                        .background {
                            if on {
                                // App icons: a white thumb, so dark icons stay visible.
                                SegmentThumb(pictures: true).matchedGeometryEffect(id: "thumb", in: thumb)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .toolTip(agent.name, edge: .above, align: .center)
            }
        }
        .padding(Theme.Segmented.padding)
        .background(SegmentTrack())
    }
}

/// An agent's own app icon, or a quiet letter when it isn't installed.
private struct AgentIcon: View {
    let agent: HandoverExporter.Agent
    let size: CGFloat

    var body: some View {
        if let icon = agent.icon {
            Image(nsImage: icon).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            Text(String(agent.name.prefix(1)))
                .font(Theme.Typography.ui(size * 0.6, .medium))
                .foregroundStyle(Archive.muted)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous).fill(Brand.fill))
        }
    }
}

/// The agents, in the style of the repo's options menu: each with its app's
/// icon, its name, and a check on the one it goes to.
private struct AgentMenu: View {
    let selected: HandoverExporter.Agent
    let pick: (HandoverExporter.Agent) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Send to")
                .font(Archive.font(Archive.Size.meta))
                .foregroundStyle(Archive.faint)
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 4)
            ForEach(HandoverExporter.Agent.available) { agent in
                AgentRow(agent: agent, on: agent == selected) { pick(agent) }
            }
        }
        .padding(5)
        .frame(width: 232)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Brand.background)
                .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }
}

private struct AgentRow: View {
    let agent: HandoverExporter.Agent
    let on: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                AgentIcon(agent: agent, size: 18)
                Text(agent.name)
                    .font(Archive.sans(13))
                    .foregroundStyle(Archive.ink)
                Spacer(minLength: 12)
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Archive.ink)
                    .opacity(on ? 1 : 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(hovering ? 0.06 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A quiet action in the archive's type: mono capitals, grey until you
/// point at it. Its word can change for a moment after a click ("Copied").
private struct TextAction: View {
    let title: String
    var done: String? = nil
    let help: String
    let enabled: Bool
    let action: () -> Void
    @State private var flashed = false
    @State private var hovering = false

    var body: some View {
        Button {
            action()
            guard done != nil else { return }
            withAnimation(Brand.quick) { flashed = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                withAnimation(Brand.quick) { flashed = false }
            }
        } label: {
            Text(flashed ? (done ?? title) : title)
                .font(Theme.Typography.ui(Theme.Typography.body))
                .foregroundStyle(hovering || flashed ? Archive.ink : Archive.muted)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .onHover { hovering = $0 }
        .animation(Brand.quick, value: hovering)
        .help(help)
    }
}

/// The one action: Claude's icon in a circle at the left of a dark pill.
/// - Packing: a ring around the icon fills as files are copied.
/// - Hover: the circle leans in, the arrow nudges toward Claude.
/// - Click: the label clears, the circle rolls across the pill with a fill
///   following it, then lands with a check: handed over.
private struct HandoverButton: View {
    @ObservedObject var model: HandoverModel
    @State private var hovering = false
    @State private var pressed = false

    static let width: CGFloat = 288
    static let height: CGFloat = 36
    static let inset: CGFloat = 4
    /// Room on the right for the agent picker.
    static let picker: CGFloat = 52
    private var circle: CGFloat { Self.height - Self.inset * 2 }
    /// How far the circle travels to the right edge.
    private var travel: CGFloat { Self.width - Self.height }

    var body: some View {
        let handing = model.phase == .handing
        let quiet = model.phase == .packing || model.phase == .failed
        ZStack(alignment: .trailing) {
            Button(action: model.handOver) {
                ZStack(alignment: .leading) {
                    // Pill.
                    Rectangle().fill(quiet ? Brand.fill : Archive.ink.opacity(hovering && !handing ? 0.86 : 1))
                    // The trail behind the rolling circle.
                    Rectangle()
                        .fill(Brand.background.opacity(0.14))
                        .frame(width: handing ? Self.width : Self.height)
                        .opacity(handing ? 1 : 0)
                    Text(title)
                        .font(Theme.Typography.ui(Theme.Typography.body, .medium))
                        .lineLimit(1)
                        .contentTransition(.opacity)
                        .foregroundStyle(quiet ? Color.primary.opacity(0.5) : Brand.background)
                        .padding(.leading, Self.height + 8)
                        .padding(.trailing, Self.picker + 8)
                        .opacity(handing ? 0 : 1)
                        .offset(x: handing ? 14 : 0)
                    // Margin's mark in its circle: it rolls the work across to the agent.
                    MarkBadge(phase: model.phase, progress: progress, hovering: hovering && !handing, size: circle)
                        .padding(.leading, Self.inset)
                        .offset(x: handing ? travel : 0)
                        .zIndex(1)
                }
                .frame(width: Self.width, height: Self.height)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressReader(pressed: $pressed))
            .disabled(quiet || handing)
            .onHover { hovering = $0 }
            // Which agent: Claude Code by default; any other installed one.
            AgentPicker(model: model, dark: !quiet)
                .padding(.trailing, 6)
                .opacity(handing ? 0 : 1)
                .disabled(handing)
        }
        .frame(width: Self.width, height: Self.height)
        .scaleEffect(pressed ? 0.97 : 1)
        .animation(Theme.Motion.hover, value: hovering)
        .animation(Theme.Motion.press, value: pressed)
        .animation(handing ? .timingCurve(0.65, 0, 0.25, 1, duration: HandoverView.handTime) : .spring(response: 0.5, dampingFraction: 0.78), value: model.phase)
        .help(model.agent == .claude ? "Opens a new Claude Code session in the handoff folder" : "Opens the handoff folder in \(model.agent.name) and copies the prompt")
    }

    private var title: String {
        switch model.phase {
        case .packing:
            return model.total == 0 ? "Packing" : "Packing \(model.copied) of \(model.total)"
        case .ready: return "Brief \(model.agent.name)"
        case .handing: return "Handing off"
        case .handed: return "Handed to \(model.agent.name)"
        case .noClaude: return "Try again"
        case .failed: return "Couldn't pack"
        }
    }

    private var progress: Double {
        model.total == 0 ? 0 : Double(model.copied) / Double(model.total)
    }
}

/// The chosen agent's app icon with a small chevron, inside the pill.
/// Opens a menu of the agents on this Mac.
private struct AgentPicker: View {
    @ObservedObject var model: HandoverModel
    let dark: Bool
    @State private var hovering = false

    var body: some View {
        Menu {
            ForEach(HandoverExporter.Agent.available) { agent in
                Button {
                    model.agent = agent
                } label: {
                    if agent == model.agent {
                        Label(agent.name, systemImage: "checkmark")
                    } else {
                        Text(agent.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Group {
                    if let icon = model.agent.icon {
                        Image(nsImage: icon).resizable().interpolation(.high)
                    } else {
                        Image(systemName: "sparkle").resizable().scaledToFit().padding(3)
                    }
                }
                .frame(width: 20, height: 20)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7.5, weight: .bold))
                    .opacity(0.7)
            }
            .foregroundStyle(dark ? Brand.background : Color.primary)
            .padding(.leading, 5)
            .padding(.trailing, 7)
            .frame(height: 28)
            .background(Rectangle().fill((dark ? Brand.background : Color.primary).opacity(hovering ? 0.2 : 0.12)))
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .animation(Brand.quick, value: hovering)
        .help("Brief \(model.agent.name) on this project. Click to pick another agent.")
    }
}

/// Reads the press without drawing anything of its own.
private struct PressReader: ButtonStyle {
    @Binding var pressed: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { pressed = $0 }
    }
}

/// Margin's mark in a light circle. While packing, a ring fills around it;
/// handing off, it turns once as it rolls across; once handed, a check.
private struct MarkBadge: View {
    let phase: HandoverModel.Phase
    let progress: Double
    let hovering: Bool
    let size: CGFloat

    var body: some View {
        let handing = phase == .handing
        ZStack {
            Rectangle().fill(Brand.background)
            Mark(size: size * 0.42, dot: 1)
                .rotationEffect(.degrees(handing ? 360 : hovering ? -12 : 0))
                .scaleEffect(handing ? 0.82 : hovering ? 1.08 : 1)
                .opacity(phase == .handed ? 0 : 1)
            if phase == .packing {
                // Packing: a line along the bottom fills as files are copied.
                GeometryReader { geo in
                    Rectangle()
                        .fill(Archive.ink)
                        .frame(width: geo.size.width * progress, height: 2)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .animation(Brand.motion, value: progress)
                }
            }
            if phase == .handed {
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.38, weight: .bold))
                    .foregroundStyle(Color.primary)
                    .transition(.scale(scale: 0.3).combined(with: .opacity))
            }
        }
        .frame(width: size, height: size)
        .opacity(phase == .packing ? 0.85 : 1)
    }
}

private extension View {
    /// The captures gather toward the button, bottom right, one after another.
    func gather(_ on: Bool, index: Int, count: Int) -> some View {
        let order = Double(count - index) / Double(max(count, 1))
        return self
            .scaleEffect(on ? 0.4 : 1, anchor: .bottomTrailing)
            .offset(x: on ? 60 : 0, y: on ? 120 : 0)
            .opacity(on ? 0 : 1)
            .animation(
                on ? .easeIn(duration: 0.38).delay(order * 0.3) : .easeOut(duration: 0.5).delay(0.4 + order * 0.2),
                value: on
            )
    }
}
