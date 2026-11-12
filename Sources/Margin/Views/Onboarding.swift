import AppKit
import SwiftUI

// MARK: - Anchors

/// Places in Margin's windows the tour can point at, by name ("slider",
/// "search", "handoff", "timeline"). Each is read live, in screen
/// coordinates, so a moved or resized window is followed.
@MainActor
enum TourAnchors {
    private final class Box { weak var view: NSView? }
    private static var boxes: [String: Box] = [:]

    fileprivate static func register(_ name: String, _ view: NSView) {
        let box = Box()
        box.view = view
        boxes[name] = box
    }

    static func frame(_ name: String) -> NSRect? {
        guard let view = boxes[name]?.view, let window = view.window, window.isVisible else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }
}

private final class AnchorView: NSView {
    var name = ""
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        MainActor.assumeIsolated { TourAnchors.register(name, self) }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct TourAnchorView: NSViewRepresentable {
    let name: String
    func makeNSView(context: Context) -> NSView {
        let view = AnchorView()
        view.name = name
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

extension View {
    /// Lets the tour point at this view.
    func tourAnchor(_ name: String) -> some View {
        background(TourAnchorView(name: name))
    }
}


// MARK: - The tour

/// Margin's welcome. The screen dims and softens, the mark builds itself,
/// then a short tour on the real things: you double-tap ⌘ once yourself;
/// the nudge, the automatic tile, the archive, zooming and the hand-off
/// play on their own, each moving on by itself (the button fills until
/// it does). Return or → moves on now, ← goes back, Esc closes.
@MainActor
final class OnboardingTour: ObservableObject {
    static let shared = OnboardingTour()

    /// Asks the archive to open a project (its name as the object).
    static let showProject = Notification.Name("MarginTourShowProject")
    /// Asks the archive to zoom to a scale (an Int), slider and all.
    static let zoomTo = Notification.Name("MarginTourZoomTo")
    /// Asks the archive to show the map (true) or the timeline (false).
    static let showMap = Notification.Name("MarginTourShowMap")
    /// Asks the map to glide to a zoom (a Double, 0 close-up ... 3 big picture).
    static let mapZoom = Notification.Name("MarginTourMapZoom")
    /// Asks the archive to open (true) or close (false) the hand-off window.
    static let handoff = Notification.Name("MarginTourHandoff")

    enum Target: Equatable {
        case none
        /// Something hanging at the top center: the capture menu, the
        /// nudge, the automatic tile, at its own size.
        case top(CGSize)
        case anchor(String)
        /// The archive's whole window.
        case window
    }

    struct Stop {
        var target: Target
        var label: String
        var title: String
        var line: String = ""
        /// Waits for the double-tap instead of moving on by itself.
        var waitsForCapture = false
        /// How long before it moves on by itself.
        var seconds: Double = 4.5
        var enter: (@MainActor () -> Void)? = nil
    }

    @Published private(set) var index = 0
    @Published private(set) var introDone = false
    /// The double-tap came in: the capture menu drops in, then on.
    @Published private(set) var captured = false
    /// When the button started filling, and how long it takes; nil while
    /// waiting for you.
    @Published private(set) var autoStart: Date?
    @Published private(set) var autoSeconds: Double = 4.5
    private(set) var movedAt = Date()
    private(set) var fromRect: CGRect?
    private var panel: NSPanel?
    private var keys: Any?
    private var autoWork: DispatchWorkItem?
    var isActive: Bool { panel != nil }

    /// The capture menu's size, the nudge's and the automatic tile's.
    static var menuSize: CGSize { RegionOverlay.openMenuSize() }
    static var nudgeSize: CGSize {
        let font = Theme.Typography.nsUI(13, .medium)
        let text = ceil(NSAttributedString(string: NudgeController.text, attributes: [.font: font]).size().width)
        return CGSize(width: 12 + 14 + 8 + text + 15, height: menuSize.height)
    }
    static let tileSize = CGSize(width: 36, height: 36)

    let stops: [Stop] = [
        Stop(target: .none, label: "", title: ""),
        Stop(target: .top(OnboardingTour.menuSize), label: "Capture", title: "Double-tap ⌘",
             line: "Select a frame or text first, or pick an area after.", waitsForCapture: true),
        Stop(target: .top(OnboardingTour.nudgeSize), label: "Nudge", title: "Reminds you to document",
             enter: { AppModel.shared.showNudge() }),
        Stop(target: .top(OnboardingTour.tileSize), label: "Automatic", title: "Saves your screen as you work",
             line: "Quietly, whenever something changes.",
             // Once the nudge has gone up, so the two never overlap.
             enter: { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { AutoCaptureToast.shared.show() } }),
        Stop(target: .window, label: "Archive", title: "The whole story", seconds: 4,
             enter: { OnboardingTour.openArchive() }),
        Stop(target: .anchor("slider"), label: "Zoom", title: "Step back, step in", line: "Drag or pinch.", seconds: 5.5,
             enter: { OnboardingTour.shared.playZoom() }),
        Stop(target: .anchor("modeSwitch"), label: "Themes", title: "Every step, or the big picture", line: "Timeline keeps each step in order. Themes shows the threads across the project.", seconds: 5,
             enter: { OnboardingTour.shared.flipToMap() }),
        Stop(target: .window, label: "Themes", title: "Sorted by meaning", line: "Rename, drag, add a theme. It's yours.", seconds: 8,
             enter: { OnboardingTour.shared.playMap() }),
        Stop(target: .anchor("handoff"), label: "Hand off", title: "Hand it off", line: "Your story as files, for your coding agent, a review or a case study.", seconds: 6,
             enter: { OnboardingTour.shared.playHandoff() }),
        Stop(target: .none, label: "", title: "You're set"),
    ]

    var stop: Stop { stops[index] }
    var isLast: Bool { index == stops.count - 1 }

    func start() {
        UserDefaults.standard.set(true, forKey: "onboardingSeen")
        guard panel == nil, let screen = TopCenter.screen else { return }
        index = 0
        introDone = false
        captured = false
        autoStart = nil
        fromRect = nil
        movedAt = Date()
        let panel = TourPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: TourOverlay(tour: self, screen: screen.frame))
        host.frame = NSRect(origin: .zero, size: screen.frame.size)
        panel.contentView = host
        panel.setFrame(screen.frame, display: true)
        panel.alphaValue = 0
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.45
            panel.animator().alphaValue = 1
        }
        self.panel = panel
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel != nil else { return event }
            // On the setup step the keys are for the fields (Return saves a key).
            if self.isLast {
                guard event.keyCode == 53 else { return event }
                self.finish()
                return nil
            }
            switch event.keyCode {
            case 53: self.finish(); return nil                     // esc
            case 36, 76, 124: self.next(); return nil              // return, enter, →
            case 123: self.back(); return nil                      // ←
            default: return event
            }
        }
    }

    func introFinished() {
        withAnimation(.easeOut(duration: 0.5)) { introDone = true }
    }

    /// The double-tap during the tour: shown, not acted on. True when the
    /// tour took it.
    func takeCapture() -> Bool {
        guard isActive else { return false }
        guard stop.waitsForCapture, !captured else { return true }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { captured = true }
        autoAdvance(after: 2.2)
        return true
    }

    func next() {
        guard index > 0 || introDone else { return }
        if stop.waitsForCapture && !captured { return }
        if isLast { finish(); return }
        move(to: index + 1)
    }

    func back() {
        guard index > 1 else { return }
        move(to: index - 1)
    }

    private func move(to new: Int) {
        // The nudge goes up before anything else comes down.
        if stop.label == "Nudge" { AppModel.shared.nudge?.dismiss() }
        // Leaving the map's stops: back to the timeline.
        if stop.label == "Themes", stops[new].label != "Themes" { NotificationCenter.default.post(name: Self.showMap, object: false) }
        fromRect = TourOverlay.targetRect(stop.target, screen: panel?.frame ?? .zero)
        movedAt = Date()
        if stops[new].waitsForCapture { captured = false }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.88)) { index = new }
        stops[new].enter?()
        if stops[new].waitsForCapture || new == stops.count - 1 {
            autoWork?.cancel()
            autoStart = nil
        } else {
            autoAdvance(after: stops[new].seconds)
        }
        // Opening the archive brings it forward; keep the tour above it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.panel?.makeKeyAndOrderFront(nil) }
    }

    /// The button fills, and when it's full the tour moves on.
    private func autoAdvance(after seconds: Double) {
        autoWork?.cancel()
        autoSeconds = seconds
        autoStart = Date()
        let at = index
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.index == at, self.isActive else { return }
            self.next()
        }
        autoWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// The archive, in Umbrella (or the project you were in), at the closest scale.
    static func openArchive() {
        let store = AppModel.shared.store
        let project = store.entries(in: DemoData.project).isEmpty ? store.currentProject : DemoData.project
        UserDefaults.standard.set(0, forKey: "repoTimeScale7")
        AppModel.shared.showRepo()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NotificationCenter.default.post(name: showProject, object: project)
        }
    }

    /// Zooms the archive out step by step, then back in, the slider riding along.
    func playZoom() {
        let at = index
        let steps = [1, 2, 3]
        let times = [0.6, 1.9, 3.2]
        for (step, time) in zip(steps, times) {
            DispatchQueue.main.asyncAfter(deadline: .now() + time) { [weak self] in
                guard let self, self.index == at else { return }
                NotificationCenter.default.post(name: OnboardingTour.zoomTo, object: step)
            }
        }
    }

    /// The switch, lit, flips to the map while you watch.
    func flipToMap() {
        play([(1.0, { NotificationCenter.default.post(name: OnboardingTour.showMap, object: true) })])
    }

    /// The map, the whole window lit: the project sorted by meaning at the
    /// big picture, in on a theme and back out, then back to the timeline
    /// before the hand-off.
    func playMap() {
        play([
            (0.0, { NotificationCenter.default.post(name: OnboardingTour.showMap, object: true) }),
            (1.6, { NotificationCenter.default.post(name: OnboardingTour.mapZoom, object: 1.4) }),
            (4.2, { NotificationCenter.default.post(name: OnboardingTour.mapZoom, object: 3.0) }),
            (6.6, { NotificationCenter.default.post(name: OnboardingTour.showMap, object: false) }),
        ])
    }

    /// The hand-off button, lit, is pressed: its window opens, then closes.
    func playHandoff() {
        play([
            (1.0, { [weak self] in
                NotificationCenter.default.post(name: OnboardingTour.handoff, object: true)
                // Keep the tour above the window that just opened.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self?.panel?.orderFrontRegardless() }
            }),
            (4.0, { NotificationCenter.default.post(name: OnboardingTour.handoff, object: false) }),
        ])
    }

    /// Runs beats while the tour stays on this stop.
    private func play(_ beats: [(Double, () -> Void)]) {
        let at = index
        for (time, beat) in beats {
            DispatchQueue.main.asyncAfter(deadline: .now() + time) { [weak self] in
                guard let self, self.index == at else { return }
                beat()
            }
        }
    }

    func finish() {
        autoWork?.cancel()
        NotificationCenter.default.post(name: Self.showMap, object: false)
        NotificationCenter.default.post(name: Self.handoff, object: false)
        if let keys { NSEvent.removeMonitor(keys) }
        keys = nil
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.35
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                panel.orderOut(nil)
                self.panel = nil
                AppModel.shared.showRepo()
            }
        })
    }
}

/// The tour's last screen: what's left to set up, all of it optional.
/// Claude Code for vibe coding, and your own keys for Margin's notes.
private struct SetupStep: View {
    let done: () -> Void
    @ObservedObject private var coding = AppModel.shared.coding
    @ObservedObject private var intelligence = AppModel.shared.intelligence
    @State private var gemini = ""
    @State private var openai = ""

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            Text("Almost done")
                .font(Theme.Typography.ui(Theme.Typography.caption))
                .foregroundStyle(Theme.Palette.ink3)
            Text("A few things to set up")
                .font(Theme.Typography.ui(Theme.Typography.title, .medium))
                .foregroundStyle(Theme.Palette.ink)
                .padding(.top, Theme.Space.x1)
            Text("All optional. Skip them now and find them in Settings any time.")
                .font(Theme.Typography.ui(Theme.Typography.body))
                .foregroundStyle(Theme.Palette.ink2)
                .padding(.top, Theme.Space.x1)

            item("Claude Code", "Your prompts, the code and the running app, as you vibe code.") {
                if coding.isConnected {
                    Text("Connected")
                        .font(Theme.Typography.ui(Theme.Typography.control))
                        .foregroundStyle(Theme.Palette.ink2)
                } else {
                    small("Connect") { coding.connect() }
                        .disabled(coding.port == nil)
                }
            }
            .padding(.top, Theme.Space.x6)
            Rectangle().fill(Theme.Palette.hairline).frame(height: 1)
            VStack(alignment: .leading, spacing: Theme.Space.x2) {
                item("Your own AI keys", "For notes on captures and summaries. Off until you turn it on.") {
                    Toggle("", isOn: $intelligence.isEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .disabled(!intelligence.config.hasGemini && gemini.trimmed.isEmpty)
                }
                key(intelligence.config.hasGemini ? "Gemini key saved" : "Gemini key", text: $gemini) {
                    intelligence.saveKeys(gemini: gemini)
                }
                key(intelligence.config.hasOpenAI ? "OpenAI key saved" : "OpenAI key (optional)", text: $openai) {
                    intelligence.saveKeys(openai: openai)
                }
            }
            .padding(.bottom, Theme.Space.x4)

            HStack {
                Button("Skip", action: done)
                    .buttonStyle(.plain)
                    .font(Theme.Typography.ui(Theme.Typography.control))
                    .foregroundStyle(Theme.Palette.ink2)
                Spacer()
                Button(action: finish) {
                    Text("Start Margin")
                        .font(Theme.Typography.ui(Theme.Typography.control, .medium))
                        .foregroundStyle(Theme.Palette.paper)
                        .padding(.horizontal, Theme.Space.x4)
                        .frame(height: 32)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(Theme.Palette.ink))
                }
                .buttonStyle(PressStyle())
            }
            .padding(.top, Theme.Space.x2)
        }
        .padding(Theme.Space.x6)
        .frame(width: 440)
        .background(FloatingSurface(shape: shape))
        .overlay(shape.strokeBorder(Theme.Palette.hairline, lineWidth: 1))
    }

    /// Keys typed but not yet saved go in on the way out.
    private func finish() {
        if !gemini.trimmed.isEmpty { intelligence.saveKeys(gemini: gemini) }
        if !openai.trimmed.isEmpty { intelligence.saveKeys(openai: openai) }
        done()
    }

    private func item<Control: View>(_ title: String, _ line: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: Theme.Space.x4) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Typography.ui(Theme.Typography.body, .medium))
                    .foregroundStyle(Theme.Palette.ink)
                Text(line)
                    .font(Theme.Typography.ui(Theme.Typography.caption))
                    .foregroundStyle(Theme.Palette.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Space.x4)
            control()
        }
        .padding(.vertical, Theme.Space.x3)
    }

    private func key(_ placeholder: String, text: Binding<String>, save: @escaping () -> Void) -> some View {
        SecureField("", text: text, prompt: Text(placeholder).foregroundColor(Theme.Palette.ink3))
            .textFieldStyle(.plain)
            .font(Theme.Typography.ui(Theme.Typography.control))
            .foregroundStyle(Theme.Palette.ink)
            .padding(.horizontal, Theme.Space.x2 + 2)
            .frame(height: RepoHeader.toolHeight)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(Theme.Palette.fill))
            .onSubmit(save)
    }

    private func small(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Typography.ui(Theme.Typography.control))
                .foregroundStyle(Theme.Palette.ink)
                .padding(.horizontal, Theme.Space.x3)
                .frame(height: RepoHeader.toolHeight)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).strokeBorder(Theme.Palette.hairline, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }
}

/// A borderless panel that can still take keys (Return, arrows, Esc).
private final class TourPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// What's behind, softened: a light blur of the screen.
private struct BehindBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.material = .hudWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        view.alphaValue = 0.55
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// The whole screen: on the intro a soft blur and dim with the mark in the
/// middle; after it, a dim with the real thing lit through it, a hairline
/// round it, and a small card beside it.
private struct TourOverlay: View {
    @ObservedObject var tour: OnboardingTour
    let screen: CGRect

    static let cardWidth: CGFloat = 248

    /// The target in screen coordinates (AppKit, bottom-up).
    static func targetRect(_ target: OnboardingTour.Target, screen: CGRect) -> CGRect? {
        switch target {
        case .none: return nil
        case .top(let size):
            let display = NSScreen.screens.first { $0.frame == screen } ?? NSScreen.main ?? NSScreen.screens[0]
            let top = TopCenter.top(of: display)
            return CGRect(x: (screen.midX - size.width / 2).rounded(), y: top - 8 - size.height, width: size.width, height: size.height)
        case .anchor(let name): return TourAnchors.frame(name)
        case .window: return AppModel.shared.repoWindowFrame
        }
    }

    /// How far the lit area reaches past the target, and its corners.
    private static func padding(_ target: OnboardingTour.Target) -> (inset: CGFloat, radius: CGFloat) {
        switch target {
        case .top: return (4, 14)
        case .window: return (0, 12)
        default: return (6, 9)
        }
    }

    private func local(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX - screen.minX, y: screen.maxY - r.maxY, width: r.width, height: r.height)
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            let now = timeline.date
            let size = screen.size
            let spot = spotlight(now: now)
            ZStack(alignment: .topLeading) {
                if tour.index == 0 || tour.isLast {
                    BehindBlur()
                    Color.black.opacity(0.22)
                    VStack(spacing: 34) {
                        if tour.isLast {
                            // The organisational bits, last and skippable.
                            SetupStep(done: tour.next)
                        } else {
                            LogoIntro(done: Binding(get: { tour.introDone }, set: { if $0 { tour.introFinished() } }))
                            TourButton(title: "Begin", progress: nil, action: tour.next)
                                .opacity(tour.introDone ? 1 : 0)
                                .offset(y: tour.introDone ? 0 : 8)
                        }
                    }
                    .frame(width: size.width, height: size.height)
                    .transition(.opacity)
                } else {
                    let corner = Self.padding(tour.stop.target).radius
                    SpotlightShape(hole: spot ?? .zero, hasHole: spot != nil, radius: corner)
                        .fill(Color.black.opacity(0.3), style: FillStyle(eoFill: true))
                        .contentShape(Rectangle())
                        .onTapGesture {}
                        .transition(.opacity)
                    if tour.stop.waitsForCapture, let target = Self.targetRect(tour.stop.target, screen: screen).map(local) {
                        // What the double-tap brings in, where the real one
                        // hangs, instead of starting a real capture.
                        CaptureMenuDemo(shown: tour.captured, size: OnboardingTour.menuSize)
                            .position(x: target.midX, y: target.midY)
                            .allowsHitTesting(false)
                    }
                    TourCard(tour: tour)
                        .frame(width: Self.cardWidth)
                        .id(tour.index)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 8)),
                            removal: .opacity
                        ))
                        .position(cardCenter(for: spot, in: size))
                }
            }
            .frame(width: size.width, height: size.height)
            .animation(.easeInOut(duration: 0.4), value: tour.index == 0 || tour.isLast)
        }
        .ignoresSafeArea()
    }

    /// Where the lit area is now: gliding from the last stop's.
    private func spotlight(now: Date) -> CGRect? {
        let inset = Self.padding(tour.stop.target).inset
        guard let target = Self.targetRect(tour.stop.target, screen: screen).map(local) else { return nil }
        let padded = target.insetBy(dx: -inset, dy: -inset)
        guard let from = tour.fromRect.map(local)?.insetBy(dx: -inset, dy: -inset) else { return padded }
        let t = min(max(now.timeIntervalSince(tour.movedAt) / 0.6, 0), 1)
        let e = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * e }
        return CGRect(x: mix(from.minX, padded.minX), y: mix(from.minY, padded.minY),
                      width: mix(from.width, padded.width), height: mix(from.height, padded.height))
    }

    /// Under a target near the top, else beside it; inside the whole window.
    private func cardCenter(for spot: CGRect?, in size: CGSize) -> CGPoint {
        let w = Self.cardWidth, h: CGFloat = 110
        guard let spot else { return CGPoint(x: size.width / 2, y: size.height / 2) }
        var x: CGFloat, y: CGFloat
        if case .window = tour.stop.target {
            x = spot.midX
            y = spot.midY
        } else if spot.midY < size.height * 0.3 {
            x = spot.midX
            y = spot.maxY + 20 + h / 2
        } else if spot.maxX + 24 + w < size.width - 24 {
            x = spot.maxX + 24 + w / 2
            y = spot.midY
        } else {
            x = spot.minX - 24 - w / 2
            y = spot.midY
        }
        x = min(max(x, w / 2 + 24), size.width - w / 2 - 24)
        y = min(max(y, h / 2 + 24), size.height - h / 2 - 24)
        return CGPoint(x: x, y: y)
    }
}

private struct SpotlightShape: Shape {
    var hole: CGRect
    var hasHole: Bool
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        if hasHole { path.addRoundedRect(in: hole, cornerSize: CGSize(width: radius, height: radius), style: .continuous) }
        return path
    }
}

/// The small card: a mono label, a short line in the archive's capitals,
/// at most one more, where you are, and the button that fills until the
/// tour moves on.
private struct TourCard: View {
    @ObservedObject var tour: OnboardingTour
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let stop = tour.stop
        let ink = MenuInk(scheme)
        let waiting = stop.waitsForCapture && !tour.captured
        VStack(alignment: .leading, spacing: 0) {
            Text(stop.label)
                .font(Archive.font(Theme.Typography.caption))
                .foregroundStyle(Archive.faint)
            Text(stop.waitsForCapture && tour.captured ? "That's a capture" : stop.title)
                .font(Archive.headline(Theme.Typography.heading))
                .foregroundStyle(ink.text)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            if !stop.line.isEmpty {
                Text(stop.line)
                    .font(Archive.sans(Theme.Typography.body))
                    .foregroundStyle(ink.muted)
                    .padding(.top, 4)
            }
            HStack(spacing: 10) {
                if waiting {
                    HStack(spacing: 5) {
                        KeyCap(text: "⌘", pressing: true)
                        KeyCap(text: "⌘", pressing: true, delay: 0.18)
                    }
                } else {
                    // Where you are: a short line per stop.
                    HStack(spacing: 4) {
                        ForEach(1..<(tour.stops.count - 1), id: \.self) { i in
                            Capsule()
                                .fill(i == tour.index ? ink.text : ink.text.opacity(0.18))
                                .frame(width: i == tour.index ? 14 : 6, height: 2)
                        }
                    }
                }
                Spacer()
                if !waiting {
                    TimelineView(.animation(paused: tour.autoStart == nil)) { timeline in
                        let progress = tour.autoStart.map { min(1, timeline.date.timeIntervalSince($0) / tour.autoSeconds) }
                        TourButton(title: "Next", progress: progress, action: tour.next)
                    }
                }
            }
            .padding(.top, 14)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(ink.surface)
                .shadow(color: .black.opacity(0.08), radius: 1.5, y: 1)
                .shadow(color: .black.opacity(0.2), radius: 22, y: 10)
        )
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(ink.hairline, lineWidth: 1))
    }
}

/// The capture menu as the double-tap brings it, at the real one's size:
/// it drops from the top with its two modes.
private struct CaptureMenuDemo: View {
    let shown: Bool
    let size: CGSize
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ink = MenuInk(scheme)
        let chip = max(22, size.height - 10)
        HStack(spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "photo")
                Text("Screenshot")
            }
            .foregroundStyle(ink.surface)
            .padding(.horizontal, 11)
            .frame(height: chip)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(ink.text))
            HStack(spacing: 6) {
                Image(systemName: "video")
                Text("Record")
            }
            .foregroundStyle(ink.text)
            .padding(.horizontal, 11)
            .frame(height: chip)
            Text("Drag an area or click a window")
                .foregroundStyle(ink.muted)
                .lineLimit(1)
                .padding(.leading, 4)
            Spacer(minLength: 0)
        }
        .font(Theme.Typography.ui(Theme.Typography.body, .medium))
        .padding(.horizontal, 5)
        .frame(width: size.width, height: size.height)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(ink.surface)
                .shadow(color: .black.opacity(0.16), radius: 14, y: 6)
        )
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(ink.hairline, lineWidth: 1))
        .scaleEffect(shown ? 1 : 0.92, anchor: .top)
        .offset(y: shown ? 0 : -30)
        .opacity(shown ? 1 : 0)
    }
}

// MARK: - The intro

/// The bracket builds itself (the upright grows from its middle, the arms
/// reach out, the dot lands), then "margin" arrives letter by letter.
private struct LogoIntro: View {
    @Binding var done: Bool
    @State private var bar: CGFloat = 0
    @State private var arms: CGFloat = 0
    @State private var dot: CGFloat = 0
    @State private var letters = 0

    private let word = Array("margin")

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            BuildingMark(bar: bar, arms: arms, dot: dot)
                .frame(width: 84, height: 84)
            HStack(spacing: 0) {
                ForEach(Array(word.enumerated()), id: \.offset) { index, letter in
                    Text(String(letter))
                        .font(Theme.Typography.ui(Theme.Typography.display * 1.75, .medium))
                        .tracking(-2)
                        .foregroundStyle(.white)
                        .opacity(index < letters ? 1 : 0)
                        .offset(y: index < letters ? 0 : 14)
                        .blur(radius: index < letters ? 0 : 6)
                }
            }
            .offset(y: -3)
        }
        .onAppear(perform: play)
    }

    private func play() {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            bar = 1; arms = 1; dot = 1; letters = word.count; done = true
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.5)) { bar = 1 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.45)) { arms = 1 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.05) {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.55)) { dot = 1 }
        }
        for i in 0..<word.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.35 + Double(i) * 0.06) {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { letters = i + 1 }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.1) { done = true }
    }
}

/// The bracket mark in its parts, so each can grow on its own.
private struct BuildingMark: View {
    let bar: CGFloat
    let arms: CGFloat
    let dot: CGFloat

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 300
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .frame(width: 22 * s, height: 160 * s * bar)
                    .offset(x: 72 * s, y: (70 + 80 * (1 - bar)) * s)
                Rectangle()
                    .frame(width: 58 * s * arms, height: 22 * s)
                    .offset(x: 72 * s, y: 70 * s)
                    .opacity(arms > 0 ? 1 : 0)
                Rectangle()
                    .frame(width: 58 * s * arms, height: 22 * s)
                    .offset(x: 72 * s, y: 208 * s)
                    .opacity(arms > 0 ? 1 : 0)
                Circle()
                    .frame(width: 46 * s, height: 46 * s)
                    .scaleEffect(dot)
                    .offset(x: 175 * s, y: 127 * s)
            }
            .foregroundStyle(.white)
        }
    }
}

// MARK: - Small pieces

/// A key, pressed in a slow loop while the tour waits for it.
private struct KeyCap: View {
    let text: String
    var pressing = false
    var delay: Double = 0

    var body: some View {
        TimelineView(.animation(paused: !pressing)) { timeline in
            let u = (timeline.date.timeIntervalSinceReferenceDate - delay).truncatingRemainder(dividingBy: 1.6)
            let down = pressing && u > 0 && u < 0.14
            Text(text)
                .font(Theme.Typography.ui(Theme.Typography.body, .medium))
                .foregroundStyle(Archive.ink)
                .frame(width: 30, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .fill(Brand.background)
                        .shadow(color: .black.opacity(0.12), radius: 0, y: down ? 0.5 : 2)
                )
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
                .offset(y: down ? 1.5 : 0)
        }
    }
}

/// Margin's button, like hand-off's send and the projects page's "+":
/// paper, a hairline, small capitals. With `progress`, a quiet fill runs
/// in from the left with a straight edge until the tour moves on.
private struct TourButton: View {
    let title: String
    let progress: Double?
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ink = MenuInk(scheme)
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
        Button(action: action) {
            HStack(spacing: Theme.Space.x2) {
                Text(title)
                    .font(Theme.Typography.ui(Theme.Typography.body, .medium))
                Image(systemName: "arrow.right")
                    .font(.system(size: Theme.Typography.label, weight: .semibold))
                    .offset(x: hovering ? 2 : 0)
            }
            .foregroundStyle(ink.text)
            .padding(.horizontal, 13)
            .frame(height: 30)
            .background(alignment: .leading) {
                GeometryReader { geo in
                    Rectangle()
                        .fill(ink.text.opacity(0.08))
                        .frame(width: geo.size.width * (progress ?? 0))
                }
            }
            .background(Color.primary.opacity(hovering ? 0.04 : 0))
            .background(ink.surface)
            .clipShape(shape)
            .overlay(shape.strokeBorder(ink.hairline, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Brand.quick, value: hovering)
    }
}
