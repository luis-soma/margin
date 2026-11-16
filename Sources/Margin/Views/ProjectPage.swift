import AppKit
import MarginKit
import SwiftUI

/// A project's own page: its name, icon and cover, what you tell Margin
/// about it, and what Margin has gathered about it on its own. Opened from
/// the dots on a project in the sidebar, its right-click menu, the dots on
/// its card in All projects, or ⌘I in the project.
struct ProjectPage: View {
    let project: String
    /// Into the project's timeline.
    let open: (String) -> Void
    /// After a rename, the page follows the new name.
    let renamed: (String) -> Void
    @EnvironmentObject private var store: EntryStore
    @EnvironmentObject private var intelligence: Intelligence
    @ObservedObject private var icons = ProjectIcons.shared
    @ObservedObject private var notes = ProjectNotes.shared
    @State private var name = ""
    @State private var nameProblem: String?
    @State private var about = ""
    @FocusState private var nameFocused: Bool

    /// Notifications that open the page for a project (the name as object).
    static let show = Notification.Name("MarginShowProjectPage")

    var body: some View {
        let entries = store.entries(in: project).filter { !$0.isAutomatic }
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.x8) {
                title(entries)
                group("Look") {
                    row("Icon", icons.hasOwn(project, store: store) ? "Your own picture." : "A crop Margin picks from the project's pictures.") {
                        HStack(spacing: Theme.Space.x2) {
                            ProjectIcon(project: project)
                            if icons.hasOwn(project, store: store) {
                                button("Use a picture from the project") { icons.automatic(for: project, store: store) }
                            }
                            button("Choose…") { icons.choose(for: project, store: store) }
                        }
                    }
                    divider
                    row("Cover", ProjectCovers.has(project, in: store) ? "Your own picture, on the project's card." : "The newest captures, on the project's card.") {
                        HStack(spacing: Theme.Space.x2) {
                            cover(entries)
                            if ProjectCovers.has(project, in: store) {
                                button("Use latest captures") { ProjectCovers.clear(project, in: store) }
                            }
                            button("Choose…") { ProjectCovers.choose(for: project, in: store) }
                        }
                    }
                }
                aboutGroup
                knowsGroup(entries)
            }
            .padding(.horizontal, Archive.Page.margin)
            .padding(.top, Archive.Page.top)
            .padding(.bottom, Theme.Space.x12)
            .frame(maxWidth: 640 + 2 * Archive.Page.margin, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Brand.background)
        .onAppear(perform: refresh)
        .onChange(of: project) { _ in refresh() }
        .onDisappear(perform: commitName)
    }

    private func refresh() {
        notes.load(store)
        name = project
        nameProblem = nil
        about = notes.about(project)
    }

    // MARK: Name

    private func title(_ entries: [Entry]) -> some View {
        HStack(alignment: .center, spacing: Theme.Space.x4) {
            ProjectIcon(project: project, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                TextField("", text: $name, prompt: Text("Project name").foregroundColor(Theme.Palette.ink3))
                    .textFieldStyle(.plain)
                    .font(Theme.Typography.ui(Theme.Typography.title, .medium))
                    .foregroundStyle(Theme.Palette.ink)
                    .focused($nameFocused)
                    .onSubmit(commitName)
                    .onChange(of: nameFocused) { focused in if !focused { commitName() } }
                Text(nameProblem ?? summaryLine(entries))
                    .font(Theme.Typography.ui(Theme.Typography.caption))
                    .foregroundStyle(nameProblem == nil ? Theme.Palette.ink3 : Theme.Palette.ink)
            }
            Spacer(minLength: Theme.Space.x4)
            primary("Open project") { commitName(); open(store.currentProject == project ? project : name.trimmed.isEmpty ? project : name.trimmed) }
        }
    }

    private func commitName() {
        let clean = name.trimmed
        guard clean != project else { nameProblem = nil; return }
        if let problem = ProjectRename.problem(with: clean, renaming: project, in: store) {
            nameProblem = problem
            return
        }
        ProjectRename.rename(project, to: clean, in: store)
        nameProblem = nil
        renamed(clean)
    }

    private func summaryLine(_ entries: [Entry]) -> String {
        guard let first = entries.last?.createdAt, let last = entries.first?.createdAt else { return "No captures yet" }
        let style = Date.FormatStyle.dateTime.month(.abbreviated).day().year()
        let span = Calendar.current.isDate(first, inSameDayAs: last) ? first.formatted(style) : "\(first.formatted(style)) to \(last.formatted(style))"
        return "\(Archive.count(entries.count)), \(span)"
    }

    // MARK: About

    /// What you tell Margin. Saved as you type.
    private var aboutGroup: some View {
        VStack(alignment: .leading, spacing: Theme.Space.x2) {
            Text("About this project")
                .font(Theme.Typography.ui(Theme.Typography.body, .medium))
                .foregroundStyle(Theme.Palette.ink)
            Text("What it's for, who it's for, what you're trying to find out. Ask, the hand off and Claude read this when they work on the project.")
                .font(Theme.Typography.ui(Theme.Typography.caption))
                .foregroundStyle(Theme.Palette.ink3)
                .fixedSize(horizontal: false, vertical: true)
            ZStack(alignment: .topLeading) {
                if about.isEmpty {
                    Text("A master thesis on…")
                        .font(Theme.Typography.ui(Theme.Typography.body))
                        .foregroundStyle(Theme.Palette.ink3)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $about)
                    .font(Theme.Typography.ui(Theme.Typography.body))
                    .foregroundStyle(Theme.Palette.ink)
                    .scrollContentBackground(.hidden)
                    .padding(.vertical, 8)
                    .onChange(of: about) { text in notes.setAbout(text, for: project) }
            }
            .frame(minHeight: 120)
            .padding(.horizontal, Theme.Space.x3)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.Palette.raised))
        }
    }

    // MARK: What Margin knows

    /// What Margin has gathered on its own: no setup, read from the captures.
    private func knowsGroup(_ entries: [Entry]) -> some View {
        let facts = Self.facts(entries, themes: intelligence.tabs(in: project))
        return VStack(alignment: .leading, spacing: Theme.Space.x2) {
            Text("What Margin knows")
                .font(Theme.Typography.ui(Theme.Typography.body, .medium))
                .foregroundStyle(Theme.Palette.ink)
            VStack(alignment: .leading, spacing: 0) {
                if facts.isEmpty {
                    row("Nothing yet", "Margin learns about the project from what you capture.") { EmptyView() }
                }
                ForEach(Array(facts.enumerated()), id: \.offset) { index, fact in
                    if index > 0 { divider }
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.x4) {
                        Text(fact.label)
                            .font(Theme.Typography.ui(Theme.Typography.body))
                            .foregroundStyle(Theme.Palette.ink)
                            .frame(width: 120, alignment: .leading)
                        Text(fact.value)
                            .font(Theme.Typography.ui(Theme.Typography.body))
                            .foregroundStyle(Theme.Palette.ink2)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, Theme.Space.x3)
                }
            }
            .padding(.horizontal, Theme.Space.x4)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.Palette.raised))
        }
    }

    struct Fact { let label: String; let value: String }

    /// The project at a glance: what kinds of captures, the themes, where
    /// the work happened and what it points to.
    static func facts(_ entries: [Entry], themes: [String]) -> [Fact] {
        guard !entries.isEmpty else { return [] }
        var out: [Fact] = []
        var kinds: [EntryKind: Int] = [:]
        for entry in entries { kinds[entry.kind, default: 0] += 1 }
        let kindLine = kinds.sorted { $0.value > $1.value }.map { "\($0.value) \($0.key.label.lowercased())\($0.value == 1 ? "" : "s")" }
        out.append(Fact(label: "Captures", value: kindLine.joined(separator: ", ")))
        if !themes.isEmpty { out.append(Fact(label: "Themes", value: themes.joined(separator: ", "))) }

        func top(_ values: [String], _ limit: Int) -> [String] {
            var counts: [String: Int] = [:]
            for value in values where !value.isEmpty { counts[value, default: 0] += 1 }
            return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(limit).map(\.key)
        }
        let apps = top(entries.compactMap(\.sourceApp), 6)
        if !apps.isEmpty { out.append(Fact(label: "Made in", value: apps.joined(separator: ", "))) }
        let figma = top(entries.compactMap { FigmaLink.parse($0.link)?.fileName }, 6)
        if !figma.isEmpty { out.append(Fact(label: "Figma files", value: figma.joined(separator: ", "))) }
        let sites = top(entries.filter { FigmaLink.parse($0.link) == nil }.compactMap { URL(string: $0.link)?.host?.replacingOccurrences(of: "www.", with: "") }, 8)
        if !sites.isEmpty { out.append(Fact(label: "Websites", value: sites.joined(separator: ", "))) }
        let code = top(entries.compactMap { $0.codeRoot.map { URL(fileURLWithPath: $0).lastPathComponent } }, 4)
        if !code.isEmpty { out.append(Fact(label: "Code", value: code.joined(separator: ", "))) }
        let decisions = entries.filter { $0.kind == .decision }.prefix(5).map(\.displayTitle)
        if !decisions.isEmpty { out.append(Fact(label: "Decisions", value: decisions.joined(separator: "\n"))) }
        let explained = entries.filter { !$0.rationale.trimmed.isEmpty }.count
        out.append(Fact(label: "With your why", value: "\(explained) of \(entries.count)"))
        return out
    }

    // MARK: Pieces

    @ViewBuilder private func cover(_ entries: [Entry]) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.tiny, style: .continuous)
        Group {
            if let image = ProjectCovers.image(for: project, in: store) ?? entries.first(where: { $0.imageFile != nil }).flatMap({ store.thumbnail(for: $0) }) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                shape.fill(Theme.Palette.fill)
            }
        }
        .frame(width: 44, height: 28)
        .clipShape(shape)
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.x2) {
            Text(title)
                .font(Theme.Typography.ui(Theme.Typography.body, .medium))
                .foregroundStyle(Theme.Palette.ink)
            VStack(alignment: .leading, spacing: 0) { content() }
                .padding(.horizontal, Theme.Space.x4)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.Palette.raised))
        }
    }

    private func row<Control: View>(_ title: String, _ detail: String? = nil, @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: Theme.Space.x4) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Typography.ui(Theme.Typography.body))
                    .foregroundStyle(Theme.Palette.ink)
                if let detail {
                    Text(detail)
                        .font(Theme.Typography.ui(Theme.Typography.caption))
                        .foregroundStyle(Theme.Palette.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Theme.Space.x4)
            control()
        }
        .padding(.vertical, Theme.Space.x3)
    }

    private var divider: some View {
        Rectangle().fill(Theme.Palette.hairline).frame(height: 1)
    }

    private func button(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Typography.ui(Theme.Typography.control))
                .foregroundStyle(Theme.Palette.ink)
                .padding(.horizontal, Theme.Space.x3)
                .frame(height: RepoHeader.toolHeight)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(Theme.Palette.fill))
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        }
        .buttonStyle(PressStyle())
        .fixedSize()
    }

    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Typography.ui(Theme.Typography.control, .medium))
                .foregroundStyle(Theme.Palette.paper)
                .padding(.horizontal, Theme.Space.x3)
                .frame(height: RepoHeader.toolHeight)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(Theme.Palette.ink))
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        }
        .buttonStyle(PressStyle())
        .fixedSize()
    }
}
