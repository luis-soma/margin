import AppKit
import ImageIO
import MarginKit
import SwiftUI

/// Captures vibe coding: every instruction you give Claude Code that changes
/// your project becomes an iteration with the version of the code, a picture
/// of the running app and your words. While Claude works, Margin asks what
/// you expect; when it's done, whether it matched.
@MainActor
final class CodingSessions: ObservableObject {
    /// Claude Code's hooks point at Margin.
    @Published private(set) var isConnected: Bool
    /// The port Margin listens on, nil if it couldn't start.
    @Published private(set) var port: UInt16?
    /// The turn Claude is working on right now, if any.
    @Published private(set) var activeTurn: CodingTurn?
    @Published private(set) var lastEvent: Date?
    @Published private(set) var lastError: String?
    /// Versions currently running on localhost, by entry.
    @Published private(set) var runningVersions: [UUID: URL] = [:]

    /// Ask while Claude works only once a turn has run this long and edited files.
    static let longTurn: TimeInterval = 15

    private let store: EntryStore
    private let cards: QuickCaptureController
    private let connector = ClaudeCodeConnector()
    let snapshots: CodeSnapshots
    private let tracker: CodingTurnTracker
    let runner = VersionRunner()
    /// Serves copied HTML sites to the browser.
    let sites = SiteServer()
    private var server: HookServer?
    /// Margin's Figma plugin talks to the same server.
    var figmaBridge: FigmaBridge?
    /// Requests for other parts of Margin, answered on the server's queue.
    var extraRoutes: ((HookServer.Request) -> HookServer.Response?)?
    /// Requests answered later (the Figma plugin waiting for work).
    var deferredRoutes: HookServer.Deferred?

    init(store: EntryStore, cards: QuickCaptureController) {
        self.store = store
        self.cards = cards
        snapshots = CodeSnapshots(base: store.baseURL.appendingPathComponent("code", isDirectory: true))
        tracker = CodingTurnTracker(snapshots: snapshots)
        isConnected = connector.isConnected

        tracker.onTurnStarted = { [weak self] turn in self?.turnStarted(turn) }
        tracker.onTurnFinished = { [weak self] turn, kept in self?.turnFinished(turn, kept: kept) }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.runner.stopAll()
        }
    }

    // MARK: Lifecycle

    func start() {
        let extra = extraRoutes
        let server = HookServer(router: { [weak self] request in
            // Other parts of Margin (the Figma plugin) share this server.
            if let response = extra?(request) { return response }
            let path = request.path
            let body = request.body
            DispatchQueue.main.async { self?.receive(path: path, body: body) }
            return .ok
        })
        server.deferred = deferredRoutes
        let base = ClaudeCodeConnector.defaultPort
        do {
            let port = try server.start(ports: (0..<10).map { base + $0 })
            self.server = server
            self.port = port
            MarginLog.info("Listening for coding agents on 127.0.0.1:\(port)")
            if isConnected { try? connector.writeSupportFiles(port: port) }
        } catch {
            lastError = "Margin couldn't listen for Claude Code: \(error.localizedDescription)"
            MarginLog.info(lastError ?? "")
        }
    }

    func connect() {
        guard let port else { return }
        do {
            try connector.connect(port: port)
            isConnected = true
            lastError = nil
            MarginLog.info("Connected Claude Code (hooks in \(connector.settingsURL.path))")
        } catch {
            lastError = "\(error)"
        }
    }

    func disconnect() {
        do {
            try connector.disconnect()
            isConnected = false
        } catch {
            lastError = "\(error)"
        }
    }

    func refreshConnection() {
        isConnected = connector.isConnected
    }

    // MARK: Events

    private func receive(path: String, body: Data) {
        guard path.hasPrefix("/hooks/claude-code"), let event = HookEvent.claudeCode(body) else { return }
        lastEvent = Date()
        tracker.handle(event)
    }

    private func turnStarted(_ turn: CodingTurn) {
        activeTurn = turn
    }


    private func turnFinished(_ turn: CodingTurn, kept: Bool) {
        if activeTurn === turn { activeTurn = nil }
        MarginLog.info("Turn finished (\(kept ? "kept" : "no file changes, dropped")): \(turn.prompt.prefix(80))")
        guard kept, let root = turn.root, let after = turn.after else { return }
        Task { await save(turn, root: root, after: after) }
    }

    // MARK: Saving an iteration

    private func save(_ turn: CodingTurn, root: URL, after: CodeSnapshots.Snapshot) async {
        let snapshots = self.snapshots
        let before = turn.before?.commit
        let excluded = Set([Int(port ?? 0)] + runningVersions.values.compactMap(\.port))
        let mentioned = turn.mentionedURLs
        let transcript = turn.transcriptPath

        let (stat, url, title) = await Task.detached { () -> (CodeSnapshots.DiffStat, URL?, String?) in
            let stat = snapshots.diffStat(root: root, from: before, to: after.commit)
            var url = DevServer.best(mentioned: mentioned, root: root, excludingPorts: excluded)
            if url == nil {
                let index = root.appendingPathComponent("index.html")
                if FileManager.default.fileExists(atPath: index.path) { url = index }
            }
            return (stat, url, transcript.flatMap(Transcript.title))
        }.value

        var entry = store.newEntry(.iteration)
        entry.createdAt = turn.endedAt ?? Date()
        entry.prompt = turn.prompt
        entry.summary = turn.summary
        entry.expectation = turn.expectation
        entry.codeRoot = root.path
        entry.snapshot = after.commit
        entry.baseSnapshot = before
        entry.diffStat = stat.summary
        entry.agent = turn.agent
        entry.sessionID = turn.sessionID
        entry.sourceApp = turn.agent
        entry.windowTitle = root.lastPathComponent
        entry.label = title

        if let url, let png = await PagePreview.capture(url) {
            entry.imageFile = saveJPEG(png)
            if !url.isFileURL { entry.previewURL = url.absoluteString }
        }
        if entry.imageFile == nil, let card = Self.codeCard(prompt: turn.prompt, stat: stat) {
            entry.imageFile = store.saveFile(card, ext: "png")
        }
        store.add(entry)
        onIteration?(entry)
        onProject?(root)
        MarginLog.info("Saved iteration: \(stat.summary), picture from \(url?.absoluteString ?? "code card")")
    }

    func saveJPEG(_ png: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return store.saveFile(png, ext: "png") }
        let url = store.newImageURL(ext: "jpg")
        return ImageTools.writeJPEG(image, maxWidth: 1600, quality: 0.82, to: url) ? url.lastPathComponent : store.saveFile(png, ext: "png")
    }

    /// When there's no app to picture: the instruction and what changed, on paper.
    static func codeCard(prompt: String, stat: CodeSnapshots.DiffStat) -> Data? {
        let text = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        text.append(NSAttributedString(string: "“\(prompt.trimmingCharacters(in: .whitespacesAndNewlines))”\n\n", attributes: [
            .font: NSFont.systemFont(ofSize: 17, weight: .medium),
            .foregroundColor: NSColor(white: 0.1, alpha: 1),
            .paragraphStyle: paragraph,
        ]))
        let files = stat.files.prefix(6).map { "  \($0)" }.joined(separator: "\n") + (stat.files.count > 6 ? "\n  …" : "")
        text.append(NSAttributedString(string: "\(stat.summary)\n\(files)", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor(white: 0.35, alpha: 1),
        ]))
        return RichText.preview(text, dark: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
    }

    /// A project got its first iteration (so chat capture can watch it too).
    var onProject: ((URL) -> Void)?
    /// A turn was saved as an iteration (an automatic capture).
    var onIteration: ((Entry) -> Void)?

    // MARK: Versions

    enum VersionError: LocalizedError {
        case missing
        var errorDescription: String? { "This version's files aren't in Margin's history." }
    }

    /// Writes a version's files to ~/Documents/Margin/versions and returns the folder.
    func exportVersion(_ entry: Entry) async throws -> URL {
        guard let rootPath = entry.codeRoot, let commit = entry.snapshot else { throw VersionError.missing }
        let root = URL(fileURLWithPath: rootPath)
        let folder = store.baseURL
            .appendingPathComponent("versions", isDirectory: true)
            .appendingPathComponent("\(root.lastPathComponent)-\(commit.prefix(7))", isDirectory: true)
        if FileManager.default.fileExists(atPath: folder.path) { return folder }
        let snapshots = self.snapshots
        let fromRepo = entry.snapshotSource == "repo"
        try await Task.detached {
            if fromRepo {
                try RepoWatcher.export(root, commit: commit, to: folder)
            } else {
                try snapshots.export(root: root, commit: commit, to: folder)
            }
        }.value
        return folder
    }

    /// Runs a version on localhost and opens it in the browser. Projects
    /// Margin can't run open in Finder instead.
    func openVersion(_ entry: Entry) async throws {
        if let url = try await runVersion(entry) {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([try await exportVersion(entry)])
        }
    }

    /// Runs a version on localhost and returns its address, without opening
    /// it anywhere; nil when Margin can't run that kind of project.
    func runVersion(_ entry: Entry) async throws -> URL? {
        if let running = runningVersions[entry.id] { return running }
        let folder = try await exportVersion(entry)
        guard VersionRunner.detect(folder) != .unknown, let rootPath = entry.codeRoot else { return nil }
        let running = try await runner.start(directory: folder, original: URL(fileURLWithPath: rootPath))
        runningVersions[entry.id] = running.url
        return running.url
    }

    /// The copied site of an HTML capture, in Margin's folder.
    func siteFolder(_ entry: Entry) -> URL? {
        guard let folder = entry.siteFolder else { return nil }
        let url = store.baseURL.appendingPathComponent(folder, isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Opens an HTML capture's copy in the browser, served by Margin; the
    /// file itself if the server can't start.
    func openSite(_ entry: Entry) {
        if let url = siteURL(entry) { NSWorkspace.shared.open(url) }
    }

    /// Where an HTML capture's copy can be seen: served by Margin, or the
    /// file itself if the server can't start. nil without a copy.
    func siteURL(_ entry: Entry) -> URL? {
        guard let folder = siteFolder(entry) else { return nil }
        let page = entry.sitePage ?? "index.html"
        do {
            return try sites.url(for: folder, page: page)
        } catch {
            MarginLog.info("Site server didn't start (\(error)); using the file")
            return folder.appendingPathComponent(page)
        }
    }

    func stopVersion(_ entry: Entry) {
        guard let rootPath = entry.codeRoot, let commit = entry.snapshot else { return }
        let folder = store.baseURL
            .appendingPathComponent("versions/\(URL(fileURLWithPath: rootPath).lastPathComponent)-\(commit.prefix(7))", isDirectory: true)
        runner.stop(folder)
        runningVersions[entry.id] = nil
    }

    /// The change this iteration made, as a unified diff.
    func diff(for entry: Entry) async -> String {
        guard let rootPath = entry.codeRoot, let commit = entry.snapshot else { return "" }
        let snapshots = self.snapshots
        let base = entry.baseSnapshot
        let fromRepo = entry.snapshotSource == "repo"
        return await Task.detached {
            fromRepo
                ? RepoWatcher.diff(URL(fileURLWithPath: rootPath), from: base, to: commit)
                : snapshots.diff(root: URL(fileURLWithPath: rootPath), from: base, to: commit)
        }.value
    }
}
