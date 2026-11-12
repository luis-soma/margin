import AppKit
import AVFoundation
import SwiftUI

// MARK: - Header pieces

/// Where you are, top left: "Projects", "Projects / Umbrella" or
/// "Projects / Umbrella / Hand over". It's one view for all screens so
/// what's already there never moves: deeper steps fade in to its right.
/// Earlier steps are grey and take you back.
struct Breadcrumb: View {
    let project: String
    /// 0 home, 1 a project, 2 its handover.
    let depth: Int
    /// Settings is open (a step past home).
    var settings = false
    let goHome: () -> Void
    let back: () -> Void

    var body: some View {
        HStack(spacing: Self.slashGap) {
            Crumb(title: "Projects", current: depth == 0 && !settings, help: "All projects", action: goHome)
            if settings {
                HStack(spacing: Self.slashGap) {
                    slash
                    Crumb(title: "Settings", current: true, help: "", action: {})
                }
                .transition(.opacity.combined(with: .offset(x: 10)))
            }
            if depth >= 1 {
                HStack(spacing: Self.slashGap) {
                    slash
                    Crumb(title: project, current: depth == 1, help: "Back to the project", action: back)
                }
                .transition(.opacity.combined(with: .offset(x: 10)))
            }
            if depth >= 2 {
                HStack(spacing: Self.slashGap) {
                    slash
                    Crumb(title: "Explain", current: true, help: "", action: {})
                }
                .transition(.opacity.combined(with: .offset(x: 10)))
            }
        }
    }

    /// Around the slash: snug, so "Projects / Umbrella" reads as one line.
    static let slashGap: CGFloat = 3

    private var slash: some View {
        Text("/")
            .font(Archive.crumbFont(Archive.Size.crumb))
            .foregroundStyle(Archive.faint)
    }
}

/// One step of the breadcrumb. Same font and size whether it's where you
/// are or a step back, so it never shifts: only its shade changes.
private struct Crumb: View {
    let title: String
    let current: Bool
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        // Not disabled when current: a disabled button greys its label, and
        // where you are should read darkest.
        Button(action: { if !current { action() } }) {
            // The archive's labels: mono caps, ink where you are, faint behind.
            Text(title)
                .font(Archive.crumbFont(Archive.Size.crumb))
                // Pointing at an earlier step turns it ink, like where you are; no fill.
                .foregroundStyle(current || hovering ? Archive.ink : Archive.faint)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 5)
                .frame(height: RepoHeader.controlHeight + 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(!current)
        .onHover { hovering = $0 }
        .animation(Brand.quick, value: hovering)
        .help(current ? "" : help)
    }
}

/// A square header control matching search: an icon on a quiet fill.
struct HeaderIconButton: View {
    let symbol: String
    let help: String
    /// On (a toggle that's switched on): full ink, stronger fill.
    var active = false
    /// The glyph's size, and a nudge to sit it at the optical center (the
    /// share glyph's arrow makes it look low).
    var glyph: CGFloat = 9.5
    var lift: CGFloat = 0
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: glyph, weight: .semibold))
                .offset(y: -lift)
                .foregroundStyle(active ? Brand.background : Color.primary.opacity(hovering ? 0.75 : 0.5))
                .frame(width: RepoHeader.searchClosed, height: RepoHeader.controlHeight)
                .background(
                    RoundedRectangle(cornerRadius: RepoHeader.controlRadius, style: .continuous)
                        .fill(active ? Color.primary.opacity(hovering ? 0.75 : 0.85) : Color.primary.opacity(hovering ? 0.1 : 0.07))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: - Home

/// Every project as a cover with its name and count beneath, like the
/// timeline's dates: nothing else. Up to three across between the archive's
/// margins. A quiet "+" bottom right starts a new one.
struct HomeView: View {
    @EnvironmentObject private var store: EntryStore
    let open: (String) -> Void
    let settings: () -> Void
    @State private var scrollOffset: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var visibleHeight: CGFloat = 0

    /// Most recently worked on first. In the demo, Umbrella always leads.
    private var projects: [(name: String, entries: [Entry])] {
        let pinned = DemoData.isOn ? DemoData.project : nil
        return store.projects
            .map { ($0, store.entries(in: $0)) }
            .filter { !$0.1.isEmpty || $0.0 == store.currentProject }
            .sorted { a, b in
                if a.0 == pinned { return b.0 != pinned }
                if b.0 == pinned { return false }
                return (a.1.first?.createdAt ?? .distantPast) > (b.1.first?.createdAt ?? .distantPast)
            }
    }

    var body: some View {
        GeometryReader { geo in
            let P = Archive.Page.self
            let width = max(0, geo.size.width - 2 * P.margin)
            let columns = min(P.maxColumns, max(1, Int((width + P.cardGap) / (P.minCardWidth + P.cardGap))))
            ScrollView {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: P.cardGap, alignment: .top), count: columns),
                    alignment: .leading,
                    spacing: P.cardRowGap
                ) {
                    ForEach(Array(projects.enumerated()), id: \.element.name) { index, project in
                        ProjectCard(name: project.name, entries: project.entries, order: index) {
                            open(project.name)
                        }
                    }
                }
                .padding(.horizontal, P.margin)
                .padding(.top, P.top)
                .padding(.bottom, 96)
                // macOS keeps its own scroll bar when "Show scroll bars" is
                // set to always: take it off the scroll view itself, and read
                // where it's scrolled to from there for Margin's own bar.
                .background(NoSystemScroller { offset, content, visible in
                    scrollOffset = offset
                    contentHeight = content
                    visibleHeight = visible
                })
            }
            .scrollIndicators(.hidden)
            // The archive's scroll bar: a thin grey capsule, nothing else.
            .overlay(alignment: .trailing) {
                let visible = visibleHeight > 0 ? visibleHeight : geo.size.height
                if contentHeight > visible + 1 {
                    let height = max(24, visible * visible / contentHeight)
                    let y = (visible - height) * min(max(scrollOffset, 0), contentHeight - visible) / max(1, contentHeight - visible)
                    Capsule()
                        .fill(Color.primary.opacity(0.18))
                        .frame(width: 4, height: height)
                        .offset(y: y - (visible - height) / 2)
                        .padding(.trailing, 4)
                        .allowsHitTesting(false)
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            NewProjectButton(create: open)
                .padding(.trailing, RepoHeader.inset + 6)
                .padding(.bottom, RepoHeader.inset + 6)
        }
        .background(Brand.background)
    }
}

/// "+", bottom right. Pointed at, it says what it does; clicked, it opens
/// into a field for the name. Return starts the project, Esc folds it back.
private struct NewProjectButton: View {
    let create: (String) -> Void
    @State private var hovering = false
    @State private var naming = false
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Archive.ink)
                .rotationEffect(.degrees(naming ? 45 : 0))
                .frame(width: 14)
                .onTapGesture { naming ? close() : open() }
            if naming {
                TextField("", text: Binding(get: { name }, set: { name = $0 }), prompt: Text("Project name").foregroundColor(Archive.faint))
                    .textFieldStyle(.plain)
                    .font(Archive.headline(Archive.Size.title))
                    .foregroundStyle(Archive.ink)
                    .focused($focused)
                    .onSubmit(submit)
                    .onExitCommand(perform: close)
                    .frame(width: 168)
                    .transition(.opacity)
            } else if hovering {
                Text("New project")
                    .font(Archive.headline(Archive.Size.title))
                    .foregroundStyle(Archive.ink)
                    .fixedSize()
                    .transition(.opacity.combined(with: .offset(x: -4)))
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 34)
        // Words only ever inside the button, even while it grows or shrinks.
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Brand.background)
                .shadow(color: .black.opacity(hovering || naming ? 0.1 : 0.05), radius: hovering || naming ? 10 : 4, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { if !naming { open() } }
        .onHover { inside in withAnimation(Brand.motion) { hovering = inside } }
        .animation(Brand.motion, value: naming)
        .help(naming ? "" : "New project")
    }

    private func open() {
        withAnimation(Brand.motion) { naming = true }
        DispatchQueue.main.async { focused = true }
    }

    private func close() {
        withAnimation(Brand.motion) { naming = false }
        name = ""
    }

    private func submit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        close()
        if !trimmed.isEmpty { create(trimmed) }
    }
}

/// You, top right of the projects page: picture and first name. Opens
/// settings, where both are changed.
struct ProfileChip: View {
    @ObservedObject private var profile = Profile.shared
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                ProfileAvatar(size: 20)
                if !profile.name.isEmpty {
                    Text(profile.name)
                        .font(Archive.crumbFont(Archive.Size.crumb))
                        .foregroundStyle(hovering ? Archive.ink : Archive.faint)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .frame(height: RepoHeader.controlHeight + 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Brand.quick, value: hovering)
        .help("Profile and settings")
    }
}

// MARK: - Project cards

/// One project: its cover, then its name and, on the same line at the far
/// edge, how many artifacts it holds, set like a date on the timeline.
private struct ProjectCard: View {
    let name: String
    let entries: [Entry] // newest first
    let order: Int
    let tap: () -> Void
    @State private var hovering = false
    @State private var appeared = false
    @State private var menuOpen = false

    var body: some View {
        let P = Archive.Page.self
        VStack(alignment: .leading, spacing: 0) {
            ProjectCover(project: name, entries: entries, seed: name.unicodeScalars.reduce(0) { $0 + Int($1.value) }, lift: hovering)
                .aspectRatio(1 / P.coverRatio, contentMode: .fit)
                .overlay(Rectangle().strokeBorder(Archive.frame, lineWidth: 1))
                .overlay(alignment: .topTrailing) { CoverMenu(project: name, open: $menuOpen, visible: hovering) }
            Spacer().frame(height: Archive.Space.x3)
            HStack(alignment: .firstTextBaseline, spacing: Archive.Space.x3) {
                Text(name)
                    .font(Archive.headline(Archive.Size.date))
                    .foregroundStyle(Archive.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Text(Archive.count(entries.count))
                    .font(Archive.sansLight(Archive.Size.count))
                    .foregroundStyle(Archive.faint)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if menuOpen { withAnimation(Brand.quick) { menuOpen = false } } else { tap() } }
        .zIndex(menuOpen ? 1 : 0)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 10)
        .onHover { inside in
            withAnimation(Brand.motion) { hovering = inside }
            if !inside && menuOpen { withAnimation(Brand.quick) { menuOpen = false } }
        }
        .help(entries.first.map { "Last capture \($0.createdAt.formatted(.relative(presentation: .named)))" } ?? "No captures yet")
        .onAppear {
            // Cards arrive one after another.
            withAnimation(Brand.motion.delay(Double(min(order, 8)) * 0.05)) { appeared = true }
        }
    }
}

// MARK: - Cover menu

/// The three dots on a cover (shown on hover) and what they open: choose a
/// thumbnail, or go back to the newest captures.
private struct CoverMenu: View {
    @EnvironmentObject private var store: EntryStore
    let project: String
    @Binding var open: Bool
    let visible: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            MoreButton(open: open) { withAnimation(Brand.quick) { open.toggle() } }
            if open {
                VStack(alignment: .leading, spacing: 0) {
                    MenuRow(title: "Choose thumbnail…", symbol: "photo") {
                        withAnimation(Brand.quick) { open = false }
                        ProjectCovers.choose(for: project, in: store)
                    }
                    MenuRow(title: "Use latest captures", symbol: "square.stack", checked: !ProjectCovers.has(project, in: store)) {
                        withAnimation(Brand.quick) { open = false }
                        ProjectCovers.clear(project, in: store)
                    }
                }
                .padding(5)
                .frame(width: 214)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Brand.background)
                        .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                )
                .transition(.pop(from: .topTrailing))
            }
        }
        .padding(8)
        .opacity(visible || open ? 1 : 0)
        .animation(Brand.quick, value: visible)
    }
}

private struct MoreButton: View {
    let open: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Archive.ink.opacity(hovering || open ? 0.9 : 0.65))
                .frame(width: 26, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Brand.background.opacity(hovering || open ? 1 : 0.9))
                        .shadow(color: .black.opacity(0.1), radius: 4, y: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Brand.quick, value: hovering)
        .help("Project options")
    }
}

private struct MenuRow: View {
    let title: String
    let symbol: String
    var checked = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Archive.muted)
                    .frame(width: 16)
                Text(title)
                    .font(Archive.sans(13))
                    .foregroundStyle(Archive.ink)
                Spacer(minLength: 12)
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Archive.ink)
                    .opacity(checked ? 1 : 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.06 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A project's cover: its newest capture, slowly crossfading through the
/// latest eight. Square, raw edges, like every artifact.
struct ProjectCover: View {
    @EnvironmentObject private var store: EntryStore
    /// With a project, its chosen thumbnail wins over the captures.
    var project: String? = nil
    let entries: [Entry] // newest first
    var seed = 0
    /// Pointed at: the picture eases a little closer inside its frame.
    var lift = false
    /// Bumped once the newest pictures are decoded (off the main thread).
    @State private var warmed = 0

    static let cycle: TimeInterval = 4.5

    var body: some View {
        let shipped = project.flatMap { ProjectCovers.shipped(for: $0) }
        let cover = shipped != nil ? nil : project.flatMap { ProjectCovers.image(for: $0, in: store) }
        let _ = warmed
        // Only pictures already decoded: the rest are read in the background
        // (below), so opening All projects never waits on the disk.
        let images: [NSImage] = shipped != nil || cover != nil ? [] : Array(entries.lazy.compactMap { entry in
            entry.imageFile.flatMap { store.cachedThumbnail(forFile: $0) }
        }.prefix(8))
        GeometryReader { geo in
            ZStack {
                Brand.fill
                if case .film(let url) = shipped {
                    LoopingFilm(url: url)
                        .frame(width: geo.size.width, height: geo.size.height)
                } else if case .picture(let image) = shipped {
                    tile(image, size: geo.size)
                } else if let cover {
                    tile(cover, size: geo.size)
                } else if images.count > 1 {
                    TimelineView(.periodic(from: .now, by: Self.cycle)) { context in
                        let i = (Int(context.date.timeIntervalSinceReferenceDate / Self.cycle) + seed) % images.count
                        ZStack {
                            tile(images[i], size: geo.size)
                                .id(i)
                                .transition(.opacity)
                        }
                        .animation(.easeInOut(duration: 1.2), value: i)
                    }
                } else if let image = images.first {
                    tile(image, size: geo.size)
                } else {
                    Mark(size: 28, dot: 0)
                        .opacity(0.25)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .scaleEffect(lift ? 1.035 : 1)
            .animation(.easeOut(duration: 0.6), value: lift)
        }
        .clipped()
        .task(id: entries.first?.id) {
            var found = 0
            for entry in entries {
                if found >= 8 { break }
                guard let file = entry.imageFile else { continue }
                if store.cachedThumbnail(forFile: file) == nil {
                    guard await store.loadThumbnail(forFile: file) != nil else { continue }
                    if Task.isCancelled { return }
                }
                found += 1
            }
            withAnimation(.easeOut(duration: 0.2)) { warmed += 1 }
        }
    }

    private func tile(_ image: NSImage, size: CGSize) -> some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.medium)
            .scaledToFill()
            .frame(width: size.width, height: size.height)
            .clipped()
    }
}

/// A film playing on a loop, silent, filling its frame edge to edge (cropped
/// to fit, never letterboxed).
private struct LoopingFilm: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> FilmView { FilmView(url: url) }
    func updateNSView(_ view: FilmView, context: Context) {}

    final class FilmView: NSView {
        private let player = AVQueuePlayer()
        private var looper: AVPlayerLooper?
        private let film = AVPlayerLayer()

        init(url: URL) {
            super.init(frame: .zero)
            wantsLayer = true
            player.isMuted = true
            player.preventsDisplaySleepDuringVideoPlayback = false
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            film.player = player
            film.videoGravity = .resizeAspectFill
            layer?.addSublayer(film)
            player.play()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            film.frame = bounds
            CATransaction.commit()
        }
    }
}

/// Turns off the enclosing scroll view's own scroll bars, whatever the
/// system setting, and reports where it's scrolled to (offset, content
/// height, visible height) as you scroll, for Margin's thin capsule.
private struct NoSystemScroller: NSViewRepresentable {
    let report: (CGFloat, CGFloat, CGFloat) -> Void

    final class Probe: NSView {
        var report: ((CGFloat, CGFloat, CGFloat) -> Void)?
        private weak var watched: NSScrollView?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attach()
            DispatchQueue.main.async { [weak self] in self?.attach() }
        }
        override func layout() {
            super.layout()
            attach()
            send()
        }
        func attach() {
            guard let scroll = enclosingScrollView else { return }
            if scroll.hasVerticalScroller { scroll.hasVerticalScroller = false }
            if scroll.hasHorizontalScroller { scroll.hasHorizontalScroller = false }
            guard watched !== scroll else { return }
            watched = scroll
            scroll.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
            send()
        }
        @objc private func scrolled() { send() }
        func send() {
            guard let scroll = watched, let document = scroll.documentView else { return }
            let clip = scroll.contentView.bounds
            let content = document.frame.height
            let offset = document.isFlipped ? clip.minY : content - clip.maxY
            let report = self.report
            DispatchQueue.main.async { report?(offset, content, clip.height) }
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        deinit { NotificationCenter.default.removeObserver(self) }
    }

    func makeNSView(context: Context) -> NSView {
        let probe = Probe()
        probe.report = report
        return probe
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? Probe)?.report = report
        (nsView as? Probe)?.attach()
    }
}
