import AppKit
import QuartzCore
import SwiftUI

/// The hand-off's own narrow window, beside the repo.
///
/// Opening: the repo's right edge moves in and the hand-off grows out of it
/// by the same amount, frame by frame on one easing curve, so the two edges
/// travel together. Its contents are there from the start: the window
/// shows more of them as it grows. Closing is the same, backward.
///
/// It goes away when you press hand-off again, click its ×, press Esc, click
/// the repo, or move either window.
@MainActor
final class HandoffWindow {
    static let width: CGFloat = 420
    /// Below a narrow repo instead of beside it: this tall.
    static let belowHeight: CGFloat = 480
    static let gap: CGFloat = 10
    /// The repo keeps at least this much when it makes room.
    static let minRepoWidth: CGFloat = 640
    static let minRepoHeight: CGFloat = 380
    /// The edge's travel. Slow out, slow in.
    static let duration: TimeInterval = 0.6

    private weak var repo: NSWindow?
    private let panel: NSWindow
    private let reveal = HandoffReveal()
    private let onClosed: () -> Void
    private var repoBefore: NSRect = .zero
    /// Beside the repo (to its right), or below it when the repo is narrow.
    private let below: Bool
    private var animation: Timer?
    private var animating = false
    private var closing = false
    private var observers: [NSObjectProtocol] = []
    private var clickMonitor: Any?

    init(repo: NSWindow, content: AnyView, onClosed: @escaping () -> Void) {
        self.repo = repo
        self.onClosed = onClosed
        below = repo.frame.width - Self.width - Self.gap < Self.minRepoWidth
        let panel = NSWindow(contentRect: .zero, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        // Not by its background: a click inside would count as moving it, which closes it.
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = Brand.backgroundNS
        panel.contentMinSize = .zero
        panel.minSize = .zero
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(type)?.isHidden = true
        }
        self.panel = panel
        let size = below ? CGSize(width: repo.frame.width, height: Self.belowHeight) : CGSize(width: Self.width, height: repo.frame.height)
        let root = HandoffContainer(reveal: reveal, size: size, content: content)
        let host = NSHostingView(rootView: root)
        // The window sets the size; the content never pushes back on it.
        host.sizingOptions = []
        panel.contentView = host
        reveal.close = { [weak self] in self?.close() }
    }

    func open() {
        guard let repo else { return }
        repoBefore = repo.frame
        let from = repo.frame
        if below {
            // The repo can only get so short (its own minimum height). What
            // doesn't fit by shrinking it comes from the screen below; if
            // the screen runs out, both move up together.
            let minHeight = max(Self.minRepoHeight, repo.minSize.height, repo.contentMinSize.height)
            let repoHeight = max(minHeight, from.height - Self.belowHeight - Self.gap)
            let total = repoHeight + Self.gap + Self.belowHeight
            var top = from.maxY
            if let screen = repo.screen?.visibleFrame, top - total < screen.minY {
                top = min(screen.maxY, screen.minY + total)
            }
            let repoTarget = NSRect(x: from.minX, y: top - repoHeight, width: from.width, height: repoHeight)
            let panelTarget = NSRect(x: from.minX, y: repoTarget.minY - Self.gap - Self.belowHeight, width: from.width, height: Self.belowHeight)
            // Starts as a sliver at the repo's bottom edge.
            panel.setFrame(NSRect(x: from.minX, y: from.minY - 1, width: from.width, height: 1), display: false)
            show()
            run(duration: Self.duration) { [weak self] t in
                guard let self, let repo = self.repo else { return }
                let r = Self.mix(from, repoTarget, t)
                repo.setFrame(r, display: true)
                let h = max(1, Self.belowHeight * t)
                let panelTop = r.minY - Self.gap * t
                self.panel.setFrame(NSRect(x: panelTarget.minX, y: panelTop - h, width: panelTarget.width, height: h), display: true)
            } done: { [weak self] in self?.opened() }
        } else {
            let narrower = max(Self.minRepoWidth, from.width - Self.width - Self.gap)
            let travel = from.width - narrower
            // Starts as a sliver at the repo's right edge.
            panel.setFrame(NSRect(x: from.maxX, y: from.minY, width: 1, height: from.height), display: false)
            show()
            run(duration: Self.duration) { [weak self] t in
                guard let self, let repo = self.repo else { return }
                let w = from.width - travel * t
                repo.setFrame(NSRect(x: from.minX, y: from.minY, width: w, height: from.height), display: true)
                let pw = max(1, Self.width * t)
                self.panel.setFrame(NSRect(x: from.minX + w + Self.gap * t, y: from.minY, width: pw, height: from.height), display: true)
            } done: { [weak self] in self?.opened() }
        }
    }

    private func show() {
        panel.alphaValue = 1
        panel.orderFront(nil)
        repo?.addChildWindow(panel, ordered: .above)
    }

    private func opened() {
        withAnimation(.timingCurve(0.25, 0.1, 0.25, 1, duration: 0.35)) { reveal.shown = true }
        panel.makeKey()
        // Nothing typed into until you click a field: the window would
        // otherwise put the cursor in the description straight away.
        // The page itself takes the keys instead, so Esc still closes it.
        panel.makeFirstResponder(panel.contentView)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.panel.firstResponder is NSTextView { self.panel.makeFirstResponder(self.panel.contentView) }
        }
        watch()
    }

    func close() {
        guard !closing else { return }
        closing = true
        unwatch()
        withAnimation(.timingCurve(0.4, 0, 0.6, 1, duration: 0.2)) { reveal.shown = false }
        // Nothing fades out first: the edge starts back straight away.
        DispatchQueue.main.async { [weak self] in
            guard let self, let repo = self.repo else { self?.finish(); return }
            let start = repo.frame
            let panelStart = self.panel.frame
            if self.below {
                let target = self.repoBefore
                self.run(duration: Self.duration * 0.85) { [weak self] t in
                    guard let self, let repo = self.repo else { return }
                    let r = Self.mix(start, target, t)
                    repo.setFrame(r, display: true)
                    let h = max(1, panelStart.height * (1 - t))
                    let panelTop = r.minY - Self.gap * (1 - t)
                    self.panel.setFrame(NSRect(x: panelStart.minX, y: panelTop - h, width: panelStart.width, height: h), display: true)
                } done: { [weak self] in self?.finish() }
            } else {
                let travel = self.repoBefore.width - start.width
                self.run(duration: Self.duration * 0.85) { [weak self] t in
                    guard let self, let repo = self.repo else { return }
                    let w = start.width + travel * t
                    repo.setFrame(NSRect(x: start.minX, y: start.minY, width: w, height: start.height), display: true)
                    let pw = max(1, panelStart.width * (1 - t))
                    self.panel.setFrame(NSRect(x: start.minX + w + Self.gap * (1 - t), y: start.minY, width: pw, height: start.height), display: true)
                } done: { [weak self] in self?.finish() }
            }
        }
    }

    private func finish() {
        repo?.removeChildWindow(panel)
        panel.orderOut(nil)
        onClosed()
    }

    // MARK: Motion

    /// A frame between two frames.
    private static func mix(_ a: NSRect, _ b: NSRect, _ t: CGFloat) -> NSRect {
        NSRect(x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
               width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t)
    }

    /// Ease in and out, strongly: slow start, slow landing.
    private static func ease(_ x: Double) -> Double {
        x < 0.5 ? 16 * pow(x, 5) : 1 - pow(-2 * x + 2, 5) / 2
    }

    /// Steps `frame` at the screen's pace from 0 to 1 along the curve.
    private func run(duration: TimeInterval, frame: @escaping (CGFloat) -> Void, done: @escaping () -> Void) {
        animation?.invalidate()
        animating = true
        let start = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                let x = min(1, (CACurrentMediaTime() - start) / duration)
                frame(CGFloat(Self.ease(x)))
                if x >= 1 {
                    timer.invalidate()
                    self?.animating = false
                    done()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        animation = timer
    }

    // MARK: What closes it

    private func watch() {
        let center = NotificationCenter.default
        // Moving either window.
        for window in [repo, panel].compactMap({ $0 }) {
            observers.append(center.addObserver(forName: NSWindow.willMoveNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.animating else { return }
                    self.close()
                }
            })
        }
        // A click in the repo.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, !self.animating, event.window === self.repo { self.close() }
            }
            return event
        }
    }

    private func unwatch() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }
}

/// Whether the hand-off's contents are in, and how to close it from inside.
@MainActor
final class HandoffReveal: ObservableObject {
    @Published var shown = false
    var close: () -> Void = {}
}

/// The hand-off laid out at its full width from the start, so nothing
/// reflows while the window grows; the window just shows more of it, with
/// no fade (the × is in the hand-off's own header).
private struct HandoffContainer: View {
    @ObservedObject var reveal: HandoffReveal
    let size: CGSize
    let content: AnyView
    var body: some View {
        content
            // Wide and short (below the repo): the page lays out in two columns.
            .environment(\.handoffWide, size.width > size.height)
            .frame(width: size.width, height: size.height)
            .onExitCommand(perform: reveal.close)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
            .background(Brand.background)
            .ignoresSafeArea()
    }
}

private struct HandoffWideKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// The hand-off sits below the repo, wide and short.
    var handoffWide: Bool {
        get { self[HandoffWideKey.self] }
        set { self[HandoffWideKey.self] = newValue }
    }
}
