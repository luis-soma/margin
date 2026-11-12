import AppKit
import SwiftUI

/// The floating sidebar: your projects, pinned ones first, a new one, and
/// you with Settings at the bottom. A white card inset from the window's
/// edges, holding the traffic lights at its top. It collapses away (⌘\)
/// and the archive takes the whole window.
struct ProjectSidebar: View {
    @EnvironmentObject private var store: EntryStore
    /// The project open, nil on All projects or Settings.
    let current: String?
    let onHome: Bool
    let onSettings: Bool
    /// Out or tucked away; its rows come in one after another.
    var shown = true
    let open: (String) -> Void
    let home: () -> Void
    let settings: () -> Void
    let collapse: () -> Void
    @AppStorage("pinnedProjects") private var pinnedList = ""

    static let width: CGFloat = 224
    /// From the window's edges to the card.
    static let inset = Theme.Space.x2
    /// What the archive gives up for it while it's open.
    static var room: CGFloat { width + inset }

    /// Projects, most recently worked on first: one pass over the captures,
    /// worked out once per draw (not per row: that made the window lag).
    private func projectNames() -> [String] {
        var latest: [String: Date] = [:]
        for entry in store.entries where entry.createdAt > latest[entry.project] ?? .distantPast {
            latest[entry.project] = entry.createdAt
        }
        if latest[store.currentProject] == nil { latest[store.currentProject] = .distantPast }
        return latest.sorted { $0.value > $1.value }.map(\.key)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            // The traffic lights sit here; the collapse button at the end.
            HStack {
                Spacer(minLength: 0)
                SidebarToggle(action: collapse)
            }
            .padding(.horizontal, Theme.Space.x2)
            .frame(height: RepoHeader.height - Self.inset)

            ScrollView {
                let names = projectNames()
                let pinnedSet = Set(pinnedList.split(separator: "\n").map(String.init))
                let pinned = names.filter { pinnedSet.contains($0) }
                let others = names.filter { !pinnedSet.contains($0) }
                let pinnedRows = pinned.isEmpty ? 0 : pinned.count + 1
                VStack(alignment: .leading, spacing: 1) {
                    SidebarRow(title: "All projects", selected: onHome, action: home) {
                        GridGlyph().frame(width: 14, height: 14)
                    }
                    .staggered(0, shown)
                    if !pinned.isEmpty {
                        SidebarSection(title: "Pinned").staggered(1, shown)
                        ForEach(Array(pinned.enumerated()), id: \.element) { index, name in
                            projectRow(name, pinned: true).staggered(2 + index, shown)
                        }
                    }
                    SidebarSection(title: "Projects").staggered(1 + pinnedRows, shown)
                    ForEach(Array(others.enumerated()), id: \.element) { index, name in
                        projectRow(name, pinned: false).staggered(2 + pinnedRows + index, shown)
                    }
                    NewProjectRow(create: open).staggered(2 + pinnedRows + others.count, shown)
                }
                .padding(.horizontal, Theme.Space.x2)
                .padding(.bottom, Theme.Space.x3)
            }
            .scrollIndicators(.never)

            Rectangle().fill(Theme.Palette.hairline).frame(height: 1)
            ProfileRow(selected: onSettings, action: settings)
                .padding(Theme.Space.x2)
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        // The side opening: the card itself grows out of the window's edge
        // (and folds back into it), its rows only ever showing inside it.
        .mask(alignment: .leading) {
            shape.frame(width: shown ? Self.width : Self.folded)
        }
        .background(alignment: .leading) {
            ZStack {
                FloatingSurface(shape: shape)
                shape.strokeBorder(Theme.Palette.hairline, lineWidth: 1)
            }
            .frame(width: shown ? Self.width : Self.folded)
        }
        .padding(Self.inset)
    }

    /// How narrow the card gets as it folds away, before it fades.
    static let folded: CGFloat = 40

    private func projectRow(_ name: String, pinned isPinned: Bool) -> some View {
        SidebarRow(title: name, selected: !onHome && !onSettings && current == name, action: { open(name) }) {
            SidebarCover(project: name)
        }
        .contextMenu {
            Button(isPinned ? "Unpin" : "Pin") { togglePin(name) }
        }
    }

    private func togglePin(_ name: String) {
        var list = pinnedList.split(separator: "\n").map(String.init)
        if let index = list.firstIndex(of: name) { list.remove(at: index) } else { list.append(name) }
        withAnimation(Theme.Motion.snappy) { pinnedList = list.joined(separator: "\n") }
    }
}

// MARK: - Rows

/// One line in the sidebar: an icon or cover, then the words. 28 tall,
/// radius 8 (concentric with the card), a fill when hovered or selected.
struct SidebarRow<Icon: View>: View {
    let title: String
    var selected = false
    let action: () -> Void
    @ViewBuilder let icon: () -> Icon
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
        Button(action: action) {
            HStack(spacing: Theme.Space.x2) {
                icon()
                    .frame(width: 18, height: 18)
                    .foregroundStyle(selected ? Theme.Palette.ink : Theme.Palette.ink2)
                Text(title)
                    .font(Theme.Typography.ui(Theme.Typography.body, selected ? .medium : .regular))
                    .foregroundStyle(selected ? Theme.Palette.ink : Theme.Palette.ink.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.x2 - 2)
            .frame(height: RepoHeader.toolHeight)
            .background(shape.fill(selected ? Theme.Palette.fillSelected : hovering ? Theme.Palette.fill : .clear))
            .contentShape(shape)
        }
        .buttonStyle(PressStyle(scale: 0.98))
        .onHover { inside in withAnimation(Theme.Motion.hover) { hovering = inside } }
    }
}

extension View {
    /// A sidebar row coming in: 30 ms after the one above it, fading and
    /// coming into focus (a light 3 pt blur) as it drifts 4 pt into place,
    /// with a long soft ease. Going, all together and quicker.
    func staggered(_ index: Int, _ shown: Bool) -> some View {
        let delay = Double(min(index, 12)) * Theme.Motion.stagger
        return opacity(shown ? 1 : 0)
            .blur(radius: shown ? 0 : 3)
            .offset(x: shown ? 0 : -Theme.Space.x1)
            .animation(shown ? Theme.Motion.settle.delay(0.16 + delay) : Theme.Motion.exit, value: shown)
    }
}

/// A quiet label over a group of rows.
private struct SidebarSection: View {
    let title: String

    var body: some View {
        Text(title)
            .font(Theme.Typography.ui(Theme.Typography.caption))
            .foregroundStyle(Theme.Palette.ink3)
            .padding(.horizontal, Theme.Space.x2 - 2)
            .padding(.top, Theme.Space.x4)
            .padding(.bottom, Theme.Space.x1)
    }
}

/// A project's cover at row size: its own latest picture, square, with a
/// hairline, like every capture. No picture: its first letter. Found once
/// per project and kept, never looked up while drawing.
private struct SidebarCover: View {
    @EnvironmentObject private var store: EntryStore
    let project: String
    @State private var image: NSImage?

    private static var found: [String: NSImage] = [:]

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().interpolation(.medium).scaledToFill()
            } else {
                Theme.Palette.fill
                Text(project.prefix(1).uppercased())
                    .font(Theme.Typography.ui(Theme.Typography.label, .medium))
                    .foregroundStyle(Theme.Palette.ink2)
            }
        }
        .frame(width: 18, height: 18)
        .clipped()
        .overlay(Rectangle().strokeBorder(Theme.Palette.hairline, lineWidth: 1))
        .task(id: project) {
            if let known = Self.found[project] { image = known; return }
            var picture = ProjectCovers.image(for: project, in: store)
            if picture == nil {
                // The first picture in the project, read off the main thread.
                for entry in store.entries(in: project).prefix(12) {
                    guard let file = entry.imageFile else { continue }
                    if let found = await store.loadThumbnail(forFile: file) { picture = found; break }
                }
            }
            if let picture { Self.found[project] = picture }
            image = picture
        }
    }
}

/// "New project": a plus, then a field in place once clicked.
private struct NewProjectRow: View {
    let create: (String) -> Void
    @State private var naming = false
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        if naming {
            HStack(spacing: Theme.Space.x2) {
                PlusGlyph().frame(width: 18, height: 18).foregroundStyle(Theme.Palette.ink2)
                TextField("", text: $name, prompt: Text("Project name").foregroundColor(Theme.Palette.ink3))
                    .textFieldStyle(.plain)
                    .font(Theme.Typography.ui(Theme.Typography.body))
                    .foregroundStyle(Theme.Palette.ink)
                    .focused($focused)
                    .onSubmit(submit)
                    .onExitCommand { naming = false; name = "" }
            }
            .padding(.horizontal, Theme.Space.x2 - 2)
            .frame(height: RepoHeader.toolHeight)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(Theme.Palette.fill))
            .onAppear { focused = true }
        } else {
            SidebarRow(title: "New project", action: { naming = true }) {
                PlusGlyph().frame(width: 18, height: 18)
            }
        }
    }

    private func submit() {
        let typed = name.trimmed
        naming = false
        name = ""
        if !typed.isEmpty { create(typed) }
    }
}

/// You, at the bottom: your picture, your name, and Settings.
private struct ProfileRow: View {
    @ObservedObject private var profile = Profile.shared
    var selected: Bool
    let action: () -> Void

    var body: some View {
        SidebarRow(title: profile.name.isEmpty ? "Settings" : profile.name, selected: selected, action: action) {
            ProfileAvatar(size: 18)
        }
        .toolTip("Settings", "Profile, capture and AI", edge: .above, align: .leading)
    }
}

/// Shows or hides the sidebar (⌘\).
struct SidebarToggle: View {
    let action: () -> Void

    var body: some View {
        HeaderTool(help: "Sidebar", detail: "Show or hide it with ⌘\\", tipAlign: .leading, action: action) {
            SidebarGlyph().frame(width: 16, height: 16)
        }
        .keyboardShortcut("\\", modifiers: .command)
    }
}

// MARK: - Glyphs

// Margin's own icons: drawn on a 16 grid with a 1.25 pt line and round
// ends, so they sit together (and beside the magnifier) at one weight.

private let glyphLine: CGFloat = 1.25

/// Show or hide the sidebar: a window with its side panel.
struct SidebarGlyph: View {
    var body: some View {
        Canvas { context, size in
            let u = size.width / 16
            let frame = Path(roundedRect: CGRect(x: 1.5 * u, y: 2.5 * u, width: 13 * u, height: 11 * u), cornerRadius: 2.5 * u)
            var divider = Path()
            divider.move(to: CGPoint(x: 6 * u, y: 2.5 * u))
            divider.addLine(to: CGPoint(x: 6 * u, y: 13.5 * u))
            let style = StrokeStyle(lineWidth: glyphLine, lineCap: .round, lineJoin: .round)
            context.stroke(frame, with: .foreground, style: style)
            context.stroke(divider, with: .foreground, style: style)
        }
    }
}

/// All projects: four squares.
struct GridGlyph: View {
    var body: some View {
        Canvas { context, size in
            let u = size.width / 16
            let style = StrokeStyle(lineWidth: glyphLine, lineJoin: .round)
            for (x, y) in [(2.0, 2.0), (9.0, 2.0), (2.0, 9.0), (9.0, 9.0)] {
                context.stroke(Path(CGRect(x: x * u, y: y * u, width: 5 * u, height: 5 * u)), with: .foreground, style: style)
            }
        }
    }
}

/// New project.
struct PlusGlyph: View {
    var body: some View {
        Canvas { context, size in
            let u = size.width / 16
            var path = Path()
            path.move(to: CGPoint(x: 8 * u, y: 3.5 * u)); path.addLine(to: CGPoint(x: 8 * u, y: 12.5 * u))
            path.move(to: CGPoint(x: 3.5 * u, y: 8 * u)); path.addLine(to: CGPoint(x: 12.5 * u, y: 8 * u))
            context.stroke(path, with: .foreground, style: StrokeStyle(lineWidth: glyphLine, lineCap: .round))
        }
    }
}

/// Settings and options: two sliders.
struct SettingsGlyph: View {
    var body: some View {
        Canvas { context, size in
            let u = size.width / 16
            let style = StrokeStyle(lineWidth: glyphLine, lineCap: .round)
            var lines = Path()
            lines.move(to: CGPoint(x: 2 * u, y: 5 * u)); lines.addLine(to: CGPoint(x: 14 * u, y: 5 * u))
            lines.move(to: CGPoint(x: 2 * u, y: 11 * u)); lines.addLine(to: CGPoint(x: 14 * u, y: 11 * u))
            context.stroke(lines, with: .foreground, style: style)
            for (x, y) in [(10.5, 5.0), (5.5, 11.0)] {
                let knob = Path(ellipseIn: CGRect(x: (x - 2) * u, y: (y - 2) * u, width: 4 * u, height: 4 * u))
                context.fill(knob, with: .color(Theme.Palette.paper))
                context.stroke(knob, with: .foreground, style: style)
            }
        }
    }
}

/// Documenting: a viewfinder's four corners around Margin's dot.
struct DocumentingGlyph: View {
    var body: some View {
        Canvas { context, size in
            let u = size.width / 16
            let style = StrokeStyle(lineWidth: glyphLine, lineCap: .round, lineJoin: .round)
            var corners = Path()
            for (x, y, dx, dy) in [(2.0, 2.0, 1.0, 1.0), (14.0, 2.0, -1.0, 1.0), (2.0, 14.0, 1.0, -1.0), (14.0, 14.0, -1.0, -1.0)] {
                corners.move(to: CGPoint(x: x * u, y: (y + 3.5 * dy) * u))
                corners.addLine(to: CGPoint(x: x * u, y: y * u))
                corners.addLine(to: CGPoint(x: (x + 3.5 * dx) * u, y: y * u))
            }
            context.stroke(corners, with: .foreground, style: style)
            context.fill(Path(ellipseIn: CGRect(x: 6.25 * u, y: 6.25 * u, width: 3.5 * u, height: 3.5 * u)), with: .foreground)
        }
    }
}

/// Reminders: a small bell.
struct BellGlyph: View {
    var body: some View {
        Canvas { context, size in
            let u = size.width / 16
            let style = StrokeStyle(lineWidth: glyphLine, lineCap: .round, lineJoin: .round)
            var bell = Path()
            bell.move(to: CGPoint(x: 3 * u, y: 11.5 * u))
            bell.addLine(to: CGPoint(x: 13 * u, y: 11.5 * u))
            bell.addCurve(to: CGPoint(x: 11.5 * u, y: 8 * u), control1: CGPoint(x: 12 * u, y: 10.5 * u), control2: CGPoint(x: 11.5 * u, y: 9.5 * u))
            bell.addLine(to: CGPoint(x: 11.5 * u, y: 6.5 * u))
            bell.addCurve(to: CGPoint(x: 4.5 * u, y: 6.5 * u), control1: CGPoint(x: 11.5 * u, y: 2 * u), control2: CGPoint(x: 4.5 * u, y: 2 * u))
            bell.addLine(to: CGPoint(x: 4.5 * u, y: 8 * u))
            bell.addCurve(to: CGPoint(x: 3 * u, y: 11.5 * u), control1: CGPoint(x: 4.5 * u, y: 9.5 * u), control2: CGPoint(x: 4 * u, y: 10.5 * u))
            bell.closeSubpath()
            bell.move(to: CGPoint(x: 6.5 * u, y: 13.5 * u))
            bell.addLine(to: CGPoint(x: 9.5 * u, y: 13.5 * u))
            context.stroke(bell, with: .foreground, style: style)
        }
    }
}

/// Hand the project off: Margin's bracket, with the work leaving it.
struct HandoffMarkGlyph: View {
    var body: some View {
        Canvas { context, size in
            let u = size.width / 16
            let style = StrokeStyle(lineWidth: glyphLine, lineCap: .round, lineJoin: .round)
            var bracket = Path()
            bracket.move(to: CGPoint(x: 6 * u, y: 2.5 * u))
            bracket.addLine(to: CGPoint(x: 2.5 * u, y: 2.5 * u))
            bracket.addLine(to: CGPoint(x: 2.5 * u, y: 13.5 * u))
            bracket.addLine(to: CGPoint(x: 6 * u, y: 13.5 * u))
            var arrow = Path()
            arrow.move(to: CGPoint(x: 6.5 * u, y: 8 * u)); arrow.addLine(to: CGPoint(x: 14 * u, y: 8 * u))
            arrow.move(to: CGPoint(x: 10.5 * u, y: 4.5 * u)); arrow.addLine(to: CGPoint(x: 14 * u, y: 8 * u))
            arrow.addLine(to: CGPoint(x: 10.5 * u, y: 11.5 * u))
            context.stroke(bracket, with: .foreground, style: style)
            context.stroke(arrow, with: .foreground, style: style)
        }
    }
}
