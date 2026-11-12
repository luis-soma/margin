import Foundation

/// Names the groups on a project's map, the themes and the patterns inside
/// them, each by what the designer was deciding or working out. One call
/// names every group that needs a name; the designer's own headlines are
/// passed along unchanged so the new names fit around them.
public struct PatternNamer {
    public struct Group {
        /// Short id for the model, like "2" (a theme) or "2.1" (a pattern in it).
        public var id: String
        /// 0 a pattern, 1 a theme.
        public var tier: Int
        /// The name it has. Nil asks for one.
        public var name: String?
        /// The designer wrote this name: keep it, build around it.
        public var designer: Bool
        /// One line per capture in it (patterns only).
        public var lines: [String]

        public init(id: String, tier: Int, name: String?, designer: Bool = false, lines: [String]) {
            self.id = id
            self.tier = tier
            self.name = name
            self.designer = designer
            self.lines = lines
        }
    }

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
    You name the groups on a map of one design project. Its captures (screenshots, notes, chats with AI, code changes, \
    decisions) were grouped by meaning: themes, and patterns inside each theme. Ids show the nesting: theme 2 holds \
    patterns 2.1, 2.2.
    Some names were written by the designer (marked DESIGNER). Never change them; they show how the designer sees the \
    project, so name the other groups in the same spirit and so they sit well beside them.
    Name each group marked NEW by the design question, decision or part of the project it is about: what the designer \
    was deciding, testing or working out there. Think in process: framing the problem, research, exploring options, \
    deciding, refining, testing.
    THEME: the broad parts of the project's focus, 2 to 4 words. PATTERN: narrower, 2 to 5 words.
    Plain sentence case, concrete, like "Setting direction of intent", "Softening the AI's replies", "Choosing the \
    intervention tone". Never generic: not "Design work", "Screenshots", "Miscellaneous", "UI exploration", \
    "Iterations", "Various". A pattern never repeats its theme's name. No two groups share a name.
    Use the designer's own words when they give them. Never invent reasons. No em dashes.
    """

    static let schema: [String: Any] = [
        "type": "OBJECT",
        "properties": [
            "names": [
                "type": "ARRAY",
                "items": [
                    "type": "OBJECT",
                    "properties": [
                        "id": ["type": "STRING"],
                        "name": ["type": "STRING"],
                    ],
                    "required": ["id", "name"],
                ],
            ],
        ],
        "required": ["names"],
    ]

    static func prompt(_ groups: [Group]) -> String {
        var out: [String] = []
        for group in groups.sorted(by: { $0.id.localizedStandardCompare($1.id) == .orderedAscending }) {
            let head = "[\(group.id)] \(group.tier == 1 ? "THEME" : "PATTERN")"
            if let name = group.name, group.designer {
                out.append("\(head) DESIGNER \"\(name)\"")
            } else if let name = group.name {
                out.append("\(head) named \"\(name)\"")
            } else {
                out.append("\(head) NEW")
            }
            if group.tier == 0 {
                for line in group.lines.prefix(14) { out.append("  - \(line)") }
                if group.lines.count > 14 { out.append("  - and \(group.lines.count - 14) more like these") }
                if group.lines.isEmpty { out.append("  - (no captures yet)") }
            }
        }
        return "Groups:\n" + out.joined(separator: "\n")
    }

    /// Names for the groups marked new, by id.
    public func name(_ groups: [Group]) async throws -> [String: String] {
        guard let gemini else { throw AIError.missingKey("Gemini") }
        guard groups.contains(where: { $0.name == nil }) else { return [:] }
        let data = try await gemini.generateJSON(model: model, system: Self.system, parts: [.text(Self.prompt(groups))],
                                                 schema: Self.schema, temperature: 0.3, timeout: 60)
        struct Raw: Decodable {
            struct Name: Decodable { var id: String; var name: String }
            var names: [Name]
        }
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        let wanted = Set(groups.filter { $0.name == nil }.map(\.id))
        var result: [String: String] = [:]
        for item in raw.names {
            let id = item.id.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
            let name = item.name
                .replacingOccurrences(of: "—", with: ",")
                .trimmingCharacters(in: CharacterSet(charactersIn: " .\"\n"))
            guard wanted.contains(id), !name.isEmpty, result[id] == nil else { continue }
            result[id] = name
        }
        return result
    }
}
