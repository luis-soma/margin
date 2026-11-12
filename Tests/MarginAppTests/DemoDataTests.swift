import XCTest
import MarginKit
@testable import Margin

/// The demo (Umbrella, and Margin's own project) loads, every capture is
/// already noted, and every zoomed-out stretch of Umbrella already has a
/// summary: opening it spends no tokens.
@MainActor
final class DemoDataTests: XCTestCase {
    func testDemoIsFullyAnnotated() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = repo.appendingPathComponent("Resources/Demo")
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("margin-demo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        XCTAssertTrue(DemoData.seed(into: base, from: source))

        let store = EntryStore(baseURL: base, projectKey: "test-demo-project")
        XCTAssertGreaterThan(store.entries.count, 20)
        XCTAssertEqual(Set(store.entries.map(\.project)), [DemoData.project, "Margin"])

        // Pictures exist, and every picture already has Margin's note.
        for entry in store.entries where entry.imageFile != nil {
            XCTAssertNotNil(store.thumbnail(for: entry), "missing image for \(entry.displayTitle)")
            XCTAssertNotNil(entry.ai, "no note on \(entry.displayTitle)")
            for frame in entry.frames ?? [] {
                XCTAssertTrue(FileManager.default.fileExists(atPath: store.imageURL(forFile: frame.imageFile!).path))
            }
        }

        // Nothing left for the annotator to do.
        let ai = Intelligence(store: store, config: AIConfig())
        XCTAssertTrue(store.entries.filter { $0.ai == nil && $0.imageFile != nil }.isEmpty)

        // Every stretch shown at the zoomed-out steps has its summary.
        for step in 2..<RepoView.gaps.count {
            for session in Session.group(store.chronological(in: DemoData.project), gap: RepoView.gaps[step]) {
                guard Intelligence.summaryKey(for: session.entries) != nil else { continue }
                XCTAssertNotNil(ai.summary(for: session.entries), "no summary at step \(step) for \(session.title)")
            }
        }

        // Tabs: two the team made, more suggested.
        XCTAssertEqual(ai.tabs(in: DemoData.project), ["Filter overlay", "Research"])
        XCTAssertFalse(ai.suggestedTabs(in: DemoData.project).isEmpty)
    }
}
