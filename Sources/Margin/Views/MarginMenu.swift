import AppKit
import SwiftUI

// Margin's own menus: the profile menu's card and rows, for right-click
// menus too, instead of the system's.

/// A menu card: the frosted floating surface, rows inset by 6.
struct MarginMenu<Content: View>: View {
    var width: CGFloat = 236
    @ViewBuilder let content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(Theme.Space.x1 + 2)
            .frame(width: width)
            .background(FloatingSurface(shape: shape, frosted: true))
    }
}

/// One row: one of Margin's drawn icons, the name, a shortcut at the end.
/// 32 tall, the fill nested in the card's curve on hover: the profile
/// menu's rows.
struct MarginMenuItem<Icon: View>: View {
    let title: String
    var shortcut: String? = nil
    let action: () -> Void
    @ViewBuilder let icon: () -> Icon
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.inside(Theme.Radius.card, by: Theme.Space.x1 + 2), style: .continuous)
        Button(action: action) {
            HStack(spacing: Theme.Space.x2 + 2) {
                icon()
                    .frame(width: 16, height: 16)
                    .foregroundStyle(hovering ? Theme.Palette.ink : Theme.Palette.ink2)
                Text(title)
                    .font(Theme.Typography.ui(Theme.Typography.body))
                    .foregroundStyle(Theme.Palette.ink)
                    .lineLimit(1)
                Spacer(minLength: Theme.Space.x2)
                if let shortcut {
                    Text(shortcut)
                        .font(Theme.Typography.ui(Theme.Typography.caption))
                        .foregroundStyle(Theme.Palette.ink3)
                }
            }
            .padding(.horizontal, Theme.Space.x2)
            .frame(height: 32)
            .background(shape.fill(hovering ? Theme.Palette.fillHover : .clear))
            .contentShape(shape)
        }
        .buttonStyle(PressStyle(scale: 0.99))
        .onHover { inside in withAnimation(Theme.Motion.hover) { hovering = inside } }
    }
}

/// The line between groups of rows.
struct MarginMenuRule: View {
    var body: some View {
        Rectangle()
            .fill(Theme.Palette.hairline)
            .frame(height: 1)
            .padding(.horizontal, Theme.Space.x2)
            .padding(.vertical, Theme.Space.x1)
    }
}

// MARK: - Right click

extension View {
    /// A right-click (or Control-click) on this view, for Margin's own
    /// menu. Every other click goes through to the view as before.
    func onRightClick(_ action: @escaping () -> Void) -> some View {
        overlay(RightClickCatcher(action: action))
    }
}

private struct RightClickCatcher: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.action = action
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.action = action
    }

    final class CatcherView: NSView {
        var action: (() -> Void)?

        /// Only a right-click or Control-click lands here; the rest passes through.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            let isRight = event.type == .rightMouseDown
                || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            return isRight ? super.hitTest(point) : nil
        }

        override func rightMouseDown(with event: NSEvent) { action?() }

        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) { action?() }
        }
    }
}
