import AppKit
import CoreText
import SwiftUI

/// Margin's one design system: a white light table with ink controls.
///
/// Your work sits on a plain white canvas and brings the only color.
/// Margin's own chrome is neutral (R = G = B): no warm or cool tint, no
/// glass inside the archive. Every size, color, corner, space and curve
/// in the app comes from here.
/// `Brand` and `Archive` are being moved onto these tokens one view at a
/// time; `scripts/check-theme.sh` lists what still uses literal values.
///
/// See docs/REDESIGN.md for the reasoning behind each choice.
enum Theme {
    // MARK: - Type

    /// Two faces of Margin's own, both SIL OFL so the open-source download
    /// can ship them (Resources/Fonts, registered at launch):
    /// - Mona Sans for the interface and your words: the text cut up to
    ///   17 pt, the Display cut for larger titles.
    /// - Geist Mono for data only: times, counts, sizes, file names.
    /// Regular and medium only, as static cuts (SwiftUI drops a variable
    /// font's weight, which drew everything at its 200 default: hairline).
    /// No tracked capitals. Native menus, Settings, alerts stay SF.
    enum Typography {
        /// The smallest text: data and the narrowest labels.
        static let label: CGFloat = 10
        /// Meta, slider labels, notes under captures.
        static let caption: CGFloat = 11
        /// What you read: your notes, descriptions, list rows.
        static let body: CGFloat = 13
        /// Every control's words: switches, buttons, the slider, fields.
        /// One step under what you read, so controls sit back.
        static let control: CGFloat = 12
        /// Section titles ("Today"), the project title in the header.
        static let heading: CGFloat = 15
        /// A page's title: the project on Explain, a capture in focus.
        static let title: CGFloat = 20
        /// Home, empty states, onboarding.
        static let display: CGFloat = 32

        /// No tracked capitals anywhere; kept at 0 so old callers compile.
        static let labelTracking: CGFloat = 0

        /// The interface face. Anything above medium is drawn as medium.
        static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
            let name = sansName(size, weight)
            return installed(name)
                ? .custom(name, fixedSize: size)
                : .system(size: size, weight: isMedium(weight) ? .medium : .regular)
        }

        /// The data face, figures in columns.
        static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
            let name = isMedium(weight) ? "GeistMono-Medium" : "GeistMono-Regular"
            return installed(name)
                ? .custom(name, fixedSize: size)
                : .system(size: size, weight: isMedium(weight) ? .medium : .regular, design: .monospaced)
        }

        /// `ui` for AppKit and for measuring text.
        static func nsUI(_ size: CGFloat, _ weight: Font.Weight = .regular) -> NSFont {
            cachedFont(sansName(size, weight), size: size)
                ?? .systemFont(ofSize: size, weight: isMedium(weight) ? .medium : .regular)
        }

        /// `mono` for AppKit and for measuring text.
        static func nsMono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> NSFont {
            cachedFont(isMedium(weight) ? "GeistMono-Medium" : "GeistMono-Regular", size: size)
                ?? .monospacedSystemFont(ofSize: size, weight: isMedium(weight) ? .medium : .regular)
        }

        // Looking a font up by name costs a little every time; the timeline
        // draws hundreds of words a frame while you pinch. Each name is
        // checked once (until it's found), each size made once.
        private static let lock = NSLock()
        private static var found: Set<String> = []
        private static let fonts = NSCache<NSString, NSFont>()

        private static func installed(_ name: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            if found.contains(name) { return true }
            guard NSFont(name: name, size: 12) != nil else { return false }
            found.insert(name)
            return true
        }

        private static func cachedFont(_ name: String, size: CGFloat) -> NSFont? {
            let key = "\(name) \(size)" as NSString
            if let font = fonts.object(forKey: key) { return font }
            guard let font = NSFont(name: name, size: size) else { return nil }
            fonts.setObject(font, forKey: key)
            return font
        }

        private static func sansName(_ size: CGFloat, _ weight: Font.Weight) -> String {
            let cut = size > 17 ? "MonaSansDisplay" : "MonaSans"
            return cut + (isMedium(weight) ? "-Medium" : "-Regular")
        }

        /// Medium, semibold and heavier all draw as medium.
        private static func isMedium(_ weight: Font.Weight) -> Bool {
            !(weight == .ultraLight || weight == .thin || weight == .light || weight == .regular)
        }
    }

    // MARK: - Color

    /// One true neutral ramp (R = G = B) for every surface, in light and
    /// dark. Never warm: next to screenshots a warm grey reads as aged, not
    /// as a choice. No brand accent: the captures bring the color. Red is
    /// only for recording.
    enum Palette {
        /// The canvas under your work: windows, the timeline, the focus view.
        static let paperNS = adaptiveNS("ThemePaper", light: 0xFFFFFF, dark: 0x0F0F0F)
        static let paper = Color(nsColor: paperNS)
        /// One step off the canvas: panels, the inspector, Home tiles.
        static let raisedNS = adaptiveNS("ThemeRaised", light: 0xF7F7F7, dark: 0x171717)
        static let raised = Color(nsColor: raisedNS)
        /// Primary text.
        static let inkNS = adaptiveNS("ThemeInk", light: 0x111111, dark: 0xEDEDED)
        static let ink = Color(nsColor: inkNS)
        /// Secondary text.
        static let ink2 = ink.opacity(0.6)
        /// Tertiary text: labels, counts, placeholders.
        static let ink3 = ink.opacity(0.4)
        /// Dividers, capture frames, the edge of cards.
        static let hairline = ink.opacity(0.08)
        /// Tracks (segmented, slider) and resting chips.
        static let fill = ink.opacity(0.04)
        /// Hovered fill.
        static let fillHover = ink.opacity(0.06)
        /// Pressed, selected or open.
        static let fillSelected = ink.opacity(0.07)
        /// Recording, and nothing else.
        static let recording = Color(nsColor: .systemRed)

        private static func adaptiveNS(_ name: String, light: Int, dark: Int) -> NSColor {
            NSColor(name: NSColor.Name(name)) { appearance in
                let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
                return NSColor(
                    srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                    green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255,
                    alpha: 1
                )
            }
        }
    }

    // MARK: - Shape

    /// Margin's UI is rounded; the work it holds is not.
    /// The one switch, everywhere there are two or three choices side by
    /// side (Timeline / Themes, Reminder / Automatic, Everything / What's
    /// new, the agent, Screenshot / Record): a light track 28 tall, 24 tall
    /// segments, words at the control size and a thumb that slides to the
    /// chosen one.
    enum Segmented {
        /// The chosen side as a solid ink chip with the words reversed out,
        /// like the capture bar. False gives a white thumb with a hairline
        /// shadow instead. One switch for the whole app.
        static let inkThumb = true
        static let segment: CGFloat = 24
        static let padding: CGFloat = 2
        static let radius: CGFloat = Radius.control
        static var thumbRadius: CGFloat { radius - padding }
        static let icon: CGFloat = 12

        /// The words' color on a segment.
        static func label(_ selected: Bool, hovered: Bool = false) -> Color {
            if selected { return inkThumb ? Palette.paper : Palette.ink }
            return hovered ? Palette.ink : Palette.ink2
        }
    }

    enum Radius {
        /// Chips and tags.
        static let chip: CGFloat = 4
        /// Buttons, fields, header tools.
        static let control: CGFloat = 8
        /// Menus, cards, the capture card, the loading pill's ends.
        static let card: CGFloat = 12
        /// Captured content (images, video, frames, code): square.
        static let media: CGFloat = 0
    }

    // MARK: - Space

    /// A 4 pt grid. Use these, never 5, 7, 9, 10 or 11.
    enum Space {
        static let x1: CGFloat = 4
        static let x2: CGFloat = 8
        static let x3: CGFloat = 12
        static let x4: CGFloat = 16
        static let x6: CGFloat = 24
        static let x8: CGFloat = 32
        static let x12: CGFloat = 48
    }

    // MARK: - Motion

    /// Two curves. `snappy` for the interface, `liquid` (in Liquid.swift)
    /// for the capture morph only. Hover changes use `hover` or nothing.
    enum Motion {
        /// Settles in about 300 ms without bouncing.
        static let snappy = Animation.spring(response: 0.3, dampingFraction: 0.9)
        /// Hover and small state changes.
        static let hover = Animation.easeOut(duration: 0.12)
        /// Something arriving (a popover, a menu, a row): a strong ease out,
        /// 200 ms (cubic-bezier 0.23, 1, 0.32, 1).
        static let enter = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.2)
        /// Leaving: about 20% shorter than arriving, easing in.
        static let exit = Animation.timingCurve(0.4, 0, 1, 1, duration: 0.16)
        /// Something moving from one place to another: ease in and out
        /// (cubic-bezier 0.77, 0, 0.175, 1).
        static let move = Animation.timingCurve(0.77, 0, 0.175, 1, duration: 0.32)
        /// Between rows coming in one after another.
        static let stagger: Double = 0.03
        /// A press: down quickly.
        static let press = Animation.easeOut(duration: 0.1)
        /// The sidebar opening: its card unfolds from the window's edge, fast
        /// at first and long and soft at the end, like a panel swung open.
        static let sidebarIn = Animation.timingCurve(0.32, 0.72, 0, 1, duration: 0.56)
        /// The sidebar closing: folding back into the edge, eased both ways,
        /// a little quicker than it opened.
        static let sidebarOut = Animation.timingCurve(0.65, 0, 0.35, 1, duration: 0.42)
        /// Words and rows settling in: a long, soft ease out.
        static let settle = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.38)

        /// nil when Reduce Motion is on, so `withAnimation(Theme.Motion.ui)`
        /// changes state instantly for people who asked for that.
        static var ui: Animation? {
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : snappy
        }
    }
}

// MARK: - Press and pop

/// A plain button that gives under your finger: scales to 0.97 while held,
/// back on release. Nothing tweens while it's held beyond that.
struct PressStyle: ButtonStyle {
    var scale: CGFloat = 0.97

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(Theme.Motion.press, value: configuration.isPressed)
    }
}

private struct Blurred: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View { content.blur(radius: radius) }
}

extension AnyTransition {
    /// Words or a row arriving: fading and coming into focus together, a
    /// light blur only (3 pt), never a smear.
    static var blurFade: AnyTransition {
        .modifier(active: Blurred(radius: 3), identity: Blurred(radius: 0)).combined(with: .opacity)
    }

    /// One icon swapping for another in place: a crossfade with a little
    /// scale and a light blur, so neither pops.
    static var iconSwap: AnyTransition {
        .modifier(active: Blurred(radius: 2), identity: Blurred(radius: 0))
            .combined(with: .scale(scale: 0.8))
            .combined(with: .opacity)
    }

    /// A popover or menu: grows from 0.95 out of the edge it opened from,
    /// fading in fast; leaves the same way, a little quicker.
    static func pop(from anchor: UnitPoint) -> AnyTransition {
        .asymmetric(
            insertion: .scale(scale: 0.95, anchor: anchor).combined(with: .opacity).animation(Theme.Motion.enter),
            removal: .scale(scale: 0.97, anchor: anchor).combined(with: .opacity).animation(Theme.Motion.exit)
        )
    }
}

// MARK: - Surfaces

/// The surface behind a floating control (the capture menu, card, pill,
/// nudge, the mode switch): solid white with the card shadow. Callers draw
/// their own hairline on top. No Liquid Glass: over a white canvas it has
/// nothing to refract and reads as a grey smudge.
/// The chosen segment's thumb. `pictures` keeps it white under app icons,
/// which an ink chip would swallow.
struct SegmentThumb: View {
    var pictures = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Segmented.thumbRadius, style: .continuous)
        if Theme.Segmented.inkThumb && !pictures {
            shape.fill(Theme.Palette.ink)
        } else {
            shape.fill(Theme.Palette.paper).thumbShadow()
        }
    }
}

/// The track the segments sit in.
struct SegmentTrack: View {
    var body: some View {
        RoundedRectangle(cornerRadius: Theme.Segmented.radius, style: .continuous)
            .fill(Theme.Palette.fill)
    }
}

struct FloatingSurface<S: Shape>: View {
    let shape: S

    var body: some View {
        shape.fill(Theme.Palette.paper).cardShadow()
    }
}

extension View {
    /// A floating control's surface on `self`: solid white, hairline, card
    /// shadow (the shadow sits on the shape, not on the content).
    func glassSurface<S: Shape>(_ shape: S) -> some View {
        background(FloatingSurface(shape: shape))
            .overlay(shape.stroke(Theme.Palette.hairline, lineWidth: 1))
    }

    /// Solid canvas with a hairline edge: the surface for anything that
    /// holds content. No shadow.
    func paperSurface<S: Shape>(_ shape: S) -> some View {
        background(shape.fill(Theme.Palette.paper))
            .overlay(shape.stroke(Theme.Palette.hairline, lineWidth: 1))
    }

    /// For `.background`: the surface of a floating control. See
    /// `FloatingSurface`.
    func floatingSurface<S: Shape>(_ shape: S) -> some View {
        FloatingSurface(shape: shape)
    }

    /// `shadow.card`, neutral black and quiet: a contact shadow (0 1 2, 5%)
    /// and a soft one (0 4 16, 6%). Floating cards, menus and panels only;
    /// captures never get a shadow.
    func cardShadow() -> some View {
        shadow(color: .black.opacity(0.05), radius: 1, x: 0, y: 1)
            .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: 4)
    }

    /// `shadow.thumb`: the selected segment (0 1 1, 8%).
    func thumbShadow() -> some View {
        shadow(color: .black.opacity(0.08), radius: 0.5, x: 0, y: 1)
    }
}
