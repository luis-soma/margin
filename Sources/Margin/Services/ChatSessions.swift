import AppKit
import ApplicationServices
import MarginKit

/// Captures vibe coding in Claude's chat app, where the work may happen
/// somewhere else (a cloud session) and arrive as commits pushed to GitHub.
///
/// - Your prompt is read from the Claude app's message field (Accessibility)
///   when you send it.
/// - Versions are the commits that reach your projects' remotes while Claude
///   works on that prompt (Margin fetches; it never changes your branches),
///   plus any changes to the project folders on this Mac.
/// - A turn with no new versions was a question or research: nothing is kept.
@MainActor
final class ChatSessions: ObservableObject {
    static let claudeBundleIDs: Set<String> = ["com.anthropic.claudefordesktop"]

    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "captureClaudeChats") }
    }
    /// Projects whose remotes Margin checks for new versions.
    @Published private(set) var watched: [URL]
    @Published private(set) var activeTurn: ChatTurn?
    /// Margin has read the Claude app's message field at least once.
    @Published private(set) var canReadPrompts = false

    final class ChatTurn: Identifiable {
        let id = UUID()
        let prompt: String
        let conversation: String?
        let startedAt = Date()
        var baselines: [URL: RepoWatcher.State] = [:]
        var localBefore: [URL: CodeSnapshots.Snapshot] = [:]
        var baselineReady = false
        var entryID: UUID?
        var expectation: String?
        var sawWorking = false
        var lastWorking: Date?
        var notWorkingChecks = 0
        var lastVersionAt: Date?
        var lastFetch = Date.distantPast

        init(prompt: String, conversation: String?) {
            self.prompt = prompt
            self.conversation = conversation
        }
    }

    private let store: EntryStore
    private let coding: CodingSessions
    private let queue = DispatchQueue(label: "margin.chats")
    private var timer: Timer?
    private var keyMonitor: Any?
    private var draft = ""
    private var draftAt = Date.distantPast
    private var draftInComposer = false
    private var lastSent: (text: String, at: Date)?
    private var accessibilityOn: Set<pid_t> = []
    private var tickCount = 0
    private var checking = false

    private static let watchedKey = "watchedRepos"
    private static let codingConversationsKey = "codingConversations"

    init(store: EntryStore, coding: CodingSessions) {
        self.store = store
        self.coding = coding
        // Off unless you switch it on in Settings: your Claude chats are yours.
        isEnabled = UserDefaults.standard.object(forKey: "captureClaudeChats") as? Bool ?? false
        var paths = UserDefaults.standard.stringArray(forKey: Self.watchedKey) ?? []
        // Margin's own project is watched from the start.
        if let url = Bundle.main.url(forResource: "repo-path", withExtension: nil),
           let path = try? String(contentsOf: url, encoding: .utf8).trimmed, !path.isEmpty, !paths.contains(path) {
            paths.append(path)
        }
        watched = paths.map { URL(fileURLWithPath: $0) }
    }

    func start() {
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 36 || event.keyCode == 76,
                  !event.modifierFlags.contains(.shift), !event.modifierFlags.contains(.option) else { return }
            Task { @MainActor in self?.returnPressed() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    // MARK: Projects

    func watch(_ folder: URL) {
        let path = folder.standardizedFileURL.path
        guard !watched.contains(where: { $0.path == path }) else { return }
        watched.append(URL(fileURLWithPath: path))
        UserDefaults.standard.set(watched.map(\.path), forKey: Self.watchedKey)
    }

    func unwatch(_ folder: URL) {
        watched.removeAll { $0.path == folder.path }
        UserDefaults.standard.set(watched.map(\.path), forKey: Self.watchedKey)
    }

    private var codingConversations: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.codingConversationsKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue.prefix(200)), forKey: Self.codingConversationsKey) }
    }

    // MARK: Prompts

    private var claudeInFront: NSRunningApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication, let id = app.bundleIdentifier,
              Self.claudeBundleIDs.contains(id) else { return nil }
        return app
    }

    private func tick() {
        guard isEnabled else { return }
        tickCount += 1
        if let claude = claudeInFront { readDraft(claude) }
        guard let turn = activeTurn else { return }
        // Is Claude still working? Every ~2 s.
        if tickCount % 3 == 0 { checkWorking(turn) }
        // New versions? Every 45 s, and right away once the baseline is in.
        if turn.baselineReady, !checking, Date().timeIntervalSince(turn.lastFetch) > 45 {
            checkVersions(turn, final: false)
        }
        // Without a visible "working" signal, end a turn once versions stop coming.
        if !turn.sawWorking, let last = turn.lastVersionAt, Date().timeIntervalSince(last) > 600 {
            end(turn)
        }
        if Date().timeIntervalSince(turn.startedAt) > 3 * 3600 { end(turn) }
    }

    private func readDraft(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        let element = AXUIElementCreateApplication(pid)
        if !accessibilityOn.contains(pid) {
            // Electron apps build their accessibility tree only when asked.
            AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            accessibilityOn.insert(pid)
        }
        AXUIElementSetMessagingTimeout(element, 0.2)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            draftInComposer = false
            return
        }
        let field = focused as! AXUIElement
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(field, kAXRoleAttribute as CFString, &role)
        guard let role = role as? String, role == "AXTextArea" || role == "AXTextField" else {
            draftInComposer = false
            return
        }
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(field, kAXValueAttribute as CFString, &value)
        let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !canReadPrompts, !text.isEmpty {
            canReadPrompts = true
            MarginLog.info("Reading Claude's message field (\(role))")
        }
        // Sent with the button instead of Return: the field empties.
        if text.isEmpty, draftInComposer, !draft.isEmpty, Date().timeIntervalSince(draftAt) < 3 {
            send(draft)
        }
        draftInComposer = true
        if !text.isEmpty {
            draft = text
            draftAt = Date()
        } else {
            draft = ""
        }
    }

    private func returnPressed() {
        guard isEnabled, claudeInFront != nil, draftInComposer, !draft.isEmpty,
              Date().timeIntervalSince(draftAt) < 3 else { return }
        send(draft)
        draft = ""
    }

    /// A message was sent to Claude (also used by tests).
    func send(_ prompt: String) {
        // The same message once, however it was sent.
        if let lastSent, lastSent.text == prompt, Date().timeIntervalSince(lastSent.at) < 10 { return }
        lastSent = (prompt, Date())
        let conversation = claudeInFront.flatMap { SelectionReader.windowTitle(pid: $0.processIdentifier) }
            .flatMap { $0 == "Claude" ? nil : $0 }
        MarginLog.info("Claude chat prompt (\(prompt.count) chars) in \(conversation ?? "a conversation")")
        if let open = activeTurn { end(open) }
        begin(ChatTurn(prompt: prompt, conversation: conversation))
    }

    // MARK: Turns

    private func begin(_ turn: ChatTurn) {
        activeTurn = turn
        let repos = watched
        let snapshots = coding.snapshots
        queue.async {
            var baselines: [URL: RepoWatcher.State] = [:]
            var local: [URL: CodeSnapshots.Snapshot] = [:]
            for repo in repos where RepoWatcher.isRepository(repo) {
                RepoWatcher.fetch(repo)
                baselines[repo] = RepoWatcher.state(repo)
                if let snapshot = try? snapshots.snapshot(root: repo, message: "before chat: \(turn.prompt.prefix(200))") {
                    local[repo] = snapshot
                }
            }
            DispatchQueue.main.async {
                turn.baselines = baselines
                turn.localBefore = local
                turn.baselineReady = true
                turn.lastFetch = Date()
            }
        }
    }

    /// Ends the open turn now and records what arrived (also used by tests).
    func endActiveTurn() {
        if let turn = activeTurn { end(turn) }
    }

    private func end(_ turn: ChatTurn) {
        guard activeTurn === turn else { return }
        activeTurn = nil
        checkVersions(turn, final: true)
    }

    /// Looks for a "Stop" button in Claude's window: Claude is still answering.
    private func checkWorking(_ turn: ChatTurn) {
        guard let claude = NSRunningApplication.runningApplications(withBundleIdentifier: "com.anthropic.claudefordesktop").first else { return }
        let pid = claude.processIdentifier
        Task.detached {
            let working = Self.hasStopButton(pid: pid)
            await MainActor.run {
                if working {
                    turn.sawWorking = true
                    turn.lastWorking = Date()
                    turn.notWorkingChecks = 0
                } else if turn.sawWorking {
                    turn.notWorkingChecks += 1
                    // Gone for a few seconds: Claude is done with this prompt.
                    if turn.notWorkingChecks >= 3 { self.end(turn) }
                }
            }
        }
    }

    nonisolated static func hasStopButton(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        var windows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success,
              let list = windows as? [AXUIElement] else { return false }
        var queue = list.map { ($0, 0) }
        var visited = 0
        while !queue.isEmpty, visited < 4000 {
            let (element, depth) = queue.removeFirst()
            visited += 1
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            if (role as? String) == "AXButton" {
                for attribute in [kAXDescriptionAttribute, kAXTitleAttribute, kAXHelpAttribute] {
                    var value: CFTypeRef?
                    AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
                    if let text = (value as? String)?.lowercased(), text.contains("stop") { return true }
                }
                continue
            }
            guard depth < 60 else { continue }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
               let kids = children as? [AXUIElement] {
                queue.append(contentsOf: kids.map { ($0, depth + 1) })
            }
        }
        return false
    }

    /// Fetches the watched projects and records what's new since the prompt.
    private func checkVersions(_ turn: ChatTurn, final: Bool) {
        guard turn.baselineReady else {
            if final { MarginLog.info("Chat turn ended before Margin had a baseline") }
            return
        }
        checking = true
        turn.lastFetch = Date()
        let baselines = turn.baselines
        let localBefore = turn.localBefore
        let snapshots = coding.snapshots
        queue.async {
            var found: Version?
            for (repo, baseline) in baselines {
                RepoWatcher.fetch(repo)
                let changes = RepoWatcher.changes(repo, from: baseline, to: RepoWatcher.state(repo))
                // The branch with the most new work stands for this turn.
                if let change = changes.max(by: { $0.commits.count < $1.commits.count }) {
                    let stat = RepoWatcher.diffStat(repo, from: change.base, to: change.to)
                    found = Version(repo: repo, commit: change.to, base: change.base, fromRepo: true,
                                    stat: stat, notes: change.commits.prefix(6).map(\.subject), branch: change.branch)
                    break
                }
                // Or changes right here in the folder.
                if let before = localBefore[repo],
                   let after = try? snapshots.snapshot(root: repo, message: "chat"), after.tree != before.tree {
                    let stat = snapshots.diffStat(root: repo, from: before.commit, to: after.commit)
                    found = Version(repo: repo, commit: after.commit, base: before.commit, fromRepo: false,
                                    stat: stat, notes: [], branch: nil)
                    break
                }
            }
            DispatchQueue.main.async {
                self.checking = false
                if let found { self.record(found, for: turn) }
                if final { self.finish(turn) }
            }
        }
    }

    private struct Version {
        let repo: URL
        let commit: String
        let base: String?
        let fromRepo: Bool
        let stat: CodeSnapshots.DiffStat
        let notes: [String]
        let branch: String?
    }

    private func record(_ version: Version, for turn: ChatTurn) {
        turn.lastVersionAt = Date()
        if let conversation = turn.conversation {
            var known = codingConversations
            known.insert(conversation)
            codingConversations = known
        }
        let summary = version.notes.isEmpty ? nil : version.notes.joined(separator: "\n")
        if let id = turn.entryID, store.entry(id: id) != nil {
            store.modify(id) { entry in
                entry.snapshot = version.commit
                entry.diffStat = version.stat.summary
                entry.summary = summary ?? entry.summary
            }
            return
        }
        var entry = store.newEntry(.iteration)
        entry.prompt = turn.prompt
        entry.expectation = turn.expectation
        entry.summary = summary
        entry.agent = "Claude"
        entry.sourceApp = "Claude"
        entry.codeRoot = version.repo.path
        entry.snapshot = version.commit
        entry.baseSnapshot = version.base
        entry.snapshotSource = version.fromRepo ? "repo" : nil
        entry.diffStat = version.stat.summary
        entry.windowTitle = version.repo.lastPathComponent
        entry.label = turn.conversation
        if let card = CodingSessions.codeCard(prompt: turn.prompt, stat: version.stat) {
            entry.imageFile = store.saveFile(card, ext: "png")
        }
        store.add(entry)
        turn.entryID = entry.id
        MarginLog.info("Claude chat version: \(version.stat.summary) in \(version.repo.lastPathComponent)\(version.branch.map { " (\($0))" } ?? "")")
    }

    private func finish(_ turn: ChatTurn) {
        if turn.entryID == nil {
            MarginLog.info("Claude chat turn without new versions: nothing kept")
        }
    }
}
