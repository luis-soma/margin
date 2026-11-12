import Foundation

/// One capture, as the pattern finder reads it.
public struct PatternItem {
    public var id: String
    public var date: Date
    public var app: String?
    public var window: String?
    public var title: String?
    /// The designer's words.
    public var words: String?
    public var seen: String?
    public var topic: String?
    public var tags: [String]

    public init(id: String, date: Date, app: String? = nil, window: String? = nil, title: String? = nil, words: String? = nil, seen: String? = nil, topic: String? = nil, tags: [String] = []) {
        self.id = id
        self.date = date
        self.app = app
        self.window = window
        self.title = title
        self.words = words
        self.seen = seen
        self.topic = topic
        self.tags = tags
    }
}

/// The patterns Margin sees across a whole project: a few groups of its
/// captures, each titled by what the designer was working out. Not by time.
public struct ProjectPatterns: Codable, Equatable {
    public struct Group: Codable, Equatable {
        public var title: String
        public var ids: [String]

        public init(title: String, ids: [String]) {
            self.title = title
            self.ids = ids
        }
    }

    public var groups: [Group]
    /// Which captures these were found for; a different set asks again.
    public var key: String
    /// The model that found them, or nil when Margin grouped them itself.
    public var model: String?
    public var createdAt: Date

    public init(groups: [Group], key: String, model: String?, createdAt: Date = Date()) {
        self.groups = groups
        self.key = key
        self.model = model
        self.createdAt = createdAt
    }
}

/// Sorts a project's captures into the patterns that run through it.
public struct PatternFinder {
    public var gemini: GeminiClient?
    public var model: String

    public init(gemini: GeminiClient?, model: String = AIConfig.defaultSummaryModel) {
        self.gemini = gemini
        self.model = model
    }

    public init(config: AIConfig, session: URLSession = .shared) {
        self.init(gemini: config.gemini.map { GeminiClient(apiKey: $0, session: session) }, model: config.summary)
    }

    static let system = """
    You sort the captures of one design project (screenshots, notes, chats with AI, code changes) into the patterns \
    that run through the whole project. Not by time: by what the work is about, the problems the designer keeps \
    coming back to, the threads that recur across days.
    Make 3 to 6 groups. Every capture id goes in exactly one group. Groups can be uneven if the work is.
    Title each group with what the designer was working out, 2 to 5 words, concrete, in plain sentence case, like \
    "Setting direction of intent", "Softening the AI's replies", "Making annotations peripheral". \
    Never generic: not "Design work", "Screenshots", "Miscellaneous", "UI exploration", "Iterations".
    Use the designer's own words when they give them. Never invent reasons. No em dashes.
    """

    static let schema: [String: Any] = [
        "type": "OBJECT",
        "properties": [
            "groups": [
                "type": "ARRAY",
                "items": [
                    "type": "OBJECT",
                    "properties": [
                        "title": ["type": "STRING", "description": "2 to 5 words: what the designer was working out."],
                        "ids": ["type": "ARRAY", "items": ["type": "STRING"], "description": "The ids of the captures in this pattern."],
                    ],
                    "required": ["title", "ids"],
                ],
            ],
        ],
        "required": ["groups"],
    ]

    static func prompt(_ items: [PatternItem]) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let lines = items.enumerated().map { index, item -> String in
            var parts = ["[\(index + 1)] \(formatter.string(from: item.date))"]
            if let app = item.app, !app.isEmpty { parts.append(app) }
            if let window = item.window, !window.isEmpty { parts.append("window \"\(window.prefix(80))\"") }
            if let title = item.title, !title.isEmpty { parts.append("named \"\(title.prefix(80))\"") }
            if let words = item.words, !words.isEmpty { parts.append("designer said: \"\(words.prefix(240))\"") }
            if let seen = item.seen, !seen.isEmpty { parts.append("Margin saw: \(seen.prefix(200))") }
            if let topic = item.topic, !topic.isEmpty { parts.append("topic: \(topic)") }
            if !item.tags.isEmpty { parts.append("tags: \(item.tags.prefix(6).joined(separator: ", "))") }
            return parts.joined(separator: " · ")
        }
        return "Captures:\n" + lines.joined(separator: "\n")
    }

    /// The groups, with every capture in exactly one of them (in the
    /// caller's ids). Captures the model left out join the group of their
    /// nearest neighbour in the list.
    public func find(_ items: [PatternItem]) async throws -> [ProjectPatterns.Group] {
        guard let gemini else { throw AIError.missingKey("Gemini") }
        guard !items.isEmpty else { return [] }
        let data = try await gemini.generateJSON(model: model, system: Self.system, parts: [.text(Self.prompt(items))], schema: Self.schema, temperature: 0.3, timeout: 60)
        struct Raw: Decodable {
            struct Group: Decodable { var title: String; var ids: [String] }
            var groups: [Group]
        }
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        return Self.complete(raw.groups.map { ($0.title, $0.ids) }, items: items)
    }

    /// Maps the model's short ids back, keeps each capture in its first
    /// group only, and places any it missed beside their nearest neighbour.
    static func complete(_ groups: [(title: String, ids: [String])], items: [PatternItem]) -> [ProjectPatterns.Group] {
        var owner = [Int?](repeating: nil, count: items.count)
        var titles: [String] = []
        for (title, ids) in groups {
            let clean = title.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "—", with: ",")
            guard !clean.isEmpty else { continue }
            let group = titles.count
            var took = false
            for id in ids {
                let digits = id.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                guard let n = Int(digits), (1...items.count).contains(n), owner[n - 1] == nil else { continue }
                owner[n - 1] = group
                took = true
            }
            if took { titles.append(clean) }
        }
        guard !titles.isEmpty else { return [] }
        for index in items.indices where owner[index] == nil {
            var step = 1
            while step < items.count {
                if index - step >= 0, let g = owner[index - step] { owner[index] = g; break }
                if index + step < items.count, let g = owner[index + step] { owner[index] = g; break }
                step += 1
            }
            if owner[index] == nil { owner[index] = 0 }
        }
        var ids = [[String]](repeating: [], count: titles.count)
        for (index, group) in owner.enumerated() { ids[group ?? 0].append(items[index].id) }
        return zip(titles, ids).filter { !$0.1.isEmpty }.map { ProjectPatterns.Group(title: $0.0, ids: $0.1) }
    }
}
