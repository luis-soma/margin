import AppKit
import SwiftUI

/// The notch answers Margin's small surfaces. When the capture bar or the
/// capture card comes out from under it, the notch swells down after it,
/// a little wider, with soft flares where it meets the menu bar, then
/// settles back; when one goes back up, a smaller gulp as it takes it in.
///
/// It's a black shape drawn exactly over the notch, in a window that lets
/// every click through and is only on screen for the pulse. On screens
/// without a notch, or with Reduce Motion on, it does nothing.
@MainActor
final class NotchPulse {
    static let shared = NotchPulse()

    final class Model: ObservableObject {
        @Published var drop: CGFloat = 0
        @Published var notch: CGSize = .zero
    }

    private let model = Model()
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?
    private var last = Date.distantPast

    /// How far it spreads at full strength: a little to the sides, barely
    /// down, its edges meeting the menu bar in a small soft flare. Quiet, like
    /// the rest of Margin's motion; no belly, no overshoot.
    nonisolated static let grow: CGFloat = 6
    nonisolated static let depth: CGFloat = 1.5
    nonisolated static let flare: CGFloat = 3
    nonisolated static let belly: CGFloat = 0
    /// Off switch: false and the notch never moves.
    static let enabled = false

    /// Something comes out: the notch swells down after it and settles.
    func release() { pulse(strength: 1) }

    /// Something goes back up: a smaller swell as it takes it in.
    func take() { pulse(strength: 0.6) }

    private func pulse(strength: CGFloat) {
        guard Self.enabled, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        // One pulse per moment, even if two surfaces hand over at once.
        guard Date().timeIntervalSince(last) > 0.25 else { return }
        guard let screen = TopCenter.screen, let notch = Self.notch(of: screen) else { return }
        last = Date()

        let panel = self.panel ?? makePanel()
        self.panel = panel
        model.notch = notch.size
        let size = CGSize(width: notch.width + 2 * (Self.grow + Self.flare) + 16,
                          height: notch.height + Self.depth + Self.belly + 8)
        panel.setFrame(NSRect(x: (screen.frame.midX - size.width / 2).rounded(),
                              y: screen.frame.maxY - size.height,
                              width: size.width, height: size.height), display: false)

        hideWork?.cancel()
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { model.drop = 0 }
        panel.orderFrontRegardless()

        // Out on Margin's own settle curve (the sidebar's and the tooltips'
        // ease-out), held a breath while the surface leaves it, then back in
        // eased both ways. No spring, nothing wobbles.
        withAnimation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.5)) { model.drop = strength }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            withAnimation(.timingCurve(0.65, 0, 0.35, 1, duration: 0.55)) { self.model.drop = 0 }
        }
        let work = DispatchWorkItem { [weak self] in
            self?.panel?.orderOut(nil)
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    /// The notch, in screen coordinates, or nil on a screen without one.
    static func notch(of screen: NSScreen) -> CGRect? {
        let top = screen.safeAreaInsets.top
        guard top > 0,
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else { return nil }
        let width = screen.frame.width - left.width - right.width
        guard width > 40, width < 400 else { return nil }
        return CGRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - top, width: width, height: top)
    }

    private func makePanel() -> NSPanel {
        let panel = NotchPanel(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Over the menu bar, so it can draw where the notch is.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let host = NSHostingView(rootView: NotchBulgeView(model: model))
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        return panel
    }
}

/// Lets the window sit over the menu bar and notch.
private final class NotchPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct NotchBulgeView: View {
    @ObservedObject var model: NotchPulse.Model

    var body: some View {
        NotchBulge(drop: model.drop, notch: model.notch)
            .fill(Color.black)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// The notch's own shape, swollen by `drop` (0 is exactly the notch):
/// wider, deeper, rounded at the bottom, flaring into the top edge.
private struct NotchBulge: Shape {
    var drop: CGFloat
    let notch: CGSize

    var animatableData: CGFloat {
        get { drop }
        set { drop = newValue }
    }

    /// Each side is one S-curve from the menu bar down into the bottom
    /// corner, so the shape reads as one poured form rather than a box with
    /// corners. At rest (drop 0) it's the notch with its rounded bottom.
    func path(in rect: CGRect) -> Path {
        let d = max(drop, 0)
        let grow = NotchPulse.grow * d
        let f = NotchPulse.flare * d
        let width = notch.width + 2 * grow
        let bottom = notch.height + NotchPulse.depth * d
        // The bottom corners soften a little as it spreads.
        let r = min(10 + 2 * d, width / 2, bottom)
        let left = (rect.width - width) / 2
        let right = left + width
        let mid = rect.width / 2

        var path = Path()
        path.move(to: CGPoint(x: left - f, y: 0))
        // Down the left side: leaves the top edge flat, falls, turns into the bottom.
        path.addCurve(to: CGPoint(x: left + r, y: bottom),
                      control1: CGPoint(x: left + f * 0.15, y: 0),
                      control2: CGPoint(x: left, y: bottom))
        // The bottom, bellying a little at the middle.
        path.addQuadCurve(to: CGPoint(x: right - r, y: bottom),
                          control: CGPoint(x: mid, y: bottom + NotchPulse.belly * d * 2))
        // Up the right side, the mirror of the left.
        path.addCurve(to: CGPoint(x: right + f, y: 0),
                      control1: CGPoint(x: right, y: bottom),
                      control2: CGPoint(x: right - f * 0.15, y: 0))
        path.closeSubpath()
        return path
    }
}
