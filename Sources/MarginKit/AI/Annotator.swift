import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Shrinks captures before they are sent anywhere.
public enum ImagePrep {
    /// A JPEG no larger than `maxPixel` on its long edge.
    public static func jpeg(contentsOf url: URL, maxPixel: Int = 1024, quality: Double = 0.8) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return jpeg(source: source, maxPixel: maxPixel, quality: quality)
    }

    public static func jpeg(data: Data, maxPixel: Int = 1024, quality: Double = 0.8) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return jpeg(source: source, maxPixel: maxPixel, quality: quality)
    }

    private static func jpeg(source: CGImageSource, maxPixel: Int, quality: Double) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }

    static func mime(of data: Data) -> String {
        data.starts(with: [0xFF, 0xD8, 0xFF]) ? "image/jpeg" : "image/png"
    }
}

// MARK: - Notes on captures

/// What Margin saw in a capture. Facts only: never the designer's reasons.
public struct CaptureNote: Codable, Hashable {
    /// 2 to 5 words naming what the capture is: the artifact's title when
    /// the designer hasn't named it ("Paywall, annual plan selected").
    public var title: String?
    /// One line: what the capture shows.
    public var seen: String
    /// What looks different from the previous version of the same thing.
    public var changed: String?
    /// The most important readable text, for search.
    public var visibleText: String?
    public var tags: [String]
    /// What is being designed, e.g. "Filter overlay". A suggested tab.
    public var topic: String?
    /// How likely the previous capture shows an earlier version of the same thing.
    public var sameThingAsBefore: Double?
    /// 0 none, 1 small, 2 notable, 3 major.
    public var changeSize: Double?
    public var model: String?
    public var createdAt: Date

    public init(title: String? = nil, seen: String, changed: String? = nil, visibleText: String? = nil, tags: [String] = [], topic: String? = nil,
                sameThingAsBefore: Double? = nil, changeSize: Double? = nil, model: String? = nil, createdAt: Date = Date()) {
        self.title = title
        self.seen = seen
        self.changed = changed
        self.visibleText = visibleText
        self.tags = tags
        self.topic = topic
        self.sameThingAsBefore = sameThingAsBefore
        self.changeSize = changeSize
        self.model = model
        self.createdAt = createdAt
    }

    public var isBigChange: Bool { (changeSize ?? 0) >= 2 }
}

/// What Margin knows around a capture.
public struct CaptureContext {
    public var kind: String
    public var app: String?
    public var window: String?
    /// e.g. the Figma frame's name.
    public var label: String?
    /// The designer's own words, if any. Context only; never rewritten.
    public var designerWords: String?
    /// Tabs and suggested tabs in the project, with a line about what's in each.
    public var topics: [(name: String, example: String)]

    public init(kind: String, app: String? = nil, window: String? = nil, label: String? = nil, designerWords: String? = nil, topics: [(name: String, example: String)] = []) {
        self.kind = kind
        self.app = app
        self.window = window
        self.label = label
        self.designerWords = designerWords
        self.topics = topics
    }
}

public struct Annotator {
    public var gemini: GeminiClient?
    public var decisions: DecisionsClient?
    public var model: String

    public init(gemini: GeminiClient?, decisions: DecisionsClient?, model: String = AIConfig.defaultAnnotateModel) {
        self.gemini = gemini
        self.decisions = decisions
        self.model = model
    }

    public init(config: AIConfig, session: URLSession = .shared) {
        self.init(
            gemini: config.gemini.map { GeminiClient(apiKey: $0, session: session) },
            decisions: config.openai.map { DecisionsClient(apiKey: $0, model: config.decisions, session: session) },
            model: config.annotate
        )
    }

    static let system = """
    You write short factual notes on captures from a designer's work, for their process archive.
    Describe only what is visible. Never state or guess reasons, goals or intentions. Never use words like \
    "to improve", "for better", "because", "in order to", "aims", "clearer", "more intuitive". \
    The designer writes the why; you only say what is there and what changed.
    Be concrete and plain: name components, layout, colors, text. No praise, no judgement.
    """

    static let schema: [String: Any] = [
        "type": "OBJECT",
        "properties": [
            "title": ["type": "STRING", "description": "2 to 5 words naming what this capture is, specific to it: the screen, component or content and its state, e.g. \"Paywall, annual plan selected\", \"Filter sheet with tag chips\", \"Checkout error state\". Never generic (not \"UI screen\", \"Design\", \"Capture\", \"Screenshot\", \"Figma file\"). No reasons. Sentence case, no period."],
            "seen": ["type": "STRING", "description": "One sentence, at most 14 words: what the capture shows."],
            "changed": ["type": "STRING", "description": "If a previous version is given: at most 16 words on the visible differences, most important first. Empty if none or no previous version."],
            "visible_text": ["type": "STRING", "description": "The most important readable text in the capture, at most 30 words. Empty if none."],
            "tags": ["type": "ARRAY", "items": ["type": "STRING"], "description": "2 to 4 lowercase nouns: component or screen types, e.g. banner, chat, onboarding."],
            "topic": ["type": "STRING", "description": "1 to 3 words naming the thing being designed, e.g. Filter overlay. Reuse an existing topic name exactly if it fits."],
        ],
        "required": ["title", "seen", "changed", "visible_text", "tags", "topic"],
    ]

    struct GeminiNote: Decodable {
        var title: String?
        var seen: String
        var changed: String?
        var visible_text: String?
        var tags: [String]?
        var topic: String?
    }

    func contextText(_ context: CaptureContext, hasPrevious: Bool) -> String {
        var lines = ["Capture type: \(context.kind)"]
        if let app = context.app { lines.append("App: \(app)") }
        if let window = context.window, !window.isEmpty { lines.append("Window: \(window)") }
        if let label = context.label, !label.isEmpty { lines.append("Frame or page name: \(label)") }
        if let words = context.designerWords, !words.isEmpty { lines.append("The designer's note (context only, do not repeat or rephrase it): \(words)") }
        if !context.topics.isEmpty {
            lines.append("Existing topics: " + context.topics.map(\.name).joined(separator: "; "))
        }
        lines.append(hasPrevious
            ? "Image 1 is this capture. Image 2 is the designer's previous capture of what may be the same thing."
            : "Image 1 is this capture. There is no previous version.")
        return lines.joined(separator: "\n")
    }

    /// Notes on one capture. Gemini writes; Decisions (if available) sorts it
    /// into an existing topic and judges whether and how much it changed.
    public func annotate(image: Data, previous: Data?, context: CaptureContext) async throws -> CaptureNote {
        guard let gemini else { throw AIError.missingKey("Gemini") }
        let text = contextText(context, hasPrevious: previous != nil)
        var builder: [GeminiClient.Part] = [.text(text), .image(image, mime: ImagePrep.mime(of: image))]
        if let previous { builder.append(.image(previous, mime: ImagePrep.mime(of: previous))) }
        let parts = builder

        async let written = gemini.generateJSON(model: model, system: Self.system, parts: parts, schema: Self.schema, timeout: 30)
        async let decided = decide(image: image, previous: previous, context: context)

        let raw = try JSONDecoder().decode(GeminiNote.self, from: try await written)
        let answers = await decided

        var note = CaptureNote(
            title: raw.title.map(Self.cleanTitle)?.nilIfEmpty,
            seen: raw.seen.trimmed,
            changed: raw.changed?.trimmed.nilIfEmpty,
            visibleText: raw.visible_text?.trimmed.nilIfEmpty,
            tags: (raw.tags ?? []).map { $0.trimmed.lowercased() }.filter { !$0.isEmpty }.prefix(4).map { $0 },
            topic: raw.topic?.trimmed.nilIfEmpty,
            model: model
        )
        if previous == nil { note.changed = nil }

        if let same = answers["same_thing"]?.probability {
            note.sameThingAsBefore = same
            // Not the same thing: a "what changed" would compare apples and pears.
            if same < 0.5 { note.changed = nil }
        }
        if let size = answers["change_size"]?.score, (note.sameThingAsBefore ?? 1) >= 0.5 {
            note.changeSize = size
        }
        // Prefer an existing topic when Decisions is confident it fits.
        if let pick = answers["topic"], let choice = pick.choice, choice != Self.newTopic,
           (pick.confidence ?? 0) >= 0.55, context.topics.contains(where: { $0.name == choice }) {
            note.topic = choice
        } else if let topic = note.topic,
                  let existing = context.topics.first(where: { $0.name.caseInsensitiveCompare(topic) == .orderedSame }) {
            note.topic = existing.name
        }
        return note
    }

    static let newTopic = "__new__"

    /// Short, no trailing period, no quotes.
    static func cleanTitle(_ text: String) -> String {
        var title = text.trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”."))
        if title.count > 60 { title = String(title.prefix(58)) + "…" }
        return title
    }

    static let textSystem = """
    You write short factual notes on a piece of text a designer captured for their process archive \
    (copy, notes, a spec, a message, research). Say what the text is about, never why it was captured.
    Be concrete and plain. No praise, no judgement.
    """

    static let textSchema: [String: Any] = [
        "type": "OBJECT",
        "properties": [
            "title": ["type": "STRING", "description": "2 to 5 words naming what the text is about, specific to it, e.g. \"Onboarding tone guidelines\", \"Pricing page FAQ copy\", \"User quotes on search\". Never generic (not \"Text\", \"Notes\", \"Document\"). Sentence case, no period."],
            "seen": ["type": "STRING", "description": "One sentence, at most 16 words: what the text says or covers."],
            "tags": ["type": "ARRAY", "items": ["type": "STRING"], "description": "2 to 4 lowercase nouns for what it's about, e.g. copy, pricing, research."],
            "topic": ["type": "STRING", "description": "1 to 3 words naming the thing being designed it belongs to. Reuse an existing topic name exactly if it fits."],
        ],
        "required": ["title", "seen", "tags", "topic"],
    ]

    /// Notes on captured text: what it's about, read from the text itself.
    public func annotate(text: String, context: CaptureContext) async throws -> CaptureNote {
        guard let gemini else { throw AIError.missingKey("Gemini") }
        var lines = ["Captured text" + (context.app.map { " from \($0)" } ?? "") + ":", String(text.prefix(6000))]
        if !context.topics.isEmpty { lines.append("Existing topics: " + context.topics.map(\.name).joined(separator: "; ")) }
        let data = try await gemini.generateJSON(model: model, system: Self.textSystem, parts: [.text(lines.joined(separator: "\n\n"))], schema: Self.textSchema, timeout: 30)
        struct Raw: Decodable { var title: String?; var seen: String; var tags: [String]?; var topic: String? }
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        var note = CaptureNote(
            title: raw.title.map(Self.cleanTitle)?.nilIfEmpty,
            seen: raw.seen.trimmed,
            tags: (raw.tags ?? []).map { $0.trimmed.lowercased() }.filter { !$0.isEmpty }.prefix(4).map { $0 },
            topic: raw.topic?.trimmed.nilIfEmpty,
            model: model
        )
        if let topic = note.topic, let existing = context.topics.first(where: { $0.name.caseInsensitiveCompare(topic) == .orderedSame }) {
            note.topic = existing.name
        }
        return note
    }

    /// Fast bounded questions. Never throws: Decisions only refines the note.
    func decide(image: Data, previous: Data?, context: CaptureContext) async -> [String: DecisionsClient.Answer] {
        guard let decisions else { return [:] }
        var questions: [DecisionsClient.Question] = []
        if !context.topics.isEmpty {
            var choices = context.topics.prefix(12).map { (value: $0.name, description: "\($0.name): \($0.example)") }
            choices.append((value: Self.newTopic, description: "Something else: none of these fit."))
            questions.append(.choice(name: "topic", instructions: "Which topic of the designer's project does image 1 belong to?", choices: choices))
        }
        if previous != nil {
            questions.append(.predicate(name: "same_thing", instructions: "Image 2 shows an earlier version of the same screen, frame or element as image 1."))
            questions.append(.score(name: "change_size", instructions: "How much did the design change from image 2 to image 1?", levels: [
                (label: "None", description: "Looks the same."),
                (label: "Small", description: "A detail: spacing, a color, a word."),
                (label: "Notable", description: "A visible change to a component or layout."),
                (label: "Major", description: "A different approach or a redesign."),
            ]))
        }
        guard !questions.isEmpty else { return [:] }
        let text = contextText(context, hasPrevious: previous != nil)
        var images = [image]
        if let previous { images.append(previous) }
        do {
            return try await decisions.decide(text: text, images: images, questions: questions)
        } catch {
            MarginLog.info("Decisions failed: \(error)")
            return [:]
        }
    }
}

// MARK: - Chapter summaries

/// One moment, as the summarizer sees it.
public struct MomentFact {
    public var id: String
    public var date: Date
    public var kind: String
    public var label: String?
    /// The designer's words: the only source of reasons.
    public var words: String?
    public var verdict: String?
    public var seen: String?
    public var changed: String?

    public init(id: String, date: Date, kind: String, label: String? = nil, words: String? = nil, verdict: String? = nil, seen: String? = nil, changed: String? = nil) {
        self.id = id
        self.date = date
        self.kind = kind
        self.label = label
        self.words = words
        self.verdict = verdict
        self.seen = seen
        self.changed = changed
    }
}

/// A draft title and summary for a stretch of work.
public struct ChapterSummary: Codable, Equatable {
    public var title: String
    public var summary: String
    /// Ids of the moments the summary draws on.
    public var sources: [String]
    public var model: String?
    public var createdAt: Date
    /// The designer accepted it as their own.
    public var accepted: Bool
    /// The designer hid it.
    public var hidden: Bool

    public init(title: String, summary: String, sources: [String] = [], model: String? = nil, createdAt: Date = Date(), accepted: Bool = false, hidden: Bool = false) {
        self.title = title
        self.summary = summary
        self.sources = sources
        self.model = model
        self.createdAt = createdAt
        self.accepted = accepted
        self.hidden = hidden
    }

    /// Stable across launches: changes when the moments or their words change.
    /// - Parameter level: the span the title is for ("day", "week", "month",
    ///   "year"), so the same moments get a different title at each zoom.
    public static func key(for moments: [MomentFact], level: String? = nil) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        // Bumped when the prompt changes, so summaries are written again.
        for byte in ("v2-decisions\n" + (level.map { "level:\($0)\n" } ?? "")).utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        for moment in moments {
            for byte in (moment.id + "|" + (moment.words ?? "") + "|" + (moment.verdict ?? "") + "|" + (moment.seen ?? "") + "\n").utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x100000001b3
            }
        }
        return String(hash, radix: 16)
    }
}

public struct Summarizer {
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
    You title one stretch of a designer's work for their process archive. The archive is about decisions: \
    what the designer settled on, tried, compared, changed or dropped. You get the moments of the stretch, oldest first.
    Title: name the step as a move, starting with a verb when you can, with concrete nouns from the work: \
    "Moved filters into a bottom sheet", "Compared three paywall layouts", "Dropped the blocking reply state", \
    "Settled on mono labels". Never generic: not "UI changes", "Design updates", "Iterations", "Refinements", \
    "Exploration", "Work session", "Various tweaks".
    Summary: what was decided or tried and what changed. A reason, goal or intention only if a line marked \
    "designer said" gives it: quote or closely paraphrase. Never invent one. If nobody said why, describe the move \
    and end with "No reason noted."
    Dead ends and "not quite" verdicts are decisions too: name them plainly.
    Plain, specific language. No em dashes. No praise.
    """

    static let schema: [String: Any] = [
        "type": "OBJECT",
        "properties": [
            "title": ["type": "STRING", "description": "At most 6 words. The decision or move of this stretch, verb first, concrete, never generic."],
            "summary": ["type": "STRING", "description": "One or two sentences, at most 40 words."],
            "sources": ["type": "ARRAY", "items": ["type": "STRING"], "description": "Ids of the moments the summary relies on."],
        ],
        "required": ["title", "summary", "sources"],
    ]

    static func prompt(_ moments: [MomentFact]) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let lines = moments.map { m -> String in
            var parts = ["[\(m.id)] \(formatter.string(from: m.date)) · \(m.kind)"]
            if let label = m.label, !label.isEmpty { parts.append("named \"\(label)\"") }
            if let words = m.words, !words.isEmpty { parts.append("designer said: \"\(words)\"") }
            if let verdict = m.verdict { parts.append("verdict: \(verdict)") }
            if let seen = m.seen { parts.append("Margin saw: \(seen)") }
            if let changed = m.changed { parts.append("changed: \(changed)") }
            return parts.joined(separator: " · ")
        }
        return "Moments:\n" + lines.joined(separator: "\n")
    }

    /// How close in the title is: each zoom level names a different thing,
    /// from one concrete move up to the arc of the project.
    static func levelGuide(_ level: String?) -> String? {
        switch level {
        case "moment": return "This stretch is one day, seen up close. Title its single sharpest decision or move, naming the screen or element."
        case "day": return "This stretch is one day, seen among the others of its week. Title what the day was about as a whole, broader than any one move in it."
        case "week": return "This stretch is one week. Title the step the week took as a whole, broader than any single day's move. Don't repeat a day's title."
        case "month": return "This stretch is one month. Title the phase of the project this month was, the direction it set. Broader than a week, never a single screen."
        case "year": return "This stretch is a year or more. Title the arc of the project: where it started and where it ended up, in a few words."
        default: return nil
        }
    }

    /// `context`: process notes from the designer's Claude Code sessions in
    /// the same stretch of time. Background only, never a source to cite.
    public func summarize(_ moments: [MomentFact], level: String? = nil, context: [String] = []) async throws -> ChapterSummary {
        guard let gemini else { throw AIError.missingKey("Gemini") }
        var text = Self.levelGuide(level).map { $0 + "\n\n" + Self.prompt(moments) } ?? Self.prompt(moments)
        if !context.isEmpty {
            text += "\n\nBackground, from the designer's sessions with an AI coding assistant in the same weeks. "
            text += "Use it only to understand what was decided and why; a reason counts only where it says the designer gave it. Don't cite it.\n"
            text += context.prefix(30).map { "- " + $0 }.joined(separator: "\n")
        }
        let data = try await gemini.generateJSON(model: model, system: Self.system, parts: [.text(text)], schema: Self.schema, temperature: 0.3, timeout: 45)
        struct Raw: Decodable { var title: String; var summary: String; var sources: [String]? }
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        let ids = Set(moments.map(\.id))
        return ChapterSummary(
            title: raw.title.trimmed,
            summary: raw.summary.trimmed.replacingOccurrences(of: "—", with: ","),
            sources: (raw.sources ?? []).filter { ids.contains($0) },
            model: model
        )
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
