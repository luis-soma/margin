import AppKit
import MarginKit

/// Demo only: drags the archive's slider by itself, with real mouse events,
/// so it can be screen-recorded exactly as the app draws it. Opens the demo
/// project at "days", then: to close-up, a rest, one sweep to big picture,
/// a rest, let go, and the pointer drifts off. Started from the command line:
///
///     swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(.init("MarginDemoSlider"), object: nil, deliverImmediately: true)'
///
/// It only ever clicks when one of Margin's own windows is the one under the
/// pointer, so it can't press anything in another app.
@MainActor
enum SliderDemo {
    static let notification = Notification.Name("MarginDemoSlider")
    private static var observer: NSObjectProtocol?

    static func listen() {
        // Development builds only (they know where their repo is): a
        // downloaded Margin never lets another process move the pointer.
        guard Bundle.main.url(forResource: "repo-path", withExtension: nil) != nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(forName: notification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { start() }
        }
    }

    static func start() {
        let store = AppModel.shared.store
        let project = store.entries(in: DemoData.project).isEmpty ? store.currentProject : DemoData.project
        // Days, so the drag has somewhere to go both ways.
        UserDefaults.standard.set(1, forKey: "repoTimeScale7")
        AppModel.shared.showRepo()
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NotificationCenter.default.post(name: OnboardingTour.showProject, object: project)
        }
        // Give the archive a moment to settle, then drag.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { play() }
    }

    // MARK: The drag

    /// Slider stops are 0 (close-up) to 3 (big picture); x is where each sits.
    private static func handleX(_ value: CGFloat, in frame: NSRect) -> CGFloat {
        let inset: CGFloat = 8
        return frame.minX + inset + (frame.width - 2 * inset) * value / 3
    }

    private static func play() {
        guard let slider = TourAnchors.frame("slider") else {
            MarginLog.info("Slider demo: no slider on screen")
            return
        }
        let y = slider.midY
        let x = { (v: CGFloat) in handleX(v, in: slider) }
        let start = NSPoint(x: x(1) + 70, y: y - 120)
        // (seconds from now, where, holding the handle?) — as the approved motion.
        let moves: [(Double, Double, NSPoint, NSPoint, Bool)] = [
            (0.0, 0.7, start, NSPoint(x: x(1), y: y), false),
            (0.9, 2.1, NSPoint(x: x(1), y: y), NSPoint(x: x(0) - 6, y: y), true),
            (2.9, 5.0, NSPoint(x: x(0) - 6, y: y), NSPoint(x: x(3) + 8, y: y), true),
            (6.2, 7.0, NSPoint(x: x(3) + 8, y: y), NSPoint(x: x(3) - 42, y: y - 110), false),
        ]
        let fps = 120.0
        let began = Date()
        var pressed = false
        let timer = Timer(timeInterval: 1 / fps, repeats: true) { timer in
            MainActor.assumeIsolated {
                let t = Date().timeIntervalSince(began)
                // Press when the first drag starts, release when the last one ends.
                if !pressed, t >= 0.9, t < 6.2 {
                    let at = NSPoint(x: x(1), y: y)
                    guard ownsPoint(at) else {
                        MarginLog.info("Slider demo: Margin isn't under the pointer; stopped")
                        timer.invalidate()
                        return
                    }
                    post(.leftMouseDown, at)
                    pressed = true
                }
                if pressed, t >= 6.2 {
                    post(.leftMouseUp, NSPoint(x: x(3) + 8, y: y))
                    pressed = false
                }
                var point = moves.last!.3
                for move in moves where t >= move.0 && t <= move.1 {
                    let u = arrive((t - move.0) / (move.1 - move.0))
                    point = NSPoint(x: move.2.x + (move.3.x - move.2.x) * u, y: move.2.y + (move.3.y - move.2.y) * u)
                }
                if let gap = zip(moves, moves.dropFirst()).first(where: { t > $0.0.1 && t < $0.1.0 }) {
                    point = gap.0.3
                }
                if t < moves[0].0 { point = start }
                post(pressed ? .leftMouseDragged : .mouseMoved, point)
                if t > moves.last!.1 + 0.3 { timer.invalidate() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// cubic-bezier(0.45, 0, 0.12, 1): eases off, then slows down gradually into the end.
    private static func arrive(_ u: Double) -> CGFloat {
        func c(_ s: Double, _ a: Double, _ b: Double) -> Double { 3 * a * s * (1 - s) * (1 - s) + 3 * b * s * s * (1 - s) + s * s * s }
        var lo = 0.0, hi = 1.0
        for _ in 0..<40 { let m = (lo + hi) / 2; if c(m, 0.45, 0.12) < u { lo = m } else { hi = m } }
        return CGFloat(c((lo + hi) / 2, 0, 1))
    }

    /// The frontmost window under this point (AppKit coordinates) is Margin's.
    private static func ownsPoint(_ point: NSPoint) -> Bool {
        let number = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
        return NSApp.windows.contains { $0.windowNumber == number && $0.isVisible }
    }

    /// A mouse event at an AppKit point (the event system counts from the top).
    private static func post(_ type: CGEventType, _ point: NSPoint) {
        let height = NSScreen.screens.first?.frame.height ?? 0
        let quartz = CGPoint(x: point.x, y: height - point.y)
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: quartz, mouseButton: .left)?.post(tap: .cghidEventTap)
    }
}
