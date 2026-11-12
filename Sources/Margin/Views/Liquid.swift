import SwiftUI

/// The shape behind the capture card while it changes form: always one
/// shape with straight sides, whose top edge and top corners stay the
/// capture menu's the whole way.
///
/// - From the capture menu (an instant capture): a sheet unfolding. The bar
///   stays where it is as the card's top, and the shape grows down from it
///   evenly, its corners the menu's the whole way, no give at the end.
/// - Through the loading pill: the menu draws in to the pill, and the pill
///   grows straight into the card with a little give.
///
/// Every size is a spring, stepped per frame.
final class Liquid {
    enum Mode {
        /// The menu's shape, holding still: the capture is being taken.
        case menu
        /// The loading pill.
        case waiting
        /// The card.
        case card
    }

    struct Spring {
        var x: CGFloat
        var v: CGFloat = 0
        var t: CGFloat
        var k: CGFloat
        var c: CGFloat

        init(_ x: CGFloat, k: CGFloat, c: CGFloat) {
            self.x = x
            self.t = x
            self.k = k
            self.c = c
        }

        mutating func step(_ dt: CGFloat) {
            v += (-k * (x - t) - c * v) * dt
            x += v * dt
        }

        mutating func jump(to value: CGFloat) {
            x = value
            t = value
            v = 0
        }

        mutating func tune(_ k: CGFloat, _ c: CGFloat) {
            self.k = k
            self.c = c
        }
    }

    /// Where the card's top edge sits in the canvas.
    static let top: CGFloat = 6
    /// The capture menu sits 2 pt lower than the card.
    static let menuTop: CGFloat = 8
    static let menuHeight: CGFloat = 38
    static let pillHeight: CGFloat = 36
    /// The capture menu's corners, which the card and the pill share.
    static let cardRadius: CGFloat = 11
    /// The bottom corners while the shape grows down from the menu.
    static let pouringRadius: CGFloat = 40

    private(set) var mode: Mode = .card
    /// The size of what's showing on top: the card, or the pill's word.
    var contentSize: CGSize = .zero

    private var w = Spring(0, k: 360, c: 27)
    private var h = Spring(0, k: 260, c: 24)
    private var y = Spring(top, k: 300, c: 30)
    /// The bottom corners; the top ones are always `cardRadius`.
    private var bottom = Spring(cardRadius, k: 500, c: 41)
    /// When the bottom corners settle back to the menu's.
    private var settleCornersAt: Date?

    private var last: Date?

    // MARK: Changing form

    /// The capture menu's shape, exactly where the menu was.
    func showMenu(width: CGFloat) {
        mode = .menu
        w.jump(to: width)
        h.jump(to: Self.menuHeight)
        y.jump(to: Self.menuTop)
        bottom.jump(to: Self.cardRadius)
    }

    /// The loading pill. From the menu, the menu draws in to the pill.
    func showWaiting(fresh: Bool) {
        mode = .waiting
        w.tune(360, 27); h.tune(260, 24); y.tune(300, 30)
        bottom.jump(to: Self.cardRadius)
        settleCornersAt = nil
        if fresh {
            w.jump(to: pillWidth)
            h.jump(to: Self.pillHeight)
            y.jump(to: Self.top)
        } else {
            h.t = Self.pillHeight
            y.t = Self.top
        }
    }

    /// The card: from the menu it pours down with soft bottom corners; from
    /// the pill it grows straight into it; with nothing before, it's there.
    func showCard(now: Date) {
        switch mode {
        case .menu:
            mode = .card
            // Critically damped: it eases out and stops, never past the card.
            w.tune(300, 2 * 300.squareRoot()); y.tune(300, 2 * 300.squareRoot()); h.tune(150, 2 * 150.squareRoot())
            y.t = Self.top
            bottom.jump(to: Self.cardRadius)
            settleCornersAt = nil
        case .waiting:
            mode = .card
            y.t = Self.top
        case .card:
            w.jump(to: contentSize.width)
            h.jump(to: contentSize.height)
            y.jump(to: Self.top)
            bottom.jump(to: Self.cardRadius)
        }
    }

    private var pillWidth: CGFloat { max(contentSize.width, 80) }

    /// Settled enough to be drawn as a plain shape.
    var isCalm: Bool {
        abs(w.x - w.t) < 0.5 && abs(h.x - h.t) < 0.5 && abs(w.v) + abs(h.v) < 4
            && abs(bottom.x - Self.cardRadius) < 0.5 && settleCornersAt == nil
    }

    // MARK: Each frame

    func advance(to date: Date) {
        let dt = CGFloat(min(1.0 / 30, last.map { date.timeIntervalSince($0) } ?? 0))
        last = date
        switch mode {
        case .menu:
            break
        case .waiting:
            w.t = pillWidth
        case .card:
            w.t = contentSize.width
            h.t = contentSize.height
            if let settleCornersAt, date >= settleCornersAt {
                bottom.tune(220, 30)
                bottom.t = Self.cardRadius
                self.settleCornersAt = nil
            }
        }
        for _ in 0..<4 {
            let step = dt / 4
            w.step(step); h.step(step); y.step(step); bottom.step(step)
        }
    }

    /// Fills the shape. Use as a mask.
    func draw(in context: GraphicsContext, size: CGSize) {
        let width = max(w.x, 0), height = max(h.x, 0)
        guard width > 0.5, height > 0.5 else { return }
        let rect = CGRect(x: size.width / 2 - width / 2, y: y.x, width: width, height: height)
        let top = min(Self.cardRadius, width / 2, height / 2)
        let low = max(0, min(bottom.x, width / 2, height - top))
        context.fill(Path {
            $0.addRoundedRect(in: rect, cornerRadii: RectangleCornerRadii(topLeading: top, bottomLeading: low, bottomTrailing: low, topTrailing: top), style: .continuous)
        }, with: .color(.white))
    }
}
