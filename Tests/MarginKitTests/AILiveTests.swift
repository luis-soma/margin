import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import MarginKit

/// Real calls to Gemini and OpenAI with the keys in Resources/ai-keys.json.
/// Runs only when MARGIN_LIVE_AI=1 (CI sets it); prints "LIVE …" lines that
/// CI turns into annotations.
final class AILiveTests: XCTestCase {
    var config: AIConfig!

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["MARGIN_LIVE_AI"] == "1" else { throw XCTSkip("live AI calls are off") }
        let keys = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/ai-keys.json")
        config = AIConfig.load(environment: [:], files: [keys])
    }

    func image() -> Data {
        let ctx = CGContext(data: nil, width: 800, height: 500, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.95, green: 0.95, blue: 0.93, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 800, height: 500))
        ctx.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)); ctx.fill(CGRect(x: 60, y: 380, width: 680, height: 60))
        ctx.setFillColor(CGColor(red: 0.18, green: 0.3, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 60, y: 60, width: 200, height: 56))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return ImagePrep.jpeg(data: out as Data)!
    }

    func testGeminiNote() async throws {
        guard config.hasGemini else { print("LIVE gemini: no key"); throw XCTSkip("no Gemini key") }
        let started = Date()
        do {
            let note = try await Annotator(gemini: GeminiClient(apiKey: config.gemini!), decisions: nil, model: config.annotate)
                .annotate(image: image(), previous: nil, context: CaptureContext(kind: "Screenshot", app: "Figma"))
            print("LIVE gemini ok \(config.annotate) \(String(format: "%.1f", Date().timeIntervalSince(started)))s: \(note.seen) | topic \(note.topic ?? "-")")
        } catch {
            print("LIVE gemini FAILED \(config.annotate): \(error)")
            throw error
        }
    }

    func testGeminiSummary() async throws {
        guard config.hasGemini else { throw XCTSkip("no Gemini key") }
        let started = Date()
        do {
            let summary = try await Summarizer(gemini: GeminiClient(apiKey: config.gemini!), model: config.summary).summarize([
                MomentFact(id: "a1", date: Date(), kind: "Figma frame", words: "the border read as decoration", seen: "Banner with a gradient border"),
                MomentFact(id: "b2", date: Date(), kind: "Figma frame", verdict: "Keep", seen: "Slim banner, no border", changed: "Border removed"),
            ])
            print("LIVE summary ok \(config.summary) \(String(format: "%.1f", Date().timeIntervalSince(started)))s: \(summary.title) / \(summary.summary)")
        } catch {
            print("LIVE summary FAILED \(config.summary): \(error)")
            throw error
        }
    }

    func testDecisions() async throws {
        guard config.hasOpenAI else { print("LIVE decisions: no key"); throw XCTSkip("no OpenAI key") }
        let started = Date()
        do {
            let answers = try await DecisionsClient(apiKey: config.openai!, model: config.decisions).decide(text: "A design capture.", images: [image()], questions: [
                .predicate(name: "has_button", instructions: "The image shows a blue rectangle that could be a button."),
                .score(name: "change_size", instructions: "How busy is the image?", levels: [(label: "Empty", description: "Nothing"), (label: "Busy", description: "Lots")]),
            ])
            print("LIVE decisions ok \(config.decisions) \(String(format: "%.1f", Date().timeIntervalSince(started)))s: has_button \(answers["has_button"]?.probability.map { String(format: "%.2f", $0) } ?? "?") score \(answers["change_size"]?.score.map { String(format: "%.2f", $0) } ?? "?")")
        } catch {
            print("LIVE decisions FAILED \(config.decisions): \(error)")
            throw error
        }
    }
}
