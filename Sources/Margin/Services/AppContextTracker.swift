import AppKit

/// Remembers which app the designer is working in, so entries get context for free.
@MainActor
final class AppContextTracker: ObservableObject {
    @Published private(set) var appName: String?
    @Published private(set) var bundleID: String?
    @Published private(set) var since = Date()
    /// The last app in front that isn't Margin.
    private(set) var frontApp: NSRunningApplication?

    static let designApps: Set<String> = [
        "com.figma.Desktop",
        "com.bohemiancoding.sketch3",
        "com.adobe.illustrator",
        "com.adobe.Photoshop",
        "com.adobe.InDesign",
        "com.adobe.xd",
        "com.framer.electron",
        "com.seriflabs.affinitydesigner2",
    ]

    /// Where designers build with AI. Browsers and the Claude app are left out
    /// on purpose: they hold too much personal stuff to capture by default.
    static let codeApps: Set<String> = [
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.microsoft.VSCode",
        "com.exafunction.windsurf",
        "dev.zed.Zed",
        "com.apple.dt.Xcode",
    ]

    /// Terminals are never captured automatically: they're mostly logs and
    /// commands, and Claude Code turns are already recorded as iterations.
    /// A capture you ask for (the shortcut) still works there.
    static let terminals: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
    ]

    var isInDesignApp: Bool {
        bundleID.map { Self.designApps.contains($0) } ?? false
    }

    /// Design or code app: the places live capture watches.
    var isInWorkApp: Bool {
        bundleID.map { !Self.terminals.contains($0) && (Self.designApps.contains($0) || Self.codeApps.contains($0)) } ?? false
    }

    /// Margin itself (its menu or repo window) is in front right now.
    var isMarginInFront: Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
    }

    private var observer: NSObjectProtocol?

    init() {
        update(NSWorkspace.shared.frontmostApplication)
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor in self?.update(app) }
        }
    }

    private func update(_ app: NSRunningApplication?) {
        // Ignore Margin itself, so "the app you were in" stays meaningful.
        guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        frontApp = app
        guard app.bundleIdentifier != bundleID else { return }
        appName = app.localizedName
        bundleID = app.bundleIdentifier
        since = Date()
    }
}
