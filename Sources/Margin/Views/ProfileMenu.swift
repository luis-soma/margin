import SwiftUI

/// The menu on your name at the bottom of the sidebar: the settings you
/// reach for while working, and the way to all of them. How Margin helps
/// you document (reminder or automatic), Intelligence on or off, Update
/// Margin (team builds only), then Settings. One card, the capture card's
/// surface; rows 32 tall with an icon, like the sidebar's.
struct ProfileMenu: View {
    @EnvironmentObject private var autoCapture: AutoCapture
    @EnvironmentObject private var intelligence: Intelligence
    @ObservedObject private var updater = AppModel.shared.updater
    let openSettings: () -> Void

    static let width: CGFloat = 264

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            // Documenting: the same switch as in Settings, and what it means.
            VStack(alignment: .leading, spacing: Theme.Space.x2) {
                Text("Documenting")
                    .font(Theme.Typography.ui(Theme.Typography.caption))
                    .foregroundStyle(Theme.Palette.ink3)
                DocumentingSwitch()
                ZStack(alignment: .topLeading) {
                    Text(DocumentingSwitch.line(automatic: autoCapture.isEnabled))
                        .font(Theme.Typography.ui(Theme.Typography.caption))
                        .foregroundStyle(Theme.Palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                        .id(autoCapture.isEnabled)
                        .transition(.blurFade)
                }
            }
            .padding(.horizontal, Theme.Space.x2)
            .padding(.top, Theme.Space.x2)
            .padding(.bottom, Theme.Space.x3)

            rule

            MenuRow(title: "Intelligence",
                    detail: intelligence.config.hasGemini ? "Notes, summaries and Ask" : "Add a Gemini key in Settings",
                    action: { if intelligence.config.hasGemini || intelligence.isEnabled { intelligence.isEnabled.toggle() } }) {
                IntelligenceGlyph()
            } accessory: {
                Toggle("", isOn: $intelligence.isEnabled)
                    .labelsHidden()
                    .toggleStyle(InkSwitch())
                    .controlSize(.mini)
                    .disabled(!intelligence.config.hasGemini && !intelligence.isEnabled)
            }

            if !BuildInfo.isRelease {
                MenuRow(title: "Update Margin", detail: updateLine, action: AppModel.shared.updateMargin) {
                    UpdateGlyph()
                } accessory: {
                    EmptyView()
                }
                .disabled(updater.state.isBusy)
            }

            rule

            MenuRow(title: "Settings", action: openSettings) {
                SettingsGlyph()
            } accessory: {
                Text("⌘,")
                    .font(Theme.Typography.ui(Theme.Typography.caption))
                    .foregroundStyle(Theme.Palette.ink3)
            }
        }
        .padding(Theme.Space.x1 + 2)
        .frame(width: Self.width)
        .background(FloatingSurface(shape: shape, frosted: true))
    }

    private var rule: some View {
        Rectangle()
            .fill(Theme.Palette.hairline)
            .frame(height: 1)
            .padding(.horizontal, Theme.Space.x2)
            .padding(.vertical, Theme.Space.x1)
    }

    private var updateLine: String? {
        switch updater.state {
        case .idle: return nil
        case .checking: return "Checking…"
        case .building: return "Building…"
        case .installing: return "Restarting…"
        case .upToDate: return "Up to date"
        case let .failed(message): return message
        }
    }
}

/// A row in the menu: an icon, its name (and a line under it), and at the
/// end a switch or a shortcut. The fill on hover, nested in the card's curve.
private struct MenuRow<Icon: View, Accessory: View>: View {
    let title: String
    var detail: String? = nil
    let action: () -> Void
    @ViewBuilder let icon: () -> Icon
    @ViewBuilder let accessory: () -> Accessory
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        // Nested in the card: its radius less the card's padding.
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.inside(Theme.Radius.card, by: Theme.Space.x1 + 2), style: .continuous)
        Button(action: action) {
            HStack(spacing: Theme.Space.x2 + 2) {
                icon()
                    .frame(width: 16, height: 16)
                    .foregroundStyle(hovering ? Theme.Palette.ink : Theme.Palette.ink2)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(Theme.Typography.ui(Theme.Typography.body))
                        .foregroundStyle(Theme.Palette.ink)
                    if let detail {
                        Text(detail)
                            .font(Theme.Typography.ui(Theme.Typography.caption))
                            .foregroundStyle(Theme.Palette.ink3)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: Theme.Space.x2)
                accessory()
            }
            .padding(.horizontal, Theme.Space.x2)
            .frame(minHeight: 32)
            .padding(.vertical, detail == nil ? 0 : Theme.Space.x1)
            .background(shape.fill(hovering && enabled ? Theme.Palette.fillHover : .clear))
            .contentShape(shape)
            .opacity(enabled ? 1 : 0.5)
        }
        .buttonStyle(PressStyle(scale: 0.99))
        .onHover { inside in withAnimation(Theme.Motion.hover) { hovering = inside } }
    }
}

/// Intelligence: Margin's dot with a small spark of light around it.
private struct IntelligenceGlyph: View {
    var body: some View {
        Canvas { context, size in
            let u = size.width / 16
            let style = StrokeStyle(lineWidth: 1.25, lineCap: .round)
            context.fill(Path(ellipseIn: CGRect(x: 6 * u, y: 6 * u, width: 4 * u, height: 4 * u)), with: .foreground)
            var rays = Path()
            for (dx, dy) in [(0.0, -1.0), (0.0, 1.0), (-1.0, 0.0), (1.0, 0.0)] {
                rays.move(to: CGPoint(x: (8 + dx * 4.5) * u, y: (8 + dy * 4.5) * u))
                rays.addLine(to: CGPoint(x: (8 + dx * 6.5) * u, y: (8 + dy * 6.5) * u))
            }
            context.stroke(rays, with: .foreground, style: style)
        }
    }
}

/// Update: a circle closing on an arrow.
private struct UpdateGlyph: View {
    var body: some View {
        Canvas { context, size in
            let u = size.width / 16
            let style = StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round)
            var arc = Path()
            arc.addArc(center: CGPoint(x: 8 * u, y: 8 * u), radius: 5.5 * u,
                       startAngle: .degrees(-60), endAngle: .degrees(250), clockwise: false)
            var head = Path()
            head.move(to: CGPoint(x: 11 * u, y: 2.2 * u))
            head.addLine(to: CGPoint(x: 11 * u, y: 4.8 * u))
            head.addLine(to: CGPoint(x: 13.4 * u, y: 4.8 * u))
            context.stroke(arc, with: .foreground, style: style)
            context.stroke(head, with: .foreground, style: style)
        }
    }
}
