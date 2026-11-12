import Foundation

/// Reads a Claude Code session (JSON lines in ~/.claude/projects) down to
/// what matters for a design record: the designer's prompts and Claude's
/// replies in words, without tool calls, file contents or pictures, with
/// anything that looks like a secret taken out.
public enum SessionReader {
    public struct Turn: Equatable {
        public var date: Date
        /// true: the designer; false: Claude.
        public var designer: Bool
        public var text: String
    }

    public struct Session {
        public var id: String
        public var cwd: String?
        public var turns: [Turn]
        public var title: String?
    }

    public static func read(_ url: URL) -> Session? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        var turns: [Turn] = []
        var cwd: String?
        var title: String?
        var sessionID = url.deletingPathExtension().lastPathComponent
        for slice in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            // Lines with pictures or whole files are large and never words we need.
            guard slice.count < 400_000 else { continue }
            guard let json = try? JSONSerialization.jsonObject(with: Data(slice)) as? [String: Any] else { continue }
            let type = json["type"] as? String
            if type == "ai-title", let t = json["aiTitle"] as? String { title = t }
            guard type == "user" || type == "assistant" else { continue }
            if json["isMeta"] as? Bool == true || json["isSidechain"] as? Bool == true { continue }
            if cwd == nil, let c = json["cwd"] as? String { cwd = c }
            if let s = json["sessionId"] as? String { sessionID = s }
            let stamp = json["timestamp"] as? String
            let date = stamp.flatMap { iso.date(from: $0) ?? isoPlain.date(from: $0) } ?? Date.distantPast
            guard let message = json["message"] as? [String: Any] else { continue }
            var text = ""
            if let s = message["content"] as? String {
                text = s
            } else if let items = message["content"] as? [[String: Any]] {
                text = items.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
            }
            text = clean(text)
            guard !text.isEmpty else { continue }
            turns.append(Turn(date: date, designer: type == "user", text: text))
        }
        guard turns.contains(where: \.designer) else { return nil }
        return Session(id: sessionID, cwd: cwd, turns: turns, title: title)
    }

    /// Drops the harness's own notes and anything that looks like a key,
    /// token or password.
    static func clean(_ raw: String) -> String {
        var text = raw
        // System reminders, command wrappers and hook output aren't the designer's words.
        for tag in ["system-reminder", "command-name", "command-message", "command-args", "local-command-stdout", "user-prompt-submit-hook"] {
            text = text.replacingOccurrences(of: "<\(tag)>[\\s\\S]*?</\(tag)>", with: "", options: .regularExpression)
        }
        if text.hasPrefix("Caveat:") || text.hasPrefix("[Request interrupted") { return "" }
        return redact(text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func redact(_ text: String) -> String {
        var out = text
        let patterns = [
            "sk-[A-Za-z0-9_\\-]{16,}", "AIza[0-9A-Za-z_\\-]{20,}", "gh[pousr]_[A-Za-z0-9]{20,}", "xox[abpr]-[A-Za-z0-9\\-]{10,}",
            "figd_[A-Za-z0-9_\\-]{20,}", "(?i)(password|passwd|secret|token|api[_ ]?key)\\s*[:=]\\s*\\S+",
            "[A-Za-z0-9+/=_\\-]{40,}",
        ]
        for p in patterns { out = out.replacingOccurrences(of: p, with: "[removed]", options: .regularExpression) }
        return out
    }

    /// The session as dated lines, short enough to send: every prompt of the
    /// designer (shortened), Claude's replies shorter still, and when it's
    /// still too long, an even sample across the whole session.
    public static func condensed(_ session: Session, maxCharacters: Int = 60_000) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        func lines(prompt: Int, reply: Int) -> [String] {
            session.turns.compactMap { turn in
                let limit = turn.designer ? prompt : reply
                guard limit > 0 else { return nil }
                let words = turn.text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                let short = words.count > limit ? String(words.prefix(limit)) + "…" : words
                return "[\(formatter.string(from: turn.date))] \(turn.designer ? "Designer" : "Claude"): \(short)"
            }
        }
        for (p, r) in [(700, 300), (500, 150), (400, 0)] {
            let all = lines(prompt: p, reply: r)
            if all.reduce(0, { $0 + $1.count + 1 }) <= maxCharacters { return all.joined(separator: "\n") }
        }
        let all = lines(prompt: 300, reply: 0)
        let total = all.reduce(0) { $0 + $1.count + 1 }
        let keep = max(1, all.count * maxCharacters / max(total, 1))
        let stride = Double(all.count) / Double(keep)
        return (0..<keep).map { all[min(all.count - 1, Int(Double($0) * stride))] }.joined(separator: "\n")
    }

    /// Only the designer's prompts, for matching a session to a project.
    public static func designerWords(_ session: Session, limit: Int = 4_000) -> String {
        String(session.turns.filter(\.designer).map(\.text).joined(separator: " ").prefix(limit))
    }
}

/// One thing worth keeping from a session: a decision, something tried or
/// dropped, a change of direction, feedback that changed something.
public struct ProcessNote: Codable, Equatable {
    public var date: Date
    /// decision, tried, dropped, changed, feedback
    public var kind: String
    public var text: String
    /// The designer's own reason, only when they gave one.
    public var why: String?
}

/// Turns a condensed session into a few process notes, with Gemini.
public struct ProcessNoteWriter {
    public var gemini: GeminiClient?
    public var model: String

    public init(config: AIConfig, session: URLSession = .shared) {
        gemini = config.gemini.map { GeminiClient(apiKey: $0, session: session) }
        model = config.summary
    }

    static let system = """
    You read a designer's working session with an AI coding assistant and keep only what belongs in their design record. \
    Keep: a decision and its reason, something tried and dropped (and why), a change of direction, feedback that changed something. \
    Drop: small fixes, build errors, debugging, back-and-forth on wording, setup, anything private or personal, keys and passwords. \
    A reason ("why") only if the designer said it: quote or closely paraphrase their words. Never invent a reason; leave it empty. \
    Each note is one plain, specific sentence about the product or its design, at most 25 words. No em dashes. No praise. \
    At most 12 notes; fewer is better. If nothing is worth keeping, return none.
    """

    static let schema: [String: Any] = [
        "type": "OBJECT",
        "properties": [
            "notes": [
                "type": "ARRAY",
                "items": [
                    "type": "OBJECT",
                    "properties": [
                        "date": ["type": "STRING", "description": "yyyy-MM-dd of the moment in the session."],
                        "kind": ["type": "STRING", "enum": ["decision", "tried", "dropped", "changed", "feedback"]],
                        "text": ["type": "STRING"],
                        "why": ["type": "STRING", "description": "The designer's own reason, or empty."],
                    ],
                    "required": ["date", "kind", "text"],
                ],
            ],
        ],
        "required": ["notes"],
    ]

    public func notes(from condensed: String) async throws -> [ProcessNote] {
        guard let gemini else { throw AIError.missingKey("Gemini") }
        let data = try await gemini.generateJSON(model: model, system: Self.system, parts: [.text("Session:\n" + condensed)],
                                                 schema: Self.schema, temperature: 0.2, timeout: 90)
        struct Raw: Decodable { struct N: Decodable { var date: String; var kind: String; var text: String; var why: String? }; var notes: [N] }
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return raw.notes.compactMap { n in
            let text = n.text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "—", with: ",")
            guard !text.isEmpty else { return nil }
            let why = n.why?.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "—", with: ",")
            return ProcessNote(date: formatter.date(from: n.date) ?? Date(), kind: n.kind, text: text,
                               why: (why?.isEmpty ?? true) ? nil : why)
        }
    }
}
