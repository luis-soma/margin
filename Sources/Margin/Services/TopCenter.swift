import AppKit

/// Where every small Margin surface lives: top center of the screen you're
/// looking at, hanging just under the menu bar and the notch.
@MainActor
enum TopCenter {
    /// The screen with the mouse, else the key window's, else the main one.
    static var screen: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSApp.keyWindow?.screen ?? NSScreen.main
    }

    /// The y coordinate (AppKit, bottom-up) of the usable top edge: under
    /// the menu bar, and under the notch on screens that have one.
    static func top(of screen: NSScreen) -> CGFloat {
        var top = screen.visibleFrame.maxY
        if #available(macOS 12.0, *) {
            top = min(top, screen.frame.maxY - screen.safeAreaInsets.top)
        }
        return top
    }

    /// How far the usable top edge sits below the top of the screen.
    static func inset(of screen: NSScreen) -> CGFloat {
        screen.frame.maxY - top(of: screen)
    }

    /// Origin for a window of `size` centered on the screen (and its notch),
    /// with its top edge `gap` points under the menu bar.
    static func origin(for size: CGSize, on screen: NSScreen, gap: CGFloat = 0) -> CGPoint {
        CGPoint(x: (screen.frame.midX - size.width / 2).rounded(), y: (top(of: screen) - gap - size.height).rounded())
    }
}
