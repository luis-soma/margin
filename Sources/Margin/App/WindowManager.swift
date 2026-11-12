import AppKit
import SwiftUI

/// Opens plain AppKit windows hosting SwiftUI views. A menu bar app has no
/// main window, and managing these by hand keeps SwiftUI from opening a
/// window at launch.
@MainActor
final class WindowManager {
    private var windows: [String: NSWindow] = [:]
    private var placers: [String: TrafficLights] = [:]

    func show<Content: View>(
        id: String,
        title: String,
        size: NSSize,
        floating: Bool = false,
        chromeless: Bool = false,
        trafficLights: CGPoint? = nil,
        @ViewBuilder content: () -> Content
    ) {
        // A window is made once and kept while Margin runs, so closing it and
        // opening it again brings it back where you left it (snapped to half
        // the screen, resized, on another display). Only a new window gets the
        // default size, centered.
        let existing = windows[id]
        let window = existing ?? makeWindow(size: size, chromeless: chromeless)
        windows[id] = window
        let previousFrame = existing?.frame
        if let trafficLights, placers[id] == nil {
            placers[id] = TrafficLights(window: window, origin: trafficLights)
            // The header row holds controls (the slider), so the window moves
            // only from the corner around its buttons.
            (window as? MarginWindow)?.dragZone = CGRect(x: 0, y: 0, width: trafficLights.x + 78, height: trafficLights.y * 2)
        }
        window.title = title
        window.level = floating ? .floating : .normal
        window.contentViewController = NSHostingController(rootView: content())
        if let previousFrame {
            // New content resizes the window to fit it; put it back.
            window.setFrame(previousFrame, display: false)
        } else {
            window.setContentSize(size)
            window.center()
        }
        ensureEditMenu()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        placers[id]?.place()
    }

    /// You're working in one of Margin's own windows (the archive, a
    /// project): Margin is active and one of them has the keyboard.
    var hasFocus: Bool {
        guard NSApp.isActive, let key = NSApp.keyWindow else { return false }
        return windows.values.contains { $0 === key }
    }

    /// The window shown under `id`, if it was ever opened.
    func window(id: String) -> NSWindow? { windows[id] }

    func close(id: String) {
        windows[id]?.close()
    }

    /// Menu bar apps may have no main menu, which silently breaks ⌘C/⌘V/⌘Z in
    /// text fields. Add a standard Edit menu if one is missing.
    private func ensureEditMenu() {
        let mainMenu: NSMenu
        if let existing = NSApp.mainMenu {
            mainMenu = existing
        } else {
            mainMenu = NSMenu()
            mainMenu.addItem(NSMenuItem()) // app menu placeholder
            NSApp.mainMenu = mainMenu
        }
        guard mainMenu.item(withTitle: "Edit") == nil else { return }

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let item = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        item.submenu = edit
        mainMenu.addItem(item)
    }

    /// `chromeless` hides the title bar but keeps the traffic lights, so the
    /// content runs edge to edge and the window can be dragged by its background.
    private func makeWindow(size: NSSize, chromeless: Bool) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        if chromeless { style.insert(.fullSizeContentView) }
        let window = MarginWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: style,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        if chromeless {
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.backgroundColor = Brand.backgroundNS
        }
        return window
    }
}

/// Keeps a window's traffic lights where the design puts them, rather than
/// AppKit's default spot in a 28 pt title bar. AppKit lays the buttons out
/// again on resize, focus and full screen, so this puts them back each time.
@MainActor
final class TrafficLights {
    /// x of the close button's left edge and y of the buttons' center, from the top left.
    let origin: CGPoint
    private weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var appearance: NSKeyValueObservation?
    private var placing = false

    init(window: NSWindow, origin: CGPoint) {
        self.window = window
        self.origin = origin
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            NSWindow.didExitFullScreenNotification, NSWindow.didChangeScreenNotification,
        ]
        for name in names {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.place() }
            })
        }
        // AppKit also moves them back on its own layout passes.
        if let close = window.standardWindowButton(.closeButton) {
            close.postsFrameChangedNotifications = true
            observers.append(center.addObserver(forName: NSView.frameDidChangeNotification, object: close, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.place() }
            })
        }
        // Switching light and dark lays the title bar out again after this
        // fires; put the buttons back once that pass is done.
        appearance = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.placeSoon() }
            }
        }
        observers.append(center.addObserver(forName: NSWindow.didUpdateNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.placeIfMoved() }
        })
        place()
    }

    /// Now and again after AppKit's next layout passes.
    private func placeSoon() {
        place()
        for delay in [0.05, 0.2, 0.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.place() }
        }
    }

    /// Cheap check on every window update: only moves the buttons when
    /// something put them somewhere else.
    private func placeIfMoved() {
        guard let window, let close = window.standardWindowButton(.closeButton), let bar = close.superview else { return }
        let top = origin.y - close.frame.height / 2
        let y = bar.isFlipped ? top : bar.bounds.height - top - close.frame.height
        if abs(close.frame.minX - origin.x) > 0.5 || abs(close.frame.minY - y) > 0.5 { place() }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Native spacing between the buttons, measured once.
    private lazy var spacing: CGFloat = {
        guard let window,
              let close = window.standardWindowButton(.closeButton),
              let mini = window.standardWindowButton(.miniaturizeButton) else { return 20 }
        let measured = mini.frame.minX - close.frame.minX
        return measured > 10 ? measured : 20
    }()

    func place() {
        guard !placing, let window, !window.styleMask.contains(.fullScreen) else { return }
        placing = true
        defer { placing = false }
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let gap = spacing
        // Make the title bar tall enough to center the buttons at origin.y,
        // so they aren't clipped (the title bar is 28 pt by default).
        if let bar = window.standardWindowButton(.closeButton)?.superview,
           let container = bar.superview, let frameView = container.superview {
            let height = max(origin.y * 2, 28)
            let target = NSRect(x: container.frame.minX, y: frameView.isFlipped ? 0 : frameView.bounds.height - height, width: container.frame.width, height: height)
            if container.frame != target { container.frame = target }
            if bar.frame != container.bounds { bar.frame = container.bounds }
        }
        for (index, type) in buttons.enumerated() {
            guard let button = window.standardWindowButton(type), let bar = button.superview else { continue }
            // The title bar view is flipped or not depending on the OS; work from its top.
            let size = button.frame.size
            let top = origin.y - size.height / 2
            let y = bar.isFlipped ? top : bar.bounds.height - top - size.height
            let target = NSPoint(x: origin.x + CGFloat(index) * gap, y: y)
            if button.frame.origin != target { button.setFrameOrigin(target) }
        }
    }
}

/// Margin's windows. Controls in the title bar row (the repo's slider) mark
/// themselves with `DragSurface`; a press there goes straight to the control,
/// before the title bar can turn it into a window drag.
final class MarginWindow: NSWindow {
    private weak var tracking: DragSurface.SurfaceView?
    private var dragWatch: Timer?

    /// Where the window can be dragged from, from the top left. When set, the
    /// window doesn't move from anywhere else: not the title bar, not the
    /// background. Double-click it to zoom, like a title bar.
    var dragZone: CGRect? {
        didSet {
            isMovable = dragZone == nil
            if dragZone != nil { isMovableByWindowBackground = false }
        }
    }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            if let surface = surface(at: event.locationInWindow) {
                tracking = surface
                surface.mouseDown(with: event)
                return
            }
            if inDragZone(event.locationInWindow) {
                if event.clickCount == 2 { performZoom(nil); return }
                startDrag(with: event)
                return
            }
        case .leftMouseDragged:
            if let tracking {
                tracking.mouseDragged(with: event)
                return
            }
        case .leftMouseUp:
            if let surface = tracking {
                tracking = nil
                surface.mouseUp(with: event)
                return
            }
        default:
            break
        }
        super.sendEvent(event)
    }

    private func inDragZone(_ point: NSPoint) -> Bool {
        guard let zone = dragZone, let frameView = contentView?.superview else { return false }
        // The window's own buttons keep working.
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            if let button = standardWindowButton(type), let bar = button.superview,
               bar.convert(button.frame, to: nil).insetBy(dx: -2, dy: -2).contains(point) { return false }
        }
        let fromTop = NSPoint(x: point.x, y: frameView.bounds.height - point.y)
        return zone.contains(fromTop)
    }

    /// Lets AppKit move the window for this one drag, then locks it again.
    func startDrag(with event: NSEvent) {
        isMovable = true
        performDrag(with: event)
        dragWatch?.invalidate()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                if NSEvent.pressedMouseButtons & 1 == 0 {
                    timer.invalidate()
                    if self.dragZone != nil { self.isMovable = false }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        dragWatch = timer
    }

    /// The drag surface under the point, if any.
    private func surface(at point: NSPoint) -> DragSurface.SurfaceView? {
        DragSurface.SurfaceView.all.allObjects.first { $0.takes(point, in: self) }
    }
}
