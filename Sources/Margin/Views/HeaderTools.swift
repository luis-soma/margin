import SwiftUI

// MARK: - Header tools

/// An icon in the archive's header: bare until you point at it, then a light
/// fill behind it (darker while what it opens is open). It gives a little
/// when pressed, and resting on it shows its name, and a line on what it
/// does, under it.
struct HeaderTool<Label: View>: View {
    let help: String
    /// A line under the name in the tooltip: what it does.
    var detail: String? = nil
    var active = false
    /// Which side of the tool the tooltip lines up with.
    var tipAlign: HorizontalAlignment = .trailing
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label()
                .foregroundStyle(active || hovering ? Theme.Palette.ink : Theme.Palette.ink2)
                .frame(width: RepoHeader.toolWidth, height: RepoHeader.toolHeight)
                .background(
                    RoundedRectangle(cornerRadius: RepoHeader.toolRadius, style: .continuous)
                        .fill(active ? Theme.Palette.fillSelected : hovering ? Theme.Palette.fillHover : .clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: RepoHeader.toolRadius, style: .continuous))
        }
        .buttonStyle(PressStyle())
        .onHover { inside in withAnimation(Theme.Motion.hover) { hovering = inside } }
        .toolTip(help, detail, align: tipAlign, enabled: !active)
        .accessibilityLabel(help)
    }
}

/// Where a tooltip hangs: under the control, or over it (for controls at
/// the bottom of the window).
enum TipEdge { case below, above }

private struct HoverTip: ViewModifier {
    let title: String
    let detail: String?
    let edge: TipEdge
    let align: HorizontalAlignment
    let enabled: Bool
    @State private var shown = false
    @State private var work: DispatchWorkItem?

    func body(content: Content) -> some View {
        content
            .onHover { inside in inside && enabled ? showSoon() : hide() }
            .simultaneousGesture(TapGesture().onEnded { hide() })
            .onChange(of: enabled) { if !$0 { hide() } }
            .overlay(alignment: Alignment(horizontal: align, vertical: edge == .below ? .bottom : .top)) {
                if shown {
                    ToolTip(title: title, detail: detail)
                        .fixedSize()
                        .frame(height: 0, alignment: edge == .below ? .top : .bottom)
                        .offset(y: edge == .below ? Theme.Space.x2 : -Theme.Space.x2)
                        .allowsHitTesting(false)
                        .transition(.pop(from: edge == .below ? .top : .bottom))
                        .zIndex(10)
                }
            }
    }

    private func showSoon() {
        work?.cancel()
        let next = DispatchWorkItem { withAnimation(Theme.Motion.enter) { shown = true } }
        work = next
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: next)
    }

    private func hide() {
        work?.cancel()
        work = nil
        if shown { withAnimation(Theme.Motion.exit) { shown = false } }
    }
}

extension View {
    /// Margin's tooltip, the same ink card on every control: its name, and
    /// what it does in a line. Shows after resting on it for half a second.
    func toolTip(_ title: String, _ detail: String? = nil, edge: TipEdge = .below,
                 align: HorizontalAlignment = .trailing, enabled: Bool = true) -> some View {
        modifier(HoverTip(title: title, detail: detail, edge: edge, align: align, enabled: enabled))
    }
}

/// The tools' tooltip: the name, and what it does in one line. Ink card,
/// white words.
struct ToolTip: View {
    let title: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(Theme.Typography.ui(Theme.Typography.caption, .medium))
                .foregroundStyle(Theme.Palette.paper)
                .lineLimit(1)
                .fixedSize()
            if let detail {
                // One line, always: a tooltip that wraps gets cut off.
                Text(detail)
                    .font(Theme.Typography.ui(Theme.Typography.caption))
                    .foregroundStyle(Theme.Palette.paper.opacity(0.7))
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, Theme.Space.x2 + 2)
        .padding(.vertical, Theme.Space.x1 + 2)
        .background(Theme.Palette.ink, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
    }
}

/// The thin upright line between search and the other tools.
struct HeaderDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.Palette.hairline)
            .frame(width: 1, height: 16)
    }
}

/// Hand off to an agent: an open hand with an AI star over it and a small
/// one beside it (design/handoff-icon.svg, drawn on a 64 grid).
struct HandoffGlyph: View {
    var lineWidth: CGFloat = 1.25

    private static let outline = [
        // Cuff
        "M5.5 31.5 L13.5 32.8 C14.6 33 15.2 33.9 15.1 35 L14.4 48.6 C14.3 49.7 13.4 50.4 12.3 50.3 L5.6 49.8 C4.6 49.7 3.9 48.9 3.9 47.9 L3.9 33.2 C3.9 32.1 4.5 31.4 5.5 31.5 Z",
        // Palm
        "M15 34.5 C20 32.6 25.5 31.8 30.5 33.2 C34.5 34.4 38 36.6 42 37.6 L51.5 35.2 C55.8 34.1 59.6 35.6 58.4 38.2 C53.6 42.6 46 46.6 38 48.4 C30 50.2 22 49.8 15 47.6",
        // Thumb
        "M27 41 L37.6 41.2 C40.8 41.3 42.6 39.6 42 37.6",
        // AI star
        "M40 9 C40.8 14.5 42.8 16.5 48 17.2 C42.8 17.9 40.8 19.9 40 25.4 C39.2 19.9 37.2 17.9 32 17.2 C37.2 16.5 39.2 14.5 40 9 Z",
    ]
    private static let companion = "M51.5 4.5 C51.8 6.6 52.6 7.4 54.7 7.7 C52.6 8 51.8 8.8 51.5 10.9 C51.2 8.8 50.4 8 48.3 7.7 C50.4 7.4 51.2 6.6 51.5 4.5 Z"

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 64
            let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
            for path in Self.outline {
                context.stroke(SVGPath.make(path, scale: scale), with: .foreground, style: style)
            }
            context.fill(SVGPath.make(Self.companion, scale: scale), with: .foreground)
        }
    }
}

/// Three dots stacked: more options.
struct MoreGlyph: View {
    var body: some View {
        VStack(spacing: 2.6) {
            ForEach(0..<3, id: \.self) { _ in
                Circle().frame(width: 2.6, height: 2.6)
            }
        }
    }
}

/// Absolute M, L, C and Z, enough for icons drawn as SVG.
enum SVGPath {
    static func make(_ d: String, scale: CGFloat) -> Path {
        var path = Path()
        var tokens = d.replacingOccurrences(of: ",", with: " ").split(separator: " ").map(String.init)[...]
        var command = ""
        func number() -> CGFloat { CGFloat(Double(tokens.popFirst() ?? "0") ?? 0) * scale }
        func point() -> CGPoint { let x = number(); return CGPoint(x: x, y: number()) }
        while let token = tokens.first {
            if let letter = token.first, letter.isLetter {
                command = String(letter)
                tokens = tokens.dropFirst()
                // A letter glued to its first number ("M5.5").
                if token.count > 1 { tokens.insert(String(token.dropFirst()), at: tokens.startIndex) }
                if command == "Z" { path.closeSubpath(); continue }
            }
            switch command {
            case "M": path.move(to: point()); command = "L"
            case "L": path.addLine(to: point())
            case "C":
                let c1 = point(), c2 = point()
                path.addCurve(to: point(), control1: c1, control2: c2)
            default: tokens = tokens.dropFirst()
            }
        }
        return path
    }
}

// MARK: - Options menu

/// How Margin helps you document: it captures on its own, or it reminds you
/// to. One or the other, never both: a switch, with a line on what the
/// choice means under it.
struct CaptureOptionsMenu: View {
    @EnvironmentObject private var autoCapture: AutoCapture

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        VStack(alignment: .leading, spacing: Theme.Space.x2) {
            Text("Documenting")
                .font(Theme.Typography.ui(Theme.Typography.caption))
                .foregroundStyle(Theme.Palette.ink3)
                .padding(.horizontal, Theme.Space.x1)
            DocumentingSwitch()
            ZStack(alignment: .topLeading) {
                Text(DocumentingSwitch.line(automatic: autoCapture.isEnabled))
                    .font(Theme.Typography.ui(Theme.Typography.caption))
                    .foregroundStyle(Theme.Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Theme.Space.x1)
                    .id(autoCapture.isEnabled)
                    // The old line and the new one cross, each softly blurred.
                    .transition(.blurFade)
            }
        }
        .padding(Theme.Space.x3)
        .frame(width: 260)
        .background(FloatingSurface(shape: shape))
        .overlay(shape.strokeBorder(Theme.Palette.hairline, lineWidth: 1))
    }
}

/// Reminder or Automatic: a white thumb that slides between the two.
/// The same control in the documenting menu and in Settings.
struct DocumentingSwitch: View {
    @EnvironmentObject private var autoCapture: AutoCapture
    @Namespace private var thumb

    static func line(automatic: Bool) -> String {
        automatic
            ? "Margin keeps a capture whenever your design moves on. You add the why when you like."
            : "Margin asks once after a quiet stretch. Nothing is kept unless you capture it."
    }

    var body: some View {
        HStack(spacing: 0) {
            choice(automatic: false, "Reminder") { BellGlyph() }
            choice(automatic: true, "Automatic") { DocumentingGlyph() }
        }
        .padding(Theme.Segmented.padding)
        .background(SegmentTrack())
    }

    private func choice<Icon: View>(automatic: Bool, _ title: String, @ViewBuilder icon: () -> Icon) -> some View {
        let selected = autoCapture.isEnabled == automatic
        return Button {
            guard !selected else { return }
            // The white thumb slides across; the words under it cross-fade.
            withAnimation(Theme.Motion.snappy) { set(automatic) }
        } label: {
            HStack(spacing: 6) {
                icon().frame(width: 12, height: 12)
                Text(title).font(Theme.Typography.ui(Theme.Typography.control))
            }
            .foregroundStyle(Theme.Segmented.label(selected))
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Theme.Space.x3)
            .frame(height: Theme.Segmented.segment)
            .background {
                if selected {
                    SegmentThumb().matchedGeometryEffect(id: "thumb", in: thumb)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }

    private func set(_ automatic: Bool) {
        autoCapture.isEnabled = automatic
        UserDefaults.standard.set(!automatic, forKey: "nudgesEnabled")
        AppModel.shared.nudge?.isEnabled = !automatic
    }
}

private struct OptionRow: View {
    let title: String
    let on: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                Text(title)
                    .font(Archive.sans(13))
                    .foregroundStyle(Archive.ink)
                Spacer(minLength: 12)
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Archive.ink)
                    .opacity(on ? 1 : 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.06 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
