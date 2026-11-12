import Foundation

/// Connects Claude Code to Margin by adding hooks to Claude Code's user
/// settings (~/.claude/settings.json). They apply to the terminal, the
/// desktop app's local sessions and the editor extensions alike.
///
/// Each hook runs a small script that forwards the event to Margin and
/// exits at once (async), so Claude is never slowed down, and nothing
/// breaks when Margin isn't running.
public struct ClaudeCodeConnector {
    public static let defaultPort: UInt16 = 47821

    public var settingsURL: URL
    public var supportDirectory: URL

    public init(
        settingsURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json"),
        supportDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".margin", isDirectory: true)
    ) {
        self.settingsURL = settingsURL
        self.supportDirectory = supportDirectory
    }

    public var scriptURL: URL { supportDirectory.appendingPathComponent("claude-hook.sh") }
    public var portURL: URL { supportDirectory.appendingPathComponent("port") }

    /// How each hook is written into settings. The marker finds ours again.
    static let marker = ".margin/claude-hook.sh"
    var command: String { "/bin/sh \"$HOME/.margin/claude-hook.sh\"" }

    /// Events Margin listens to, with their matchers.
    static let events: [(event: String, matcher: String?)] = [
        ("UserPromptSubmit", nil),
        ("PostToolUse", "Edit|Write|MultiEdit|NotebookEdit|Bash"),
        ("Stop", nil),
        ("SessionEnd", nil),
    ]

    public enum ConnectorError: Error, CustomStringConvertible {
        case unreadableSettings(String)
        public var description: String {
            switch self {
            case .unreadableSettings(let why): return "Couldn't read Claude Code's settings: \(why)"
            }
        }
    }

    static let script = """
    #!/bin/sh
    # Margin: forwards Claude Code hook events to the Margin app on this Mac.
    # Never blocks Claude and stays quiet when Margin isn't running.
    PORT=$(cat "$HOME/.margin/port" 2>/dev/null || echo 47821)
    curl -s -m 3 -X POST -H 'Content-Type: application/json' -H 'Expect:' \\
      --data-binary @- "http://127.0.0.1:${PORT}/hooks/claude-code" >/dev/null 2>&1
    exit 0

    """

    // MARK: State

    public var isConnected: Bool {
        guard let settings = try? readSettings(), let hooks = settings["hooks"] as? [String: Any] else { return false }
        return Self.events.allSatisfy { Self.contains(hooks[$0.event]) }
    }

    /// Writes the script and the port Margin listens on. Safe to repeat.
    public func writeSupportFiles(port: UInt16) throws {
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try Self.script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        try "\(port)\n".write(to: portURL, atomically: true, encoding: .utf8)
    }

    // MARK: Connect / disconnect

    public func connect(port: UInt16) throws {
        try writeSupportFiles(port: port)
        var settings = try readSettings()
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for (event, matcher) in Self.events {
            var groups = (hooks[event] as? [[String: Any]]) ?? []
            groups = groups.compactMap(Self.removingOurs)
            var group: [String: Any] = ["hooks": [["type": "command", "command": command, "async": true, "timeout": 10]]]
            if let matcher { group["matcher"] = matcher }
            groups.append(group)
            hooks[event] = groups
        }
        settings["hooks"] = hooks
        try writeSettings(settings)
    }

    public func disconnect() throws {
        var settings = try readSettings()
        guard var hooks = settings["hooks"] as? [String: Any] else { return }
        for (event, _) in Self.events {
            let groups = ((hooks[event] as? [[String: Any]]) ?? []).compactMap(Self.removingOurs)
            hooks[event] = groups.isEmpty ? nil : groups
        }
        settings["hooks"] = hooks.isEmpty ? nil : hooks
        try writeSettings(settings)
    }

    // MARK: Helpers

    static func contains(_ value: Any?) -> Bool {
        guard let groups = value as? [[String: Any]] else { return false }
        return groups.contains { group in
            ((group["hooks"] as? [[String: Any]]) ?? []).contains { ($0["command"] as? String)?.contains(marker) == true }
        }
    }

    /// The group without Margin's hook; nil if nothing else was in it.
    static func removingOurs(_ group: [String: Any]) -> [String: Any]? {
        var group = group
        let handlers = ((group["hooks"] as? [[String: Any]]) ?? []).filter { ($0["command"] as? String)?.contains(marker) != true }
        if handlers.isEmpty { return nil }
        group["hooks"] = handlers
        return group
    }

    func readSettings() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return [:] }
        let data = try Data(contentsOf: settingsURL)
        if data.isEmpty || String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [:] }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConnectorError.unreadableSettings("\(settingsURL.path) isn't valid JSON")
        }
        return json
    }

    func writeSettings(_ settings: [String: Any]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Keep the original once, in case anything goes wrong.
        let backup = settingsURL.appendingPathExtension("before-margin")
        if fm.fileExists(atPath: settingsURL.path), !fm.fileExists(atPath: backup.path) {
            try? fm.copyItem(at: settingsURL, to: backup)
        }
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: settingsURL, options: .atomic)
    }
}
