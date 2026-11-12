import XCTest
import MarginKit
@testable import Margin

final class EntryTests: XCTestCase {
    private func decode(_ json: String) throws -> [Entry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([Entry].self, from: Data(json.utf8))
    }

    func testReadsOlderFilesAndUnknownKinds() throws {
        let entries = try decode("""
        [
          {"id": "6F1C3D2E-0000-4000-8000-000000000001", "kind": "snapshot", "project": "Margin", "createdAt": "2026-10-15T10:00:00Z", "imageFile": "a.jpg", "isPivot": true},
          {"kind": "hologram", "project": "Margin"}
        ]
        """)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].kind, .snapshot)
        XCTAssertNil(entries[0].mediaFile)
        XCTAssertEqual(entries[1].kind, .note)
    }

    func testRoundTripsNewFields() throws {
        var entry = Entry(kind: .recording, project: "P")
        entry.mediaFile = "x.mp4"
        entry.duration = 12.5
        entry.label = "Checkout flow"
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode([entry])
        let back = try decode(String(decoding: data, as: UTF8.self))[0]
        XCTAssertEqual(back.mediaFile, "x.mp4")
        XCTAssertEqual(back.duration, 12.5)
        XCTAssertEqual(back.displayTitle, "Checkout flow")
    }

    func testCapturedTextIsNotTheDesignersWords() {
        var text = Entry(kind: .text, project: "P")
        text.body = "Someone else's paragraph"
        XCTAssertFalse(text.hasWords)
        XCTAssertTrue(text.standsAlone)
        text.rationale = "Tone I want for onboarding"
        XCTAssertTrue(text.hasWords)

        var note = Entry(kind: .note, project: "P")
        note.body = "My own note"
        XCTAssertTrue(note.hasWords)
    }

    func testSnapshotsStackButCapturesStandAlone() {
        var snapshot = Entry(kind: .snapshot, project: "P")
        snapshot.imageFile = "s.jpg"
        XCTAssertFalse(snapshot.standsAlone)
        var figma = Entry(kind: .figma, project: "P")
        figma.imageFile = "f.png"
        XCTAssertTrue(figma.standsAlone)
    }

    func testSessionsSplitOnGaps() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let entries = [0, 60, 120, 4000, 4060].map { offset -> Entry in
            var entry = Entry(kind: .snapshot, project: "P")
            entry.createdAt = start.addingTimeInterval(TimeInterval(offset))
            entry.windowTitle = "Checkout – Figma"
            return entry
        }
        let sessions = Session.group(entries, gap: 300)
        XCTAssertEqual(sessions.map(\.entries.count), [3, 2])
        XCTAssertEqual(sessions[0].title, "Checkout – Figma")
    }

    @MainActor
    func testFigmaLinkPointsAtTheExportedNode() throws {
        let page = try XCTUnwrap(FigmaLink.parse("https://www.figma.com/design/abcdefghij1234567890AB/File?node-id=0-1&t=xyz"))
        let linked = AppModel.link(page, node: "12:34")
        XCTAssertTrue(linked.contains("node-id=12-34"), linked)
        XCTAssertTrue(linked.contains("t=xyz"), linked)
        let frame = try XCTUnwrap(FigmaLink.parse("https://www.figma.com/design/abcdefghij1234567890AB/File?node-id=12-34"))
        XCTAssertEqual(AppModel.link(frame, node: "12:34"), frame.url.absoluteString)
    }
}
