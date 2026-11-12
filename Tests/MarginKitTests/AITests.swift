import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import MarginKit

/// Answers requests in-process, so the AI clients are tested without a network.
final class StubProtocol: URLProtocol {
    struct Reply { var status: Int; var body: Data }
    static var handler: ((URLRequest, Data) -> Reply)?
    static var requests: [(URLRequest, Data)] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                body.append(buffer, count: n)
            }
            stream.close()
        }
        Self.requests.append((request, body))
        let reply = Self.handler?(request, body) ?? Reply(status: 500, body: Data("{}".utf8))
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }

    static func json(_ object: Any, status: Int = 200) -> Reply {
        Reply(status: status, body: try! JSONSerialization.data(withJSONObject: object))
    }
}

func geminiReply(_ inner: [String: Any], fenced: Bool = false) -> StubProtocol.Reply {
    var text = String(decoding: try! JSONSerialization.data(withJSONObject: inner), as: UTF8.self)
    if fenced { text = "```json\n\(text)\n```" }
    return StubProtocol.json(["candidates": [["content": ["parts": [["text": text]], "role": "model"], "finishReason": "STOP"]]])
}

func bodyJSON(_ data: Data) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
}

final class AITests: XCTestCase {
    override func setUp() {
        StubProtocol.handler = nil
        StubProtocol.requests = []
    }

    /// A small real JPEG.
    func sampleImage(_ size: Int = 1600) -> Data {
        let space = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: size, height: size / 2, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.3, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size / 2, height: size / 2))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return ImagePrep.jpeg(data: out as Data, maxPixel: 4000)!
    }

    func testImagePrepShrinksToJPEG() throws {
        let big = sampleImage(2400)
        let small = try XCTUnwrap(ImagePrep.jpeg(data: big, maxPixel: 1024))
        XCTAssertTrue(small.starts(with: [0xFF, 0xD8, 0xFF]))
        let source = CGImageSourceCreateWithData(small as CFData, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
        XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, 1024)
        XCTAssertEqual(props[kCGImagePropertyPixelHeight] as? Int, 512)
    }

    func testConfigPrefersEnvironmentAndIgnoresEmpty() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ai-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("ai-keys.json")
        try Data(#"{"gemini":"file-key","openai":"  ","summary_model":"gemini-x"}"#.utf8).write(to: file)
        var config = AIConfig.load(environment: [:], files: [dir.appendingPathComponent("missing.json"), file])
        XCTAssertEqual(config.gemini, "file-key")
        XCTAssertNil(config.openai)
        XCTAssertEqual(config.summary, "gemini-x")
        XCTAssertEqual(config.annotate, AIConfig.defaultAnnotateModel)
        config = AIConfig.load(environment: ["MARGIN_GEMINI_KEY": "env-key", "OPENAI_API_KEY": "sk-1"], files: [file])
        XCTAssertEqual(config.gemini, "env-key")
        XCTAssertEqual(config.openai, "sk-1")
    }

    func testGeminiRequestShapeAndFencedJSON() async throws {
        StubProtocol.handler = { _, _ in geminiReply(["seen": "ok"], fenced: true) }
        let client = GeminiClient(apiKey: "g-key", session: StubProtocol.session())
        let data = try await client.generateJSON(model: "gemini-test", system: "sys", parts: [.text("hi"), .image(Data([0xFF, 0xD8, 0xFF, 0x00]), mime: "image/jpeg")], schema: ["type": "OBJECT"])
        XCTAssertEqual(bodyJSON(data)["seen"] as? String, "ok")
        let (request, body) = try XCTUnwrap(StubProtocol.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://generativelanguage.googleapis.com/v1beta/models/gemini-test:generateContent")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "g-key")
        let json = bodyJSON(body)
        let parts = ((json["contents"] as? [[String: Any]])?.first?["parts"] as? [[String: Any]]) ?? []
        XCTAssertEqual(parts.first?["text"] as? String, "hi")
        let inline = parts.last?["inline_data"] as? [String: Any]
        XCTAssertEqual(inline?["mime_type"] as? String, "image/jpeg")
        XCTAssertEqual(inline?["data"] as? String, Data([0xFF, 0xD8, 0xFF, 0x00]).base64EncodedString())
        let gen = json["generation_config"] as? [String: Any]
        XCTAssertEqual(gen?["response_mime_type"] as? String, "application/json")
        XCTAssertNotNil(gen?["response_schema"])
        XCTAssertEqual(((json["system_instruction"] as? [String: Any])?["parts"] as? [[String: Any]])?.first?["text"] as? String, "sys")
    }

    func testGeminiErrorsCarryTheMessage() async {
        StubProtocol.handler = { _, _ in StubProtocol.json(["error": ["message": "API key not valid"]], status: 400) }
        let client = GeminiClient(apiKey: "bad", session: StubProtocol.session())
        do {
            _ = try await client.generateJSON(model: "m", system: nil, parts: [.text("x")], schema: [:])
            XCTFail("should throw")
        } catch let error as AIError {
            XCTAssertEqual(error, .http(400, "API key not valid"))
            XCTAssertFalse(error.isTransient)
        } catch { XCTFail("\(error)") }
    }

    func testDecisionsRequestAndAnswers() async throws {
        StubProtocol.handler = { _, _ in StubProtocol.json(["answers": [
            ["type": "predicate", "name": "same_thing", "probability": 0.91],
            ["type": "choice", "name": "topic", "choice": "Filter overlay", "confidence": 0.8, "probabilities": [["value": "Filter overlay", "probability": 0.8]]],
            ["type": "score", "name": "change_size", "score": 2.2, "confidence": 0.6],
            ["type": "refusal", "name": "other"],
        ]]) }
        let client = DecisionsClient(apiKey: "sk-test", session: StubProtocol.session())
        let answers = try await client.decide(text: "context", images: [Data([0xFF, 0xD8, 0xFF])], questions: [
            .predicate(name: "same_thing", instructions: "same?"),
            .choice(name: "topic", instructions: "which?", choices: [(value: "Filter overlay", description: "d")]),
            .score(name: "change_size", instructions: "how much?", levels: [(label: "None", description: "n"), (label: "Major", description: "m")]),
        ])
        XCTAssertEqual(answers["same_thing"]?.probability, 0.91)
        XCTAssertEqual(answers["topic"]?.choice, "Filter overlay")
        XCTAssertEqual(answers["change_size"]?.score, 2.2)
        XCTAssertNil(answers["other"])
        let (request, body) = try XCTUnwrap(StubProtocol.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/decisions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        let json = bodyJSON(body)
        XCTAssertEqual(json["model"] as? String, "gpt-6-luna")
        let content = ((json["input"] as? [[String: Any]])?.first?["content"] as? [[String: Any]]) ?? []
        XCTAssertEqual(content.first?["type"] as? String, "input_text")
        XCTAssertEqual(content.last?["type"] as? String, "input_image")
        XCTAssertTrue((content.last?["image_url"] as? String ?? "").hasPrefix("data:image/jpeg;base64,"))
        let questions = json["questions"] as? [[String: Any]] ?? []
        XCTAssertEqual(questions.map { $0["type"] as? String }, ["predicate", "choice", "score"])
        XCTAssertNotNil(questions[2]["levels"])
    }

    /// Gemini writes, Decisions sorts: an existing topic wins when Decisions is
    /// confident, and "what changed" is dropped when the previous capture
    /// isn't the same thing.
    func testAnnotatorMergesBothModels() async throws {
        StubProtocol.handler = { request, _ in
            if request.url?.host == "api.openai.com" {
                return StubProtocol.json(["answers": [
                    ["type": "choice", "name": "topic", "choice": "Filter overlay", "confidence": 0.82],
                    ["type": "predicate", "name": "same_thing", "probability": 0.88],
                    ["type": "score", "name": "change_size", "score": 2.4],
                ]])
            }
            return geminiReply(["seen": "Chat reply with a slim banner above it", "changed": "Border removed", "visible_text": "Filtered by Umbrella", "tags": ["Chat", "banner"], "topic": "Filter banner"])
        }
        let session = StubProtocol.session()
        let annotator = Annotator(gemini: GeminiClient(apiKey: "g", session: session), decisions: DecisionsClient(apiKey: "o", session: session), model: "m")
        let context = CaptureContext(kind: "Figma frame", app: "Figma", label: "Filter v2", designerWords: "old status bar", topics: [(name: "Filter overlay", example: "dark chat"), (name: "Brand", example: "logo")])
        let note = try await annotator.annotate(image: sampleImage(400), previous: sampleImage(400), context: context)
        XCTAssertEqual(note.seen, "Chat reply with a slim banner above it")
        XCTAssertEqual(note.changed, "Border removed")
        XCTAssertEqual(note.topic, "Filter overlay")
        XCTAssertEqual(note.tags, ["chat", "banner"])
        XCTAssertEqual(note.changeSize, 2.4)
        XCTAssertTrue(note.isBigChange)
        // The prompt carries the designer's words as context, and the rule against reasons.
        let gemini = try XCTUnwrap(StubProtocol.requests.first { $0.0.url?.host == "generativelanguage.googleapis.com" })
        let body = String(decoding: gemini.1, as: UTF8.self)
        XCTAssertTrue(body.contains("old status bar"))
        XCTAssertTrue(body.contains("Never state or guess reasons"))
        XCTAssertEqual(((bodyJSON(gemini.1)["contents"] as? [[String: Any]])?.first?["parts"] as? [Any])?.count, 3)
    }

    func testAnnotatorDropsChangeForADifferentThingAndWorksWithoutDecisions() async throws {
        StubProtocol.handler = { request, _ in
            if request.url?.host == "api.openai.com" {
                return StubProtocol.json(["answers": [["type": "predicate", "name": "same_thing", "probability": 0.1], ["type": "score", "name": "change_size", "score": 3]]])
            }
            return geminiReply(["seen": "Pricing page", "changed": "Everything", "visible_text": "", "tags": [], "topic": "brand"])
        }
        let session = StubProtocol.session()
        var annotator = Annotator(gemini: GeminiClient(apiKey: "g", session: session), decisions: DecisionsClient(apiKey: "o", session: session))
        let context = CaptureContext(kind: "Screenshot", topics: [(name: "Brand", example: "logo")])
        var note = try await annotator.annotate(image: sampleImage(200), previous: sampleImage(200), context: context)
        XCTAssertNil(note.changed)
        XCTAssertNil(note.changeSize)
        XCTAssertEqual(note.topic, "Brand") // matched case-insensitively to the existing name
        XCTAssertNil(note.visibleText)

        // Decisions failing (or missing) never breaks the note.
        StubProtocol.handler = { request, _ in
            request.url?.host == "api.openai.com" ? StubProtocol.json(["error": ["message": "down"]], status: 503)
                : geminiReply(["seen": "A", "changed": "", "visible_text": "", "tags": ["x"], "topic": "T"])
        }
        note = try await annotator.annotate(image: sampleImage(200), previous: nil, context: CaptureContext(kind: "Screenshot"))
        XCTAssertEqual(note.seen, "A")
        annotator.decisions = nil
        note = try await annotator.annotate(image: sampleImage(200), previous: nil, context: CaptureContext(kind: "Screenshot"))
        XCTAssertEqual(note.topic, "T")
    }

    func testSummarizerUsesOnlyTheDesignersWordsAndKnownSources() async throws {
        StubProtocol.handler = { _, _ in geminiReply(["title": "The filter", "summary": "Removed the border — it read as decoration.", "sources": ["a1", "zz"]]) }
        let summarizer = Summarizer(gemini: GeminiClient(apiKey: "g", session: StubProtocol.session()), model: "s")
        let moments = [
            MomentFact(id: "a1", date: Date(timeIntervalSince1970: 0), kind: "Figma frame", label: "Filter v1", words: "reads as decoration", seen: "Gradient banner"),
            MomentFact(id: "b2", date: Date(timeIntervalSince1970: 60), kind: "Figma frame", verdict: "Keep", seen: "Slim banner", changed: "Border removed"),
        ]
        let summary = try await summarizer.summarize(moments)
        XCTAssertEqual(summary.title, "The filter")
        XCTAssertEqual(summary.sources, ["a1"])
        XCTAssertFalse(summary.summary.contains("—"))
        XCTAssertFalse(summary.accepted)
        let body = String(decoding: try XCTUnwrap(StubProtocol.requests.first).1, as: UTF8.self)
        XCTAssertTrue(body.contains("designer said") && body.contains("reads as decoration"))
        XCTAssertTrue(body.contains("No reason noted."))
        // Same moments and words: same key. New words: new key.
        XCTAssertEqual(ChapterSummary.key(for: moments), ChapterSummary.key(for: moments))
        var edited = moments
        edited[1].words = "keeps the reply readable"
        XCTAssertNotEqual(ChapterSummary.key(for: moments), ChapterSummary.key(for: edited))
    }
}
