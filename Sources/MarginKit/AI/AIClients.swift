import Foundation

/// Keys and models for Margin's intelligence layer.
///
/// Read, in order: environment variables, then the first `ai-keys.json` that
/// exists (in the app bundle, ~/.margin, or a path given). Empty values count
/// as missing.
public struct AIConfig: Codable, Equatable {
    public var gemini: String?
    public var openai: String?
    public var annotateModel: String?
    public var summaryModel: String?
    public var decisionsModel: String?

    public static let defaultAnnotateModel = "gemini-3.5-flash-lite"
    public static let defaultSummaryModel = "gemini-3.8-flash"
    public static let defaultDecisionsModel = "gpt-6-luna"

    enum CodingKeys: String, CodingKey {
        case gemini, openai
        case annotateModel = "annotate_model"
        case summaryModel = "summary_model"
        case decisionsModel = "decisions_model"
    }

    public init(gemini: String? = nil, openai: String? = nil, annotateModel: String? = nil, summaryModel: String? = nil, decisionsModel: String? = nil) {
        self.gemini = gemini
        self.openai = openai
        self.annotateModel = annotateModel
        self.summaryModel = summaryModel
        self.decisionsModel = decisionsModel
    }

    public var hasGemini: Bool { !(gemini ?? "").isEmpty }
    public var hasOpenAI: Bool { !(openai ?? "").isEmpty }

    public var annotate: String { nonEmpty(annotateModel) ?? Self.defaultAnnotateModel }
    public var summary: String { nonEmpty(summaryModel) ?? Self.defaultSummaryModel }
    public var decisions: String { nonEmpty(decisionsModel) ?? Self.defaultDecisionsModel }

    /// Where the keys came from, for Settings.
    public var source: String?

    public static func load(environment: [String: String] = ProcessInfo.processInfo.environment, files: [URL]) -> AIConfig {
        var config = AIConfig()
        for url in files {
            guard let data = try? Data(contentsOf: url),
                  let file = try? JSONDecoder().decode(AIConfig.self, from: data) else { continue }
            config = file
            config.source = url.path
            break
        }
        if let key = nonEmpty(environment["MARGIN_GEMINI_KEY"] ?? environment["GEMINI_API_KEY"]) {
            config.gemini = key
            config.source = "environment"
        }
        if let key = nonEmpty(environment["MARGIN_OPENAI_KEY"] ?? environment["OPENAI_API_KEY"]) {
            config.openai = key
        }
        config.gemini = nonEmpty(config.gemini)
        config.openai = nonEmpty(config.openai)
        return config
    }

    private func nonEmpty(_ value: String?) -> String? { Self.nonEmpty(value) }
    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

public enum AIError: Error, CustomStringConvertible, Equatable {
    case missingKey(String)
    case http(Int, String)
    case badResponse(String)
    case blocked(String)

    public var description: String {
        switch self {
        case .missingKey(let which): return "no \(which) key"
        case .http(let status, let message): return "HTTP \(status): \(message)"
        case .badResponse(let detail): return "unexpected response: \(detail)"
        case .blocked(let reason): return "blocked: \(reason)"
        }
    }

    /// Worth waiting before trying again (rate limit or server trouble).
    public var isTransient: Bool {
        if case .http(let status, _) = self { return status == 429 || status >= 500 }
        return false
    }
}

enum AIHTTP {
    static func post(_ url: URL, headers: [String: String], body: [String: Any], session: URLSession, timeout: TimeInterval) async throws -> [String: Any] {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(status) else {
            let message = ((json?["error"] as? [String: Any])?["message"] as? String)
                ?? String(decoding: data.prefix(300), as: UTF8.self)
            throw AIError.http(status, message)
        }
        guard let json else { throw AIError.badResponse(String(decoding: data.prefix(200), as: UTF8.self)) }
        return json
    }
}

// MARK: - Gemini

/// Gemini's generateContent with structured JSON output.
public struct GeminiClient {
    public var apiKey: String
    public var baseURL: URL
    public var session: URLSession

    public init(apiKey: String, baseURL: URL = URL(string: "https://generativelanguage.googleapis.com/v1beta")!, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.session = session
    }

    public enum Part {
        case text(String)
        case image(Data, mime: String)
    }

    /// Returns the JSON the model wrote, matching `schema`.
    public func generateJSON(model: String, system: String?, parts: [Part], schema: [String: Any], temperature: Double = 0.2, timeout: TimeInterval = 30) async throws -> Data {
        var body: [String: Any] = [
            "contents": [["role": "user", "parts": parts.map(Self.encode)]],
            "generation_config": [
                "response_mime_type": "application/json",
                "response_schema": schema,
                "temperature": temperature,
            ],
        ]
        if let system { body["system_instruction"] = ["parts": [["text": system]]] }
        let url = baseURL.appendingPathComponent("models/\(model):generateContent")
        let json = try await AIHTTP.post(url, headers: ["x-goog-api-key": apiKey], body: body, session: session, timeout: timeout)
        return try Self.jsonText(from: json)
    }

    static func encode(_ part: Part) -> [String: Any] {
        switch part {
        case .text(let text): return ["text": text]
        case .image(let data, let mime): return ["inline_data": ["mime_type": mime, "data": data.base64EncodedString()]]
        }
    }

    static func jsonText(from json: [String: Any]) throws -> Data {
        guard let candidates = json["candidates"] as? [[String: Any]], let first = candidates.first else {
            if let feedback = json["promptFeedback"] as? [String: Any], let reason = feedback["blockReason"] as? String {
                throw AIError.blocked(reason)
            }
            throw AIError.badResponse("no candidates")
        }
        let parts = ((first["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
        var text = parts.compactMap { $0["text"] as? String }.joined()
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Some models wrap JSON in a code fence.
        if text.hasPrefix("```") {
            text = text.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
            if let end = text.range(of: "```", options: .backwards) { text = String(text[..<end.lowerBound]) }
        }
        guard !text.isEmpty else {
            throw AIError.badResponse("empty text (finish: \(first["finishReason"] as? String ?? "?"))")
        }
        return Data(text.utf8)
    }
}

// MARK: - OpenAI Decisions

/// OpenAI's Decisions API: fast, bounded answers (yes/no, pick one, score).
public struct DecisionsClient {
    public var apiKey: String
    public var model: String
    public var baseURL: URL
    public var session: URLSession

    public init(apiKey: String, model: String = AIConfig.defaultDecisionsModel, baseURL: URL = URL(string: "https://api.openai.com/v1")!, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.model = model
        self.baseURL = baseURL
        self.session = session
    }

    public enum Question {
        case predicate(name: String, instructions: String)
        case choice(name: String, instructions: String, choices: [(value: String, description: String)])
        case score(name: String, instructions: String, levels: [(label: String, description: String)])

        var json: [String: Any] {
            switch self {
            case .predicate(let name, let instructions):
                return ["type": "predicate", "name": name, "instructions": instructions]
            case .choice(let name, let instructions, let choices):
                return ["type": "choice", "name": name, "instructions": instructions,
                        "choices": choices.map { ["value": $0.value, "description": $0.description] }]
            case .score(let name, let instructions, let levels):
                return ["type": "score", "name": name, "instructions": instructions,
                        "levels": levels.map { ["label": $0.label, "description": $0.description] }]
            }
        }
    }

    public struct Answer: Equatable {
        public var name: String
        public var type: String
        public var probability: Double?
        public var choice: String?
        public var score: Double?
        public var confidence: Double?
    }

    public func decide(text: String, images: [Data], questions: [Question], timeout: TimeInterval = 15) async throws -> [String: Answer] {
        var content: [[String: Any]] = [["type": "input_text", "text": text]]
        for image in images {
            content.append(["type": "input_image", "image_url": "data:\(ImagePrep.mime(of: image));base64,\(image.base64EncodedString())"])
        }
        let body: [String: Any] = [
            "model": model,
            "input": [["role": "user", "content": content]],
            "questions": questions.map(\.json),
        ]
        let json = try await AIHTTP.post(baseURL.appendingPathComponent("decisions"),
                                         headers: ["Authorization": "Bearer \(apiKey)"],
                                         body: body, session: session, timeout: timeout)
        return try Self.answers(from: json)
    }

    static func answers(from json: [String: Any]) throws -> [String: Answer] {
        guard let list = json["answers"] as? [[String: Any]] else { throw AIError.badResponse("no answers") }
        var result: [String: Answer] = [:]
        for item in list {
            guard let name = item["name"] as? String else { continue }
            let type = item["type"] as? String ?? ""
            guard type != "refusal" else { continue }
            result[name] = Answer(
                name: name,
                type: type,
                probability: (item["probability"] as? NSNumber)?.doubleValue,
                choice: item["choice"] as? String,
                score: (item["score"] as? NSNumber)?.doubleValue,
                confidence: (item["confidence"] as? NSNumber)?.doubleValue
            )
        }
        return result
    }
}
