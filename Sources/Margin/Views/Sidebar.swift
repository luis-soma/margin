import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Vision

/// The floating sidebar: your projects, pinned ones first, a new one, and
/// you with Settings at the bottom. A white card inset from the window's
/// edges, holding the traffic lights at its top.
///
/// One card, two widths. Open, names sit beside the icons; collapsed (⌘\)
/// it narrows to a 72 pt rail. Every item is laid out once, at the open
/// width, and only shown through the card's current width: its icon never
/// moves (36 pt in, the rail's centre line), its fill narrows into a tile
/// and its name fades. One motion, nothing swapped. On the rail, pointing
/// at an item names it in an ink pill to the right.
struct ProjectSidebar: View {
    @EnvironmentObject private var store: EntryStore
    @ObservedObject private var profile = Profile.shared
    /// The project open, nil on All projects or Settings.
    let current: String?
    let onHome: Bool
    let onSettings: Bool
    /// Open (true) or narrowed to the rail.
    var shown = true
    let open: (String) -> Void
    let home: () -> Void
    let settings: () -> Void
    /// The menu on your name is open.
    var menuOpen = false
    let openMenu: () -> Void
    let collapse: () -> Void
    /// In a project: Hand off, a tool at the foot of the sidebar.
    var handoff: (() -> Void)? = nil
    var handingOver = false
    @AppStorage("pinnedProjects") private var pinnedList = ""
    /// Your order for the projects below the pinned ones, once you've
    /// dragged one; new projects come in above it.
    @AppStorage("projectOrder") private var orderList = ""
    /// The project being dragged to a new place.
    @State private var dragging: String?
    /// The name showing beside the rail, if any.
    @State private var tip: RailTip?
    @ObservedObject private var icons = ProjectIcons.shared

    static let width: CGFloat = 224
    /// From the window's edges to the card.
    static let inset = Theme.Space.x2
    /// What the archive gives up for it while it's open.
    static var room: CGFloat { width + inset }
    /// Collapsed: just wide enough to hold the traffic lights with the
    /// same space on both sides of them (18 from the window, 10 from the card).
    static let railWidth: CGFloat = 72
    /// What the archive gives up for the rail.
    static var railRoom: CGFloat { railWidth + inset }

    /// Every item: 36 tall, 2 apart, 8 in from the card's sides.
    static let rowHeight: CGFloat = 36
    static let rowGap: CGFloat = 2
    static let rowInset: CGFloat = Theme.Space.x2
    /// A row at full width (the open card less its insets).
    static var fullRow: CGFloat { width - 2 * rowInset }
    /// The icon's column, as wide as a rail tile: the icon sits 36 pt in,
    /// on the rail's centre line, open or not.
    static var iconColumn: CGFloat { railWidth - 2 * rowInset }
    /// The name starts this far back into the icon column, 10 pt from the icon.
    static let labelPull: CGFloat = -8
    /// The traffic lights' row.
    static var topRow: CGFloat { RepoHeader.height - inset }
    /// The toggle: on the traffic lights' line (24 pt down the window),
    /// at the open card's top right corner, or just outside the rail where
    /// the archive's bar begins. It slides between the two with the card's edge.
    static var toggleY: CGFloat { RepoHeader.trafficLights.y - inset - RepoHeader.toolHeight / 2 }
    static func toggleX(open: Bool) -> CGFloat {
        open ? width - rowInset - RepoHeader.toolWidth : railWidth + inset + Theme.Space.x2
    }

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
        let cardWidth: CGFloat = shown ? Self.width : Self.railWidth
        let rowWidth: CGFloat = cardWidth - 2 * Self.rowInset
        let names = projectNames()
        let (pinned, others) = sections(names)
        let pinnedRows: Int = pinned.isEmpty ? 0 : pinned.count + 1

        VStack(alignment: .leading, spacing: 0) {
            // The traffic lights.
            Color.clear.frame(width: cardWidth, height: Self.topRow)

            ScrollView {
                VStack(alignment: .leading, spacing: Self.rowGap) {
                    SidebarItem(title: "All projects", selected: onHome, open: shown, width: rowWidth, index: 1,
                                tip: $tip, action: home) {
                        GridGlyph().frame(width: 16, height: 16)
                    }
                    if !pinned.isEmpty {
                        SidebarSection(title: "Pinned", open: shown, width: rowWidth, index: 2)
                        ForEach(Array(pinned.enumerated()), id: \.element) { i, name in
                            projectRow(name, pinned: true, width: rowWidth, index: 3 + i)
                        }
                    }
                    SidebarSection(title: "Projects", open: shown, width: rowWidth, index: 2 + pinnedRows)
                    ForEach(Array(others.enumerated()), id: \.element) { i, name in
                        projectRow(name, pinned: false, width: rowWidth, index: 3 + pinnedRows + i)
                    }
                    NewProjectRow(open: shown, width: rowWidth, index: 3 + pinnedRows + others.count,
                                  tip: $tip, create: open, expand: collapse)
                }
                .padding(.horizontal, Self.rowInset)
                .padding(.bottom, Theme.Space.x3)
                .frame(width: cardWidth, alignment: .leading)
            }
            .scrollIndicators(.never)
            .frame(width: cardWidth)

            // The project's tool, above the line: hand it off to your agent,
            // a review or a case study.
            if let handoff {
                SidebarItem(title: "Hand off", selected: handingOver, open: shown, width: rowWidth, index: 0,
                            tip: $tip, action: handoff) {
                    HandoffMarkGlyph().frame(width: 16, height: 16)
                }
                .tourAnchor("handoff")
                .padding(.horizontal, Self.rowInset)
                .padding(.bottom, Self.rowInset)
                .transition(.opacity)
            }
            Rectangle().fill(Theme.Palette.hairline).frame(width: cardWidth, height: 1)
            // You: a menu with documenting, Intelligence and Settings.
            SidebarItem(title: profile.name.isEmpty ? "You" : profile.name, selected: onSettings || menuOpen,
                        open: shown, width: rowWidth, index: 0, menu: true, tip: $tip, action: openMenu) {
                ProfileAvatar(size: 22)
            }
            .padding(Self.rowInset)
        }
        .frame(width: cardWidth, alignment: .leading)
        .frame(maxHeight: .infinity)
        .clipShape(shape)
        .background {
            FloatingSurface(shape: shape, frosted: true)
        }
        .coordinateSpace(name: RailTip.space)
        // Let go between rows: the drag ends where the project now is.
        .onDrop(of: [.text], isTargeted: nil) { _ in
            let wasDragging = dragging != nil
            dragging = nil
            return wasDragging
        }
        // The toggle rides the card's edge: inside its top right corner when
        // open, just outside the rail when collapsed, on the same curve.
        .overlay(alignment: .topLeading) {
            SidebarToggle(action: collapse, plain: shown)
                .offset(x: Self.toggleX(open: shown), y: Self.toggleY)
        }
        // Outside the card's clip, so the name can stand beside the rail:
        // the same ink tooltip as every other control, centred on its row.
        .overlay(alignment: .topLeading) {
            if !shown, let tip {
                ToolTip(title: tip.name)
                    .fixedSize()
                    .frame(height: 0, alignment: .center)
                    .offset(x: Self.railWidth + Theme.Space.x2, y: tip.y)
                    .allowsHitTesting(false)
                    .transition(.opacity.combined(with: .offset(x: -4)))
                    .id(tip.name)
            }
        }
        .onChange(of: shown) { _ in tip = nil }
        .padding(Self.inset)
    }

    /// Pinned in the order you pinned (or dragged) them; the rest in your
    /// order, new ones (most recent first) above it.
    private func sections(_ names: [String]) -> (pinned: [String], others: [String]) {
        let present = Set(names)
        let pins = list(pinnedList).filter { present.contains($0) }
        let pinSet = Set(pins)
        let saved = list(orderList).filter { present.contains($0) && !pinSet.contains($0) }
        let savedSet = Set(saved)
        let fresh = names.filter { !pinSet.contains($0) && !savedSet.contains($0) }
        return (pins, fresh + saved)
    }

    private func list(_ stored: String) -> [String] {
        stored.split(separator: "\n").map(String.init)
    }

    /// Dragging `name` over `target`: it takes the target's place, in the
    /// target's section (so dragging into Pinned pins it).
    private func move(_ name: String, onto target: String) {
        guard name != target else { return }
        var (pins, others) = sections(projectNames())
        let toPinned = pins.contains(target)
        let fromPinned = pins.contains(name)
        if toPinned == fromPinned {
            var items = toPinned ? pins : others
            guard let from = items.firstIndex(of: name), let to = items.firstIndex(of: target) else { return }
            items.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
            if toPinned { pins = items } else { others = items }
        } else {
            pins.removeAll { $0 == name }
            others.removeAll { $0 == name }
            if toPinned {
                pins.insert(name, at: pins.firstIndex(of: target) ?? pins.count)
            } else {
                others.insert(name, at: others.firstIndex(of: target) ?? others.count)
            }
        }
        withAnimation(Theme.Motion.snappy) {
            pinnedList = pins.joined(separator: "\n")
            orderList = others.joined(separator: "\n")
        }
    }

    private func projectRow(_ name: String, pinned isPinned: Bool, width: CGFloat, index: Int) -> some View {
        SidebarItem(title: name, selected: !onHome && !onSettings && current == name, open: shown, width: width,
                    index: index, tip: $tip, action: { open(name) }) {
            ProjectIcon(project: name)
        }
        // Drag a project up or down to put it where you want it.
        .opacity(dragging == name ? 0.5 : 1)
        .onDrag {
            dragging = name
            tip = nil
            endWithMouseUp()
            return NSItemProvider(object: name as NSString)
        }
        .onDrop(of: [.text], delegate: ProjectDrop(target: name, dragging: $dragging, move: move))
        .contextMenu {
            Button(isPinned ? "Unpin" : "Pin") { togglePin(name) }
            Button("Choose icon…") { icons.choose(for: name, store: store) }
            if icons.hasOwn(name, store: store) {
                Button("Use a picture from the project") { icons.automatic(for: name, store: store) }
            }
        }
    }

    /// A drag let go outside the sidebar never lands on a row: the drag
    /// ends when the button comes up, wherever it is.
    private func endWithMouseUp() {
        let state = $dragging
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
            guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
            timer.invalidate()
            MainActor.assumeIsolated { state.wrappedValue = nil }
        }
    }

    private func togglePin(_ name: String) {
        var list = pinnedList.split(separator: "\n").map(String.init)
        if let index = list.firstIndex(of: name) { list.remove(at: index) } else { list.append(name) }
        withAnimation(Theme.Motion.snappy) { pinnedList = list.joined(separator: "\n") }
    }
}

/// A project row as a place to drop another: the dragged one moves into
/// its place as it passes over, so the list makes room as you drag.
private struct ProjectDrop: DropDelegate {
    let target: String
    @Binding var dragging: String?
    let move: (String, String) -> Void

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        move(dragging, target)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func validateDrop(info: DropInfo) -> Bool {
        dragging != nil
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

/// The name beside the rail: which item, and the middle of its row in the
/// card's own coordinates.
struct RailTip: Equatable {
    static let space = "sidebarCard"
    let name: String
    let y: CGFloat
}

// MARK: - Items

/// One item, open or on the rail: the icon in its column, then the name,
/// always laid out at the open width and seen through `width`. Open, a 36
/// tall row with a fill when hovered or selected (radius 8); on the rail
/// the same fill is a 56 x 36 tile, and the name moves to a pill.
private struct SidebarItem<Icon: View>: View {
    let title: String
    var selected = false
    let open: Bool
    let width: CGFloat
    /// Its place in the stagger, top to bottom.
    let index: Int
    /// Opens a menu: a small up-and-down chevron at the row's end.
    var menu = false
    @Binding var tip: RailTip?
    let action: () -> Void
    @ViewBuilder let icon: () -> Icon
    @State private var hovering = false
    @State private var midY: CGFloat = 0

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
        Button(action: action) {
            HStack(spacing: 0) {
                icon()
                    .frame(width: 20, height: 20)
                    .foregroundStyle(selected || hovering ? Theme.Palette.ink : Theme.Palette.ink2)
                    .frame(width: ProjectSidebar.iconColumn, height: ProjectSidebar.rowHeight)
                SidebarLabel(text: title, selected: selected, open: open, index: index)
                if menu {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.Palette.ink3)
                        .padding(.trailing, Theme.Space.x3)
                        .sidebarReveal(open, index)
                }
            }
            .frame(width: ProjectSidebar.fullRow, height: ProjectSidebar.rowHeight, alignment: .leading)
            .frame(width: width, alignment: .leading)
            .clipped()
            .background(shape.fill(selected ? Theme.Palette.fillSelected : hovering ? Theme.Palette.fillHover : .clear))
            .contentShape(shape)
        }
        .buttonStyle(PressStyle(scale: 0.98))
        .background(GeometryReader { geo in
            let y: CGFloat = geo.frame(in: .named(RailTip.space)).midY
            Color.clear
                .onAppear { midY = y }
                .onChange(of: y) { midY = $0 }
        })
        .onHover { inside in
            withAnimation(Theme.Motion.hover) { hovering = inside }
            railTip(inside)
        }
        .accessibilityLabel(title)
    }

    private func railTip(_ inside: Bool) {
        if inside, !open {
            withAnimation(Theme.Motion.enter) { tip = RailTip(name: title, y: midY) }
        } else if tip?.name == title {
            withAnimation(Theme.Motion.exit) { tip = nil }
        }
    }
}

/// An item's name: gone quickly as the card starts to narrow, back once
/// it's most of the way open.
private struct SidebarLabel: View {
    let text: String
    let selected: Bool
    let open: Bool
    let index: Int

    var body: some View {
        Text(text)
            .font(Theme.Typography.ui(Theme.Typography.body, selected ? .medium : .regular))
            .foregroundStyle(selected ? Theme.Palette.ink : Theme.Palette.ink.opacity(0.8))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.leading, ProjectSidebar.labelPull)
            .padding(.trailing, Theme.Space.x2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .sidebarReveal(open, index)
    }
}

/// A quiet label over a group of items. On the rail it becomes a short
/// hairline in the icon column, in the same place.
private struct SidebarSection: View {
    let title: String
    let open: Bool
    let width: CGFloat
    let index: Int

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Text(title)
                .font(Theme.Typography.ui(Theme.Typography.caption))
                .foregroundStyle(Theme.Palette.ink3)
                .lineLimit(1)
                .padding(.leading, (ProjectSidebar.iconColumn - 20) / 2)
                .padding(.bottom, Theme.Space.x1)
                .sidebarReveal(open, index)
            Rectangle()
                .fill(Theme.Palette.hairline)
                .frame(width: 20, height: 1)
                .frame(width: ProjectSidebar.iconColumn, height: 28)
                .railReveal(!open, index)
        }
        .frame(width: ProjectSidebar.fullRow, height: 28, alignment: .leading)
        .frame(width: width, alignment: .leading)
        .clipped()
    }
}

/// "New project": a plus, then a field in place once clicked. On the rail
/// it opens the sidebar and the field with it.
private struct NewProjectRow: View {
    let open: Bool
    let width: CGFloat
    let index: Int
    @Binding var tip: RailTip?
    let create: (String) -> Void
    let expand: () -> Void
    @State private var naming = false
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if naming && open {
                HStack(spacing: 0) {
                    PlusGlyph()
                        .frame(width: 16, height: 16)
                        .foregroundStyle(Theme.Palette.ink2)
                        .frame(width: ProjectSidebar.iconColumn)
                    TextField("", text: $name, prompt: Text("Project name").foregroundColor(Theme.Palette.ink3))
                        .textFieldStyle(.plain)
                        .font(Theme.Typography.ui(Theme.Typography.body))
                        .foregroundStyle(Theme.Palette.ink)
                        .focused($focused)
                        .onSubmit(submit)
                        .onExitCommand { naming = false; name = "" }
                        .padding(.leading, ProjectSidebar.labelPull)
                        .padding(.trailing, Theme.Space.x2)
                }
                .frame(width: width, height: ProjectSidebar.rowHeight, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).fill(Theme.Palette.fill))
                .onAppear { focused = true }
            } else {
                SidebarItem(title: "New project", open: open, width: width, index: index, tip: $tip, action: start) {
                    PlusGlyph().frame(width: 16, height: 16)
                }
            }
        }
        .onChange(of: open) { if !$0 { naming = false; name = "" } }
    }

    private func start() {
        if !open { expand() }
        naming = true
    }

    private func submit() {
        let typed = name.trimmed
        naming = false
        name = ""
        if !typed.isEmpty { create(typed) }
    }
}

/// Shows or hides the sidebar (⌘\): in the open card's top corner, or
/// just outside the rail.
struct SidebarToggle: View {
    let action: () -> Void
    /// Only the toggle on screen answers ⌘\, so one press is one change.
    var shortcut = true
    /// Inside the open card: the icon darkens on hover, no fill.
    var plain = false

    var body: some View {
        HeaderTool(help: "Sidebar", detail: "Show or hide it with ⌘\\", plain: plain, tipAlign: .leading, action: action) {
            SidebarGlyph().frame(width: 16, height: 16)
        }
        .keyboardShortcut(shortcut ? KeyboardShortcut("\\", modifiers: .command) : nil)
    }
}

extension View {
    /// The open sidebar's contents: once the card has mostly widened, each
    /// piece comes in 30 ms after the one above it, fading up, drifting
    /// 4 pt into place and coming into focus on a long soft ease. Closing,
    /// all of it goes at once and quickly, ahead of the card narrowing.
    func sidebarReveal(_ open: Bool, _ index: Int) -> some View {
        let delay: Double = 0.2 + Double(min(index, 14)) * 0.03
        return opacity(open ? 1 : 0)
            .offset(x: open ? 0 : -4)
            .blur(radius: open ? 0 : 2)
            .animation(open ? Theme.Motion.settle.delay(delay) : .easeOut(duration: 0.1), value: open)
    }

    /// What only the rail has (its toggle, the section hairlines): the same
    /// entrance, once the card has narrowed.
    func railReveal(_ rail: Bool, _ index: Int) -> some View {
        let delay: Double = 0.18 + Double(min(index, 14)) * 0.03
        return opacity(rail ? 1 : 0)
            .blur(radius: rail ? 0 : 2)
            .animation(rail ? Theme.Motion.settle.delay(delay) : .easeOut(duration: 0.1), value: rail)
    }
}

/// A project's cover at row size: its own latest picture, square, with a
/// hairline, like every capture. No picture: its first letter. Found once
/// per project and kept, never looked up while drawing.
struct SidebarCover: View {
    @EnvironmentObject private var store: EntryStore
    let project: String
    var size: CGFloat = 18
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
        .frame(width: size, height: size)
        .clipped()
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

// MARK: - Project icons

/// What each project shows in the sidebar: a small picture from its own
/// work, cropped to the part that reads at 22 pt. Margin looks through the
/// cover and the first captures, finds where the eye goes in each (a logo,
/// a face, a bold shape) and keeps the crop with the most contrast, so the
/// icon is a recognisable piece of the project rather than a whole
/// screenshot shrunk to noise. You can give a project its own picture
/// (a logo) instead.
@MainActor
final class ProjectIcons: ObservableObject {
    static let shared = ProjectIcons()
    @Published private(set) var images: [String: NSImage] = [:]
    private var working: Set<String> = []

    static func folder(_ store: EntryStore) -> URL {
        ProjectCovers.folder(store).appendingPathComponent("icons", isDirectory: true)
    }

    static func url(for project: String, in store: EntryStore) -> URL {
        folder(store).appendingPathComponent(HandoverExporter.safe(project) + ".png")
    }

    func image(for project: String, store: EntryStore) -> NSImage? {
        if let image = images[project] { return image }
        load(project, store: store)
        return nil
    }

    /// Your own picture for the icon (a logo), kept beside the covers.
    func choose(for project: String, store: EntryStore) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an icon for \(project), like its logo"
        guard panel.runModal() == .OK, let url = panel.url, let picture = NSImage(contentsOf: url),
              let png = ProjectCovers.pngData(picture, maxWidth: 256) else { return }
        try? FileManager.default.createDirectory(at: Self.folder(store), withIntermediateDirectories: true)
        try? png.write(to: Self.url(for: project, in: store), options: .atomic)
        images[project] = NSImage(data: png)
    }

    /// Back to the picture Margin picks.
    func automatic(for project: String, store: EntryStore) {
        try? FileManager.default.removeItem(at: Self.url(for: project, in: store))
        images[project] = nil
        working.remove(project)
        load(project, store: store)
    }

    func hasOwn(_ project: String, store: EntryStore) -> Bool {
        FileManager.default.fileExists(atPath: Self.url(for: project, in: store).path)
    }

    private func load(_ project: String, store: EntryStore) {
        guard !working.contains(project) else { return }
        working.insert(project)
        let own = Self.url(for: project, in: store)
        Task { @MainActor in
            if let picture = NSImage(contentsOf: own) {
                images[project] = picture
                return
            }
            // The cover first, then the newest captures with a picture.
            var candidates: [CGImage] = []
            if let cover = ProjectCovers.image(for: project, in: store), let cg = cover.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                candidates.append(cg)
            }
            if case let .picture(shipped)? = ProjectCovers.shipped(for: project),
               let cg = shipped.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                candidates.append(cg)
            }
            for entry in store.entries(in: project).prefix(40) where candidates.count < 12 {
                guard let file = entry.imageFile, let thumb = await store.loadThumbnail(forFile: file),
                      let cg = thumb.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
                candidates.append(cg)
            }
            guard !candidates.isEmpty else { return }
            let found = await Task.detached(priority: .utility) { IconCrop.best(of: candidates) }.value
            if let found { images[project] = NSImage(cgImage: found, size: NSSize(width: 22, height: 22)) }
        }
    }
}

/// Finding the part of a picture that reads small.
enum IconCrop {
    /// The most legible square crop across `pictures`, at 88 px.
    static func best(of pictures: [CGImage]) -> CGImage? {
        var best: (score: Double, image: CGImage)?
        for picture in pictures {
            guard let crop = crop(picture), let small = render(crop, side: 88) else { continue }
            let score = contrast(small)
            if score > (best?.score ?? -1) { best = (score, small) }
        }
        return best?.image
    }

    /// A square around where the eye goes (Vision's attention), a little
    /// wider than it, never smaller than a fifth of the picture.
    static func crop(_ picture: CGImage) -> CGImage? {
        let w = CGFloat(picture.width), h = CGFloat(picture.height)
        var focus = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let request = VNGenerateAttentionBasedSaliencyImageRequest()
        if (try? VNImageRequestHandler(cgImage: picture).perform([request])) != nil,
           let observation = request.results?.first as? VNSaliencyImageObservation,
           let box = observation.salientObjects?.max(by: { $0.confidence * Float($0.boundingBox.width * $0.boundingBox.height)
               < $1.confidence * Float($1.boundingBox.width * $1.boundingBox.height) })?.boundingBox {
            focus = box
        }
        // Vision's boxes start at the bottom left.
        let rect = CGRect(x: focus.minX * w, y: (1 - focus.maxY) * h, width: focus.width * w, height: focus.height * h)
        let shortest = min(w, h)
        let side = min(shortest, max(max(rect.width, rect.height) * 1.15, shortest * 0.2))
        let x = min(max(rect.midX - side / 2, 0), w - side)
        let y = min(max(rect.midY - side / 2, 0), h - side)
        return picture.cropping(to: CGRect(x: x, y: y, width: side, height: side).integral)
    }

    static func render(_ picture: CGImage, side: Int) -> CGImage? {
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(picture, in: CGRect(x: 0, y: 0, width: side, height: side))
        return context.makeImage()
    }

    /// How much the picture's light varies at icon size: plain, washed-out
    /// crops score low, bold marks high.
    static func contrast(_ picture: CGImage) -> Double {
        let side = 22
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return 0 }
        context.draw(picture, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = context.data else { return 0 }
        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side)
        var sum = 0.0, squares = 0.0
        for i in 0..<(side * side) {
            let v = Double(pixels[i]) / 255
            sum += v
            squares += v * v
        }
        let n = Double(side * side)
        let mean = sum / n
        return max(0, squares / n - mean * mean).squareRoot()
    }
}

/// A project's icon at sidebar size: its picture, slightly square. Until
/// the picture is found, its first letter on a soft tile.
struct ProjectIcon: View {
    let project: String
    var size: CGFloat = 22
    @EnvironmentObject private var store: EntryStore
    @ObservedObject private var icons = ProjectIcons.shared

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        ZStack {
            if let image = icons.image(for: project, store: store) {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFill()
                    .transition(.opacity)
            } else {
                shape.fill(Theme.Palette.ink.opacity(0.06))
                Text(project.trimmingCharacters(in: .whitespaces).prefix(1).uppercased())
                    .font(Theme.Typography.ui(size * 0.5, .semibold))
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .animation(.easeOut(duration: 0.25), value: icons.images[project] != nil)
    }
}
