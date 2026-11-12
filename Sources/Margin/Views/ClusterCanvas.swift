import AppKit
import ImageIO
import MarginKit
import SwiftUI

/// The cluster view: the project as a map of meaning. Each theme's name
/// sits in the middle of its captures, the most telling nearest, and stays
/// at every zoom; faint threads join themes that share meaning. The zoom is
/// continuous and nothing rearranges as you zoom. Nothing overlaps.
///
/// Margin sorts the map once, as a starting point. From then on it's yours
/// and it holds still: double-click a name to rename it, double-click the
/// map to add a headline, drag a capture where you want it (it joins the
/// nearest group), click a note at the close-up to change it. Only what you
/// touch moves. A new headline gets a quiet offer of the captures that
/// might fit; nothing moves until you take it. New captures settle into the
/// group they fit, at the nearest free spot.
struct ClusterCanvas: View {
    let entries: [Entry]
    /// Where each artifact is on the timeline right now, in this view's
    /// coordinates: where they leave from and land back.
    let start: [UUID: CGRect]
    let size: CGSize
    /// Off: everything returns to the timeline, then `exited` is called.
    let active: Bool
    /// The slider's step: 0 close-up ... 3 big picture.
    @Binding var level: Int
    /// The slider's live position while pinching.
    @Binding var pinchZoom: CGFloat?
    /// The map's zoom, anywhere from close-up (0) to big picture (3); the
    /// slider and pinching both move it.
    @Binding var mapDepth: CGFloat
    let exited: () -> Void

    @EnvironmentObject private var store: EntryStore
    @EnvironmentObject private var intelligence: Intelligence
    @Environment(\.focusMoment) private var focusMoment

    /// Each artifact's frame on the map now (at no pan and no zoom).
    @State private var frames: [UUID: CGRect] = [:]
    /// Each artifact's frame at the big picture, and at the closer steps.
    @State private var farFrames: [UUID: CGRect] = [:]
    @State private var nearFrames: [UUID: CGRect] = [:]
    @State private var mapCentre: CGPoint = .zero
    /// The room each theme's name takes on screen.
    @State private var themeRoom: [String: CGSize] = [:]
    /// Each theme's captures, ready to draw in toward its name as you zoom.
    @State private var gathers: [Gather] = []
    /// Where each capture's box sits now as the themes draw in: each zoom
    /// starts from here, so the motion never jumps.
    @State private var relaxed: [UUID: CGPoint] = [:]
    @State private var fitZoom: CGFloat = 0.3
    @State private var stepRatio: CGFloat = 1.8
    @State private var laidOut = false
    @State private var layoutToken = 0
    @State private var arrivalPending = false

    @State private var lifted = false
    @State private var gridShown = false
    /// The artifacts have moved onto the map.
    @State private var mapped = false
    @State private var labelsShown = false
    @State private var pan: CGSize = .zero
    @State private var zoom: CGFloat = 1
    /// Where between close-up (0) and big picture (3) the view is, continuously.
    @State private var depth: CGFloat = 0
    @State private var pinching = false
    @State private var dragging: UUID?
    /// The captures moving with the one under the pointer: the selection,
    /// when it's part of it.
    @State private var group: Set<UUID> = []
    /// Captures you've selected by dragging a box around them.
    @State private var selected: Set<UUID> = []
    /// The box being drawn, on screen, and what was selected before it.
    @State private var marquee: CGRect?
    @State private var marqueeBase: Set<UUID> = []
    @State private var dragDelta: CGSize = .zero
    /// Captures lit while you look at what Margin suggests for a group.
    @State private var highlighted: Set<UUID> = []
    /// The capture under the pointer: lines to what it's closest to.
    @State private var hovered: UUID?
    /// How many captures use each telling word, for naming what's shared.
    @State private var openedAt = Date()
    @State private var tick = 0

    /// What you're writing on the map, if anything.
    enum Editing: Equatable {
        case name(tier: Int, key: String)
        case headline(at: CGPoint, tier: Int)
        case note(UUID)
    }
    @State private var editing: Editing?
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    private var project: String { store.currentProject }
    private var maps: ProjectMaps { intelligence.maps }
    private var map: ProjectMap? { maps.maps[project] }
    private var arrangement: Arrangement? { maps.arrangements[project] }

    // MARK: Timing and sizes

    static let liftTime = 0.6
    /// The least time floating before they move onto the map.
    static let floatTime = 0.9
    static let mapMotion = Animation.spring(response: 1.0, dampingFraction: 0.88)
    static let stepMotion = Animation.spring(response: 0.6, dampingFraction: 0.92)
    static let noteSize: CGFloat = 11

    var body: some View {
        let patterns = placedPatterns
        ZStack(alignment: .topLeading) {
            DotGrid(pan: pan, zoom: zoom)
                .opacity(gridShown ? 1 : 0)
                .allowsHitTesting(false)
            // Double-click the bare map to add a headline there.
            Color.clear
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture(count: 2).onEnded { value in startHeadline(at: value.location) })
                .onTapGesture { finishEditing(); selected = [] }
                .simultaneousGesture(boxSelect)
            world(patterns)
                .scaleEffect(zoom, anchor: .topLeading)
                .offset(pan)
            // The box you're drawing: a hairline, the faintest wash.
            if let box = marquee {
                Rectangle()
                    .fill(Archive.ink.opacity(0.035))
                    .overlay(Rectangle().strokeBorder(Archive.ink.opacity(0.5), lineWidth: 1))
                    .frame(width: box.width, height: box.height)
                    .offset(x: box.minX, y: box.minY)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()
        .contentShape(Rectangle())
        .background(CanvasEvents(
            enabled: active && editing == nil,
            pan: { dx, dy in pan.width += dx; pan.height += dy },
            pinch: { magnification, point in pinch(by: magnification, at: point) },
            pinchEnded: { point in endPinch(at: point) }
        ))
        .overlay(alignment: .bottom) { footer }
        .onAppear(perform: enter)
        .onChange(of: active) { if !$0 { leave() } }
        .onChange(of: map?.signature) { _ in mapChanged() }
        .onChange(of: maps.titles[project]) { _ in
            maps.followNames(project: project)
            if arrivalPending { tryArrive() }
        }
        .onChange(of: arrangement) { _ in arrangementChanged() }
        .onChange(of: entries.map(\.id)) { _ in
            if mapped { maps.adopt(project: project, entries: entries) }
        }
        .onChange(of: size) { _ in sync(animated: true) }
        .onChange(of: mapDepth) { slid(to: $0) }
    }

    // MARK: The map

    private func world(_ patterns: [PlacedPattern]) -> some View {
        let notes = noteOpacity
        let branch = hoverBranch
        return ZStack(alignment: .topLeading) {
            // What the capture under the pointer is closest to in meaning.
            if !branch.isEmpty {
                Path { path in
                    for line in branch {
                        path.move(to: line.0)
                        path.addLine(to: line.1)
                    }
                }
                .stroke(Archive.muted.opacity(0.6), lineWidth: 1 / max(zoom, 0.05))
                .allowsHitTesting(false)
                .transition(.opacity)
            }
            ForEach(entries) { entry in
                if let frame = frames[entry.id] {
                    let moving = dragging != nil && group.contains(entry.id)
                    CanvasArtifact(entry: entry, size: frame.size, lifted: lifted, held: moving, seed: seed(entry.id),
                                   sharp: wantsSharp(frame), zoom: zoom, selected: selected.contains(entry.id),
                                   floats: entries.count <= Self.mostFloating)
                        .opacity(artifactOpacity(entry.id))
                        .offset(x: frame.minX + (moving ? dragDelta.width : 0), y: frame.minY + (moving ? dragDelta.height : 0))
                        .zIndex(moving ? 4 : 0)
                        .onHover { inside in
                            if inside { hovered = entry.id } else if hovered == entry.id { hovered = nil }
                        }
                        .gesture(drag(entry.id))
                        .onTapGesture {
                            // Shift-click adds to the selection or takes away from it.
                            if NSEvent.modifierFlags.contains(.shift) {
                                if selected.contains(entry.id) { selected.remove(entry.id) } else { selected.insert(entry.id) }
                            } else {
                                focusMoment(entry)
                            }
                        }
                    if notes > 0.01, !moving {
                        note(for: entry, under: frame)
                            .opacity(notes)
                    }
                }
            }
            // The names, each in the middle of its group, one size on screen.
            ForEach(patterns) { pattern in
                Group {
                    if editing == .name(tier: pattern.tier, key: pattern.key) {
                        field(placeholder: "Name", delete: { removeGroup(pattern) })
                    } else {
                        PatternLabel(title: pattern.title, count: pattern.count, scale: labelScale,
                                     suggested: pattern.suggested.compactMap { id in entries.first { $0.id == id } },
                                     take: { maps.acceptSuggestions(project: project, tier: pattern.tier, key: pattern.key); highlighted = [] },
                                     takeOne: { id in maps.acceptSuggestions(project: project, tier: pattern.tier, key: pattern.key, only: id.uuidString) },
                                     skip: { maps.dismissSuggestions(project: project, tier: pattern.tier, key: pattern.key); highlighted = [] },
                                     look: { on in withAnimation(Brand.quick) { highlighted = on ? Set(pattern.suggested) : [] } })
                            .onTapGesture(count: 2) { startRename(pattern) }
                            .onTapGesture { zoomInto(pattern) }
                    }
                }
                .scaleEffect(1 / max(zoom, 0.05))
                .position(pattern.center)
                .opacity(pattern.opacity)
                .allowsHitTesting(pattern.opacity > 0.5)
                .zIndex(3)
            }
            // A headline you're adding.
            if case let .headline(at, _)? = editing {
                field(placeholder: "New theme")
                    .scaleEffect(1 / max(zoom, 0.05))
                    .position(at)
                    .zIndex(5)
            }
        }
        .animation(Brand.quick, value: hovered)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    /// Suggestions being looked at light those; a hovered capture quiets
    /// everything it isn't close to.
    private func artifactOpacity(_ id: UUID) -> Double {
        if !highlighted.isEmpty { return highlighted.contains(id) ? 1 : 0.3 }
        guard mapped, dragging == nil, let hovered, hovered != id else { return 1 }
        let near = map?.neighbors[hovered.uuidString] ?? []
        guard !near.isEmpty else { return 1 }
        return near.contains(id.uuidString) ? 1 : 0.35
    }

    /// Lines from the hovered capture to the three it's closest to in meaning.
    private var hoverBranch: [(CGPoint, CGPoint)] {
        guard mapped, dragging == nil, let hovered, let from = frames[hovered],
              let near = map?.neighbors[hovered.uuidString] else { return [] }
        return near.compactMap { key -> (CGPoint, CGPoint)? in
            guard let id = UUID(uuidString: key), let to = frames[id] else { return nil }
            return (CGPoint(x: from.midX, y: from.midY), CGPoint(x: to.midX, y: to.midY))
        }
    }

    struct ThemeLink: Identifiable {
        var id: String { "\(a)|\(b)" }
        let a: String
        let b: String
        let from: CGPoint
        let to: CGPoint
        /// 0...1: how much more they share than the other pairs.
        let strength: Double
    }

    /// The links between theme names, each line stopping short of the names.
    private var themeLinks: [ThemeLink] {
        guard mapped, let a = arrangement else { return [] }
        let centers = Dictionary(a.themes.map { ($0.key, CGPoint(x: $0.label.x, y: $0.label.y)) }, uniquingKeysWith: { x, _ in x })
        let clearance = 70 / max(zoom, 0.05)
        return maps.themeLinks(project: project).compactMap { link -> ThemeLink? in
            guard let p = centers[link.a], let q = centers[link.b] else { return nil }
            let d = hypot(q.x - p.x, q.y - p.y)
            guard d > clearance * 2.4 else { return nil }
            let ux = (q.x - p.x) / d, uy = (q.y - p.y) / d
            return ThemeLink(a: link.a, b: link.b,
                             from: CGPoint(x: p.x + ux * clearance, y: p.y + uy * clearance),
                             to: CGPoint(x: q.x - ux * clearance, y: q.y - uy * clearance),
                             strength: link.strength)
        }
    }

    /// Your note under a capture, the same size on screen at any zoom.
    /// Click it to change it.
    @ViewBuilder
    private func note(for entry: Entry, under frame: CGRect) -> some View {
        let width = frame.width * zoom
        Group {
            if editing == .note(entry.id) {
                TextField("Add a note", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Archive.sans(Self.noteSize))
                    .foregroundStyle(Archive.ink)
                    .lineLimit(1...3)
                    .focused($fieldFocused)
                    .onSubmit(finishEditing)
                    .onExitCommand(perform: cancelEditing)
            } else {
                Text(entry.annotation ?? "Add a note")
                    .font(Archive.sans(Self.noteSize))
                    .foregroundStyle(entry.annotation == nil ? Archive.faint : Archive.muted)
                    .lineLimit(2)
                    .contentShape(Rectangle())
                    .onTapGesture { startNote(entry) }
            }
        }
        .frame(width: width, alignment: .topLeading)
        .scaleEffect(1 / max(zoom, 0.05), anchor: .topLeading)
        .offset(x: frame.minX, y: frame.maxY + 6 / max(zoom, 0.05))
        .zIndex(2)
    }

    /// Where you write a name, in the names' own type.
    private func field(placeholder: String, delete: (() -> Void)? = nil) -> some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: $draft)
                .textFieldStyle(.plain)
                // The same size as the name it edits, at this zoom.
                .font(Archive.font(PatternLabel.titleSize * labelScale))
                .foregroundStyle(Archive.ink)
                .multilineTextAlignment(.center)
                .frame(width: (PatternLabel.wrapWidth + 40) * labelScale)
                .focused($fieldFocused)
                .onSubmit(finishEditing)
                .onExitCommand(perform: cancelEditing)
            ConfirmButton(action: finishEditing)
            if let delete {
                ConfirmButton(symbol: "trash", help: "Delete this theme", action: delete)
            }
        }
        // Centred on the words, the buttons to their right.
        .padding(.leading, (ConfirmButton.size + 8) * (delete == nil ? 1 : 2))
    }

    /// Large on screen and in view: worth the full picture, not the thumbnail.
    private func wantsSharp(_ frame: CGRect) -> Bool {
        guard mapped, frame.width * zoom > 220 else { return false }
        let onScreen = CGRect(x: frame.minX * zoom + pan.width, y: frame.minY * zoom + pan.height,
                              width: frame.width * zoom, height: frame.height * zoom)
        return onScreen.intersects(CGRect(origin: .zero, size: size).insetBy(dx: -200, dy: -200))
    }

    /// Your notes fade in once captures are large enough on screen to read them by.
    private var noteOpacity: Double {
        guard mapped else { return 0 }
        return Double(min(max((ProjectMaps.side * zoom - 190) / 60, 0), 1))
    }

    private func drag(_ id: UUID) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                if dragging != id {
                    dragging = id
                    // A selected capture brings the rest of the selection along.
                    group = selected.contains(id) && selected.count > 1 ? selected : [id]
                }
                dragDelta = value.translation
            }
            .onEnded { value in
                // They stay where you let go, then settle into the nearest free spots.
                var moves: [(UUID, MapPoint)] = []
                let together: Set<UUID> = group.isEmpty ? [id] : group
                for member in together {
                    guard let frame = frames[member] else { continue }
                    let landed = frame.offsetBy(dx: value.translation.width, dy: value.translation.height)
                    frames[member] = landed
                    moves.append((member, MapPoint(x: Double(landed.midX), y: Double(landed.midY))))
                }
                dragging = nil
                group = []
                dragDelta = .zero
                maps.moveMany(project: project, moves: moves, far: true)
            }
    }

    /// Drag on empty space to draw a box: everything it touches is selected.
    /// With Shift held, the box adds to what's already selected.
    private var boxSelect: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard mapped, editing == nil, dragging == nil else { return }
                if marquee == nil { marqueeBase = NSEvent.modifierFlags.contains(.shift) ? selected : [] }
                let a = value.startLocation, b = value.location
                let box = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
                marquee = box
                var hit = marqueeBase
                for (id, f) in frames {
                    let onScreen = CGRect(x: f.minX * zoom + pan.width, y: f.minY * zoom + pan.height,
                                          width: f.width * zoom, height: f.height * zoom)
                    if onScreen.intersects(box) { hit.insert(id) }
                }
                if hit != selected { selected = hit }
            }
            .onEnded { _ in
                marquee = nil
                marqueeBase = []
            }
    }

    // MARK: Names

    struct PlacedPattern: Identifiable {
        var id: String { "\(tier)-\(key)" }
        let key: String
        let title: String
        let count: Int
        /// 0 a pattern, 1 a theme.
        let tier: Int
        let center: CGPoint
        let opacity: Double
        let suggested: [UUID]
    }

    /// One set of names: the themes', at every zoom, so you always know
    /// where you are.
    private func tierOpacity(_ tier: Int) -> Double { tier == 1 ? 1 : 0 }

    private var placedPatterns: [PlacedPattern] {
        guard mapped, labelsShown, let a = arrangement else { return [] }
        let here = Set(entries.map(\.id.uuidString))
        var result: [PlacedPattern] = []
        for tier in [1] {
            let opacity = tierOpacity(tier)
            let editingHere: Bool = {
                if case let .name(t, _)? = editing { return t == tier }
                return false
            }()
            guard opacity > 0.01 || editingHere else { continue }
            let groups = tier == 1 ? a.themes : a.patterns
            let membership = tier == 1 ? a.themeOf : a.patternOf
            var counts: [String: Int] = [:]
            for (id, key) in membership where here.contains(id) { counts[key, default: 0] += 1 }
            for group in groups {
                let suggested = group.suggested.filter { here.contains($0) }.compactMap(UUID.init(uuidString:))
                result.append(PlacedPattern(key: group.key, title: group.title, count: counts[group.key] ?? 0, tier: tier,
                                            center: CGPoint(x: group.label.x, y: group.label.y),
                                            opacity: max(opacity, editing == .name(tier: tier, key: group.key) ? 1 : 0),
                                            suggested: suggested))
            }
        }
        return result
    }

    /// One line in the log, at most once a second, to see what the slider
    /// and the map do on the Mac where something's off.
    private static var lastNote = Date.distantPast
    static func note(_ line: String) {
        guard Date().timeIntervalSince(lastNote) > 1 else { return }
        lastNote = Date()
        MarginLog.info(line)
    }

    /// Above this many captures the cards hold still instead of floating.
    static let mostFloating = 40

    /// Notes at the bottom sit over the Timeline / Themes switch, not on it:
    /// its 16 from the edge, its 28 and a gap.
    static let footerLift: CGFloat = 16 + 28 + 12

    @ViewBuilder
    private var footer: some View {
        if lifted && !mapped {
            Text("Margin is reading the project")
                .font(Archive.sans(13))
                .foregroundStyle(Archive.faint)
                .padding(.bottom, Self.footerLift)
                .transition(.opacity)
        } else if mapped, let change = maps.lastChange[project], Date().timeIntervalSince(change) < 8, tick >= 0 {
            Button("Undo") {
                maps.undo(project: project)
            }
            .buttonStyle(.plain)
            .font(Archive.sans(12))
            .foregroundStyle(Archive.ink)
            .pointingHand()
            .padding(.bottom, Self.footerLift)
            .transition(.opacity)
            .task(id: change) {
                try? await Task.sleep(nanoseconds: 8_200_000_000)
                tick += 1
            }
        } else if mapped && editing == nil && !selected.isEmpty {
            Text(selected.count == 1 ? "1 selected" : "\(selected.count) selected. Drag one to move them together.")
                .foregroundStyle(Archive.muted)
                .font(Archive.sans(12))
                .padding(.bottom, Self.footerLift)
                .transition(.opacity)
        }
    }

    // MARK: Writing on the map

    private func startRename(_ pattern: PlacedPattern) {
        draft = pattern.title
        editing = .name(tier: pattern.tier, key: pattern.key)
        DispatchQueue.main.async { fieldFocused = true }
    }

    private func startHeadline(at screen: CGPoint) {
        guard mapped, editing == nil else { finishEditing(); return }
        let point = CGPoint(x: (screen.x - pan.width) / zoom, y: (screen.y - pan.height) / zoom)
        draft = ""
        editing = .headline(at: point, tier: 1)
        DispatchQueue.main.async { fieldFocused = true }
    }

    private func startNote(_ entry: Entry) {
        draft = entry.rationale
        editing = .note(entry.id)
        DispatchQueue.main.async { fieldFocused = true }
    }

    private func finishEditing() {
        guard let current = editing else { return }
        let text = draft
        editing = nil
        fieldFocused = false
        switch current {
        case let .name(tier, key):
            maps.renameGroup(project: project, tier: tier, key: key, to: text)
        case let .headline(at, tier):
            maps.addGroup(project: project, title: text, at: MapPoint(x: Double(at.x), y: Double(at.y)), far: tier == 1, entries: entries)
        case let .note(id):
            store.modify(id) { $0.rationale = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
    }

    /// Deletes a headline. Its captures, if it has any, join the groups
    /// they fit best.
    private func removeGroup(_ pattern: PlacedPattern) {
        editing = nil
        fieldFocused = false
        maps.removeGroup(project: project, tier: pattern.tier, key: pattern.key)
    }

    private func cancelEditing() {
        editing = nil
        fieldFocused = false
    }

    // MARK: Sequence

    private var mapCovers: Bool {
        guard let map else { return false }
        let inMap = Set(map.patterns.flatMap(\.members))
        return entries.allSatisfy { inMap.contains($0.id.uuidString) }
    }

    private func enter() {
        openedAt = Date()
        frames = start.filter { id, _ in entries.contains { $0.id == id } }
        depth = mapDepth
        maps.ensure(project: project, entries: entries)
        DispatchQueue.main.async {
            // The grid comes up and the artifacts float a little off the timeline.
            withAnimation(.easeOut(duration: Self.liftTime)) {
                gridShown = true
                lifted = true
                for (id, frame) in frames {
                    let s = seed(id)
                    frames[id] = frame.offsetBy(dx: (s.x - 0.5) * 10, dy: (s.y - 0.5) * 10)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.floatTime) {
                guard active, !mapped else { return }
                arrivalPending = true
                tryArrive()
            }
        }
    }

    /// Onto the map: the one you've made if there is one (with any new
    /// captures settled in), or else Margin's first sorting.
    private func tryArrive() {
        guard arrivalPending, active else { return }
        if arrangement != nil {
            maps.makeNoteRoom(project: project)
            maps.adopt(project: project, entries: entries)
            sync(animated: false)
            arrive()
        } else if mapCovers, maps.titles[project] != nil {
            freshLayout()
        }
    }

    private func mapChanged() {
        guard active else { return }
        if !mapped {
            tryArrive()
        } else if arrangement == nil, mapCovers {
            freshLayout()
        } else {
            maps.adopt(project: project, entries: entries)
        }
    }

    private func arrangementChanged() {
        guard active else { return }
        if arrivalPending {
            tryArrive()
        } else if mapped {
            if arrangement == nil {
                // Re-sorting: Margin's sorting afresh.
                maps.ensure(project: project, entries: entries)
                if mapCovers { freshLayout() }
            } else {
                sync(animated: true)
            }
        }
    }

    private func arrive() {
        arrivalPending = false
        depth = min(max(mapDepth, 0), 3)
        let z = zoomAt(depth)
        let goal = framesAt(depth)
        withAnimation(Self.mapMotion) {
            mapped = true
            frames = goal
            zoom = z
            pan = depth >= 2.99 ? panCentring(on: mapCentre, zoom: z) : panCentring(on: largestTheme ?? mapCentre, zoom: z)
        }
        if arrangement?.touched == false { maps.requestNames(project: project) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            guard active else { return }
            withAnimation(.easeOut(duration: 0.6)) { labelsShown = true }
        }
    }

    /// Everything back to its place on the timeline, then hand back.
    private func leave() {
        finishEditing()
        pinchZoom = nil
        withAnimation(.spring(response: 0.6, dampingFraction: 0.9)) {
            for (id, frame) in start { frames[id] = frame }
            pan = .zero
            zoom = 1
            lifted = false
            gridShown = false
            mapped = false
            labelsShown = false
            highlighted = []
            selected = []
            marquee = nil
            hovered = nil
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { exited() }
    }

    // MARK: Layout

    /// Margin's first sorting, laid out in the background and kept as the
    /// map's starting point.
    private func freshLayout() {
        guard let map, active else { return }
        let titles = maps.titles[project] ?? [:]
        let here = Set(entries.map(\.id.uuidString))
        var sizes: [String: MapSize] = [:]
        for entry in entries {
            let s = maps.mapSize(for: entry)
            sizes[entry.id.uuidString] = MapSize(width: Double(s.width), height: Double(s.height))
        }
        var themeLabels: [String: MapSize] = [:], patternLabels: [String: MapSize] = [:]
        for tier in [1, 0] {
            for cluster in map.tiers[tier] {
                let s = PatternLabel.size(title: titles[cluster.key] ?? "", count: cluster.members.filter { here.contains($0) }.count)
                if tier == 1 { themeLabels[cluster.key] = s } else { patternLabels[cluster.key] = s }
            }
        }
        let input = TreeLayout.Input(map: map, sizes: sizes, themeLabels: themeLabels, patternLabels: patternLabels,
                                     window: MapSize(width: Double(size.width), height: Double(size.height)),
                                     closeSide: Double(Archive.Timeline.boxes[0].width), side: Double(ProjectMaps.side),
                                     noteHeight: ProjectMaps.noteHeight)
        layoutToken += 1
        let token = layoutToken
        Task {
            let result = await Task.detached(priority: .userInitiated) { TreeLayout.layout(input) }.value
            guard token == layoutToken, active, maps.arrangements[project] == nil else { return }
            maps.freeze(project: project, map: map, layout: result)
        }
    }

    /// Reads the arrangement into frames and names, and fits the window.
    private func sync(animated: Bool) {
        guard let a = arrangement else { return }
        let note = maps.noteRoom(a)
        var far: [UUID: CGRect] = [:], near: [UUID: CGRect] = [:]
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        for entry in entries {
            let key = entry.id.uuidString
            let s = maps.artifactSize(key)
            if let p = a.far[key] {
                far[entry.id] = CGRect(x: p.x - s.width / 2, y: p.y - s.height / 2, width: s.width, height: s.height)
                minX = min(minX, p.x - s.width / 2); maxX = max(maxX, p.x + s.width / 2)
                minY = min(minY, p.y - s.height / 2); maxY = max(maxY, p.y + s.height / 2)
            }
            if let p = a.near[key] {
                near[entry.id] = CGRect(x: p.x - s.width / 2, y: p.y - s.height / 2, width: s.width, height: s.height)
            }
        }
        var rooms: [String: CGSize] = [:]
        for theme in a.themes {
            let screen = PatternLabel.size(title: theme.title, count: maps.members(of: theme.key, tier: 1, in: a).count)
            rooms[theme.key] = CGSize(width: screen.width, height: screen.height)
        }
        themeRoom = rooms
        for theme in a.themes {
            let b = maps.labelBox(theme, tier: 1, in: a)
            minX = min(minX, b.x - b.width / 2); maxX = max(maxX, b.x + b.width / 2)
            minY = min(minY, b.y - b.height / 2); maxY = max(maxY, b.y + b.height / 2)
        }
        _ = note
        farFrames = far
        // One layout at every zoom: nothing rearranges as you zoom.
        nearFrames = far
        _ = near
        if minX.isFinite {
            mapCentre = CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
            let w = max(maxX - minX, 1), h = max(maxY - minY, 1)
            fitZoom = CGFloat(max(0.02, min(1.5, min((Double(size.width) - 96) / w, (Double(size.height) - 130) / h))))
        }
        // The close-up a little larger than the timeline's.
        let close = Archive.Timeline.boxes[0].width * 1.3 / ProjectMaps.side
        stepRatio = min(2.7, max(1.25, pow(close / fitZoom, 1.0 / 3.0)))
        laidOut = true

        guard mapped else { return }
        let goal = framesAt(depth)
        if animated {
            withAnimation(Self.stepMotion) {
                frames = goal
                if depth >= 2.99 {
                    zoom = zoomAt(depth)
                    pan = panCentring(on: mapCentre, zoom: zoom)
                }
            }
        } else {
            frames = goal
        }
    }

    /// One theme, as it draws in round its name.
    struct Gather {
        let label: CGPoint
        /// The name's room on screen.
        let room: CGSize
        let ids: [UUID]
        /// Each capture's box (with its note) as an offset from the name, at the big picture.
        let offsets: [CGPoint]
        let sizes: [CGSize]
        /// The most it can draw in before two of its captures would touch.
        let tightest: CGFloat
        /// The nearest capture's distance from the name.
        let inner: CGFloat
    }

    /// The names keep one size on screen, so the room kept round a name
    /// shrinks on the map as you zoom in. Each theme draws in toward its name
    /// evenly, as if the whole group were scaled about the name: nothing
    /// changes places or lines up, so it stays the shape you know. It draws
    /// in only part of the way, and never past the point where two captures,
    /// or a capture and the name, would touch.
    private func prepareGathers() {
        guard let a = arrangement else { gathers = []; return }
        let note = CGFloat(maps.noteRoom(a))
        let gap = CGFloat(ProjectMaps.mapGap)
        var result: [Gather] = []
        for theme in a.themes {
            guard let room = themeRoom[theme.key] else { continue }
            let label = CGPoint(x: theme.label.x, y: theme.label.y)
            var ids: [UUID] = [], offsets: [CGPoint] = [], sizes: [CGSize] = []
            for (id, rect) in farFrames where a.themeOf[id.uuidString] == theme.key {
                ids.append(id)
                offsets.append(CGPoint(x: rect.midX - label.x, y: rect.midY + note / 2 - label.y))
                sizes.append(CGSize(width: rect.width, height: rect.height + note))
            }
            guard !ids.isEmpty else { continue }
            // Scaled by s, two boxes stay apart while s * |dx| or s * |dy|
            // still clears their half sizes plus the gap.
            var tightest: CGFloat = 0
            for i in ids.indices {
                for j in (i + 1)..<ids.count {
                    let dx = abs(offsets[i].x - offsets[j].x), dy = abs(offsets[i].y - offsets[j].y)
                    let needX = dx > 0 ? ((sizes[i].width + sizes[j].width) / 2 + gap) / dx : .infinity
                    let needY = dy > 0 ? ((sizes[i].height + sizes[j].height) / 2 + gap) / dy : .infinity
                    tightest = max(tightest, min(needX, needY))
                }
            }
            let inner = offsets.map { hypot($0.x, $0.y) }.min() ?? 1
            result.append(Gather(label: label, room: room, ids: ids, offsets: offsets, sizes: sizes,
                                 tightest: min(tightest, 1), inner: max(inner, 1)))
        }
        gathers = result
        relaxed = [:]
    }

    /// The frames at any zoom: where the map put them. Zooming is only
    /// zooming, so nothing moves, jitters or re-sorts; the names grow a
    /// little as you zoom in (see `labelScale`), never past the room the map
    /// kept for them.
    private func framesAt(_ d: CGFloat) -> [UUID: CGRect] {
        guard laidOut else { return frames }
        var out = frames
        for (id, rect) in farFrames { out[id] = rect }
        return out
    }

    /// How large the names are drawn, against the big picture: they grow as
    /// you zoom in, but far less than the captures, so they keep to their
    /// place without ever crowding them.
    private var labelScale: CGFloat {
        min(max(pow(max(zoom, 0.01) / max(fitZoom, 0.01), 0.4), 1), 3)
    }

    /// Moves boxes the least it can, along the line between them, until
    /// none touches another or the name.
    static func easeApart(_ points: inout [CGPoint], sizes: [CGSize], label: CGPoint, name: CGSize, gap: CGFloat) {
        func push(_ dx: CGFloat, _ dy: CGFloat, _ ox: CGFloat, _ oy: CGFloat) -> CGPoint {
            let d = max(hypot(dx, dy), 0.01)
            let ux = dx / d, uy = dy / d
            let tx = abs(ux) > 0.001 ? ox / abs(ux) : .infinity
            let ty = abs(uy) > 0.001 ? oy / abs(uy) : .infinity
            let t = min(tx, ty)
            return CGPoint(x: ux * t, y: uy * t)
        }
        for _ in 0..<40 {
            var moved = false
            for k in points.indices {
                let dx = points[k].x - label.x, dy = points[k].y - label.y
                let ox = (sizes[k].width + name.width) / 2 + gap / 2 - abs(dx)
                let oy = (sizes[k].height + name.height) / 2 + gap / 2 - abs(dy)
                guard ox > 0, oy > 0 else { continue }
                let p = push(dx == 0 && dy == 0 ? 0.01 : dx, dy, ox, oy)
                points[k].x += p.x
                points[k].y += p.y
                moved = true
            }
            for i in points.indices {
                for j in (i + 1)..<points.count {
                    let dx = points[j].x - points[i].x, dy = points[j].y - points[i].y
                    let ox = (sizes[i].width + sizes[j].width) / 2 + gap - abs(dx)
                    let oy = (sizes[i].height + sizes[j].height) / 2 + gap - abs(dy)
                    guard ox > 0, oy > 0 else { continue }
                    let p = push(dx == 0 && dy == 0 ? 0.01 : dx, dy, ox, oy)
                    points[i].x -= p.x / 2
                    points[i].y -= p.y / 2
                    points[j].x += p.x / 2
                    points[j].y += p.y / 2
                    moved = true
                }
            }
            if !moved { break }
        }
    }

    private func zoomAt(_ depth: CGFloat) -> CGFloat {
        fitZoom * pow(stepRatio, 3 - depth)
    }

    private var screenCenter: CGPoint { CGPoint(x: size.width / 2, y: (size.height - 40) / 2) }

    /// The middle of the theme with the most captures, at the closer steps.
    private var largestTheme: CGPoint? {
        guard let a = arrangement else { return nil }
        var counts: [String: Int] = [:]
        for key in a.themeOf.values { counts[key, default: 0] += 1 }
        guard let theme = counts.max(by: { $0.value < $1.value })?.key else { return nil }
        let points = a.themeOf.filter { $0.value == theme }.compactMap { UUID(uuidString: $0.key) }.compactMap { nearFrames[$0] }
        guard !points.isEmpty else { return nil }
        let x = points.reduce(0) { $0 + $1.midX } / CGFloat(points.count)
        let y = points.reduce(0) { $0 + $1.midY } / CGFloat(points.count)
        return CGPoint(x: x, y: y)
    }

    private func panCentring(on point: CGPoint, zoom z: CGFloat) -> CGSize {
        CGSize(width: screenCenter.x - point.x * z, height: screenCenter.y - point.y * z)
    }

    /// What the view should stay on when it steps: what's in the middle of
    /// the window, or the capture nearest to it when the middle is empty.
    private var focusPoint: CGPoint {
        let c = screenCenter
        let middle = CGPoint(x: (c.x - pan.width) / zoom, y: (c.y - pan.height) / zoom)
        var best: CGPoint?
        var bestDistance = CGFloat.infinity
        for frame in frames.values {
            let d = hypot(frame.midX - middle.x, frame.midY - middle.y)
            if d < bestDistance { bestDistance = d; best = CGPoint(x: frame.midX, y: frame.midY) }
        }
        guard let best, bestDistance * zoom > 140 else { return middle }
        return best
    }

    // MARK: The slider and pinching

    /// The slider moved: zoom there, anywhere along it. Closer in, the view
    /// stays on what you're looking at; nearing the big picture it eases
    /// toward the whole map, which the big picture shows.
    private func slid(to value: CGFloat) {
        Self.note(String(format: "Themes slider: asks for depth %.2f (map %@, %@, depth %.2f)",
                         value, mapped ? "ready" : "not ready", pinching ? "pinching" : "not pinching", depth))
        // Still arriving: `arrive()` reads the slider's latest value itself.
        guard mapped else { depth = min(max(value, 0), 3); return }
        guard !pinching, abs(depth - value) > 0.0005 else { return }
        let target = min(max(value, 0), 3)
        let focus = focusPoint
        let z = zoomAt(target)
        let t = min(max(target - 2, 0), 1)
        let ease = t * t * (3 - 2 * t)
        let centre = CGPoint(x: focus.x + (mapCentre.x - focus.x) * ease, y: focus.y + (mapCentre.y - focus.y) * ease)
        depth = target
        zoom = z
        pan = panCentring(on: centre, zoom: z)
        frames = framesAt(target)
    }

    private func pinch(by magnification: CGFloat, at point: CGPoint) {
        if !pinching {
            MarginLog.info("Themes pinch: \(mapped ? "map ready" : "map not ready yet"), depth \(String(format: "%.2f", depth)), zoom \(String(format: "%.3f", zoom))")
        }
        pinching = true
        // Not on the map yet (still arriving): the slider follows anyway,
        // and the map arrives at that depth.
        guard mapped, zoom > 0.0001 else {
            let next = min(max(depth - magnification * 2.4, 0), 3)
            depth = next
            mapDepth = next
            return
        }
        // A little past either end gives, then settles back.
        let next = min(max(depth - magnification * 2.4, -0.3), 3.3)
        let old = zoom
        let z = zoomAt(next)
        pan.width = point.x - (point.x - pan.width) * z / old
        pan.height = point.y - (point.y - pan.height) * z / old
        zoom = z
        depth = next
        frames = framesAt(next)
        mapDepth = min(max(next, 0), 3)
    }

    /// Let go: it stays where you stopped, unless past either end.
    private func endPinch(at point: CGPoint) {
        guard pinching else { return }
        pinching = false
        guard mapped else { return }
        let target = min(max(depth, 0), 3)
        guard target != depth else { return }
        let old = zoom
        let z = zoomAt(target)
        withAnimation(Self.stepMotion) {
            if target >= 3 {
                pan = panCentring(on: mapCentre, zoom: z)
            } else {
                pan.width = point.x - (point.x - pan.width) * z / old
                pan.height = point.y - (point.y - pan.height) * z / old
            }
            zoom = z
            depth = target
            frames = framesAt(target)
        }
        mapDepth = target
    }

    /// Clicking a theme's name zooms in on it, close enough to see its captures.
    private func zoomInto(_ pattern: PlacedPattern) {
        let target = min(depth, 1.4)
        let z = zoomAt(target)
        var centre = pattern.center
        if let a = arrangement {
            let points = a.themeOf.filter { $0.value == pattern.key }.compactMap { UUID(uuidString: $0.key) }.compactMap { farFrames[$0] }
            if !points.isEmpty {
                centre = CGPoint(x: points.reduce(0) { $0 + $1.midX } / CGFloat(points.count),
                                 y: points.reduce(0) { $0 + $1.midY } / CGFloat(points.count))
            }
        }
        withAnimation(Self.stepMotion) {
            zoom = z
            depth = target
            pan = panCentring(on: centre, zoom: z)
            frames = framesAt(target)
        }
        mapDepth = target
    }

    /// Stable 0...1 values per artifact, for its float.
    private func seed(_ id: UUID) -> (x: CGFloat, y: CGFloat, t: Double) {
        var hasher = id.uuid
        let bytes = withUnsafeBytes(of: &hasher) { Array($0) }
        return (CGFloat(bytes[0]) / 255, CGFloat(bytes[1]) / 255, Double(bytes[2]) / 255)
    }
}

// MARK: - Pieces

/// The name of a group, on the bare map: themes and patterns alike, in the
/// archive's header face, one size on screen, two lines at most, with the
/// count under it. When Margin has a suggestion for it, a quiet line under
/// that: how many might fit (hover to see them), Add, Dismiss.
struct PatternLabel: View {
    let title: String
    let count: Int
    /// Drawn this much larger than at the big picture (set in type, so it stays sharp).
    var scale: CGFloat = 1
    var suggested: [Entry] = []
    var take: () -> Void = {}
    var takeOne: (UUID) -> Void = { _ in }
    var skip: () -> Void = {}
    var look: (Bool) -> Void = { _ in }
    @State private var previewing = false

    static let titleSize = Theme.Typography.heading
    static let countSize = Theme.Typography.label
    /// Names longer than this wrap onto a second line.
    static let wrapWidth: CGFloat = 200
    /// Room kept clear round a name, on screen.
    static let margin: CGFloat = 6

    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(Archive.headline(Self.titleSize * scale))
                .foregroundStyle(Archive.ink)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(width: Self.textWidth(title) * scale)
            Text("\(count) artifacts")
                .font(Archive.mono(Self.countSize * scale))
                .foregroundStyle(Archive.muted)
            if !suggested.isEmpty {
                VStack(spacing: 8) {
                    HStack(spacing: 10) {
                        Text("\(suggested.count) might fit")
                            .foregroundStyle(previewing ? Archive.ink : Archive.muted)
                        Button("Add", action: take)
                            .buttonStyle(.plain)
                            .foregroundStyle(Archive.ink)
                            .pointingHand()
                        Button("Dismiss", action: skip)
                            .buttonStyle(.plain)
                            .foregroundStyle(Archive.faint)
                            .pointingHand()
                    }
                    .font(Archive.font(Self.countSize))
                    if previewing {
                        SuggestionPreview(entries: suggested, take: takeOne)
                            .transition(.opacity.combined(with: .offset(y: -4)))
                    }
                }
                .padding(.top, 2)
                // Hovering the line (or the preview) shows them here, and
                // lights them where they are on the map.
                .onHover { inside in
                    withAnimation(Brand.quick) { previewing = inside }
                    look(inside)
                }
            }
        }
        .fixedSize()
        .contentShape(Rectangle())
        .pointingHand()
    }

    /// How wide the name is set: its own width, wrapping past `wrapWidth`.
    static func textWidth(_ title: String) -> CGFloat {
        let one = (title as NSString).size(withAttributes: [.font: Archive.nsHeadline(titleSize)])
        return min(ceil(one.width) + 2, wrapWidth)
    }

    /// The room a name takes on screen, with the margin round it the
    /// captures keep clear of.
    static func size(title: String, count: Int) -> MapSize {
        let font = Archive.nsHeadline(titleSize)
        let text = title as NSString
        let bounds = text.boundingRect(with: NSSize(width: textWidth(title), height: 1000),
                                       options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
        let line = ("\(count) artifacts" as NSString).size(withAttributes: [.font: Archive.nsMono(countSize)])
        let lines = min(ceil(bounds.height / max(Archive.headlineLineHeight(titleSize), 1)), 2)
        let width = max(textWidth(title), line.width)
        let height = lines * Archive.headlineLineHeight(titleSize) + 4 + line.height
        return MapSize(width: Double(width + margin * 2), height: Double(height + margin * 2))
    }
}

/// One artifact on the map: the picture (or its words), raised a little
/// and floating gently.
private struct CanvasArtifact: View {
    @EnvironmentObject private var store: EntryStore
    @Environment(\.colorScheme) private var scheme
    let entry: Entry
    let size: CGSize
    let lifted: Bool
    let held: Bool
    let seed: (x: CGFloat, y: CGFloat, t: Double)
    /// Large on screen: the full picture instead of the thumbnail.
    var sharp = false
    var zoom: CGFloat = 1
    var selected = false
    /// The slow float. Off on a big map: every card's endless animation is
    /// worked out each frame, and a hundred of them made the map stutter.
    var floats = true
    @State private var bob = false
    @State private var full: NSImage?

    var body: some View {
        picture
            // Selected: a hairline ring a little outside the frame, the same on screen at any zoom.
            .overlay(
                Rectangle()
                    .strokeBorder(Archive.ink, lineWidth: 1.5 / max(zoom, 0.05))
                    .padding(-5 / max(zoom, 0.05))
                    .opacity(selected ? 1 : 0)
                    .animation(Brand.quick, value: selected)
            )
            // A slow float, each at its own pace, while it's on the map.
            .offset(y: floats && lifted && !held ? (bob ? -2 : 2) : 0)
            .scaleEffect(held ? 1.04 : 1, anchor: .center)
            .animation(Brand.quick, value: held)
            .onAppear {
                guard floats else { return }
                withAnimation(.easeInOut(duration: 2.4 + seed.t * 1.4).repeatForever(autoreverses: true).delay(seed.t)) {
                    bob = true
                }
            }
            .help(entry.displayTitle)
            .task(id: sharp) {
                guard sharp, full == nil, let file = entry.imageFile else { return }
                if entry.kind == .text, let rich = store.mediaURL(for: entry) {
                    // A text capture's picture is drawn from its words: draw it again, finer.
                    full = SharpImages.shared.text(file: file, rich: rich, dark: scheme == .dark)
                }
                if full == nil {
                    full = await SharpImages.shared.image(file: file, url: store.imageURL(forFile: file))
                }
            }
    }

    private var picture: some View {
        ZStack {
            if sharp, let full {
                Image(nsImage: full)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFill()
            } else if let file = entry.imageFile {
                // Off the main thread, so arriving on the map never waits.
                AsyncThumbnail(store: store, file: file) { Archive.paper }
            } else if sharp, zoom > 1.05 {
                // Words drawn at the size they're seen, so they stay crisp.
                WordsThumb(entry: entry, size: CGSize(width: size.width * zoom, height: size.height * zoom))
                    .scaleEffect(1 / zoom, anchor: .topLeading)
                    .frame(width: size.width, height: size.height, alignment: .topLeading)
            } else {
                WordsThumb(entry: entry, size: size)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .overlay(Rectangle().stroke(Archive.frame, lineWidth: 1).padding(-0.5))
        .background(
            Rectangle()
                .fill(Archive.paper)
                .shadow(color: .black.opacity(scheme == .dark ? 0.45 : (held ? 0.18 : lifted ? 0.1 : 0.06)),
                        radius: held ? 16 : lifted ? 10 : 6, y: held ? 8 : lifted ? 4 : 2)
        )
    }
}

/// A soft dotted grid that moves and scales with the map. Its spacing on
/// screen stays between one and two grid steps: as you zoom out, every
/// other dot fades away instead of the grid jumping.
private struct DotGrid: View {
    let pan: CGSize
    let zoom: CGFloat

    static let spacing: CGFloat = 24

    var body: some View {
        Canvas { context, size in
            var step = Self.spacing * zoom
            while step < Self.spacing { step *= 2 }
            while step >= Self.spacing * 2 { step /= 2 }
            // 0 just after a halving, 1 just before the next.
            let t = log2(step / Self.spacing)
            let color = Archive.faint.opacity(0.6)
            /// Every dot of a grid `spacing` apart, or with `between` only
            /// those halfway between the dots of the grid twice as wide.
            func dots(every spacing: CGFloat, between: Bool, alpha: Double) {
                guard alpha > 0.01 else { return }
                let r: CGFloat = 0.8
                let i0 = Int(((-spacing - pan.width) / spacing).rounded(.up))
                let j0 = Int(((-spacing - pan.height) / spacing).rounded(.up))
                var path = Path()
                var j = j0
                while pan.height + CGFloat(j) * spacing < size.height + spacing {
                    var i = i0
                    while pan.width + CGFloat(i) * spacing < size.width + spacing {
                        if !between || i % 2 != 0 || j % 2 != 0 {
                            let x = pan.width + CGFloat(i) * spacing, y = pan.height + CGFloat(j) * spacing
                            path.addEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
                        }
                        i += 1
                    }
                    j += 1
                }
                context.fill(path, with: .color(color.opacity(alpha)))
            }
            dots(every: step, between: false, alpha: 1)
            // The finer grid of the next step in, fading in as the dots spread.
            dots(every: step / 2, between: true, alpha: Double(t))
        }
    }
}

/// Two-finger scrolling moves around the map; pinching steps it in and out.
private struct CanvasEvents: NSViewRepresentable {
    let enabled: Bool
    let pan: (CGFloat, CGFloat) -> Void
    let pinch: (CGFloat, CGPoint) -> Void
    let pinchEnded: (CGPoint) -> Void

    func makeNSView(context: Context) -> EventView { EventView() }

    func updateNSView(_ view: EventView, context: Context) {
        view.enabled = enabled
        view.onPan = pan
        view.onPinch = pinch
        view.onPinchEnded = pinchEnded
    }

    final class EventView: NSView {
        var enabled = true
        var onPan: ((CGFloat, CGFloat) -> Void)?
        var onPinch: ((CGFloat, CGPoint) -> Void)?
        var onPinchEnded: ((CGPoint) -> Void)?
        private var monitor: Any?

        override var isFlipped: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
                guard let self, self.enabled, event.window === self.window else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(point) else { return event }
                switch event.type {
                case .scrollWheel:
                    let k: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
                    self.onPan?(event.scrollingDeltaX * k, event.scrollingDeltaY * k)
                case .magnify:
                    if event.phase == .ended || event.phase == .cancelled {
                        self.onPinchEnded?(point)
                    } else {
                        self.onPinch?(event.magnification, point)
                    }
                default:
                    return event
                }
                return nil
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}

/// What Margin suggests for a group, shown under its name while you look:
/// the captures themselves, large enough to judge. Click one to add it.
private struct SuggestionPreview: View {
    @EnvironmentObject private var store: EntryStore
    @Environment(\.colorScheme) private var scheme
    let entries: [Entry]
    let take: (UUID) -> Void

    static let height: CGFloat = 96
    static let perRow = 4
    static let most = 8

    var body: some View {
        let ink = MenuInk(scheme)
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        // At most four side by side; more wrap onto a second row.
        let shown = Array(entries.prefix(Self.most))
        let rows = stride(from: 0, to: shown.count, by: Self.perRow).map { Array(shown[$0..<min($0 + Self.perRow, shown.count)]) }
        VStack(spacing: 10) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(spacing: 10) {
                    ForEach(rows[r]) { entry in
                        Button { take(entry.id) } label: {
                            thumb(entry)
                        }
                        .buttonStyle(.plain)
                        .pointingHand()
                        .help("Add \(entry.displayTitle)")
                    }
                }
            }
        }
        .padding(10)
        .background(
            shape.fill(ink.surface)
                .shadow(color: .black.opacity(scheme == .dark ? 0.45 : 0.08), radius: 1.5, y: 1)
                .shadow(color: .black.opacity(scheme == .dark ? 0.4 : 0.12), radius: 14, y: 6)
        )
        .overlay(shape.strokeBorder(ink.hairline, lineWidth: 1))
    }

    @ViewBuilder
    private func thumb(_ entry: Entry) -> some View {
        let aspect = store.aspectRatio(for: entry) ?? 1.4
        let width = min(max(Self.height * aspect, 56), 170)
        ZStack {
            if let file = entry.imageFile {
                AsyncThumbnail(store: store, file: file, interpolation: .high) { Archive.paper }
            } else {
                WordsThumb(entry: entry, size: CGSize(width: width, height: Self.height))
            }
        }
        .frame(width: width, height: Self.height)
        .clipped()
        .overlay(Rectangle().stroke(Archive.frame, lineWidth: 1).padding(-0.5))
    }
}

/// Full pictures for captures large on screen, read at a size the screen
/// can use and kept a while.
@MainActor
final class SharpImages {
    static let shared = SharpImages()
    private let cache = NSCache<NSString, NSImage>()

    init() { cache.countLimit = 60 }

    func image(file: String, url: URL) async -> NSImage? {
        if let cached = cache.object(forKey: file as NSString) { return cached }
        let image = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 1800,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }.value
        if let image { cache.setObject(image, forKey: file as NSString) }
        return image
    }

    /// A text capture's card, drawn again from its words at five times the
    /// size, so it reads crisply up close. Same look as its thumbnail.
    func text(file: String, rich: URL, dark: Bool) -> NSImage? {
        let key = "text-\(dark)-\(file)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let words = RichText.load(contentsOf: rich),
              let png = RichText.preview(words, scale: 5, dark: dark),
              let image = NSImage(data: png) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}

/// The tick beside a name you're writing: confirms it, as Return does. A
/// header tool's size and look.
private struct ConfirmButton: View {
    var symbol = "checkmark"
    var help = "Done (Return)"
    let action: () -> Void
    @State private var hovering = false

    static let size: CGFloat = 24

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(hovering ? 0.85 : 0.6))
                .frame(width: Self.size, height: Self.size)
                .background(
                    RoundedRectangle(cornerRadius: RepoHeader.toolRadius, style: .continuous)
                        .fill(Color.primary.opacity(hovering ? 0.055 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHand()
        .onHover { inside in withAnimation(Brand.quick) { hovering = inside } }
        .help(help)
    }
}
