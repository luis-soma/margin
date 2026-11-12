import AppKit
import MarginKit
import SwiftUI

/// Margin's own capture overlay: dims every screen, highlights the window
/// under the cursor, and lets you drag out an area with its size shown live.
/// Click a window to take just that window. Tab (or ← and →) switches
/// between an image and a short recording; Esc cancels.
@MainActor
final class RegionOverlay {
    enum Mode: String {
        case image, recording
    }

    enum Selection {
        /// An area, in Core Graphics global coordinates (top-left origin).
        case area(CGRect)
        /// A whole window, with its frame in Core Graphics coordinates.
        case window(CGWindowID, CGRect)
    }

    struct Result {
        var selection: Selection
        var mode: Mode
    }

    let state = OverlayState()
    private var panels: [OverlayPanel] = []
    /// A picture of the menu as it was when the capture was chosen, and its
    /// size, so the capture card can take over from it in place.
    private(set) var lastMenu: (image: NSImage, size: CGSize)?
    private var completion: ((Result?) -> Void)?
    /// Every app's ordinary windows, Margin's included (its archive can be
    /// captured like any other window), front to back in AppKit coordinates.
    private var windows: [(id: CGWindowID, frame: CGRect, own: Bool)] = []
    private var monitors: [Any] = []
    /// The app that was in front, to hand the keyboard back to afterwards.
    private var previousApp: NSRunningApplication?
    /// Counts overlays shown, so a leaving animation only closes its own.
    private var generation = 0
    /// Playing the exit: input is ignored until it's gone.
    private var leaving = false
    /// Margin's own windows (the repo, settings) and the window that was right
    /// behind each, so they stay exactly where they were while the overlay is up.
    private var ownWindows: [(window: NSWindow, behind: Int?)] = []

    var isShowing: Bool { !panels.isEmpty }

    /// The open menu's size, for the nudge to stretch into exactly.
    static func openMenuSize(mode: Mode = .image) -> CGSize {
        let state = OverlayState()
        state.mode = mode
        state.phase = .open
        return NSHostingView(rootView: OverlayPill(state: state)).fittingSize
    }

    /// - Parameter inPlace: the nudge has already become the menu's shape
    ///   where the menu sits, so it's there at once instead of dropping in.
    func begin(mode: Mode, hint: String?, inPlace: Bool = false, completion: @escaping (Result?) -> Void) {
        if isShowing { finish(nil) }
        self.completion = completion
        state.mode = mode
        state.hint = hint
        state.dragStart = nil
        state.dragCurrent = nil
        state.phase = inPlace ? .open : .hidden
        state.partsHidden = false
        generation += 1
        leaving = false
        windows = Self.visibleWindows()
        state.hover = windowFrame(at: NSEvent.mouseLocation)

        for screen in NSScreen.screens {
            let panel = OverlayPanel(screen: screen, overlay: self)
            // The dimming fades in rather than snapping on.
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
            panels.append(panel)
        }
        // The menu arrives in two steps, like the nudge: a small capsule with
        // the two mode icons drops in, then the menu opens out of it, its parts
        // arriving left to right. From the nudge it's already there.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            guard let self, self.isShowing, !inPlace else { return }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.76)) { self.state.phase = .mark }
            // The notch swells as the bar drops out of it.
            NotchPulse.shared.release()
        }
        // The drop-in keeps its pace; the opening follows sooner and quicker.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) { [weak self] in
            guard let self, self.isShowing, self.state.phase == .mark else { return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { self.state.phase = .open }
        }
        // Margin takes the keyboard and cursor while the overlay is up
        // (a background app can't set the cursor), and gives them back after.
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        // The overlay must leave Margin's other windows (the repo) alone. The
        // panel under the cursor becomes key and main first, so activating
        // Margin brings forward only it; anything that still moves is put back.
        if previousApp != nil { rememberOwnWindows() }
        let mouse = NSEvent.mouseLocation
        if let panel = panels.first(where: { $0.frame.contains(mouse) }) ?? panels.first {
            panel.makeKey()
            panel.makeMain()
        }
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
        keepOwnWindowsInPlace()
        // Activation lands a moment later; check again once it has.
        for delay in [0.05, 0.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.isShowing else { return }
                self.keepOwnWindowsInPlace()
            }
        }
        NSCursor.crosshair.push()

        // If another app keeps the keyboard, still let Esc and Tab work.
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            Task { @MainActor in self?.handleKey(event.keyCode) }
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self, self.isShowing else { return event }
            return self.handleKey(event.keyCode) ? nil : event
        }) { monitors.append(monitor) }
        refresh()
    }

    /// Cancelled (Esc, or the shortcut again): the entrance in reverse. The
    /// parts leave right to left, the menu folds back into its icons and
    /// rises away as the dimming fades. A capture closes at once instead, so
    /// the menu isn't in the picture.
    func cancel() {
        guard isShowing, !leaving else { return }
        leaving = true
        let current = generation
        // First the parts fade out in place, right to left, while the menu
        // keeps its size; only then does it fold back into its icons.
        state.partsHidden = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) { [weak self] in
            guard let self, self.generation == current, self.isShowing else { return }
            withAnimation(.spring(response: 0.22, dampingFraction: 0.94)) { self.state.phase = .mark }
        }
        // Rising out of view keeps its pace.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { [weak self] in
            guard let self, self.generation == current, self.isShowing else { return }
            withAnimation(.easeIn(duration: 0.18)) { self.state.phase = .hidden }
            // ...and takes it back in as it rises.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { NotchPulse.shared.take() }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                for panel in self.panels { panel.animator().alphaValue = 0 }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.54) { [weak self] in
            guard let self, self.generation == current else { return }
            self.leaving = false
            self.finish(nil)
        }
    }

    // MARK: Input (AppKit global coordinates)

    @discardableResult
    func handleKey(_ code: UInt16) -> Bool {
        switch code {
        case 53: // Esc
            cancel()
            return true
        case _ where leaving:
            return true
        case 48: // Tab
            state.mode = state.mode == .image ? .recording : .image
            return true
        case 123: // ←: Screenshot, the left option
            state.mode = .image
            return true
        case 124: // →: Record, the right option
            state.mode = .recording
            return true
        default:
            return false
        }
    }

    func mouseDown(at point: CGPoint) {
        guard !leaving else { return }
        state.dragStart = point
        state.dragCurrent = point
        refresh()
    }

    func mouseDragged(to point: CGPoint) {
        guard state.dragStart != nil else { return }
        // Stay on the screen the drag started on.
        if let start = state.dragStart, let screen = NSScreen.screens.first(where: { $0.frame.contains(start) }) {
            state.dragCurrent = CGPoint(
                x: min(max(point.x, screen.frame.minX), screen.frame.maxX),
                y: min(max(point.y, screen.frame.minY), screen.frame.maxY)
            )
        } else {
            state.dragCurrent = point
        }
        refresh()
    }

    func mouseUp(at point: CGPoint) {
        guard !leaving, let start = state.dragStart else { return }
        let rect = RegionMath.rect(from: start, to: state.dragCurrent ?? point)
        state.dragStart = nil
        state.dragCurrent = nil
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0

        if !RegionMath.isClick(rect) {
            finish(Result(selection: .area(RegionMath.flip(rect, primaryHeight: primaryHeight)), mode: state.mode))
        } else if let window = windows.first(where: { $0.frame.contains(point) }) {
            finish(Result(selection: .window(window.id, RegionMath.flip(window.frame, primaryHeight: primaryHeight)), mode: state.mode))
        } else if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) {
            finish(Result(selection: .area(RegionMath.flip(screen.frame, primaryHeight: primaryHeight)), mode: state.mode))
        } else {
            refresh()
        }
    }

    func mouseMoved(to point: CGPoint) {
        guard state.dragStart == nil else { return }
        let hover = windowFrame(at: point)
        if hover != state.hover {
            state.hover = hover
            refresh()
        }
    }

    /// The current selection in AppKit coordinates, if dragging.
    var dragRect: CGRect? {
        guard let start = state.dragStart, let current = state.dragCurrent else { return nil }
        let rect = RegionMath.rect(from: start, to: current)
        return RegionMath.isClick(rect) ? nil : rect
    }

    // MARK: Helpers

    private func finish(_ result: Result?) {
        guard isShowing || completion != nil else { return }
        lastMenu = result == nil ? nil : menuPicture()
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        for panel in panels { panel.orderOut(nil) }
        if !panels.isEmpty { NSCursor.pop() }
        panels = []
        previousApp?.activate()
        previousApp = nil
        ownWindows = []
        let completion = self.completion
        self.completion = nil
        completion?(result)
    }

    /// The menu on the screen the card will appear on.
    /// Only its words and icons: the card's own shape stands in for the
    /// menu's surface, so the picture must not carry a second one.
    private func menuPicture() -> (image: NSImage, size: CGSize)? {
        guard let screen = TopCenter.screen,
              let pill = panels.first(where: { $0.screen == screen })?.pill ?? panels.first?.pill else { return nil }
        let dark = pill.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let renderer = ImageRenderer(content: OverlayPill(state: state, bare: true)
            .environment(\.colorScheme, dark ? .dark : .light))
        renderer.scale = screen.backingScaleFactor
        guard let image = renderer.nsImage else { return nil }
        return (image, image.size)
    }

    private func rememberOwnWindows() {
        let own = NSApp.windows.filter { $0.isVisible && !($0 is NSPanel) && $0.level == .normal }
        guard !own.isEmpty else { return }
        // Front-to-back order of every app's ordinary windows, to remember
        // what each of Margin's windows sat on top of.
        let stack = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
            .filter { ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 }
            .compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue }
        let ownNumbers = Set(own.map(\.windowNumber))
        for window in own {
            let behind = stack.firstIndex(of: window.windowNumber).flatMap { index in
                stack[(index + 1)...].first { !ownNumbers.contains($0) }
            }
            ownWindows.append((window, behind))
        }
    }

    /// Puts any of Margin's windows that moved back exactly where they were in
    /// the stack. They stay on screen the whole time; this only undoes a move.
    private func keepOwnWindowsInPlace() {
        guard !ownWindows.isEmpty else { return }
        let onScreen = Set((CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
            .compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue })
        for (window, behind) in ownWindows where window.isVisible {
            if let behind, onScreen.contains(behind) {
                window.order(.above, relativeTo: behind)
            }
        }
    }

    private func refresh() {
        for panel in panels { panel.contentView?.needsDisplay = true }
    }

    /// Draws right away instead of on the next pass (used by tests).
    func redrawNow() {
        for panel in panels { panel.contentView?.display() }
    }

    /// The window to highlight under the pointer: the top one there,
    /// Margin's archive included.
    private func windowFrame(at point: CGPoint) -> CGRect? {
        windows.first(where: { $0.frame.contains(point) })?.frame
    }

    /// Normal windows of every app, Margin's marked as its own, front to back,
    /// in AppKit coordinates.
    static func visibleWindows() -> [(id: CGWindowID, frame: CGRect, own: Bool)] {
        let own = ProcessInfo.processInfo.processIdentifier
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue, layer == 0,
                  let number = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width > 40, bounds.height > 40 else { return nil }
            if let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue, alpha < 0.05 { return nil }
            return (CGWindowID(number), RegionMath.flip(bounds, primaryHeight: primaryHeight), pid == own)
        }
    }
}

/// What the overlay shows; observed by the hint pill.
@MainActor
final class OverlayState: ObservableObject {
    /// The capture menu's entrance: nothing, then a small capsule with just
    /// the two mode icons, then the whole menu opening out of it.
    enum Phase { case hidden, mark, open }

    @Published var mode: RegionOverlay.Mode = .image
    @Published var hint: String?
    @Published var phase: Phase = .hidden
    /// Leaving: the menu's parts fade out in place before it folds up.
    @Published var partsHidden = false
    var dragStart: CGPoint?
    var dragCurrent: CGPoint?
    var hover: CGRect?
}

// MARK: - Panels

/// One borderless panel per screen, above everything including the menu bar.
@MainActor
final class OverlayPanel: KeyablePanel {
    /// The capture menu's view.
    private(set) var pill: NSView?
    /// Main as well as key, so activating Margin for the overlay brings
    /// forward only the overlay, not the repo.
    override var canBecomeMain: Bool { true }

    init(screen: NSScreen, overlay: RegionOverlay) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let view = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size), overlay: overlay)
        contentView = view

        let pill = FirstClickHostingView(rootView: OverlayPill(state: overlay.state))
        self.pill = pill
        pill.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pill)
        NSLayoutConstraint.activate([
            pill.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            // Top center, under the menu bar and notch, like the capture card.
            pill.topAnchor.constraint(equalTo: view.topAnchor, constant: TopCenter.inset(of: screen) + 8),
        ])
    }
}

@MainActor
final class OverlayView: NSView {
    private weak var overlay: RegionOverlay?

    init(frame: NSRect, overlay: RegionOverlay) {
        self.overlay = overlay
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate],
            owner: self
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }

    override func keyDown(with event: NSEvent) {
        if overlay?.handleKey(event.keyCode) != true { super.keyDown(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        overlay?.mouseDown(at: NSEvent.mouseLocation)
    }

    override func mouseDragged(with event: NSEvent) {
        overlay?.mouseDragged(to: NSEvent.mouseLocation)
    }

    override func mouseUp(with event: NSEvent) {
        overlay?.mouseUp(at: NSEvent.mouseLocation)
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.crosshair.set()
        overlay?.mouseMoved(to: NSEvent.mouseLocation)
    }

    override func draw(_ dirtyRect: NSRect) {
        drawOverlay()
    }

    private func drawOverlay() {
        guard let overlay, let window else { return }
        let origin = window.frame.origin
        func local(_ rect: CGRect) -> CGRect { rect.offsetBy(dx: -origin.x, dy: -origin.y) }

        NSColor.black.withAlphaComponent(0.34).setFill()
        bounds.fill()

        if let drag = overlay.dragRect {
            let rect = local(drag)
            NSColor.clear.setFill()
            rect.fill(using: .copy)
            stroke(rect, color: NSColor.white.withAlphaComponent(0.95), width: 1)
            drawSize(of: drag, at: rect)
        } else if let hover = overlay.state.hover {
            let rect = local(hover).intersection(bounds)
            NSColor.clear.setFill()
            rect.fill(using: .copy)
            NSColor.white.withAlphaComponent(0.06).setFill()
            rect.fill(using: .sourceOver)
            stroke(rect.insetBy(dx: 1, dy: 1), color: NSColor.white.withAlphaComponent(0.85), width: 2)
        }
    }

    private func stroke(_ rect: CGRect, color: NSColor, width: CGFloat) {
        // A soft dark line outside keeps it visible on white content.
        NSColor.black.withAlphaComponent(0.25).setStroke()
        let shadow = NSBezierPath(rect: rect.insetBy(dx: -width, dy: -width))
        shadow.lineWidth = 1
        shadow.stroke()
        color.setStroke()
        let path = NSBezierPath(rect: rect.insetBy(dx: -width / 2, dy: -width / 2))
        path.lineWidth = width
        path.stroke()
    }

    private func drawSize(of selection: CGRect, at rect: CGRect) {
        let text = "\(Int(selection.width.rounded())) × \(Int(selection.height.rounded()))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Theme.Typography.nsMono(11, .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let label = CGSize(width: size.width + 14, height: size.height + 6)
        let originPoint = RegionMath.labelOrigin(for: rect, labelSize: label, in: bounds)
        let box = CGRect(origin: originPoint, size: label)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
        (text as NSString).draw(at: CGPoint(x: box.minX + 7, y: box.minY + 3), withAttributes: attributes)
    }
}

/// The pill at the top center: the mark, Screenshot / Record, and a hint.
/// The capture menu: Margin's own surface rather than the system's frosted
/// solid white with ink in light mode and the reverse in dark, a crisp
/// hairline and a soft two-layer shadow. The chosen mode is a solid ink chip;
/// keys are spelled out in small monospaced capitals.
private struct OverlayPill: View {
    @ObservedObject var state: OverlayState
    /// Only the words and icons, without the menu's surface: the picture the
    /// capture card keeps while its own shape takes over.
    var bare = false
    @Environment(\.colorScheme) private var scheme
    /// One chip shared by the two modes, so choosing slides it across.
    @Namespace private var chip

    var body: some View {
        let open = state.phase == .open
        let shown = state.phase != .hidden
        let ink = MenuInk(scheme)
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        VStack(spacing: 8) {
            // The tip close to the choices, and as much room after it as the
            // first choice has before it.
            HStack(spacing: 8) {
                HStack(spacing: 0) {
                    segment("Screenshot", mode: .image, titled: open, index: 0, ink: ink) { CaptureGlyph.Image() }
                    segment("Record", mode: .recording, titled: open, index: 1, ink: ink) { CaptureGlyph.Recording() }
                }
                // The app's one switch: a light track round the two choices,
                // so they read as one control and the tip beside them as words.
                .padding(open ? Theme.Segmented.padding : 0)
                .background {
                    if open { SegmentTrack() }
                }
                if open {
                    Text("Drag an area or click a window")
                        .font(Theme.Typography.ui(12))
                        .foregroundStyle(ink.muted)
                        .fixedSize()
                        .leaving(2, state.partsHidden)
                        .transition(.arrive(2))
                    // No key hints: just the two choices and the tip.
                }
            }
            .padding(.leading, 5)
            .padding(.trailing, open ? 14 : 5)
            .frame(height: 38)
            // Nothing draws outside the menu, even mid-animation.
            .clipShape(shape)
            // The shadow belongs to the surface only, never to the words on it.
            .background(FloatingSurface(shape: shape).opacity(bare ? 0 : 1))
            .overlay(shape.strokeBorder(ink.hairline, lineWidth: 1).opacity(bare ? 0 : 1))
            // Drops in from under the menu bar, sharpening as it lands.
            .scaleEffect(shown ? 1 : 0.9, anchor: .top)
            .blur(radius: shown ? 0 : 4)
            .offset(y: shown ? 0 : -46)
            .opacity(shown ? 1 : 0)
            if open, !bare, let hint = state.hint {
                Text(hint)
                    .font(Theme.Typography.ui(12))
                    .foregroundStyle(ink.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(FloatingSurface(shape: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).strokeBorder(ink.hairline, lineWidth: 1))
                    .leaving(4, state.partsHidden)
                    .transition(.arrive(4))
            }
        }
        // The chip slides with a quick spring that settles without wobbling.
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: state.mode)
        .fixedSize()
    }

    /// One mode: its icon from the start, its name once the menu opens. The
    /// chosen one is a solid chip in the ink color.
    private func segment<Icon: View>(_ title: String, mode: RegionOverlay.Mode, titled: Bool, index: Int, ink: MenuInk, @ViewBuilder icon: () -> Icon) -> some View {
        let chosen = state.mode == mode
        return Button {
            state.mode = mode
        } label: {
            HStack(spacing: titled ? 6 : 0) {
                icon()
                    .frame(width: Theme.Segmented.icon + 1, height: Theme.Segmented.icon + 1)
                if titled {
                    Text(title)
                        .font(Theme.Typography.ui(Theme.Typography.control))
                        .fixedSize()
                        .leaving(index, state.partsHidden)
                        .transition(.arrive(index))
                }
            }
            .foregroundStyle(Theme.Segmented.label(chosen))
            .padding(.horizontal, titled ? Theme.Space.x3 : 7)
            .frame(height: Theme.Segmented.segment)
            .background {
                if chosen {
                    SegmentThumb().matchedGeometryEffect(id: "chip", in: chip)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.Segmented.thumbRadius, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private struct Key: View {
        let label: String
        let ink: MenuInk
        init(_ label: String, ink: MenuInk) { self.label = label; self.ink = ink }
        var body: some View {
            Text(label)
                .font(Theme.Typography.mono(9, .medium))
                .foregroundStyle(ink.muted)
                .padding(.horizontal, 5)
                .frame(height: 17)
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(ink.hairline, lineWidth: 1))
        }
    }
}

/// Margin's own line icons for the capture modes: one thin stroke, closed
/// frames with ever so slightly rounded corners, drawn on a 14 pt grid.
private enum CaptureGlyph {
    static let line: CGFloat = 1.2

    fileprivate static func stroke(_ path: Path, in context: GraphicsContext, scale k: CGFloat) {
        context.stroke(path, with: .foreground, style: StrokeStyle(lineWidth: line * k, lineCap: .round, lineJoin: .round))
    }

    fileprivate static func frame(_ rect: CGRect, scale k: CGFloat) -> Path {
        Path(roundedRect: CGRect(x: rect.minX * k, y: rect.minY * k, width: rect.width * k, height: rect.height * k),
             cornerSize: CGSize(width: 1.6 * k, height: 1.6 * k), style: .continuous)
    }

    /// A picture: a frame, a horizon running edge to edge, and a sun.
    struct Image: View {
        var body: some View {
            Canvas { context, size in
                let k = size.width / 14
                var path = CaptureGlyph.frame(CGRect(x: 1.5, y: 2.5, width: 11, height: 9), scale: k)
                path.move(to: CGPoint(x: 1.5 * k, y: 9 * k))
                path.addLine(to: CGPoint(x: 5.5 * k, y: 6.6 * k))
                path.addLine(to: CGPoint(x: 12.5 * k, y: 9.6 * k))
                CaptureGlyph.stroke(path, in: context, scale: k)
                context.fill(Path(ellipseIn: CGRect(x: 8.4 * k, y: 4.4 * k, width: 1.7 * k, height: 1.7 * k)), with: .foreground)
            }
        }
    }

    /// A video camera: a body with its lens on the side.
    struct Recording: View {
        var body: some View {
            Canvas { context, size in
                let k = size.width / 14
                // As tall as the picture's frame, so the two read at the same size.
                var path = CaptureGlyph.frame(CGRect(x: 1.1, y: 3, width: 8.4, height: 8), scale: k)
                path.move(to: CGPoint(x: 9.5 * k, y: 6.1 * k))
                path.addLine(to: CGPoint(x: 12.9 * k, y: 4.3 * k))
                path.addLine(to: CGPoint(x: 12.9 * k, y: 9.7 * k))
                path.addLine(to: CGPoint(x: 9.5 * k, y: 7.9 * k))
                CaptureGlyph.stroke(path, in: context, scale: k)
            }
        }
    }
}

/// How the capture menu's parts arrive: each fades in, sharpens and slides a
/// few points into place, a beat after the one before it.
private struct Arrival: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        content
            .opacity(active ? 0 : 1)
            .blur(radius: active ? 3 : 0)
            .scaleEffect(active ? 0.94 : 1, anchor: .leading)
            .offset(x: active ? -6 : 0)
    }
}

private extension View {
    /// Fades a part out in place when the menu is leaving, the last part to
    /// arrive going first.
    func leaving(_ index: Int, _ hidden: Bool) -> some View {
        modifier(Arrival(active: hidden))
            .animation(hidden ? .easeIn(duration: 0.09).delay(Double(4 - index) * 0.015) : nil, value: hidden)
    }
}

private extension AnyTransition {
    /// Arrives `index` beats (30 ms each) after the menu starts opening.
    static func arrive(_ index: Int) -> AnyTransition {
        .asymmetric(
            insertion: .modifier(active: Arrival(active: true), identity: Arrival(active: false))
                .animation(.spring(response: 0.28, dampingFraction: 0.88).delay(0.02 + Double(index) * 0.03)),
            // On the way out the parts have already faded (see `leaving`).
            removal: .opacity.animation(.easeOut(duration: 0.08))
        )
    }
}
