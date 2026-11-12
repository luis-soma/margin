import AppKit
import SwiftUI

/// Margin took an automatic capture: a small tile with the mark drops from
/// the top center, like the nudge, a line runs once round its edge, like
/// the stroke while a Figma frame exports, and it rises away again.
/// Nothing to click, nothing to read.
@MainActor
final class AutoCaptureToast: ObservableObject {
    static let shared = AutoCaptureToast()

    @Published fileprivate var shown = false
    @Published fileprivate var since = Date()
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    /// Whether it may show now (not over the capture card or a recording).
    var canShow: () -> Bool = { true }

    /// The day the tile last showed for an automatic capture.
    private var lastShownDay: Date?

    /// For automatic captures: the tile shows for the first one each day, so
    /// you know Margin is keeping track, then they land silently.
    func showFirstToday() {
        let day = Calendar.current.startOfDay(for: Date())
        guard lastShownDay != day, canShow() else { return }
        lastShownDay = day
        show()
    }

    /// How long the line takes round the tile, and how long it stays.
    static let strokeTime: Double = 1.1
    static let stay: Double = 1.6

    func show() {
        guard canShow(), let screen = TopCenter.screen else { return }
        let size = CGSize(width: 90, height: 64)
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isFloatingPanel = true
            panel.level = .statusBar
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let host = NSHostingView(rootView: AutoCaptureTile(toast: self))
            host.frame = NSRect(origin: .zero, size: size)
            panel.contentView = host
            self.panel = panel
        }
        panel?.setFrameOrigin(TopCenter.origin(for: size, on: screen))
        panel?.orderFrontRegardless()

        hideWork?.cancel()
        shown = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            guard let self else { return }
            self.since = Date().addingTimeInterval(0.25) // the line starts once it has landed
            withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) { self.shown = true }
        }
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.stay, execute: work)
    }

    private func hide() {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.9)) { shown = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self, !self.shown else { return }
            self.panel?.orderOut(nil)
        }
    }
}

/// The tile: the nudge's surface at the size of its closed state, the mark
/// in the middle, and one round of the export stroke on its edge.
private struct AutoCaptureTile: View {
    @ObservedObject var toast: AutoCaptureToast
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ink = MenuInk(scheme)
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        Mark(size: 14, dot: 1)
            .frame(width: 36, height: 36)
            .background(
                shape.fill(ink.surface)
                    .shadow(color: .black.opacity(scheme == .dark ? 0.5 : 0.08), radius: 1.5, y: 1)
                    .shadow(color: .black.opacity(scheme == .dark ? 0.45 : 0.16), radius: 14, y: 6)
            )
            .overlay(shape.strokeBorder(ink.hairline, lineWidth: 1))
            .overlay {
                // Draws on, then its tail follows the head round: once.
                TimelineView(.animation) { timeline in
                    let u = min(max(timeline.date.timeIntervalSince(toast.since) / AutoCaptureToast.strokeTime, 0), 1)
                    let head = ease(min(u / 0.65, 1))
                    let tail = ease(max(0, (u - 0.35) / 0.65))
                    shape
                        .trim(from: tail, to: max(tail + 0.0001, head))
                        .stroke(Color.primary.opacity(u > 0 && u < 1 ? 0.42 : 0), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                }
            }
            .scaleEffect(toast.shown ? 1 : 0.92)
            .offset(y: toast.shown ? 0 : -48)
            .opacity(toast.shown ? 1 : 0)
            // Exactly where the nudge and the capture menu hang.
            .padding(.top, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(false)
    }

    /// Slow out, quick through the middle, slow in.
    private func ease(_ t: Double) -> Double {
        t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }
}
