import AppKit
import SwiftUI

@main
struct MarginApp: App {
    @NSApplicationDelegateAdaptor(MarginAppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    init() {
        Self.handOverToRunningCopy()
    }

    /// One Margin at a time. Two copies open on the same archive (an old
    /// build next to a new one) each keep their own list of captures and
    /// undo each other's changes: a capture deleted in one came back, its
    /// picture gone, when the other saved. So a second copy brings the
    /// running one forward and quits before it touches anything.
    private static func handOverToRunningCopy() {
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSWorkspace.shared.runningApplications.filter {
            $0.processIdentifier != me && !$0.isTerminated
                && ($0.bundleIdentifier ?? "").hasPrefix("com.svsd.margin")
        }
        guard let running = others.first else { return }
        NSLog("Margin: already running (%@, pid %d); handing over", running.bundleURL?.path ?? "?", running.processIdentifier)
        running.activate()
        exit(0)
    }

    var body: some Scene {
        // Margin's windows are opened by AppModel; the menu bar item is
        // StatusItemController. These scenes only supply the app menu.
        // A hidden menu bar extra comes first: an app whose only scene is
        // Settings gets that (empty) Settings window opened at launch, which
        // showed before the archive and sat there while Margin started.
        MenuBarExtra("Margin", isInserted: .constant(false)) { EmptyView() }
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") { model.showSettings() }
                        .keyboardShortcut(",")
                }
                CommandGroup(replacing: .newItem) {
                    Button("Open Repo") { model.showRepo() }
                        .keyboardShortcut("o")
                }
            }
    }
}
