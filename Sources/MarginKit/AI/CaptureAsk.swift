import Foundation

/// Ask: a designer asks about their project in their own words ("where did I
/// work out the problem", "visuals for the case study") and gets back the
/// captures that answer it, best first, a short reply, and a name for them
/// as a group. One call over one line per capture.
public struct CaptureAsk {
    /// One capture as the model sees it: a short id and one line about it.
    public struct Item {
        public var id: String
        public var line: String

        public init(id: String, line: String) {
            self.id = id
            self.line = line
        }
    }

    public struct Answer: Equatable {
        /// The captures that answer the question, best first.
        public var ids: [String]
        /// One or two plain sentences.
        public var reply: String
        /// 2 to 5 words naming them as a group.
        public var label: String
    }

    /// Ask in the Themes view: the whole project regrouped around the
    /// question, every capture placed once.
    public struct Steering: Equatable {
        public struct Pattern: Equatable {
            public var name: String
            public var ids: [String]
        }
        public struct Theme: Equatable {
            public var name: String
            public var patterns: [Pattern]
        }
        public var themes: [Theme]
        public var reply: String
    }

    public var gemini: GeminiClient?
    public var model: String
    /// Tried when the main model fails twice (busy, slow or unavailable).
    public var fallbackModel: String?

    public init(gemini: GeminiClient?, model: String = AIConfig.defaultSummaryModel, fallbackModel: String? = nil) {
        self.gemini = gemini
        self.model = model
        self.fallbackModel = fallbackModel
    }

    public init(config: AIConfig, session: URLSession = .shared) {
        self.init(gemini: config.gemini.map { GeminiClient(apiKey: $0, session: session) }, model: config.summary,
                  fallbackModel: config.annotate == config.summary ? nil : config.annotate)
    }

    /// One call with patience: the main model, again after a short wait if
    /// it was busy or slow, then the lighter model. Each failure is logged.
    func generate(system: String, prompt: String, schema: [String: Any], timeout: TimeInterval,
                  onRetry: ((String) -> Void)? = nil) async throws -> Data {
        guard let gemini else { throw AIError.missingKey("Gemini") }
        var attempts: [(String, TimeInterval)] = [(model, timeout), (model, timeout)]
        if let fallbackModel { attempts.append((fallbackModel, timeout)) }
        var lastError: Error = AIError.badResponse("no attempt")
        for (index, attempt) in attempts.enumerated() {
            do {
                return try await gemini.generateJSON(model: attempt.0, system: system, parts: [.text(prompt)],
                                                     schema: schema, temperature: 0.2, timeout: attempt.1)
            } catch {
                lastError = error
                MarginLog.info("Ask: \(attempt.0) failed (try \(index + 1)): \(error)")
                if Task.isCancelled { throw error }
                // A bad key or a refused prompt won't fix itself.
                if let ai = error as? AIError, case .http(let status, _) = ai, status == 400 || status == 401 || status == 403 { throw error }
                if let ai = error as? AIError, case .blocked = ai { throw error }
                if index + 1 < attempts.count {
                    // Said out loud, never hidden: why it's taking longer.
                    onRetry?(index + 1 < 2 ? "\(Self.reason(error).prefix(1).uppercased())\(Self.reason(error).dropFirst()), trying again"
                                           : "Trying a lighter model")
                }
                if index == 0 { try? await Task.sleep(nanoseconds: 1_200_000_000) }
            }
        }
        throw lastError
    }

    /// A few words on why a call failed, for the reply.
    public static func reason(_ error: Error) -> String {
        if let url = error as? URLError {
            switch url.code {
            case .timedOut: return "Gemini took too long"
            case .notConnectedToInternet, .networkConnectionLost: return "there's no connection"
            default: return "Gemini couldn't be reached"
            }
        }
        if let ai = error as? AIError {
            switch ai {
            case .missingKey: return "there's no Gemini key"
            case .http(429, _): return "Gemini is busy right now"
            case .http(let status, _) where status >= 500: return "Gemini is having trouble"
            case .http(400, _), .http(401, _), .http(403, _): return "the Gemini key was refused"
            case .blocked: return "Gemini declined the question"
            default: return "Gemini's answer didn't come through"
            }
        }
        return "Gemini couldn't be reached"
    }

    static let system = """
    You help a designer find things in the record of one design project. Each line is one capture: a screenshot, \
    a note, a website, a chat with AI or a code change, with the date, what it is, the designer's own words about \
    why (WHY), what was seen in it (SEEN) and its topic. The designer asks a question or says what they want to show.
    Pick the captures that answer it, best first. Pick only ids from the list. Pick as many as truly fit and no more; \
    if none fit, pick none.
    reply: one or two short, plain sentences that answer the designer from what the captures show, in their own words \
    where you can. Never invent reasons, facts or results that are not in the lines. No em dashes, no markdown, no lists.
    label: 2 to 5 words naming the picked captures as a group, sentence case, concrete, like "Framing the problem".
    """

    static let schema: [String: Any] = [
        "type": "OBJECT",
        "properties": [
            "ids": ["type": "ARRAY", "items": ["type": "STRING"]],
            "reply": ["type": "STRING"],
            "label": ["type": "STRING"],
        ],
        "required": ["ids", "reply", "label"],
    ]

    static func prompt(question: String, items: [Item], context: String? = nil) -> String {
        var out: [String] = []
        // What the designer wrote about the project: background, not captures.
        if let context, !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.append("About this project, in the designer's words:")
            out.append(context)
            out.append("")
        }
        out.append("Captures:")
        for item in items { out.append("[\(item.id)] \(item.line)") }
        out.append("")
        out.append("The designer asks: \(question)")
        return out.joined(separator: "\n")
    }

    /// The captures that answer `question`, with a reply and a group name.
    public func ask(_ question: String, items: [Item], context: String? = nil, onRetry: ((String) -> Void)? = nil) async throws -> Answer {
        let data = try await generate(system: Self.system, prompt: Self.prompt(question: question, items: items, context: context),
                                      schema: Self.schema, timeout: 40, onRetry: onRetry)
        struct Raw: Decodable {
            var ids: [String]
            var reply: String
            var label: String
        }
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        let known = Set(items.map(\.id))
        var seen = Set<String>()
        let ids = raw.ids
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")) }
            .filter { known.contains($0) && seen.insert($0).inserted }
        func clean(_ text: String) -> String {
            text.replacingOccurrences(of: "—", with: ",")
                .replacingOccurrences(of: "**", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return Answer(ids: ids, reply: clean(raw.reply), label: clean(raw.label).trimmingCharacters(in: CharacterSet(charactersIn: ".\"")))
    }

    // MARK: Steering the map

    static let steerSystem = """
    You sort the record of one design project for its designer. Each line is one capture: a screenshot, a note, a \
    website, a chat with AI or a code change, with the date, what it is, the designer's own words about why (WHY), \
    what was seen in it (SEEN) and its topic. The designer tells you how they want to see the project: a question, \
    a lens or what they are making (for example "problem finding for my case study" or "how the visual style \
    evolved").
    Reorganize ALL the captures around that request: 3 to 7 themes that answer it, most relevant first, each with \
    1 to 4 patterns inside. Put every id in exactly one pattern. Captures that don't speak to the request go \
    together in one last theme named for what they are.
    Names: themes 2 to 4 words, patterns 2 to 5 words, plain sentence case, concrete, about what the designer was \
    deciding or working out, in their own words where you can. Never generic ("Miscellaneous", "Other", "UI \
    exploration", "Iterations"). No two groups share a name. No em dashes.
    reply: one or two short, plain sentences telling the designer how you sorted it and what stands out. Never \
    invent facts that are not in the lines. No markdown.
    """

    static let steerSchema: [String: Any] = [
        "type": "OBJECT",
        "properties": [
            "themes": [
                "type": "ARRAY",
                "items": [
                    "type": "OBJECT",
                    "properties": [
                        "name": ["type": "STRING"],
                        "patterns": [
                            "type": "ARRAY",
                            "items": [
                                "type": "OBJECT",
                                "properties": [
                                    "name": ["type": "STRING"],
                                    "ids": ["type": "ARRAY", "items": ["type": "STRING"]],
                                ],
                                "required": ["name", "ids"],
                            ],
                        ],
                    ],
                    "required": ["name", "patterns"],
                ],
            ],
            "reply": ["type": "STRING"],
        ],
        "required": ["themes", "reply"],
    ]

    /// The whole project regrouped around `request`. Unknown ids are dropped,
    /// each id is kept once (its first place), empty groups go.
    public func steer(_ request: String, items: [Item], context: String? = nil, onRetry: ((String) -> Void)? = nil) async throws -> Steering {
        let data = try await generate(system: Self.steerSystem, prompt: Self.prompt(question: request, items: items, context: context),
                                      schema: Self.steerSchema, timeout: 90, onRetry: onRetry)
        struct Raw: Decodable {
            struct Pattern: Decodable { var name: String; var ids: [String] }
            struct Theme: Decodable { var name: String; var patterns: [Pattern] }
            var themes: [Theme]
            var reply: String
        }
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        let known = Set(items.map(\.id))
        var placed = Set<String>()
        func clean(_ text: String) -> String {
            text.replacingOccurrences(of: "—", with: ",")
                .replacingOccurrences(of: "**", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: " .\"\n"))
        }
        var themes: [Steering.Theme] = []
        for theme in raw.themes {
            var patterns: [Steering.Pattern] = []
            for pattern in theme.patterns {
                let ids = pattern.ids
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")) }
                    .filter { known.contains($0) && placed.insert($0).inserted }
                if !ids.isEmpty { patterns.append(Steering.Pattern(name: clean(pattern.name), ids: ids)) }
            }
            if !patterns.isEmpty { themes.append(Steering.Theme(name: clean(theme.name), patterns: patterns)) }
        }
        guard !themes.isEmpty else { throw AIError.badResponse("no groups") }
        let reply = raw.reply.replacingOccurrences(of: "—", with: ",").trimmingCharacters(in: .whitespacesAndNewlines)
        return Steering(themes: themes, reply: reply)
    }
}
