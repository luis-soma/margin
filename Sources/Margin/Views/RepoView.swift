import AppKit
import MarginKit
import SwiftUI

/// A stretch of work: moments close enough in time to belong together.
struct Session: Identifiable {
    let entries: [Entry] // oldest first
    var id: UUID { entries[0].id }
    var start: Date { entries[0].createdAt }
    var end: Date { entries[entries.count - 1].createdAt }

    /// The designer's own words if there are any, otherwise the file they worked in.
    var title: String {
        if let words = entries.first(where: \.hasWords) {
            let line = words.rationale.trimmed.isEmpty ? words.displayTitle : words.rationale.trimmed
            return line.split(separator: "\n").first.map(String.init) ?? line
        }
        let windows = entries.compactMap(\.windowTitle).filter { !$0.trimmed.isEmpty }
        if let common = Dictionary(grouping: windows, by: { $0 }).max(by: { $0.value.count < $1.value.count })?.key {
            return common
        }
        return entries.compactMap(\.sourceApp).first.map { "\($0) session" } ?? "Session"
    }

    /// Splits entries wherever the gap between two moments is longer than `gap`.
    static func group(_ entries: [Entry], gap: TimeInterval) -> [Session] {
        var sessions: [Session] = []
        var current: [Entry] = []
        for entry in entries {
            if let last = current.last, entry.createdAt.timeIntervalSince(last.createdAt) > gap {
                sessions.append(Session(entries: current))
                current = []
            }
            current.append(entry)
        }
        if !current.isEmpty { sessions.append(Session(entries: current)) }
        return sessions
    }
}

/// The repo: your work on one continuous timeline, newest first. The slider
/// and a pinch zoom it from a single day out to whole years.
struct RepoView: View {
    @EnvironmentObject private var store: EntryStore
    @EnvironmentObject private var intelligence: Intelligence
    /// The time scale: 0 a day (with titles and descriptions), 1 the days of
    /// a week, 2 weeks, 3 months. A new key: the earlier ones counted other
    /// scales.
    @AppStorage("repoTimeScale7") private var step = 0
    /// The timeline's zoom while you pinch it (0 day … 3 months), so the
    /// slider's handle follows your fingers; nil when not pinching.
    @State private var pinchZoom: CGFloat?
    /// Tags and tabs the repo is narrowed to (all must match); empty shows everything.
    @State private var filters: [String] = []
    /// Words typed into the search field; they narrow the repo as you type.
    @State private var query = ""
    /// The search field is open (it grows out of the magnifier).
    @State private var searching = false
    /// The tag menu under the search field.
    @State private var menuOpen = false
    /// The search field's frame in the window, for its menu.
    @State private var searchFrame: CGRect = .zero
    /// The moment open in focus over the repo.
    @State private var focused: UUID?
    /// The cluster view: the artifacts on a canvas for sensemaking.
    @State private var clustering = false
    /// Where the map's zoom is, anywhere from close-up (0) to big picture (3).
    @State private var mapDepth: CGFloat = 0

    /// Gaps that split sessions (used by summaries and the demo data).
    static let gaps: [TimeInterval] = [5 * 60, 20 * 60, 90 * 60, 6 * 3600, 36 * 3600]

    /// On the home view (all projects) rather than inside one.
    @AppStorage("repoAtHome") private var atHome = false

    /// The handover screen, one step past the project.
    @State private var handingOver = false
    /// The options menu under "…" is open.
    @State private var optionsOpen = false
    /// Settings, one step past home.
    @State private var settingsOpen = false
    /// Automatic capture on in Settings: its captures show between yours.
    /// Off: they stay out of the archive. (AutoCapture's own setting.)
    @AppStorage("autoCaptureEnabled") private var showAuto = true
    /// Which way the last step went: deeper (content moves left) or back.
    @State private var forward = true

    /// The floating sidebar is out (⌘\ hides it).
    @AppStorage("sidebarShown") private var sidebarShown = true
    /// While the sidebar comes or goes: the archive, already at its new
    /// width, eases in from a little to the side, fading up. (No blur here:
    /// a blur over the whole timeline would cost every scroll after.)
    @State private var reflowOffset: CGFloat = 0
    @State private var reflowFade: Double = 1
    /// Files from Finder are over the project.
    @State private var dropping = false
    /// "Added 3 files", shortly after a drop.
    @State private var dropNote: String?

    private var inProject: Bool { !atHome }

    /// One header for every screen, so what stays stays put: "Projects" never
    /// moves, the project name and "Hand off" fade in beside it, and the
    /// project's controls fade in on the right. Only the content below slides.
    var body: some View {
        ZStack(alignment: .topLeading) {
        VStack(spacing: 0) {
            header
                // The focus view covers the header; its presses aren't the slider's.
                .environment(\.dragSurfacesEnabled, focused == nil)
                .zIndex(1)
            ZStack(alignment: .topLeading) {
                if atHome && settingsOpen {
                    SettingsView(embedded: true)
                        .transition(push)
                } else if atHome {
                    HomeView(open: openProject, settings: openSettings)
                        .transition(push)
                } else {
                    // The project. The hand-off opens beside it as its own
                    // narrow window, and this window makes room for it.
                    projectView
                        .transition(push)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        // The archive makes room for the sidebar while it's out. It takes
        // its new width at once (rows re-flowing on every frame of a slide
        // jump about) and eases in from where it was instead.
        .padding(.leading, sidebarShown ? ProjectSidebar.room : 0)
        .animation(nil, value: sidebarShown)
        .offset(x: reflowOffset)
        .opacity(reflowFade)
        // Always there, so it can slide: out past the window's left edge
        // when hidden, its rows coming back in one after another.
        ProjectSidebar(
            current: store.currentProject,
            onHome: atHome && !settingsOpen,
            onSettings: atHome && settingsOpen,
            shown: sidebarShown,
            open: openProject,
            home: goHome,
            settings: openSettingsAnywhere,
            collapse: toggleSidebar
        )
        // Opening, the card unfolds from the edge (inside ProjectSidebar),
        // drifting in and coming into focus; closing, it folds back, drifts
        // out and softens away. The rows follow it in, one after another.
        .offset(x: sidebarShown ? 0 : -Theme.Space.x4)
        .blur(radius: sidebarShown ? 0 : 8)
        .opacity(sidebarShown ? 1 : 0)
        .allowsHitTesting(sidebarShown)
        .accessibilityHidden(!sidebarShown)
        .zIndex(2)
        }
        .frame(minWidth: 600, minHeight: 380)
        .background(Brand.background)
        .ignoresSafeArea()
        .coordinateSpace(name: "repo")
        // The hand-off window closed itself (Esc, its own close): untick the icon.
        .onReceive(NotificationCenter.default.publisher(for: AppModel.handoffClosed)) { _ in handingOver = false }
        // The welcome tour opens a project to show the archive.
        // The welcome tour shows the map, and glides its zoom, slider and all.
        .onReceive(NotificationCenter.default.publisher(for: OnboardingTour.showMap)) { note in
            let on = (note.object as? Bool) ?? false
            if clustering != on { clustering = on }
        }
        .onReceive(NotificationCenter.default.publisher(for: OnboardingTour.handoff)) { note in
            let open = (note.object as? Bool) ?? false
            if open, !handingOver { toggleHandover() } else if !open { closeHandover() }
        }
        .onReceive(NotificationCenter.default.publisher(for: OnboardingTour.mapZoom)) { note in
            guard clustering, let target = note.object as? Double else { return }
            let from = mapDepth, to = CGFloat(target), started = Date(), duration = 1.4
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { timer in
                MainActor.assumeIsolated {
                    let t = min(1, Date().timeIntervalSince(started) / duration)
                    let eased = CGFloat(t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2)
                    mapDepth = from + (to - from) * eased
                    if t >= 1 { timer.invalidate() }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
        }
        .onReceive(NotificationCenter.default.publisher(for: OnboardingTour.showProject)) { note in
            guard let name = note.object as? String else { return }
            if !atHome && store.currentProject == name { return }
            openProject(name)
        }
        .overlay(alignment: .topTrailing) {
            if optionsOpen && inProject {
                ZStack(alignment: .topTrailing) {
                    // A click anywhere else closes it.
                    Color.black.opacity(0.0001)
                        .onTapGesture { withAnimation(Theme.Motion.exit) { optionsOpen = false } }
                    CaptureOptionsMenu()
                        .padding(.top, RepoHeader.height - 4)
                        .padding(.trailing, RepoHeader.inset + RepoHeader.toolWidth + Theme.Space.x1)
                        // Out of the tool it belongs to, and back into it.
                        .transition(.pop(from: .topTrailing))
                }
                .ignoresSafeArea()
            }
        }
        .overlay {
            if let focused, inProject {
                FocusView(
                    entryID: focused,
                    order: visibleEntries.reversed().map(\.id),
                    close: { withAnimation(Brand.motion) { self.focused = nil } }
                )
                .id(focused)
                .transition(.opacity)
                .ignoresSafeArea()
            }
        }
    }

    // MARK: Moving between screens

    /// Home, project, handover sit side by side: going deeper slides the new
    /// screen in from the right, going back slides it in from the left.
    private var push: AnyTransition {
        let distance: CGFloat = 90
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(x: forward ? distance : -distance)),
            removal: .opacity.combined(with: .offset(x: forward ? -distance : distance))
        )
    }

    private static let slide = Animation.spring(response: 0.48, dampingFraction: 0.9)

    /// Sets the direction first (so the leaving screen knows which way to
    /// go), then makes the step.
    private func step(forward deeper: Bool, _ change: @escaping () -> Void) {
        forward = deeper
        DispatchQueue.main.async {
            withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? Brand.quick : Self.slide) { change() }
        }
    }

    private func openProject(_ name: String) {
        step(forward: true) {
            store.currentProject = name
            atHome = false
        }
    }

    private func goHome() {
        step(forward: false) {
            atHome = true
            if handingOver { AppModel.shared.closeHandoffWindow() }
            handingOver = false
            optionsOpen = false
            settingsOpen = false
        }
    }

    private func openSettings() {
        step(forward: true) { settingsOpen = true }
    }

    /// Settings from the sidebar, from wherever you are.
    private func openSettingsAnywhere() {
        guard !(atHome && settingsOpen) else { return }
        step(forward: true) {
            if handingOver { AppModel.shared.closeHandoffWindow() }
            handingOver = false
            optionsOpen = false
            atHome = true
            settingsOpen = true
        }
    }

    private func toggleSidebar() {
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let opening = !sidebarShown
        if reduce {
            withAnimation(Theme.Motion.hover) { sidebarShown.toggle() }
            return
        }
        // The archive jumps to its new width, starting from where its
        // content was and a touch soft...
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            reflowOffset = opening ? -ProjectSidebar.room * 0.25 : ProjectSidebar.room * 0.25
            reflowFade = 0.55
        }
        withAnimation(opening ? Theme.Motion.sidebarIn : Theme.Motion.sidebarOut) { sidebarShown.toggle() }
        // ...then settles into place as the sidebar moves.
        DispatchQueue.main.async {
            withAnimation(opening ? Theme.Motion.sidebarIn : Theme.Motion.sidebarOut) {
                reflowOffset = 0
                reflowFade = 1
            }
        }
    }

    /// The hand-off side panel's width.
    static let handoffWidth: CGFloat = 380

    private func toggleHandover() {
        focused = nil
        menuOpen = false
        optionsOpen = false
        handingOver.toggle()
        if handingOver {
            AppModel.shared.openHandoffWindow(project: store.currentProject)
        } else {
            AppModel.shared.closeHandoffWindow()
        }
    }

    private func closeHandover() {
        guard handingOver else { return }
        handingOver = false
        AppModel.shared.closeHandoffWindow()
    }

    private var projectView: some View {
        Group {
            if visibleEntries.isEmpty {
                if isFiltering { noMatches } else { empty }
            } else {
                TimeZoomView(entries: visibleEntries, level: $step, pinchZoom: $pinchZoom, interactive: focused == nil && !menuOpen,
                             clustering: clustering, mapDepth: $mapDepth)
                    // Into the map at the timeline's scale; while there, the
                    // timeline keeps to the nearest scale, so going back is seamless.
                    .onChange(of: clustering) { on in if on { mapDepth = CGFloat(step) } }
                    .onChange(of: mapDepth) { value in
                        let nearest = Int(min(max(value, 0), 3).rounded())
                        if clustering, nearest != step { step = nearest }
                    }
                    .tourAnchor("timeline")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Brand.background)
        .environment(\.focusMoment) { entry in
            withAnimation(Brand.motion) { focused = entry.id }
        }
        // Describe the project's look ahead of time, so the handoff has
        // TASTE.md ready (at most once a day, only when there's something new).
        .task(id: store.currentProject) {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled else { return }
            let project = store.currentProject
            await TasteWriter.writeIfNeeded(project: project, entries: store.chronological(in: project), store: store,
                                            config: intelligence.config, folder: HandoverExporter.folder(for: project))
        }
        // Files from Finder: each lands in this project at the time it was made.
        .onDrop(of: [.fileURL], isTargeted: $dropping.animation(Brand.quick)) { providers in
            receive(providers)
            return true
        }
        .overlay { if dropping { dropTarget.transition(.opacity) } }
        // Timeline or Themes: floating at the bottom centre, over the work.
        .overlay(alignment: .bottom) {
            if !visibleEntries.isEmpty {
                ModeSwitch(clustering: $clustering)
                    .tourAnchor("modeSwitch")
                    .padding(.bottom, Theme.Space.x4)
            }
        }
        .overlay(alignment: .bottom) {
            if let dropNote {
                FloatingNote(text: dropNote)
                    .padding(.bottom, 22)
                    .transition(.opacity.combined(with: .offset(y: 8)).combined(with: .scale(scale: 0.96, anchor: .bottom)))
            }
        }
    }

    /// A hairline frame inside the window while files hover over it.
    private var dropTarget: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.03)))
            .overlay {
                Text("Add to \(store.currentProject)")
                    .font(Theme.Typography.ui(13, .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .allowsHitTesting(false)
    }

    private func receive(_ providers: [NSItemProvider]) {
        let project = store.currentProject
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers where provider.canLoadObject(ofClass: URL.self) {
                if let url = await withCheckedContinuation({ (done: CheckedContinuation<URL?, Never>) in
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in done.resume(returning: url) }
                }), url.isFileURL {
                    urls.append(url)
                }
            }
            guard !urls.isEmpty else { return }
            let added = await FileImport.importFiles(urls, into: store, project: project)
            let note: String
            switch added.count {
            case 0: note = "Already in \(project)"
            case 1: note = "Added 1 file to \(project)"
            default: note = "Added \(added.count) files to \(project)"
            }
            withAnimation(Brand.motion) { dropNote = note }
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            if dropNote == note { withAnimation(Brand.motion) { dropNote = nil } }
        }
    }

    // MARK: Pieces

    /// The bar over the archive: the slider, centred on the same line as
    /// the Timeline / Themes switch at the bottom, and on the right search,
    /// documenting and hand off. Where you are lives in the sidebar.
    private var header: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let leading = sidebarShown ? Theme.Space.x4 : RepoHeader.titleX - 4 + RepoHeader.toolWidth + Theme.Space.x2
            let tools = 3 * RepoHeader.toolWidth + 2 * Theme.Space.x1
                + (searching ? RepoHeader.searchOpen - RepoHeader.searchClosed : 0)
            // Centred in the archive, unless the tools (search open) need the room.
            let right = width - RepoHeader.inset - tools - Theme.Space.x6
            let slider = min(RepoHeader.sliderWidth, max(160, right - leading - Theme.Space.x6))
            let shift = min(0, right - (width + slider) / 2)
            ZStack {
                if inProject {
                    GranularitySlider(step: $step, steps: TimeScale.allCases.count, live: clustering ? mapDepth : pinchZoom,
                                      continuous: clustering, onValue: { mapDepth = $0 })
                        .tourAnchor("slider")
                        .frame(width: slider)
                        .offset(x: shift)
                        .transition(.opacity)
                }
                HStack(spacing: 0) {
                    if !sidebarShown {
                        SidebarToggle(action: toggleSidebar)
                            .transition(.opacity)
                    }
                    Spacer(minLength: 0)
                    if inProject {
                        HStack(spacing: Theme.Space.x1) {
                            RepoSearch(
                                query: $query,
                                filters: $filters,
                                open: $searching,
                                menuOpen: $menuOpen,
                                submit: submitQuery
                            )
                            // Where the field is, so its menu drops right under it.
                            .background(GeometryReader { geo in
                                Color.clear
                                    .onAppear { searchFrame = geo.frame(in: .named("repo")) }
                                    .onChange(of: geo.frame(in: .named("repo"))) { searchFrame = $0 }
                            })
                            .tourAnchor("search")
                            // How Margin helps you document; its menu opens under it.
                            HeaderTool(help: "Documenting", detail: "Reminder or automatic", active: optionsOpen, action: {
                                withAnimation(optionsOpen ? Theme.Motion.exit : Theme.Motion.enter) { optionsOpen.toggle() }
                                menuOpen = false
                            }) {
                                SettingsGlyph().frame(width: 16, height: 16)
                            }
                            // Hand the project off: to your agent, a review, a case study.
                            HeaderTool(help: "Hand off", detail: "For your agent, a review or a case study", active: handingOver, action: toggleHandover) {
                                HandoffMarkGlyph().frame(width: 16, height: 16)
                            }
                            .tourAnchor("handoff")
                        }
                        .transition(.opacity)
                    }
                }
                // Clear of the traffic lights when the sidebar isn't holding them.
                .padding(.leading, sidebarShown ? Theme.Space.x4 : RepoHeader.titleX - 4)
                .padding(.trailing, RepoHeader.inset)
            }
            .frame(width: width, height: RepoHeader.height)
            // The bar's empty space moves the window.
            .background(WindowDragArea())
            .animation(Theme.Motion.snappy, value: searching)
        }
        .frame(height: RepoHeader.height)
    }

    private var isFiltering: Bool { !filters.isEmpty || !query.trimmed.isEmpty }

    private var noMatches: some View {
        VStack(spacing: 10) {
            Text("Nothing matches")
                .font(Theme.Typography.ui(15, .medium))
            Button("Clear the filter") { clearFilter() }
                .buttonStyle(.plain)
                .font(Theme.Typography.ui(12, .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Filtering

    /// Everything the menu can offer: tabs, Margin's suggested tabs and its tags.
    private var filterOptions: FilterOptions {
        let project = store.currentProject
        let entries = store.entries(in: project)
        var tagCounts: [String: Int] = [:]
        for entry in entries {
            for tag in Set((entry.ai?.tags ?? []) + entry.tags) where !tag.trimmed.isEmpty {
                tagCounts[tag.lowercased(), default: 0] += 1
            }
        }
        let tabs = intelligence.tabs(in: project)
        let suggested = intelligence.suggestedTabs(in: project)
        let taken = Set((tabs + suggested.map(\.name)).map { $0.lowercased() })
        let tags = tagCounts.filter { !taken.contains($0.key) }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(16)
            .map { (name: $0.key, count: $0.value) }
        return FilterOptions(tabs: tabs, suggested: suggested, tags: tags)
    }

    private func pick(_ name: String) {
        withAnimation(Brand.motion) {
            if !filters.contains(name) { filters.append(name) }
            query = ""
            menuOpen = false
        }
    }

    /// Return in the field: a typed tag that matches one on offer becomes a
    /// filter; any other words stay as a search.
    private func submitQuery() {
        let typed = query.trimmed
        guard !typed.isEmpty else { closeMenu(); return }
        let names = filterOptions.allNames
        if let exact = names.first(where: { $0.caseInsensitiveCompare(typed) == .orderedSame }) {
            pick(exact)
        } else {
            let matches = names.filter { $0.localizedCaseInsensitiveContains(typed) }
            if matches.count == 1 { pick(matches[0]) } else { closeMenu() }
        }
    }

    private func closeMenu() {
        withAnimation(Brand.motion) {
            menuOpen = false
            if !isFiltering { searching = false }
        }
    }

    private func clearFilter() {
        withAnimation(Brand.motion) {
            filters = []
            query = ""
            menuOpen = false
            searching = false
        }
    }

    /// Whether a moment carries a filter: as its tab, Margin's topic or a tag.
    static func matches(_ entry: Entry, filter: String, confirmed: Set<String>) -> Bool {
        func same(_ value: String?) -> Bool { value.map { $0.caseInsensitiveCompare(filter) == .orderedSame } ?? false }
        if same(entry.effectiveTab(confirmed: confirmed)) { return true }
        if entry.tab == nil, same(entry.ai?.topic) { return true }
        return (entry.ai?.tags ?? []).contains(where: same) || entry.tags.contains(where: same)
    }

    /// Whether a moment mentions every typed word, in its words, Margin's note or tags.
    static func matches(_ entry: Entry, query: String) -> Bool {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let text = entry.searchText.lowercased()
        return words.allSatisfy { text.contains($0) }
    }

    private var empty: some View {
        VStack(spacing: 14) {
            Mark(size: 40, dot: 0)
                .opacity(0.5)
            Text("Nothing here yet")
                .font(Theme.Typography.ui(15, .medium))
            Text("Keep working. Margin captures your design and code apps in the background.\nDouble-tap ⌘ to capture a moment yourself.")
                .font(Theme.Typography.ui(13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The project's captures, oldest first, narrowed by search and filters.
    private var visibleEntries: [Entry] {
        var entries = store.chronological(in: store.currentProject)
        // Automatic captures stay out of the archive unless you ask for them.
        if !showAuto { entries = entries.filter { !$0.isAutomatic } }
        if !filters.isEmpty {
            let confirmed = Set(intelligence.tabs(in: store.currentProject))
            entries = entries.filter { entry in filters.allSatisfy { Self.matches(entry, filter: $0, confirmed: confirmed) } }
        }
        if !query.trimmed.isEmpty {
            entries = entries.filter { Self.matches($0, query: query) }
        }
        return entries
    }
}

// MARK: - Slider

/// A slim track you drag between "close-up" and "big picture". The handle
/// notches the track, a dot marks each stop, and the handle falls into the
/// nearest stop when you let go. When a label runs out of room, it hops over
/// the handle to the other side.
private struct GranularitySlider: View {
    @Binding var step: Int
    let steps: Int
    /// Where a pinch on the timeline has the zoom right now: the handle
    /// follows it as if you were dragging it.
    var live: CGFloat? = nil
    /// In the map: the handle stops anywhere and reports where.
    var continuous = false
    var onValue: (CGFloat) -> Void = { _ in }
    @State private var motion: HopMotion
    @State private var animating = false
    /// The step the slider itself last set, to tell its own changes from
    /// others (a pinch on the timeline, a saved state).
    @State private var reported: Int
    /// Bumped to redraw once when motion is reduced and nothing animates.
    @State private var redraw = 0
    /// The pointer is over it: the halves deepen a shade.
    @State private var hovering = false
    /// Your pointer is on the handle right now. Kept apart from the motion's
    /// own "dragging", which a pinch on the timeline also sets: that one
    /// could still be on in Themes and made the handle ignore the map's zoom.
    @State private var pointerDown = false

    init(step: Binding<Int>, steps: Int, live: CGFloat? = nil, continuous: Bool = false, onValue: @escaping (CGFloat) -> Void = { _ in }) {
        _step = step
        self.steps = steps
        self.live = live
        self.continuous = continuous
        self.onValue = onValue
        let motion = HopMotion(value: CGFloat(step.wrappedValue))
        motion.continuous = continuous
        _motion = State(initialValue: motion)
        _reported = State(initialValue: step.wrappedValue)
    }

    private var maxValue: CGFloat { CGFloat(max(steps - 1, 1)) }

    /// Room around the slider that grabs the handle instead of the window.
    static let grabMargin = CGSize(width: 8, height: 8)

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let _ = redraw
            TimelineView(.animation(paused: !animating)) { context in
                let frame = motion.frame(at: context.date, width: width, maxValue: maxValue, restingStep: step)
                track(frame, width: width)
                    .onChange(of: frame.step) { new in
                        // While a pinch drives the handle, the pinch decides the scale.
                        if live == nil, new != step {
                            reported = new
                            step = new
                        }
                    }
                    .onChange(of: frame.settled) { if $0 { animating = false } }
            }
            // The track got wider or narrower (the window resizing): a label
            // may hop, so run the motion until it lands.
            .onChange(of: width) { _ in start() }
            // The slider sits in the title bar row, where a drag would move
            // the window. This surface (a little larger than the slider)
            // takes the mouse itself, so dragging moves the handle only.
            .overlay(
                DragSurface(
                    changed: { x in
                        if !pointerDown { pointerDown = true }
                        motion.continuous = continuous
                        let value = motion.value(atX: x - Self.grabMargin.width, width: width, maxValue: maxValue)
                        motion.drag(to: value)
                        start()
                        if continuous { onValue(min(max(value, 0), maxValue)) }
                    },
                    ended: {
                        pointerDown = false
                        motion.release(maxValue: maxValue)
                        start()
                    }
                )
                .padding(.horizontal, -Self.grabMargin.width)
                .padding(.vertical, -Self.grabMargin.height)
            )
        }
        .onHover { inside in withAnimation(Theme.Motion.hover) { hovering = inside } }
        // Pinching the timeline: the handle follows the zoom the way it
        // follows your pointer, and falls onto the scale the pinch settles on.
        .onChange(of: live) { value in
            if continuous {
                ClusterCanvas.note(String(format: "Themes slider: follows %.2f (%@)", value ?? -1,
                                          pointerDown ? "in your hand, ignored" : "moves"))
                // The map's zoom (a pinch there): the handle follows, unless
                // your pointer is on it.
                if let value, !pointerDown {
                    motion.settle(on: value)
                    motion.skipToTarget()
                    redraw += 1
                    start()
                }
                return
            }
            if let value {
                motion.drag(to: value)
            } else {
                motion.release(maxValue: maxValue)
            }
            start()
        }
        // Back to the timeline: the handle falls onto the nearest stop.
        .onChange(of: continuous) { on in
            motion.continuous = on
            if on, let value = live {
                // Into the map: start from where the map is.
                motion.settle(on: value)
                motion.skipToTarget()
                redraw += 1
            }
            if !on {
                motion.release(maxValue: maxValue)
                start()
            }
        }
        // Changed from elsewhere (a saved state, another window): the handle
        // travels there with the same motion as when you drag it.
        .onChange(of: step) { new in
            guard !continuous, new != reported else { return }
            reported = new
            if motion.follow(new) { start() }
        }
        .frame(height: HopMotion.height)
        .accessibilityElement()
        .accessibilityLabel("Session grouping, from close-up to big picture")
        .accessibilityValue(gapLabel)
        .accessibilityAdjustableAction { direction in
            let next = step + (direction == .increment ? 1 : -1)
            guard (0..<steps).contains(next) else { return }
            motion.settle(on: CGFloat(next))
            start()
        }
    }

    private func start() {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            motion.skipToTarget()
            redraw += 1
        } else {
            animating = true
        }
    }

    private var gapLabel: String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .short
        formatter.allowedUnits = [.day, .hour, .minute]
        let gap = RepoView.gaps[max(0, min(step, RepoView.gaps.count - 1))]
        return "Sessions split at pauses over \(formatter.string(from: gap) ?? "")"
    }

    /// Two halves of a track either side of Margin's ink handle, each
    /// holding its word. The halves are the control: they lengthen and
    /// shorten as you slide, pull back from the handle the faster it moves
    /// and flatten a little with the speed, then settle as it lands. The
    /// stops are short lines inside them; a word that runs out of room
    /// hops over the handle, softening as it goes.
    private func track(_ frame: HopMotion.Frame, width: CGFloat) -> some View {
        let mid = HopMotion.height / 2
        let h = HopMotion.track - 3 * frame.speed
        let half = RoundedRectangle(cornerRadius: HopMotion.radius, style: .continuous)
        let shade = Theme.Palette.ink.opacity(frame.dragging ? 0.08 : hovering ? 0.065 : 0.05)
        return ZStack(alignment: .topLeading) {
            half.fill(shade)
                .frame(width: frame.leftWidth, height: h)
                .opacity(frame.leftWidth < 2 ? 0 : 1)
                .offset(y: mid - h / 2)
            half.fill(shade)
                .frame(width: frame.rightWidth, height: h)
                .opacity(frame.rightWidth < 2 ? 0 : 1)
                .offset(x: frame.rightX, y: mid - h / 2)
            // The stops in between, as short lines inside the track. In the
            // map there are none to fall onto, so they step away.
            ForEach(1..<max(1, steps - 1), id: \.self) { index in
                let x = HopMotion.x(of: CGFloat(index), width: width, maxValue: maxValue)
                let clear = min(max((abs(x - frame.handleX) - 6) / 8, 0), 1)
                Capsule()
                    .fill(Theme.Palette.ink.opacity(0.22))
                    .frame(width: 1, height: 6)
                    .opacity(continuous ? 0 : clear)
                    .animation(Theme.Motion.hover, value: continuous)
                    .offset(x: x - 0.5, y: mid - 3)
            }
            // The handle: a slim ink bar, a little past the track at rest,
            // longer and wider in your hand.
            let handleH = h + (frame.dragging ? 10 : 6)
            let handleW: CGFloat = frame.dragging ? 3 : 2
            Capsule()
                .fill(Theme.Palette.ink)
                .frame(width: handleW, height: handleH)
                .offset(x: frame.handleX - handleW / 2, y: mid - handleH / 2)
            word(0, x: frame.leftLabelX, emphasis: 1 - frame.progress, hopping: frame.leftHopping, mid: mid)
            word(1, x: frame.rightLabelX, emphasis: frame.progress, hopping: frame.rightHopping, mid: mid)
        }
        .frame(width: width, height: HopMotion.height, alignment: .topLeading)
    }

    private func word(_ index: Int, x: CGFloat, emphasis: CGFloat, hopping: CGFloat, mid: CGFloat) -> some View {
        // Typed as Text first: the Xcode 26.2 compiler can't pick between
        // Text.font and View.font here otherwise.
        let label: Text = Text(HopMotion.labels[index]).font(HopMotion.labelFont)
        // Every number typed, so the compiler never has to guess between
        // CGFloat and Double in one long chain.
        let ink: Double = 0.36 + 0.44 * Double(emphasis)
        let fade: Double = 1 - 0.55 * Double(hopping)
        let soft: CGFloat = 1.5 * hopping
        let top: CGFloat = mid - 8
        return label
            // The end you're at reads darker.
            .foregroundStyle(Theme.Palette.ink.opacity(ink))
            .fixedSize()
            .frame(height: 16)
            .opacity(fade)
            .blur(radius: soft)
            .offset(x: x, y: top)
            .allowsHitTesting(false)
    }
}

/// The slider's motion: a spring that follows the pointer while dragging and
/// settles on a stop when released, stops that pull the handle in, and labels
/// that hop over the handle. Plain state, advanced once per frame.
private final class HopMotion {
    /// The row it sits in (the tools' height), the track's own height and
    /// the halves' corners.
    static let height: CGFloat = 28
    static let track: CGFloat = 20
    static let radius: CGFloat = 6
    /// The labels at the ends, in sentence case, at the control size every
    /// switch uses.
    static let labels = ["Close-up", "Big picture"]
    static let labelFont: Font = Theme.Typography.ui(Theme.Typography.control)
    static let labelTracking: CGFloat = 0
    /// Notch on each side of the handle, label inset, room a label keeps
    /// from the notch, and how far the first and last stops sit from the ends.
    static let gap: CGFloat = 5, pad: CGFloat = 10, clear: CGFloat = 8, inset: CGFloat = 8

    struct Frame {
        var handleX: CGFloat
        var leftWidth: CGFloat
        var rightX: CGFloat
        var rightWidth: CGFloat
        var leftLabelX: CGFloat
        var rightLabelX: CGFloat
        var progress: CGFloat
        var step: Int
        var dragging: Bool
        var settled: Bool
        /// How fast the handle is moving, 0 to 1.
        var speed: CGFloat = 0
        /// How far each word still has to go after a hop, 0 to 1.
        var leftHopping: CGFloat = 0
        var rightHopping: CGFloat = 0
    }

    private var value: CGFloat
    private var velocity: CGFloat = 0
    private var target: CGFloat
    private var dragging = false
    /// In the map: anywhere along the track, no stops to fall onto.
    var continuous = false
    var isDragging: Bool { dragging }
    private var last: Date?
    /// Whether each label (close-up, big picture) has hopped, and where it's drawn.
    private var hopped = [false, false]
    private var hopStarted = [Date.distantPast, Date.distantPast]
    private var labelX: [CGFloat?] = [nil, nil]

    static let labelWidths: [CGFloat] = labels.map { text in
        let font = Theme.Typography.nsUI(Theme.Typography.control)
        let attributed = NSAttributedString(string: text, attributes: [.font: font, .kern: labelTracking])
        return ceil(attributed.size().width)
    }

    init(value: CGFloat) {
        self.value = value
        target = value
    }

    static func x(of value: CGFloat, width: CGFloat, maxValue: CGFloat) -> CGFloat {
        inset + (width - 2 * inset) * value / maxValue
    }

    func value(atX x: CGFloat, width: CGFloat, maxValue: CGFloat) -> CGFloat {
        let raw = (x - Self.inset) / max(width - 2 * Self.inset, 1) * maxValue
        // Rubber band past the ends.
        if raw < 0 { return raw * 0.18 }
        if raw > maxValue { return maxValue + (raw - maxValue) * 0.18 }
        if continuous { return raw }
        // Near a stop the handle is pulled onto it; between stops it moves
        // faster, so it feels like it falls into place.
        let nearest = raw.rounded(), offset = raw - nearest
        let pulled = 0.5 * pow(abs(offset) * 2, 1.6)
        return nearest + (offset < 0 ? -pulled : pulled)
    }

    func drag(to value: CGFloat) {
        if !dragging { last = nil }
        dragging = true
        target = value
    }

    func release(maxValue: CGFloat) {
        dragging = false
        let clamped = min(max(target, 0), maxValue)
        target = continuous ? clamped : clamped.rounded()
    }

    func settle(on value: CGFloat) {
        dragging = false
        target = value
    }

    /// Moves to a step chosen elsewhere, unless the handle is in your hand.
    /// Returns whether it has somewhere to go.
    func follow(_ step: Int) -> Bool {
        guard !dragging, target != CGFloat(step) else { return false }
        target = CGFloat(step)
        last = nil
        return true
    }

    func skipToTarget() {
        value = target
        velocity = 0
    }

    func frame(at now: Date, width: CGFloat, maxValue: CGFloat, restingStep: Int) -> Frame {
        // Follow the step from outside (another window, saved state) while
        // at rest: travel there rather than jump.
        if !continuous, !dragging, velocity == 0, value == target, Int(target) != restingStep {
            target = CGFloat(restingStep)
        }
        advance(to: now)

        let x = Self.x(of: min(max(value, -0.08), maxValue + 0.08), width: width, maxValue: maxValue)
        // The halves pull back from the handle as it speeds up.
        let speed = min(abs(velocity) / 8, 1)
        let gap = Self.gap + 4 * speed
        let leftWidth = max(0, x - gap)
        let rightX = min(width, x + gap)
        let rightWidth = max(0, width - rightX)

        // Hop: a label that runs out of room jumps over the handle.
        let widths = Self.labelWidths
        let leftHop = hop(0, room: leftWidth - Self.pad - Self.clear, needs: widths[0], now: now)
        let rightHop = hop(1, room: rightWidth - Self.pad - Self.clear, needs: widths[1], now: now)
        let leftTarget = leftHop ? rightX + Self.clear : Self.pad
        let rightTarget = rightHop ? x - Self.gap - Self.clear - widths[1] : width - Self.pad - widths[1]
        let leftLabel = ease(0, toward: leftTarget, now: now)
        let rightLabel = ease(1, toward: rightTarget, now: now)

        let settled = !dragging && abs(value - target) < 0.0008 && abs(velocity) < 0.01
            && abs(leftLabel - leftTarget) < 0.5 && abs(rightLabel - rightTarget) < 0.5
        if settled {
            value = target
            velocity = 0
            last = nil
        }
        return Frame(
            handleX: min(max(x, 1), width - 1),
            leftWidth: leftWidth, rightX: rightX, rightWidth: rightWidth,
            leftLabelX: leftLabel, rightLabelX: rightLabel,
            progress: min(max(value / maxValue, 0), 1),
            step: Int(min(max(value, 0), maxValue).rounded()),
            dragging: dragging, settled: settled,
            speed: settled ? 0 : speed,
            leftHopping: min(abs(leftLabel - leftTarget) / 24, 1),
            rightHopping: min(abs(rightLabel - rightTarget) / 24, 1)
        )
    }

    /// Integrates the spring in small fixed steps, so a slow frame can't overshoot.
    private func advance(to now: Date) {
        let dt = min(0.05, last.map { now.timeIntervalSince($0) } ?? 0.016)
        last = now
        guard dt > 0 else { return }
        // Tight while following the pointer, Brand.motion's spring when settling.
        let (response, damping): (CGFloat, CGFloat) = dragging ? (0.12, 1) : (0.35, 0.9)
        let omega = 2 * .pi / response, k = omega * omega, c = 2 * damping * omega
        let count = Int((dt / 0.002).rounded(.up)), h = CGFloat(dt) / CGFloat(count)
        for _ in 0..<count {
            velocity += (-k * (value - target) - c * velocity) * h
            value += velocity * h
        }
    }

    /// Whether a label has hopped, with a little hysteresis so it can't flicker.
    private func hop(_ index: Int, room: CGFloat, needs: CGFloat, now: Date) -> Bool {
        let on = hopped[index] ? room < needs + 6 : room < needs
        if on != hopped[index] {
            hopped[index] = on
            hopStarted[index] = now
        }
        return on
    }

    /// A label tracks its spot exactly, except for a short glide right after it hops.
    private func ease(_ index: Int, toward target: CGFloat, now: Date) -> CGFloat {
        guard let current = labelX[index], now.timeIntervalSince(hopStarted[index]) < 0.4 else {
            labelX[index] = target
            return target
        }
        let next = current + (target - current) * 0.22
        labelX[index] = next
        return next
    }
}

// MARK: - Intelligence

/// Margin's own words, set apart from the designer's: small, grey, labeled.
/// What Margin noted about one capture, for the opened view: the note and its
/// tags, or a thinking pill while the note is being written. The overview
/// never shows these; they belong to the moment you clicked.
struct MarginNote: View {
    @EnvironmentObject private var intelligence: Intelligence
    let entry: Entry

    var body: some View {
        Group {
            if let note = entry.ai {
                MarginSaw(note: note, tab: entry.tab, showsTags: true)
                    .transition(.opacity)
            } else if intelligence.isNoting(entry.id) {
                ThinkingPill(text: "Looking")
                    .transition(.opacity)
            }
        }
        .animation(Brand.motion, value: entry.ai)
        .animation(Brand.motion, value: intelligence.isNoting(entry.id))
    }
}

struct MarginSaw: View {
    let note: CaptureNote
    var compact = false
    /// The capture's tab, so a topic that is already its tab isn't repeated.
    var tab: String? = nil
    var showsTags = false

    /// Margin's topic (when it isn't the tab yet) and its tags.
    private var chips: [(text: String, isTopic: Bool)] {
        guard showsTags else { return [] }
        var items: [(String, Bool)] = []
        if let topic = note.topic, topic != tab { items.append((topic, true)) }
        items += note.tags.filter { $0.caseInsensitiveCompare(note.topic ?? "") != .orderedSame }.map { ($0, false) }
        return items
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text("Margin saw")
                    .font(Theme.Typography.ui(8.5, .semibold))
                    .foregroundStyle(.tertiary)
                if note.isBigChange {
                    Text("big change")
                        .font(Theme.Typography.ui(9, .medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1))
                        .foregroundStyle(.secondary)
                }
            }
            Text(note.seen)
                .font(Theme.Typography.ui(compact ? 11 : 12))
                .foregroundStyle(.secondary)
                .lineLimit(compact ? 2 : 4)
                .fixedSize(horizontal: false, vertical: true)
            if let changed = note.changed {
                (Text("Changed: ").foregroundColor(.secondary.opacity(0.7)) + Text(changed).foregroundColor(.secondary))
                    .font(Theme.Typography.ui(compact ? 11 : 12))
                    .lineLimit(compact ? 2 : 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !chips.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(chips, id: \.text) { chip in
                        TagChip(text: chip.text, isTopic: chip.isTopic)
                    }
                }
                .padding(.top, 4)
            }
        }
        .toolTip("Margin saw", "Facts from the picture; the why is yours", align: .leading)
    }
}

/// One of Margin's tags. The topic is dashed: a suggestion, not a tab yet.
private struct TagChip: View {
    let text: String
    let isTopic: Bool

    var body: some View {
        Text(text)
            .font(Theme.Typography.ui(10.5, isTopic ? .medium : .regular))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(isTopic ? Color.clear : Brand.fill))
            .overlay(
                Capsule().strokeBorder(Color.secondary.opacity(isTopic ? 0.45 : 0), style: StrokeStyle(lineWidth: 1, dash: isTopic ? [2.5, 2] : []))
            )
            .toolTip(isTopic ? "Part of \(text)?" : "Tagged by Margin", isTopic ? "Accept the tab in the repo to file it there." : nil, align: .leading)
    }
}

/// Lays chips out in rows, wrapping when a row is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        rows(in: proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, point) in rows(in: bounds.width, subviews).points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func rows(in width: CGFloat, _ subviews: Subviews) -> (points: [CGPoint], size: CGSize) {
        var points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (points, CGSize(width: widest, height: y + rowHeight))
    }
}

/// The archive's two ways in, always labelled, so both uses are plain to
/// see: Timeline for every step in order (what you did on Tuesday, why that
/// screen changed), Themes for the big picture (the threads that ran through
/// the project). A pill floating at the bottom right, the current one filled.
private struct ModeSwitch: View {
    @Binding var clustering: Bool
    @Namespace private var chip
    @State private var hovered: Int?
    /// Where the thumb is. It moves the moment you click; the view changes
    /// a beat later. Switching views is heavy work, and done in the same
    /// frame it made the thumb's slide stutter.
    @State private var chosen: Int?

    var body: some View {
        // The same switch as everywhere else, only lifted off the page
        // because it floats.
        let shape = RoundedRectangle(cornerRadius: Theme.Segmented.radius, style: .continuous)
        HStack(spacing: 0) {
            segment(0, label: "Timeline", help: "Every step, in order") { TimelineGlyph() }
            segment(1, label: "Themes", help: "The big picture, grouped by theme") { MapGlyph() }
        }
        .padding(Theme.Segmented.padding)
        .background {
            ZStack {
                FloatingSurface(shape: shape)
                SegmentTrack()
            }
        }
        .overlay(shape.strokeBorder(Theme.Palette.hairline, lineWidth: 1))
        .animation(Theme.Motion.hover, value: hovered)
        // Changed from elsewhere (the tour): the thumb follows.
        .onChange(of: clustering) { on in
            let index = on ? 1 : 0
            if chosen != index { withAnimation(Theme.Motion.snappy) { chosen = index } }
        }
    }

    private func segment<Icon: View>(_ index: Int, label: String, help: String, @ViewBuilder icon: () -> Icon) -> some View {
        let selected = (chosen ?? (clustering ? 1 : 0)) == index
        return Button {
            guard !selected else { return }
            withAnimation(Theme.Motion.snappy) { chosen = index }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                guard chosen == index else { return }
                clustering = index == 1
            }
        } label: {
            HStack(spacing: 6) {
                icon().frame(width: Theme.Segmented.icon, height: Theme.Segmented.icon)
                Text(label).font(Theme.Typography.ui(Theme.Typography.control))
            }
            .foregroundStyle(Theme.Segmented.label(selected, hovered: hovered == index))
            .padding(.horizontal, Theme.Space.x3)
            .frame(height: Theme.Segmented.segment)
            .background {
                if selected {
                    SegmentThumb().matchedGeometryEffect(id: "chip", in: chip)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .toolTip(label, help, edge: .above, align: .center)
        .onHover { inside in
            if inside { hovered = index } else if hovered == index { hovered = nil }
        }
    }
}

/// The timeline's icon: three rows, each a dot and a line, like the
/// archive's dated rows.
private struct TimelineGlyph: View {
    var body: some View {
        Canvas { context, size in
            let u = size.width / 14
            let rows: [(y: CGFloat, end: CGFloat)] = [(3.5, 12.5), (7, 10.5), (10.5, 11.5)]
            for row in rows {
                let dot = CGRect(x: (2.4 - 1.25) * u, y: (row.y - 1.25) * u, width: 2.5 * u, height: 2.5 * u)
                context.fill(Path(ellipseIn: dot), with: .foreground)
                var line = Path()
                line.move(to: CGPoint(x: 5.6 * u, y: row.y * u))
                line.addLine(to: CGPoint(x: row.end * u, y: row.y * u))
                context.stroke(line, with: .foreground, style: StrokeStyle(lineWidth: 1.3 * u, lineCap: .round))
            }
        }
    }
}

/// The map's icon: three dots, loosely gathered.
private struct MapGlyph: View {
    var body: some View {
        Canvas { context, size in
            let u = size.width / 14
            let dots: [(x: CGFloat, y: CGFloat, r: CGFloat)] = [
                (4.6, 5.0, 2.3), (10.0, 4.4, 1.6), (8.2, 10.0, 2.0),
            ]
            for dot in dots {
                let rect = CGRect(x: (dot.x - dot.r) * u, y: (dot.y - dot.r) * u, width: dot.r * 2 * u, height: dot.r * 2 * u)
                context.fill(Path(ellipseIn: rect), with: .foreground)
            }
        }
    }
}

/// A short note floating at the bottom of a window ("Added 3 files to
/// Umbrella", "Saved to Downloads"): on the surface of Margin's other floating
/// pills (the nudge, the capture menu): solid paper (near-black in dark
/// mode), a crisp hairline and a soft two-layer shadow.
struct FloatingNote: View {
    let text: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ink = MenuInk(scheme)
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        Text(text)
            .font(Theme.Typography.ui(13, .medium))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(ink.text)
            .padding(.horizontal, 15)
        .frame(height: 38)
        .background(
            shape.fill(ink.surface)
                .shadow(color: .black.opacity(scheme == .dark ? 0.5 : 0.08), radius: 1.5, y: 1)
                .shadow(color: .black.opacity(scheme == .dark ? 0.45 : 0.16), radius: 18, y: 8)
        )
        .overlay(shape.strokeBorder(ink.hairline, lineWidth: 1))
    }
}
