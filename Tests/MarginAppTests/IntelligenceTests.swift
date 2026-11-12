import AppKit
import XCTest
import MarginKit
@testable import Margin

final class AppStubProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, data) = Self.handler?(request) ?? (500, Data())
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AppStubProtocol.self]
        return URLSession(configuration: config)
    }
}

@MainActor
final class IntelligenceTests: XCTestCase {
    var base: URL!
    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("margin-ai-\(UUID().uuidString)")
        UserDefaults.standard.removeObject(forKey: "dismissedTabs")
        UserDefaults.standard.removeObject(forKey: "aiEnabled")
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: base) }

    func pngFile(in store: EntryStore) -> String {
        let image = NSImage(size: NSSize(width: 40, height: 20))
        image.lockFocus(); NSColor.systemBlue.setFill(); NSRect(x: 0, y: 0, width: 40, height: 20).fill(); image.unlockFocus()
        return store.saveImage(image)!
    }

    func testSuggestedTabsNeedTwoCapturesAndAcceptingFilesThem() {
        let store = EntryStore(baseURL: base)
        let ai = Intelligence(store: store, config: AIConfig())
        for (i, topic) in ["Filter overlay", "Filter overlay", "Brand", nil].enumerated() {
            var e = store.newEntry(.figma)
            e.createdAt = Date(timeIntervalSince1970: Double(i) * 60)
            if let topic { e.ai = CaptureNote(seen: "s\(i)", topic: topic) }
            store.add(e)
        }
        let project = store.currentProject
        XCTAssertEqual(ai.suggestedTabs(in: project).map(\.name), ["Filter overlay"])
        XCTAssertTrue(ai.tabs(in: project).isEmpty)

        ai.acceptTab("Filter overlay", in: project, renamedTo: "Filter")
        XCTAssertEqual(ai.tabs(in: project), ["Filter"])
        XCTAssertEqual(store.entries(in: project).filter { $0.tab == "Filter" }.count, 2)
        XCTAssertTrue(ai.suggestedTabs(in: project).isEmpty)

        // A new capture whose topic matches a confirmed tab shows under it.
        var later = store.newEntry(.figma)
        later.ai = CaptureNote(seen: "x", topic: "Filter")
        XCTAssertEqual(later.effectiveTab(confirmed: Set(ai.tabs(in: project))), "Filter")

        // Dismissed suggestions stay dismissed.
        var more = store.newEntry(.figma); more.ai = CaptureNote(seen: "b", topic: "Brand"); store.add(more)
        XCTAssertEqual(ai.suggestedTabs(in: project).map(\.name), ["Brand"])
        ai.dismissTab("Brand", in: project)
        XCTAssertTrue(ai.suggestedTabs(in: project).isEmpty)
    }

    func testPreviousVersionPrefersTheSameFigmaFrame() {
        let store = EntryStore(baseURL: base)
        let ai = Intelligence(store: store, config: AIConfig())
        let file = pngFile(in: store)
        func add(_ kind: EntryKind, minutes: Double, link: String = "", label: String? = nil, app: String = "Figma") -> Entry {
            var e = store.newEntry(kind)
            e.createdAt = Date(timeIntervalSince1970: minutes * 60)
            e.imageFile = file; e.link = link; e.label = label; e.sourceApp = app
            store.add(e); return e
        }
        let v1 = add(.figma, minutes: 0, link: "https://www.figma.com/design/k/F?node-id=139-218")
        _ = add(.figma, minutes: 10, link: "https://www.figma.com/design/k/F?node-id=1-1")
        _ = add(.capture, minutes: 20, app: "Arc")
        let v2 = add(.figma, minutes: 30, link: "https://www.figma.com/design/k/F?node-id=139-218&t=abc")
        XCTAssertEqual(ai.previousVersion(of: v2)?.id, v1.id)
        let named = add(.figma, minutes: 40, label: "Filter v1")
        let named2 = add(.figma, minutes: 50, label: "Filter v1")
        XCTAssertEqual(ai.previousVersion(of: named2)?.id, named.id)
        let arc2 = add(.capture, minutes: 60, app: "Arc")
        XCTAssertEqual(ai.previousVersion(of: arc2)?.sourceApp, "Arc")
        XCTAssertNil(ai.previousVersion(of: v1))
    }

    /// End to end with a fake Gemini: a capture gets a note (never touching the
    /// designer's words), and a zoomed-out stretch gets a draft summary that is
    /// cached and can be kept.
    func testNotesAndSummariesEndToEnd() async throws {
        AppStubProtocol.handler = { request in
            let isSummary = request.url?.absoluteString.contains("summary-model") == true
            let inner: [String: Any] = isSummary
                ? ["title": "The filter", "summary": "Removed the border, it read as decoration.", "sources": []]
                : ["seen": "Chat reply with a banner", "changed": "", "visible_text": "Filtered", "tags": ["chat"], "topic": "Filter overlay"]
            let text = String(decoding: try! JSONSerialization.data(withJSONObject: inner), as: UTF8.self)
            let body = try! JSONSerialization.data(withJSONObject: ["candidates": [["content": ["parts": [["text": text]]]]]])
            return (200, body)
        }
        let store = EntryStore(baseURL: base)
        let ai = Intelligence(store: store, config: AIConfig(gemini: "test", annotateModel: "note-model", summaryModel: "summary-model"), session: AppStubProtocol.session())
        var entry = store.newEntry(.figma)
        entry.imageFile = pngFile(in: store)
        entry.rationale = "It read as decoration"
        store.add(entry)
        var second = store.newEntry(.decision)
        second.title = "Keep the slim banner"
        store.add(second)

        ai.scan()
        for _ in 0..<100 where store.entry(id: entry.id)?.ai == nil { try await Task.sleep(nanoseconds: 50_000_000) }
        let noted = try XCTUnwrap(store.entry(id: entry.id))
        XCTAssertEqual(noted.ai?.seen, "Chat reply with a banner")
        XCTAssertNil(noted.ai?.changed)
        XCTAssertEqual(noted.rationale, "It read as decoration")
        XCTAssertTrue(noted.searchText.contains("Filtered"))

        let stretch = store.chronological(in: store.currentProject)
        XCTAssertNil(ai.summary(for: stretch))
        ai.requestSummary(for: stretch)
        XCTAssertTrue(ai.isSummarizing(stretch))
        for _ in 0..<100 where ai.summary(for: stretch) == nil { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(ai.summary(for: stretch)?.title, "The filter")
        ai.updateSummary(for: stretch) { $0.accepted = true }

        // Saved to disk and read back by a new instance.
        let again = Intelligence(store: store, config: AIConfig())
        XCTAssertEqual(again.summary(for: stretch)?.accepted, true)
    }

    func testOffWithoutAKey() {
        let ai = Intelligence(store: EntryStore(baseURL: base), config: AIConfig())
        XCTAssertFalse(ai.canRun)
        if case .off = ai.status {} else { XCTFail("expected off") }
    }
}
