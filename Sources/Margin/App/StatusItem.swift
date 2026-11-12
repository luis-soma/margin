import AppKit
import Combine
import SwiftUI

/// The bracket in the menu bar.
/// - Click: opens the repo (or stops a screen recording in progress).
/// - Right-click, or Control-click: the Margin panel (capture, projects,
///   updates, settings).
@MainActor
final class StatusItemController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private unowned let model: AppModel
    private var cancellables: Set<AnyCancellable> = []
    private var keyObserver: NSObjectProtocol?

    init(model: AppModel) {
        self.model = model
        super.init()
        if let button = item.button {
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Margin: click to open the repo, right-click for more"
        }
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: MenuView()
            .environmentObject(model.store)
            .environmentObject(model.context)
            .environmentObject(model.autoCapture)
            .environmentObject(model.coding)
            .environmentObject(model.updater)
            .environmentObject(model.chats))

        // The mark follows capture and recording state.
        Publishers.CombineLatest3(model.autoCapture.$isEnabled, model.autoCapture.$needsPermission, model.$isRecording)
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled, needsPermission, recording in
                self?.item.button?.image = recording ? MarkImage.menuBarRecording() : MarkImage.menuBar(live: enabled && !needsPermission)
            }
            .store(in: &cancellables)

        // A window opened from the panel (repo, settings) closes the panel.
        keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, self.popover.isShown, let window = note.object as? NSWindow,
                      window !== self.popover.contentViewController?.view.window else { return }
                self.popover.performClose(nil)
            }
        }
    }

    /// Where the bracket sits in the menu bar, in screen coordinates.
    var buttonFrame: NSRect? {
        guard let button = item.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        if wantsMenu {
            togglePanel()
        } else if model.isRecording {
            model.stopRecording()
        } else {
            if popover.isShown { popover.performClose(nil) }
            model.showRepo()
        }
    }

    func togglePanel() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

/// Dock icon clicks open the repo when no window is showing.
final class MarginAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated {
            if !flag { AppModel.shared.showRepo() }
        }
        return true
    }

    /// Never an empty window at launch; Margin opens the archive itself.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    /// Closing the repo (or any window) leaves Margin running; only Quit quits.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Don't bring back windows from the last run: that reopened the
        // (empty) settings scene after an update.
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
    }

    /// Titled windows Margin didn't open itself.
    @MainActor
    static func closeStrayWindows() {
        for window in NSApp.windows where window.styleMask.contains(.titled)
            && !(window is MarginWindow) && !(window is NSPanel) {
            window.orderOut(nil)
            window.close()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Archive.registerFonts()
        // Team builds record any moment the window gets stuck, with a sample
        // of where the time went, beside the log.
        if !BuildInfo.isRelease { StallWatch.shared.start() }
        MainActor.assumeIsolated {
            // Anything SwiftUI opened on its own (the empty Settings window)
            // goes before it's ever drawn.
            Self.closeStrayWindows()
            AppModel.shared.startStatusItem()
            SliderDemo.listen()
            // Launching (and relaunching after an update) opens the repo.
            DispatchQueue.main.async {
                Self.closeStrayWindows()
                if AppModel.shared.wantsOnboarding {
                    AppModel.shared.showOnboarding()
                } else {
                    AppModel.shared.showRepo()
                    // A development rebuild relaunches with --right-half: the
                    // repo comes back snapped to the right half, as you work.
                    if CommandLine.arguments.contains("--right-half") {
                        AppModel.shared.snapRepoToRightHalf()
                    }
                }
            }
        }
    }
}
