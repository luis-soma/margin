import AppKit
import SwiftUI

/// Margin's visual language in the app: quiet, native and precise.
/// Its values now come from `Theme` (Theme.swift); new code should use
/// `Theme` directly.
/// SF Pro for everything, colors that follow light and dark mode, soft
/// continuous corners, hairlines, and one calm spring for motion.
/// The bracket mark is the only brand element, always in the mode's color.
/// What kind of build this is. The published app (MARGIN_RELEASE=1 in
/// build-app.sh) leaves out the team's tools: Update Margin, the demo
/// switch and the advanced settings.
enum BuildInfo {
    static let isRelease = Bundle.main.object(forInfoDictionaryKey: "MarginRelease") as? Bool ?? false
}

enum Brand {
    // MARK: Motion

    /// The one animation Margin uses. Smooth, settles without bouncing.
    static let motion = Theme.Motion.snappy
    /// For small state changes like hover.
    static let quick = Theme.Motion.hover

    // MARK: Shape

    // Margin's UI is rounded; the work it holds is not. Captures (images,
    // video, frames, captured text, code) always have square corners, so
    // they read as artifacts sitting in Margin, not as Margin's own controls.
    static let radius = Theme.Radius.card
    static let smallRadius = Theme.Radius.control
    /// Corners of captured content: none.
    static let mediaRadius = Theme.Radius.media

    // MARK: Color (adaptive)

    /// Window background: Theme's white canvas.
    static let backgroundNS = Theme.Palette.paperNS
    static let background = Theme.Palette.paper
    /// A surface one step off the background (panels over it).
    static let raisedNS = Theme.Palette.raisedNS
    static let raised = Color(nsColor: raisedNS)

    /// Hairline borders and dividers.
    static let hairline = Theme.Palette.hairline
    /// Resting fill for cards and buttons.
    static let fill = Theme.Palette.fill
    /// Hovered fill.
    static let fillHover = Theme.Palette.fillHover
}

// MARK: - The mark

/// The bracket mark on a 300 × 300 grid: "[" and a dot. Fill it with
/// `.primary` so it is white in dark mode and black in light mode.
struct BracketMark: Shape {
    /// 0 hides the dot, 1 is full size. Animatable.
    var dot: CGFloat = 1

    var animatableData: CGFloat {
        get { dot }
        set { dot = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 300
        let origin = CGPoint(x: rect.midX - 150 * s, y: rect.midY - 150 * s)
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: origin.x + x * s, y: origin.y + y * s, width: w * s, height: h * s)
        }
        var path = Path()
        path.addRect(r(72, 70, 22, 160))
        path.addRect(r(72, 70, 58, 22))
        path.addRect(r(72, 208, 58, 22))
        let diameter = 46 * max(0, min(dot, 1))
        if diameter > 0.5 {
            path.addEllipse(in: r(198 - diameter / 2, 150 - diameter / 2, diameter, diameter))
        }
        return path
    }
}

/// The mark as a view, in the mode's color.
struct Mark: View {
    var size: CGFloat
    var dot: CGFloat = 1

    var body: some View {
        BracketMark(dot: dot)
            .fill(Color.primary)
            .frame(width: size, height: size)
    }
}

enum MarkImage {
    /// Template image for the menu bar, so macOS colors it for light or dark.
    /// The dot is solid while capturing and hollow while paused.
    static func menuBar(live: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: true) { rect in
            let s = rect.width / 300
            NSColor.black.setFill()
            NSColor.black.setStroke()
            for (x, y, w, h) in [(72.0, 70.0, 22.0, 160.0), (72, 70, 58, 22), (72, 208, 58, 22)] {
                NSRect(x: x * s, y: y * s, width: w * s, height: h * s).fill()
            }
            let dot = NSRect(x: 175 * s, y: 127 * s, width: 46 * s, height: 46 * s)
            if live {
                NSBezierPath(ovalIn: dot).fill()
            } else {
                let ring = NSBezierPath(ovalIn: dot.insetBy(dx: 0.6, dy: 0.6))
                ring.lineWidth = 1.2
                ring.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// While recording: the bracket in the menu bar's text color, a red dot.
    static func menuBarRecording() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            let s = rect.width / 300
            NSColor.labelColor.setFill()
            for (x, y, w, h) in [(72.0, 70.0, 22.0, 160.0), (72, 70, 58, 22), (72, 208, 58, 22)] {
                NSRect(x: x * s, y: y * s, width: w * s, height: h * s).fill()
            }
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: NSRect(x: 168 * s, y: 120 * s, width: 60 * s, height: 60 * s)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// A hosting view that reacts to the first click even when Margin isn't the
/// active app, for controls in floating panels.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Building blocks

/// Small uppercase label for section names, e.g. "TODAY".
struct Eyebrow: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(Theme.Typography.ui(10, .medium))
            .foregroundStyle(.secondary)
    }
}

/// Soft button: light fill, continuous corners, gentle hover and press.
struct SoftButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SoftButton(configuration: configuration)
    }

    private struct SoftButton: View {
        let configuration: ButtonStyleConfiguration
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .fill(isHovering ? Brand.fillHover : Brand.fill)
                )
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .animation(Brand.quick, value: isHovering)
                .animation(Brand.quick, value: configuration.isPressed)
                .onHover { isHovering = $0 }
        }
    }
}

// MARK: - Thinking

/// A soft band of light that sweeps across whatever it's on: Margin is working.
/// One sweep, a short rest, again. Still when Reduce Motion is on.
struct Shimmer: ViewModifier {
    var active = true
    /// Seconds for one sweep.
    var duration: Double = 1.5
    /// Rest between sweeps.
    var pause: Double = 0.35
    /// How far the band fades what's under it (0 none, 1 fully).
    var depth: Double = 0.6

    func body(content: Content) -> some View {
        if active && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            TimelineView(.animation) { context in
                let cycle = duration + pause
                let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle)
                content.mask(Band(progress: CGFloat(min(t / duration, 1)), depth: depth))
            }
        } else {
            content
        }
    }

    /// Opaque everywhere except a soft band that travels from left to right.
    private struct Band: View {
        let progress: CGFloat
        let depth: Double

        var body: some View {
            GeometryReader { geo in
                let w = geo.size.width
                let band = max(36, w * 0.55)
                HStack(spacing: 0) {
                    Rectangle().frame(width: w)
                    LinearGradient(stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black.opacity(1 - depth), location: 0.5),
                        .init(color: .black, location: 1),
                    ], startPoint: .leading, endPoint: .trailing)
                    .frame(width: band)
                    Rectangle().frame(width: w)
                }
                .offset(x: -w - band + progress * (w + band))
                .frame(width: w, height: geo.size.height, alignment: .leading)
            }
        }
    }
}

extension View {
    /// Sweeps a soft band of light across the view while `active`.
    func shimmer(_ active: Bool = true) -> some View {
        modifier(Shimmer(active: active))
    }
}

extension View {
    /// Fills the pill from the left as real progress comes in (0...1).
    /// nil draws nothing: when the wait can't be measured, only the shimmer shows.
    func progressFill(_ fraction: Double?) -> some View {
        background(alignment: .leading) {
            GeometryReader { geo in
                Rectangle()
                    .fill(Color.primary.opacity(0.09))
                    .frame(width: geo.size.width * CGFloat(min(max(fraction ?? 0, 0), 1)))
                    .animation(Brand.motion, value: fraction)
            }
            .opacity(fraction == nil ? 0 : 1)
            .clipShape(RoundedRectangle(cornerRadius: Island.cardRadius, style: .continuous))
        }
    }
}

/// Margin's one loading look: a quiet grey pill whose word shimmers.
/// With a `fraction` (only when the progress is real) it also fills from
/// the left, and the shimmer keeps running on top. No spinners.
struct ThinkingPill: View {
    let text: String
    var fraction: Double? = nil
    var size: CGFloat = 11

    var body: some View {
        Text(text)
            .font(Theme.Typography.ui(size, .medium))
            .foregroundStyle(Color.primary.opacity(0.5))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, size * 0.8)
            .padding(.vertical, size * 0.32)
            .progressFill(fraction)
            .background(Capsule().fill(Brand.fill))
            .shimmer()
            .accessibilityLabel(text)
            .accessibilityValue(fraction.map { "\(Int($0 * 100)) percent" } ?? "")
    }
}

// MARK: - Drags that don't move the window

/// A clear area that takes mouse drags itself, for controls in a window that
/// moves by its background or sits in the title bar. Reports x in its own
/// coordinates (left edge is 0).
struct DragSurface: NSViewRepresentable {
    var changed: (CGFloat) -> Void
    var ended: () -> Void
    @Environment(\.dragSurfacesEnabled) private var enabled

    func makeNSView(context: Context) -> SurfaceView { SurfaceView() }

    func updateNSView(_ view: SurfaceView, context: Context) {
        view.changed = changed
        view.ended = ended
        view.enabled = enabled
    }

    final class SurfaceView: NSView {
        var changed: ((CGFloat) -> Void)?
        var ended: (() -> Void)?
        /// Off while something covers it (an overlay over the header).
        var enabled = true

        /// Live surfaces, so a window can find the one under a press
        /// without relying on SwiftUI's hit testing.
        static let all = NSHashTable<SurfaceView>.weakObjects()

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { Self.all.add(self) } else { Self.all.remove(self) }
        }

        /// Whether a press at this window point lands on the surface.
        func takes(_ point: NSPoint, in window: NSWindow) -> Bool {
            enabled && self.window === window && !isHiddenOrHasHiddenAncestor
                && convert(bounds, to: nil).contains(point)
        }

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) { report(event) }
        override func mouseDragged(with event: NSEvent) { report(event) }
        override func mouseUp(with event: NSEvent) { ended?() }

        private func report(_ event: NSEvent) {
            changed?(convert(event.locationInWindow, from: nil).x)
        }
    }
}

/// The bar's empty space: press and drag to move the window, double-click
/// to zoom it, like a title bar. Sits behind the bar's controls, so a press
/// on a button or the slider is theirs.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> AreaView { AreaView() }
    func updateNSView(_ view: AreaView, context: Context) {}

    final class AreaView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if event.clickCount == 2 { window.performZoom(nil); return }
            if let margin = window as? MarginWindow {
                margin.startDrag(with: event)
            } else {
                window.performDrag(with: event)
            }
        }
    }
}

private struct DragSurfacesEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Set false on a region that an overlay covers, so its drag surfaces
    /// don't take presses meant for the overlay.
    var dragSurfacesEnabled: Bool {
        get { self[DragSurfacesEnabledKey.self] }
        set { self[DragSurfacesEnabledKey.self] = newValue }
    }
}

/// The colors of Margin's floating surfaces (the capture menu, the nudge):
/// white with ink in light mode, near-black with light ink in dark.
struct MenuInk {
    let surface: Color
    let text: Color
    let muted: Color
    let hairline: Color

    init(_ scheme: ColorScheme) {
        // Theme's colors follow the appearance on their own; the scheme is
        // kept so callers don't change.
        _ = scheme
        surface = Theme.Palette.paper
        text = Theme.Palette.ink
        muted = Theme.Palette.ink2
        hairline = Theme.Palette.hairline
    }
}

/// The pointing hand over anything you can click, so it reads as clickable.
private struct PointingHand: ViewModifier {
    @State private var inside = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                if hovering, !inside { NSCursor.pointingHand.push() }
                if !hovering, inside { NSCursor.pop() }
                inside = hovering
            }
            .onDisappear {
                if inside { NSCursor.pop() }
                inside = false
            }
    }
}

extension View {
    /// Mac controls keep the arrow; the pointing hand is for links only, so
    /// this is now a no-op on buttons. Use `linkCursor()` on real links.
    func pointingHand() -> some View {
        self
    }

    /// The pointing hand, for links that leave Margin (a URL, Figma).
    func linkCursor() -> some View {
        modifier(PointingHand())
    }
}
