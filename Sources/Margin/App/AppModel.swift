import AppKit
import Carbon
import QuartzCore
import MarginKit
import SwiftUI

/// Owns the app's state and the actions the menu triggers.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let store: EntryStore
    let context: AppContextTracker
    let autoCapture: AutoCapture
    /// Claude Code iterations.
    let coding: CodingSessions
    let updater = Updater()
    /// "Capture this step?" after ten quiet minutes in Figma or Claude.
    private(set) var nudge: NudgeController?
    /// Vibe coding in Claude's chat app (versions arrive as pushed commits).
    let chats: ChatSessions
    let intelligence: Intelligence
    private var phoneInbox: PhoneInbox?
    /// Margin's plugin inside Figma, for exports only Figma can make (video).
    let figmaBridge = FigmaBridge()
    private let windows: WindowManager
    private let quick = QuickCaptureController()
    private let overlay = RegionOverlay()
    private let figma = FigmaCapture()
    private let selection = SelectionCapture()
    private let recorder = ScreenRecorder()
    private let recordingHUD = RecordingHUD()
    private var recordingContext: (area: CGRect, app: NSRunningApplication?, url: URL, figmaLink: FigmaLink?)?
    private var recordingLimit: Task<Void, Never>?
    private var isRouting = false
    /// A screen recording is running.
    @Published private(set) var isRecording = false
    private var captureHotKey: HotKey?
    /// For demos: ⌃⌥⌘A takes an automatic capture now, ⌃⌥⌘N shows the nudge.
    private var demoAutoHotKey: HotKey?
    private var demoNudgeHotKey: HotKey?
    private var demoBuildHotKey: HotKey?
    /// Demo only (⌃⌥⌘B toggles it): the shortcut in Claude captures a build.
    private var buildCaptureDemo = false

    /// Longest recording, in seconds.
    static let recordingLimitSeconds: TimeInterval = 60
    private var doubleTap: DoubleTapShortcut?
    /// The bracket in the menu bar: click opens the repo, right-click the panel.
    private var statusItem: StatusItemController?

    /// Shows the nudge now, to try it.
    func showNudge() { nudge?.show() }

    /// The archive's window, for the tour to frame.
    var repoWindowFrame: NSRect? {
        guard let window = windows.window(id: WindowID.repo), window.isVisible else { return nil }
        return window.frame
    }

    /// The bracket in the menu bar, for the tour to point at.
    var statusItemFrame: NSRect? { statusItem?.buttonFrame }

    func startStatusItem() {
        guard statusItem == nil else { return }
        statusItem = StatusItemController(model: self)
    }

    /// The Margin panel from the menu bar (also ⌘, opens Settings directly).
    func toggleMenuPanel() { statusItem?.togglePanel() }

    private enum WindowID {
        static let composer = "composer"
        static let repo = "repo"
        static let moment = "moment"
        static let settings = "settings"
    }

    // MARK: The hand-off window

    /// Posted when the hand-off window goes away, so the repo can update.
    static let handoffClosed = Notification.Name("MarginHandoffClosed")
    private var handoff: HandoffWindow?

    /// The hand-off as its own narrow window beside the repo: as the repo
    /// gets narrower, the hand-off grows out of its right edge by the same
    /// amount, one smooth motion, then its contents come in.
    func openHandoffWindow(project: String) {
        guard handoff == nil, let repo = windows.window(id: WindowID.repo) else { return }
        let content = HandoverView(project: project, back: { [weak self] in self?.closeHandoffWindow() }, compact: true)
            .environmentObject(store)
            .environmentObject(intelligence)
        let window = HandoffWindow(repo: repo, content: AnyView(content)) { [weak self] in
            self?.handoff = nil
            NotificationCenter.default.post(name: Self.handoffClosed, object: nil)
        }
        handoff = window
        window.open()
    }

    /// Contents out, then the hand-off narrows back into the repo as the
    /// repo takes its width back.
    func closeHandoffWindow() {
        guard let handoff else {
            NotificationCenter.default.post(name: Self.handoffClosed, object: nil)
            return
        }
        handoff.close()
    }

    private init() {
        DemoData.startOnInDownloads()
        if DemoData.isOn, DemoData.seed() {
            let demo = EntryStore(baseURL: DemoData.baseURL, projectKey: "currentProjectDemo")
            if !demo.entries.contains(where: { $0.project == demo.currentProject }) {
                demo.currentProject = DemoData.project
            }
            store = demo
        } else {
            store = EntryStore()
        }
        context = AppContextTracker()
        // Luis's other projects beside Umbrella in the demo (downloaded once).
        let demoStore = store
        Task { @MainActor in PortfolioDemo.seedIfNeeded(into: demoStore) }
        autoCapture = AutoCapture(store: store, context: context)
        coding = CodingSessions(store: store, cards: quick)
        chats = ChatSessions(store: store, coding: coding)
        intelligence = Intelligence(store: store)
        windows = WindowManager()

        // Double-tap either ⌘ from anywhere captures the moment.
        doubleTap = DoubleTapShortcut { [weak self] in
            Task { @MainActor in self?.captureMoment() }
        }
        // ⌘⇧M does the same, and works without Accessibility permission.
        captureHotKey = HotKey(keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(cmdKey | shiftKey), id: 1) { [weak self] in
            Task { @MainActor in self?.captureMoment() }
        }
        // Demo shortcuts: show the automatic parts without waiting ten minutes.
        demoAutoHotKey = HotKey(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(controlKey | optionKey | cmdKey), id: 2) { [weak self] in
            Task { @MainActor in self?.autoCapture.captureNow() }
        }
        demoNudgeHotKey = HotKey(keyCode: UInt32(kVK_ANSI_N), modifiers: UInt32(controlKey | optionKey | cmdKey), id: 3) { [weak self] in
            Task { @MainActor in self?.showNudge() }
        }
        // A quiet sound says which way it went, so nothing shows on screen.
        // Development builds only: it stages a capture for the demo video.
        if Bundle.main.url(forResource: "repo-path", withExtension: nil) != nil {
        demoBuildHotKey = HotKey(keyCode: UInt32(kVK_ANSI_B), modifiers: UInt32(controlKey | optionKey | cmdKey), id: 4) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.buildCaptureDemo.toggle()
                NSSound(named: self.buildCaptureDemo ? "Pop" : "Bottle")?.play()
                MarginLog.info("Build capture demo \(self.buildCaptureDemo ? "on" : "off")")
            }
        }
        }
        // Ask for Accessibility once; after that the panel offers an "Allow" button.
        if !DoubleTapShortcut.isTrusted, !UserDefaults.standard.bool(forKey: "askedAccessibility") {
            UserDefaults.standard.set(true, forKey: "askedAccessibility")
            DoubleTapShortcut.requestTrust()
        }

        let bridge = figmaBridge
        coding.extraRoutes = { bridge.handle($0) }
        coding.deferredRoutes = { bridge.handleDeferred($0, reply: $1) }
        coding.figmaBridge = bridge
        figma.bridge = bridge
        figma.onProgress = { [weak self] text, fraction in
            self?.quick.showProgress(text, fraction: fraction)
        }
        recorder.onUnexpectedStop = { [weak self] _ in
            Task { @MainActor in self?.stopRecording() }
        }

        IconRefresh.runIfNeeded()
        FigmaPlugin.refreshIfInstalled()
        autoCapture.config = { [weak self] in self?.intelligence.config ?? AIConfig() }
        autoCapture.start()
        coding.start()
        chats.start()
        intelligence.start()
        // Photos shared from the iPhone, over Wi-Fi.
        phoneInbox = PhoneInbox(store: store) { [weak self] _ in self?.intelligence.scan() }
        phoneInbox?.start()
        let nudge = NudgeController(
            lastCapture: { [weak self] in
                self?.store.entries.filter { $0.kind != .snapshot }.map(\.createdAt).max()
            },
            onCapture: { [weak self] in self?.captureFromNudge() }
        )
        nudge.canShow = { [weak self] in
            guard let self else { return false }
            return !self.quick.isOpen && !self.isRecording && !ImagePreview.shared.isOpen
        }
        nudge.start()
        // An automatic capture landed: the small tile drops in and rises
        // away, once a day; after that they land silently.
        AutoCaptureToast.shared.canShow = { [weak self] in
            guard let self else { return false }
            return !self.quick.isOpen && !self.isRecording && !ImagePreview.shared.isOpen
        }
        autoCapture.onSnapshot = { _, _ in
            Task { @MainActor in AutoCaptureToast.shared.showFirstToday() }
        }
        self.nudge = nudge
        store.redrawTextPreviews(dark: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        coding.onProject = { [weak self] root in self?.chats.watch(root) }
    }

    // MARK: The capture shortcut

    /// One shortcut, three kinds of capture, decided by what you're doing:
    /// a selected Figma frame is exported from Figma with a link to it,
    /// selected text is kept with its formatting, and with nothing selected
    /// Margin's overlay lets you drag out an area (or record it).
    /// Pressing the shortcut again stops a recording or closes the overlay.
    func captureMoment() {
        // During the welcome tour the double-tap is shown, not acted on.
        if OnboardingTour.shared.takeCapture() { return }
        if recorder.isRecording {
            stopRecording()
            return
        }
        if overlay.isShowing {
            overlay.cancel()
            return
        }
        guard !isRouting else { return }
        isRouting = true
        // You're in Margin's own window: capture right here. Nothing else is
        // brought forward, so the shortcut never reorders windows.
        let inMargin = windows.hasFocus
        // An open card holds the keyboard; close it so ⌘C and ⌘L reach the app.
        quick.dismissImmediately()
        let front = inMargin ? NSRunningApplication.current : context.frontApp
        Task {
            defer { isRouting = false }
            await route(front: front)
        }
    }

    /// The overlay right away, from the menu: "Capture area…" and "Record area…".
    func captureArea(mode: RegionOverlay.Mode = .image) {
        let front = context.frontApp
        // Let the menu close first so it isn't in the picture.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.showOverlay(mode: mode, front: front, figmaLink: nil, hint: nil)
        }
    }

    private func route(front: NSRunningApplication?) async {
        await Keys.waitForModifierRelease()
        // Started from Margin's menu bar panel: give the keyboard back to the
        // app you were in first. Not when you're working in a Margin window.
        if NSApp.isActive, let front, front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            front.activate()
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        let canSendKeys = DoubleTapShortcut.isTrusted
        let ownPID = ProcessInfo.processInfo.processIdentifier

        if let front, front.bundleIdentifier == Self.claudeBundleID {
            // The HTML page you're building with Claude, copied into Margin.
            if await captureClaudeSite(app: front) { return }
            if buildCaptureDemo {
                await captureBuild(app: front)
                return
            }
        }

        if let front, front.bundleIdentifier == FigmaCapture.bundleID {
            // No pill yet: with nothing selected this goes straight to the
            // capture menu; the export shows its own pill once it starts.
            let outcome = await figma.capture(canSendKeys: canSendKeys)
            switch outcome {
            case .exported(let export, let link):
                let count = 1 + export.others.count
                // Several frames filled the pill while exporting; saving finishes it.
                quick.showProgress(count > 1 ? "Saving \(count) frames…" : "Saving the frame…", fraction: count > 1 ? 1 : nil)
                await saveFigma(export, link: link, app: front)
            case .noSelection(let link):
                quick.closeProgress()
                showOverlay(mode: .image, front: front, figmaLink: link, hint: nil)
            case .manual(let link, _):
                // No export (no plugin, nothing Margin can read the selection
                // from): the capture menu, as for any other app.
                quick.closeProgress()
                showOverlay(mode: .image, front: front, figmaLink: link, hint: nil)
            }
            return
        }

        if canSendKeys, let front, front.processIdentifier != ownPID,
           let clip = await selection.capture(from: front) {
            switch clip {
            case .text(let rich): saveText(rich, app: front)
            case .image(let data, let url): saveClipboardImage(data, sourceURL: url, app: front)
            case .link(let url, let isCurrentPage): await saveLink(url, isCurrentPage: isCurrentPage, app: front)
            }
            return
        }

        showOverlay(mode: .image, front: front, figmaLink: nil, hint: nil)
    }

    // MARK: Overlay

    /// From the nudge: it has stretched into the capture menu's shape, so the
    /// menu takes over right there.
    func captureFromNudge() {
        let front = context.frontApp
        showOverlay(mode: .image, front: front, figmaLink: nil, hint: nil, inPlace: true)
    }

    private func showOverlay(mode: RegionOverlay.Mode, front: NSRunningApplication?, figmaLink: FigmaLink?, hint: String?, inPlace: Bool = false) {
        guard ScreenCapture.hasPermission else {
            showPermissionCard(app: front)
            return
        }
        overlay.begin(mode: mode, hint: hint, inPlace: inPlace) { [weak self] result in
            guard let self, let result else { return }
            // The card takes over from the menu in place, unless the
            // screenshot could catch it there.
            if result.mode == .image, let menu = self.overlay.lastMenu, !self.mayCatchCard(result.selection) {
                self.quick.handOff(menu: menu.image, size: menu.size)
            }
            Task { @MainActor in
                switch result.mode {
                case .image:
                    // The whole window of a Figma Slides deck: every slide, as one stack.
                    if case .window = result.selection, let front, front.bundleIdentifier == FigmaCapture.bundleID,
                       self.figma.canExportDeck, await self.saveFigmaDeck(app: front) {
                        return
                    }
                    await self.saveScreenshot(result.selection, app: front, figmaLink: figmaLink)
                case .recording: await self.startRecording(result.selection, app: front, figmaLink: figmaLink)
                }
            }
        }
    }

    /// True when the area being captured reaches the top center, where the
    /// card's stand-in would sit. A window capture only sees that window.
    private func mayCatchCard(_ selection: RegionOverlay.Selection) -> Bool {
        guard case .area(let rect) = selection, let screen = TopCenter.screen else { return false }
        let top = TopCenter.top(of: screen)
        let band = CGRect(x: screen.frame.midX - 320, y: top - 120, width: 640, height: 120 + TopCenter.inset(of: screen))
        return rect.intersects(band)
    }

    private func saveScreenshot(_ selection: RegionOverlay.Selection, app: NSRunningApplication?, figmaLink: FigmaLink?) async {
        // Give the window server a moment to take the overlay off screen.
        try? await Task.sleep(nanoseconds: 120_000_000)
        let url = store.newImageURL(ext: "png")
        let ok: Bool
        switch selection {
        case .area(let rect): ok = await ScreenCapture.captureArea(rect, to: url)
        case .window(let id, _): ok = await ScreenCapture.captureWindow(id, to: url)
        }
        guard ok else {
            quick.closeProgress()
            MarginLog.info("Screenshot failed")
            NSSound.beep()
            return
        }
        var entry = newCapture(.capture, app: app)
        entry.imageFile = url.lastPathComponent
        if let figmaLink {
            entry.link = figmaLink.url.absoluteString
            entry.label = figmaLink.fileName
        } else if let pid = app?.processIdentifier {
            entry.link = await Task.detached { SelectionReader.read(pid: pid).url?.absoluteString ?? "" }.value
        }
        store.add(entry)
        present(entry)
    }

    // MARK: Recording

    private func startRecording(_ selection: RegionOverlay.Selection, app: NSRunningApplication?, figmaLink: FigmaLink? = nil) async {
        let area: CGRect
        switch selection {
        case .area(let rect): area = rect
        case .window(_, let rect): area = rect
        }
        try? await Task.sleep(nanoseconds: 120_000_000)
        let url = store.newImageURL(ext: "mp4")
        do {
            try await recorder.start(area: area, to: url)
        } catch {
            MarginLog.info("Recording failed to start: \(error)")
            quick.show(
                store: store, entryID: nil, image: nil, status: nil,
                prompt: "Margin couldn't start recording: \(error.localizedDescription)",
                onSave: { _ in }, onDismiss: {}
            )
            return
        }
        recordingContext = (area, app, url, figmaLink)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        recordingHUD.show(area: RegionMath.flip(area, primaryHeight: primaryHeight), limit: Self.recordingLimitSeconds) { [weak self] in
            self?.stopRecording()
        }
        recordingLimit = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.recordingLimitSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.stopRecording()
        }
        isRecording = true
    }


    func stopRecording() {
        guard recorder.isRecording else { return }
        recordingLimit?.cancel()
        recordingLimit = nil
        recordingHUD.close()
        let context = recordingContext
        recordingContext = nil
        isRecording = false
        quick.showProgress("Saving the recording…")
        Task {
            do {
                let url = try await recorder.stop()
                await saveRecording(url, app: context?.app, figmaLink: context?.figmaLink)
            } catch {
                MarginLog.info("Recording failed: \(error)")
                quick.closeProgress()
                NSSound.beep()
            }
        }
    }

    private func saveRecording(_ url: URL, app: NSRunningApplication?, figmaLink: FigmaLink? = nil) async {
        var entry = newCapture(figmaLink == nil ? .recording : .figma, app: app)
        if let figmaLink {
            entry.link = figmaLink.url.absoluteString
            entry.label = figmaLink.fileName.map { "Motion · \($0)" } ?? "Motion"
        }
        entry.mediaFile = url.lastPathComponent
        entry.duration = await VideoTools.duration(of: url)
        if let poster = await VideoTools.poster(for: url) {
            let posterURL = store.newImageURL(ext: "jpg")
            if ImageTools.writeJPEG(poster, maxWidth: 1600, quality: 0.8, to: posterURL) {
                entry.imageFile = posterURL.lastPathComponent
            }
        }
        store.add(entry)
        present(entry)
    }

    // MARK: Saving what the router found

    /// Exports the open Figma Slides deck and saves it as one stacked
    /// artifact named after the deck. False if the plugin couldn't.
    private func saveFigmaDeck(app: NSRunningApplication) async -> Bool {
        guard let deck = await figma.captureDeck() else { return false }
        let count = 1 + deck.export.others.count
        quick.showProgress("Saving \(count) slides…", fraction: 1)
        await saveFigma(deck.export, link: nil, app: app, title: deck.title)
        return true
    }

    private func saveFigma(_ export: FigmaExport, link: FigmaLink?, app: NSRunningApplication, title: String? = nil) async {
        var entry = newCapture(.figma, app: app)
        // Every selected frame, saved on its own, kept together as one capture.
        var frames: [FrameRef] = []
        for item in [export] + export.others {
            frames.append(await saveFrame(item, link: link))
        }
        let primary = frames[0]
        entry.imageFile = primary.imageFile
        entry.mediaFile = primary.mediaFile
        entry.duration = primary.duration
        entry.label = title ?? (frames.count > 1
            ? frames.compactMap(\.name).joined(separator: ", ")
            : export.node.name)
        entry.link = primary.link ?? ""
        entry.windowTitle = link?.fileName ?? entry.windowTitle
        if frames.count > 1 { entry.frames = frames }
        store.add(entry)

        // The same card as any capture; a line only when there's something to do.
        let name = export.node.name.map { "“\($0)”" } ?? "Frame"
        if frames.count == 1, let note = export.note {
            present(entry, detail: "Saved \(name) as a still. \(note)")
        } else if frames.count == 1, export.hasMotion, export.video == nil {
            present(entry, detail: "Saved \(name) as a still. To save the animation, start the Margin plugin in Figma once: Plugins → Development → Margin.")
        } else {
            present(entry)
        }
    }

    static let claudeBundleID = "com.anthropic.claudefordesktop"

    /// The local HTML page of your latest Claude Code session: its site copied
    /// into Margin (so this version opens later, as it is now) and pictured
    /// from that copy. False when there's no recent session with a page.
    private func captureClaudeSite(app: NSRunningApplication) async -> Bool {
        let found = await Task.detached { () -> (ClaudeSite.Session, URL)? in
            for session in ClaudeSite.recentSessions() {
                if let page = ClaudeSite.page(in: session) { return (session, page) }
            }
            return nil
        }.value
        guard let found else {
            MarginLog.info("Claude capture: no Claude Code session with an HTML page in the last 3 hours")
            return false
        }
        let (session, page) = found
        quick.showProgress("Capturing \(page.lastPathComponent)")
        var entry = newCapture(.iteration, app: app)
        let relative = "sites/\(entry.id.uuidString)"
        let folder = store.baseURL.appendingPathComponent(relative, isDirectory: true)
        let copy: ClaudeSite.Copy
        do {
            copy = try await Task.detached { try ClaudeSite.copy(page: page, project: session.cwd, to: folder) }.value
        } catch {
            MarginLog.info("Claude capture: copying \(page.path) failed: \(error)")
            quick.closeProgress()
            return false
        }
        entry.siteFolder = relative
        entry.sitePage = copy.page
        entry.codeRoot = session.cwd.path
        entry.sessionID = session.id
        entry.agent = "Claude"
        entry.windowTitle = session.cwd.lastPathComponent
        let served = try? coding.sites.url(for: folder, page: copy.page)
        let address = served ?? folder.appendingPathComponent(copy.page)
        if let shot = await PagePreview.shot(address) {
            entry.imageFile = coding.saveJPEG(shot.png)
            if let title = shot.title, !title.isEmpty { entry.label = title }
        }
        if entry.label == nil { entry.label = page.deletingPathExtension().lastPathComponent }
        MarginLog.info("Claude capture: \(copy.page) from \(session.cwd.path), \(copy.files) files, \(copy.bytes / 1024) KB, skipped \(copy.skipped.count)")
        store.add(entry)
        present(entry)
        return true
    }

    /// Demo only: the build that's open in Claude's preview, saved as an
    /// iteration the way a build capture will look once Margin can tell a
    /// build happened. The page itself is pictured, the way real iterations
    /// picture their dev server; failing that, Claude's window.
    private func captureBuild(app: NSRunningApplication) async {
        quick.showProgress("Capturing build")
        let started = Date()
        var entry = newCapture(.iteration, app: app)
        entry.agent = "Claude"
        if let page = Self.demoBuild, let shot = await PagePreview.shot(page) {
            entry.imageFile = coding.saveJPEG(shot.png)
            if !page.isFileURL { entry.previewURL = page.absoluteString }
            entry.label = shot.title.map { "Build · \($0)" } ?? "Build"
        } else {
            let url = store.newImageURL(ext: "heic")
            if ScreenCapture.hasPermission, let shot = await ScreenCapture.snapshot(pid: app.processIdentifier, to: url) {
                entry.imageFile = url.lastPathComponent
                entry.windowTitle = shot.title ?? entry.windowTitle
            }
            entry.label = entry.windowTitle.map { "Build · \($0)" } ?? "Build"
        }
        // Long enough for the pill to be read.
        let wait = 1.1 - Date().timeIntervalSince(started)
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        store.add(entry)
        present(entry)
    }

    /// The demo build: the prototype's preview server if it's up, else its file.
    private static var demoBuild: URL? {
        if DevServer.isListening(port: 4173) { return URL(string: "http://localhost:4173/") }
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("SVSD_Competition/demo/umbrella-sidebar/index.html")
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    /// Saves one exported frame: its picture, its video if Figma rendered one, its link.
    private func saveFrame(_ export: FigmaExport, link: FigmaLink?) async -> FrameRef {
        var frame = FrameRef(name: export.node.name, nodeID: export.node.id)
        frame.imageFile = export.image.isEmpty ? nil : store.saveFile(export.image, ext: ImageData.fileExtension(export.image))
        if let video = export.video, let file = store.saveFile(video, ext: "mp4") {
            // Rendered by Figma: the animation itself, crisp, at full length.
            frame.mediaFile = file
            let url = store.imageURL(forFile: file)
            frame.duration = await VideoTools.duration(of: url)
            if frame.imageFile == nil, let poster = await VideoTools.poster(for: url) {
                let posterURL = store.newImageURL(ext: "jpg")
                if ImageTools.writeJPEG(poster, maxWidth: 1600, quality: 0.85, to: posterURL) { frame.imageFile = posterURL.lastPathComponent }
            }
        }
        if let link { frame.link = Self.link(link, node: export.node.id) }
        return frame
    }

    /// The link to the exported node, even if ⌘L pointed at its page.
    static func link(_ link: FigmaLink, node: String) -> String {
        guard FigmaLink.apiNodeID(node) != nil, link.nodeID != node,
              var components = URLComponents(url: link.url, resolvingAgainstBaseURL: false) else { return link.url.absoluteString }
        var items = (components.queryItems ?? []).filter { $0.name != "node-id" }
        items.insert(URLQueryItem(name: "node-id", value: node.replacingOccurrences(of: ":", with: "-")), at: 0)
        components.queryItems = items
        return components.url?.absoluteString ?? link.url.absoluteString
    }

    private func saveText(_ clip: RichClip, app: NSRunningApplication) {
        var entry = newCapture(.text, app: app)
        entry.mediaFile = store.saveFile(clip.data, ext: clip.format.fileExtension)
        entry.body = clip.plain
        entry.link = clip.sourceURL?.absoluteString ?? ""
        let firstLine = clip.plain.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmed ?? ""
        entry.label = firstLine.count > 90 ? String(firstLine.prefix(88)) + "…" : firstLine
        if let attributed = RichText.load(clip.data, format: clip.format), let png = RichText.preview(attributed, dark: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua) {
            entry.imageFile = store.saveFile(png, ext: "png")
        }
        store.add(entry)
        present(entry)
    }

    /// A website: the link and a picture of the page. From the address bar,
    /// the picture is the page as you see it (logged in, scrolled); for any
    /// other selected link, Margin loads the page itself.
    private func saveLink(_ url: URL, isCurrentPage: Bool, app: NSRunningApplication) async {
        quick.showProgress("Saving \(url.host?.replacingOccurrences(of: "www.", with: "") ?? "the page")…")
        var entry = newCapture(.link, app: app)
        entry.link = url.absoluteString
        let pid = app.processIdentifier
        var title: String?

        if isCurrentPage, ScreenCapture.hasPermission {
            // Close the address bar (Arc's ⌘L bar floats over the page) so the
            // picture shows the page itself.
            Keys.escape()
            try? await Task.sleep(nanoseconds: 300_000_000)
            title = await Task.detached { SelectionReader.windowTitle(pid: pid) }.value
            let webArea = await Task.detached { SelectionReader.webAreaFrame(pid: pid) }.value
            let file = store.newImageURL(ext: "png")
            var ok = false
            if let webArea {
                ok = await ScreenCapture.captureArea(webArea, to: file)
            }
            if ok {
                entry.imageFile = file.lastPathComponent
            } else {
                // No page area from the browser: the whole window, tabs and all.
                let shot = store.newImageURL(ext: "heic")
                if await ScreenCapture.snapshot(pid: pid, to: shot) != nil { entry.imageFile = shot.lastPathComponent }
            }
        }
        if entry.imageFile == nil, let shot = await PagePreview.shot(url, timeout: 20) {
            entry.imageFile = store.saveFile(shot.png, ext: "png")
            title = title ?? shot.title
        }
        // Browsers end window titles with their name: "Page – Google Chrome".
        if let raw = title {
            var clean = raw
            for suffix in [" - Google Chrome", " – Google Chrome", " - Arc", " — Arc", " - Brave", " – Mozilla Firefox", " — Mozilla Firefox", " - Microsoft Edge"] where clean.hasSuffix(suffix) {
                clean = String(clean.dropLast(suffix.count))
            }
            entry.label = clean.trimmed.isEmpty ? nil : clean.trimmed
        }
        entry.windowTitle = url.host
        store.add(entry)
        present(entry)
    }

    private func saveClipboardImage(_ data: Data, sourceURL: URL?, app: NSRunningApplication) {
        var entry = newCapture(.capture, app: app)
        entry.imageFile = store.saveFile(data, ext: "png")
        entry.link = sourceURL?.absoluteString ?? ""
        store.add(entry)
        present(entry)
    }

    private func newCapture(_ kind: EntryKind, app: NSRunningApplication?) -> Entry {
        var entry = store.newEntry(kind)
        entry.sourceApp = app?.localizedName
        if let pid = app?.processIdentifier, ScreenCapture.hasPermission {
            entry.windowTitle = ScreenCapture.frontWindow(of: pid)?.title
        }
        return entry
    }

    /// The card under the menu bar: "Captured", the capture, room for a description.
    /// Every kind of capture gets this same card.
    private func present(_ entry: Entry, detail: String? = nil) {
        let id = entry.id
        quick.show(
            store: store,
            entryID: id,
            image: store.thumbnail(for: entry),
            status: "Captured",
            prompt: nil,
            detail: detail,
            onSave: { [weak self] text in
                self?.store.modify(id) { $0.rationale = text }
            },
            onDismiss: {}
        )
    }

    private func showPermissionCard(app: NSRunningApplication?) {
        quick.show(
            store: store,
            entryID: nil,
            image: nil,
            status: nil,
            prompt: "Margin needs screen recording access to capture the screen. Write a note instead?",
            onSave: { [weak self] text in
                guard let self else { return }
                var note = self.store.newEntry(.note)
                note.title = text
                note.sourceApp = app?.localizedName
                self.store.add(note)
            },
            onDismiss: {}
        )
    }

    /// Opens the card for an existing moment to add its why.
    func addWhy(to entry: Entry) {
        quick.show(
            store: store,
            entryID: entry.id,
            image: store.thumbnail(for: entry),
            status: nil,
            prompt: nil,
            onSave: { [weak self] text in
                self?.store.modify(entry.id) { $0.rationale = text }
            },
            onDismiss: {}
        )
    }


    /// Pulls the latest version from GitHub, rebuilds and relaunches Margin.
    func updateMargin() {
        updater.update()
    }

    /// Quits and reopens Margin. macOS applies a new Screen Recording grant
    /// only after a relaunch.
    func relaunch() {
        let path = Bundle.main.bundlePath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 0.6; /usr/bin/open -n \"$0\"", path]
        try? process.run()
        NSApp.terminate(nil)
    }

    /// Switches between the Umbrella demo and your own captures. Relaunches.
    func useDemoData(_ on: Bool, reset: Bool = false) {
        DemoData.isOn = on
        if on && reset { DemoData.seed(force: true) }
        relaunch()
    }

    func requestShortcutAccess() {
        DoubleTapShortcut.requestTrust()
    }

    // MARK: Manual entries

    func compose(_ kind: EntryKind) {
        var entry = newEntry(kind)
        if kind == .inspiration, let link = clipboardURL() {
            entry.link = link
        }
        openComposer(entry)
    }

    // MARK: Repo

    /// A moment, large: the image, recording or text, its link and its why.
    func open(_ entry: Entry) {
        windows.show(id: WindowID.moment, title: entry.displayTitle, size: NSSize(width: 960, height: 720), chromeless: true) {
            MomentView(entryID: entry.id)
                .environmentObject(self.store)
                .environmentObject(self.coding)
                .environmentObject(self.intelligence)
        }
    }

    func showSettings() {
        windows.show(id: WindowID.settings, title: "Margin Settings", size: NSSize(width: 520, height: 560), chromeless: true) {
            SettingsView()
                .environmentObject(self.coding)
                .environmentObject(self.chats)
                .environmentObject(self.intelligence)
                .environmentObject(self.autoCapture)
        }
    }

    /// The welcome: the mark over everything, then a tour of where things
    /// happen. Shown on a first launch with nothing captured yet, and from
    /// the menu.
    func showOnboarding() {
        OnboardingTour.shared.start()
    }

    /// First launch, nothing captured: the welcome instead of an empty repo.
    var wantsOnboarding: Bool {
        // The demo projects aren't the person's own work: still a first run.
        !UserDefaults.standard.bool(forKey: "onboardingSeen") && (store.entries.isEmpty || DemoData.isOn)
    }

    /// The repo on the right half of its screen, under the menu bar.
    func snapRepoToRightHalf() {
        guard let window = windows.window(id: WindowID.repo), let screen = window.screen ?? NSScreen.main else { return }
        let area = screen.visibleFrame
        window.setFrame(CGRect(x: area.midX, y: area.minY, width: area.width / 2, height: area.height), display: true)
    }

    func showRepo() {
        windows.show(id: WindowID.repo, title: "Margin", size: NSSize(width: 1080, height: 760), chromeless: true, trafficLights: RepoHeader.trafficLights) {
            RepoView()
                .environmentObject(self.store)
                .environmentObject(self.intelligence)
                .environmentObject(self.coding)
                .environmentObject(self.chats)
                .environmentObject(self.autoCapture)
        }
    }

    func exportCurrentProject() {
        let project = store.currentProject
        do {
            let url = try MarkdownExporter.export(project: project, entries: store.entries(in: project), to: store.baseURL)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            NSLog("Margin: export failed: \(error)")
            NSSound.beep()
        }
    }

    // MARK: Helpers

    private func newEntry(_ kind: EntryKind) -> Entry {
        var entry = store.newEntry(kind)
        entry.sourceApp = context.appName
        return entry
    }

    private func openComposer(_ entry: Entry) {
        windows.show(
            id: WindowID.composer,
            title: "New \(entry.kind.label.lowercased())",
            size: NSSize(width: 460, height: entry.imageFile == nil ? 420 : 600),
            floating: true
        ) {
            ComposerView(
                entry: entry,
                onSave: { [weak self] saved in
                    self?.store.add(saved)
                    self?.windows.close(id: WindowID.composer)
                },
                onCancel: { [weak self] draft in
                    self?.store.discardImage(of: draft)
                    self?.windows.close(id: WindowID.composer)
                }
            )
            .environmentObject(self.store)
        }
    }

    private func clipboardURL() -> String? {
        guard let text = NSPasteboard.general.string(forType: .string)?.trimmed,
              let url = URL(string: text),
              let scheme = url.scheme, scheme == "http" || scheme == "https" else { return nil }
        return url.absoluteString
    }
}
