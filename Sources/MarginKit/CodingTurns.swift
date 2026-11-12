import Foundation

/// An event from a coding agent's hooks, in the shape Claude Code sends:
/// session_id, cwd, hook_event_name, and per event prompt, tool_name,
/// tool_input, tool_response or last_assistant_message.
public struct HookEvent {
    public var name: String
    public var sessionID: String
    public var promptID: String?
    public var cwd: URL?
    public var transcriptPath: URL?
    public var prompt: String?
    public var toolName: String?
    public var filePath: String?
    /// Text the tool printed (Bash stdout and stderr).
    public var toolOutput: String?
    public var lastAssistantMessage: String?
    /// "Claude Code", "Cursor"…
    public var agent: String

    public init(name: String, sessionID: String, agent: String = "Claude Code") {
        self.name = name
        self.sessionID = sessionID
        self.agent = agent
    }

    /// Parses Claude Code's hook JSON. Nil if it isn't one.
    public static func claudeCode(_ data: Data) -> HookEvent? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = json["hook_event_name"] as? String,
              let session = json["session_id"] as? String else { return nil }
        var event = HookEvent(name: name, sessionID: session)
        event.promptID = json["prompt_id"] as? String
        event.cwd = (json["cwd"] as? String).map { URL(fileURLWithPath: $0) }
        event.transcriptPath = (json["transcript_path"] as? String).map { URL(fileURLWithPath: $0) }
        event.prompt = json["prompt"] as? String
        event.toolName = json["tool_name"] as? String
        let input = json["tool_input"] as? [String: Any]
        event.filePath = (input?["file_path"] as? String) ?? (input?["notebook_path"] as? String)
        if let response = json["tool_response"] as? [String: Any] {
            event.toolOutput = [response["stdout"], response["stderr"]].compactMap { $0 as? String }.joined(separator: "\n")
        } else if let response = json["tool_response"] as? String {
            event.toolOutput = response
        }
        event.lastAssistantMessage = json["last_assistant_message"] as? String
        return event
    }

    /// Tools that write files.
    public static let editingTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]
    public var isEdit: Bool { toolName.map(Self.editingTools.contains) ?? false }
}

/// Reads Claude Code's session transcript (JSON lines).
public enum Transcript {
    /// The session's title Claude Code generated, e.g. "Index.html h1 greeting".
    public static func title(at url: URL) -> String? {
        lastRecord(at: url, type: "ai-title")?["aiTitle"] as? String
    }

    /// The last thing the assistant said, as plain text.
    public static func lastAssistantText(at url: URL) -> String? {
        for line in tail(of: url).reversed() {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  json["type"] as? String == "assistant",
                  let message = json["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }
            let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        }
        return nil
    }

    static func lastRecord(at url: URL, type: String) -> [String: Any]? {
        for line in tail(of: url).reversed() where line.contains("\"\(type)\"") {
            if let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], json["type"] as? String == type {
                return json
            }
        }
        return nil
    }

    /// The last lines of a possibly large file.
    static func tail(of url: URL, bytes: Int = 512_000) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        var lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        if start > 0, !lines.isEmpty { lines.removeFirst() } // partial first line
        return lines.filter { !$0.isEmpty }
    }
}

/// One instruction and what the agent did with it.
public final class CodingTurn: Identifiable {
    public let id = UUID()
    public let sessionID: String
    public let agent: String
    public let prompt: String
    public let cwd: URL?
    public let transcriptPath: URL?
    public let startedAt: Date
    public internal(set) var endedAt: Date?
    /// The project folder, nil if the session isn't in a project.
    public internal(set) var root: URL?
    public internal(set) var before: CodeSnapshots.Snapshot?
    public internal(set) var after: CodeSnapshots.Snapshot?
    /// The agent wrote files during this turn (Edit, Write…).
    public internal(set) var edited = false
    public internal(set) var editedFiles: [String] = []
    /// Local URLs seen in tool output, e.g. a dev server's address.
    public internal(set) var mentionedURLs: [URL] = []
    /// What the agent said at the end.
    public internal(set) var summary: String?
    /// The designer's expectation, typed while the agent worked.
    public var expectation: String?
    public internal(set) var interrupted = false

    init(sessionID: String, agent: String, prompt: String, cwd: URL?, transcriptPath: URL?) {
        self.sessionID = sessionID
        self.agent = agent
        self.prompt = prompt
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        startedAt = Date()
    }

    /// Files actually differ between before and after.
    public var changedFiles: Bool {
        guard let after else { return false }
        guard let before else { return after.changed }
        return before.tree != after.tree
    }

    public var duration: TimeInterval { (endedAt ?? Date()).timeIntervalSince(startedAt) }
}

/// Turns hook events into iterations. A turn starts when you send a prompt
/// and ends when the agent stops. Margin snapshots the project before and
/// after; only turns that changed files are kept, so research and questions
/// leave nothing behind.
@MainActor
public final class CodingTurnTracker {
    public var onTurnStarted: ((CodingTurn) -> Void)?
    /// Called once per turn. `kept` is false when no files changed.
    public var onTurnFinished: ((CodingTurn, _ kept: Bool) -> Void)?
    /// The agent wrote a file (first edit of a turn and every one after).
    public var onEdit: ((CodingTurn) -> Void)?

    public private(set) var active: [String: CodingTurn] = [:]
    private let snapshots: CodeSnapshots
    /// Snapshots run here, in order: before always finishes before after.
    private let queue = DispatchQueue(label: "margin.snapshots")

    public init(snapshots: CodeSnapshots) {
        self.snapshots = snapshots
    }

    public func handle(_ event: HookEvent) {
        switch event.name {
        case "UserPromptSubmit":
            if let open = active[event.sessionID] {
                open.interrupted = true
                finish(open, summary: nil)
            }
            begin(event)
        case "PostToolUse", "PostToolUseFailure":
            guard let turn = active[event.sessionID] else { return }
            if event.isEdit {
                turn.edited = true
                if let path = event.filePath, !turn.editedFiles.contains(path) { turn.editedFiles.append(path) }
                onEdit?(turn)
            }
            if let output = event.toolOutput {
                for url in DevServer.urls(in: output) where !turn.mentionedURLs.contains(url) {
                    turn.mentionedURLs.append(url)
                }
            }
        case "Stop", "StopFailure":
            guard let turn = active[event.sessionID] else { return }
            finish(turn, summary: event.lastAssistantMessage)
        case "SessionEnd":
            if let turn = active[event.sessionID] { finish(turn, summary: nil) }
        default:
            break
        }
    }

    private func begin(_ event: HookEvent) {
        let turn = CodingTurn(
            sessionID: event.sessionID,
            agent: event.agent,
            prompt: event.prompt ?? "",
            cwd: event.cwd,
            transcriptPath: event.transcriptPath
        )
        active[event.sessionID] = turn
        onTurnStarted?(turn)
        guard let cwd = event.cwd else { return }
        let snapshots = self.snapshots
        let message = "before: \(turn.prompt.prefix(200))"
        queue.async {
            let root = CodeSnapshots.projectRoot(for: cwd)
            let before = root.flatMap { try? snapshots.snapshot(root: $0, message: message) }
            DispatchQueue.main.async {
                turn.root = root
                turn.before = before
            }
        }
    }

    private func finish(_ turn: CodingTurn, summary: String?) {
        guard active[turn.sessionID] === turn else { return }
        active[turn.sessionID] = nil
        turn.endedAt = Date()
        turn.summary = summary ?? turn.transcriptPath.flatMap(Transcript.lastAssistantText)
        let snapshots = self.snapshots
        let message = turn.prompt.isEmpty ? "iteration" : String(turn.prompt.prefix(500))
        let cwd = turn.cwd
        queue.async {
            // The before snapshot was queued first, so it's done by now.
            var root: URL?
            var after: CodeSnapshots.Snapshot?
            if let cwd, let projectRoot = CodeSnapshots.projectRoot(for: cwd) {
                root = projectRoot
                after = try? snapshots.snapshot(root: projectRoot, message: message)
            }
            DispatchQueue.main.async {
                turn.root = root ?? turn.root
                turn.after = after
                self.onTurnFinished?(turn, turn.changedFiles)
            }
        }
    }
}
