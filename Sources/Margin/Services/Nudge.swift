import AppKit
import Carbon
import SwiftUI

/// A small nudge at the top center when you've worked in Figma or Claude for
/// ten minutes without capturing. The mark drops in, the pill opens into a
/// short question, and its background fills up as it counts down; when it's
/// full the pill leaves on its own. Click it and it stretches into the
/// capture menu, which takes over in place; swipe it up or press esc to
/// dismiss it; hover to keep it.
///
/// It stays out of the way:
/// - It waits for a pause in your typing and clicking, never mid-stroke.
/// - Each nudge you let go doubles the wait before the next (10, 20, 40
///   minutes); a capture resets it.
/// - At most `dailyLimit` a day.
@MainActor
final class NudgeController: ObservableObject {
    enum Phase { case hidden, mark, open }

    /// How long without a capture before Margin asks.
    static let interval: TimeInterval = 10 * 60
    /// How long the pill stays.
    static let duration: TimeInterval = 6
    /// Where Margin asks: Figma and the Claude app.
    static let apps: Set<String> = ["com.figma.Desktop", "com.anthropic.claudefordesktop"]
    static let text = "Capture this step?"
    /// The most nudges in one day.
    static let dailyLimit = 3
    /// How long you've stopped typing and clicking before it may show.
    static let pause: TimeInterval = 3

    @Published fileprivate(set) var phase: Phase = .hidden
    /// 0 to 1: how much of the pill's time has passed.
    @Published fileprivate(set) var elapsed: CGFloat = 0
    /// Clicked: the pill is stretching into the capture menu's shape.
    @Published fileprivate(set) var stretching = false
    /// The capture menu's size, which the pill stretches to.
    fileprivate var menuSize = CGSize(width: 380, height: 38)
    /// Esc, taken only while the nudge is showing.
    private var escKey: HotKey?
    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) }
    }
    private static let enabledKey = "nudgesEnabled"

    /// False while something else is up (the capture card, a recording).
    var canShow: () -> Bool = { true }
    private let lastCapture: () -> Date?
    private let onCapture: () -> Void
    private var panel: NSPanel?
    private var checkTimer: Timer?
    private var countdown: Timer?
    private var hovering = false
    private var lastNudge = Date.distantPast
    private var workingSince: Date?
    /// Nudges in a row that went by without a capture.
    private var ignored = 0
    /// Nudges shown today, and which day that is.
    private var shownToday = 0
    private var today = Calendar.current.startOfDay(for: Date())

    init(lastCapture: @escaping () -> Date?, onCapture: @escaping () -> Void) {
        self.lastCapture = lastCapture
        self.onCapture = onCapture
        isEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    func start() {
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        RunLoop.main.add(timer, forMode: .common)
        checkTimer = timer
    }

    private func check() {
        let now = Date()
        guard let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, Self.apps.contains(app) else {
            workingSince = nil
            return
        }
        let since = workingSince ?? now
        workingSince = since
        guard isEnabled, panel == nil, canShow() else { return }
        let day = Calendar.current.startOfDay(for: now)
        if day != today { today = day; shownToday = 0 }
        guard shownToday < Self.dailyLimit else { return }
        // A capture since the last nudge: back to the shortest wait.
        if let captured = lastCapture(), captured > lastNudge { ignored = 0 }
        // Only while you're at the computer, and between moves, not mid-stroke.
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        guard idle >= Self.pause, idle < 120 else { return }
        let quietSince = max(lastCapture() ?? .distantPast, lastNudge, since)
        let wait = Self.interval * pow(2, Double(min(ignored, 2)))
        guard now.timeIntervalSince(quietSince) >= wait else { return }
        shownToday += 1
        show()
    }

    /// Shows the nudge now (also from the menu, to try it).
    func show() {
        guard panel == nil, let screen = TopCenter.screen else { return }
        lastNudge = Date()
        elapsed = 0
        phase = .hidden
        stretching = false
        menuSize = RegionOverlay.openMenuSize()
        // Wide enough for the capture menu it can stretch into.
        let size = CGSize(width: max(320, menuSize.width + 60), height: 70)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = FirstClickHostingView(rootView: NudgePill(nudge: self))
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host
        panel.setFrameOrigin(TopCenter.origin(for: size, on: screen))
        panel.orderFrontRegardless()
        self.panel = panel
        // Esc dismisses it, wherever you're typing (it never takes the
        // keyboard): a system hot key, held only while the nudge is up, so it
        // works in any app without Accessibility access.
        escKey = HotKey(keyCode: UInt32(kVK_Escape), modifiers: 0, id: 10) { [weak self] in
            Task { @MainActor in self?.dismiss() }
        }

        // The mark drops in, then the pill opens into the question.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) { self?.phase = .mark }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) { [weak self] in
            guard let self, self.phase == .mark else { return }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) { self.phase = .open }
            self.startCountdown()
        }
    }

    private func startCountdown() {
        countdown?.invalidate()
        let step = 1.0 / 60
        let timer = Timer(timeInterval: step, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.hovering else { return }
                self.elapsed = min(1, self.elapsed + CGFloat(step / Self.duration))
                if self.elapsed >= 1 { self.dismiss() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        countdown = timer
    }

    fileprivate func hover(_ inside: Bool) { hovering = inside }

    /// Closes into the mark, then rises out of view.
    func dismiss() {
        guard panel != nil, phase != .hidden else { return }
        ignored += 1
        countdown?.invalidate()
        countdown = nil
        escKey = nil
        withAnimation(Theme.Motion.snappy) { phase = .mark }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            withAnimation(.easeIn(duration: 0.2)) { self?.phase = .hidden }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in self?.close() }
    }

    /// Swiped away: straight up, no closing step.
    fileprivate func swipeAway() {
        ignored += 1
        countdown?.invalidate()
        countdown = nil
        escKey = nil
        withAnimation(.easeIn(duration: 0.16)) { phase = .hidden }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.close() }
    }

    /// Clicked: the pill stretches out to both sides into the capture menu's
    /// shape and place, its question fading, then the menu takes over right
    /// there (no drop-in) and the pill goes.
    fileprivate func capture() {
        guard !stretching else { return }
        ignored = 0
        countdown?.invalidate()
        countdown = nil
        escKey = nil
        withAnimation(.timingCurve(0.65, 0, 0.35, 1, duration: 0.42)) { stretching = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.onCapture() }
        // Once the menu is up over it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.62) { [weak self] in self?.close() }
    }

    private func close() {
        escKey = nil
        stretching = false
        panel?.orderOut(nil)
        panel = nil
        phase = .hidden
        elapsed = 0
    }
}

/// The nudge, on the same surface as the capture menu: glass on macOS 26,
/// paper before, with a crisp hairline.
private struct NudgePill: View {
    @ObservedObject var nudge: NudgeController
    @State private var drag: CGFloat = 0
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let open = nudge.phase == .open
        let shown = nudge.phase != .hidden
        let stretching = nudge.stretching
        let ink = MenuInk(scheme)
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        HStack(spacing: open ? 8 : 0) {
            Mark(size: 14, dot: shown ? 1 : 0)
            if open {
                Text(NudgeController.text)
                    .font(Theme.Typography.ui(Theme.Typography.body, .medium))
                    .lineLimit(1)
                    .fixedSize()
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .leading)))
            }
        }
        // The question goes as the pill stretches into the menu.
        .opacity(stretching ? 0 : 1)
        .padding(.leading, open ? 12 : 9)
        .padding(.trailing, open ? 15 : 9)
        // The capture menu's height from the start, so stretching into it
        // only ever widens.
        .frame(height: nudge.menuSize.height)
        .frame(width: stretching ? nudge.menuSize.width : nil)
        .foregroundStyle(ink.text)
        // The time left: the surface fills from the left with a straight
        // edge, like Margin's other progress, and the pill goes when it's full.
        .background(alignment: .leading) {
            GeometryReader { geo in
                Rectangle()
                    .fill(ink.text.opacity(0.08))
                    .frame(width: geo.size.width * (open && !stretching ? nudge.elapsed : 0))
            }
            .clipShape(shape)
        }
        // The shadow belongs to the surface only, never to the words on it.
        .background(FloatingSurface(shape: shape))
        .overlay(shape.strokeBorder(ink.hairline, lineWidth: 1))
        .contentShape(shape)
        .offset(y: (shown ? 0 : -46) + min(0, drag))
        .opacity(shown ? 1 : 0)
        .onTapGesture { nudge.capture() }
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { drag = $0.translation.height }
                .onEnded { value in
                    if value.translation.height < -12 || value.predictedEndTranslation.height < -40 {
                        nudge.swipeAway()
                    } else {
                        withAnimation(Brand.motion) { drag = 0 }
                    }
                }
        )
        .onHover { nudge.hover($0) }
        .help("Click to capture · swipe up or press esc to dismiss")
        // Exactly where the capture menu sits.
        .padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
