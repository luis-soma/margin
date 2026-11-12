import XCTest
import MarginKit
@testable import Margin

/// Two copies of Margin open on one archive (an old build next to a new
/// one) each keep the entries in memory. A capture deleted in one must not
/// come back, picture gone, when the other saves.
@MainActor
final class EntryStoreSyncTests: XCTestCase {
    private var base: URL!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("margin-sync-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func store() -> EntryStore { EntryStore(baseURL: base, projectKey: "test-sync-project") }

    /// A capture with a real picture file in the store's images folder.
    private func capture(in store: EntryStore, file: String) throws -> Entry {
        try Data("picture".utf8).write(to: store.imageURL(forFile: file))
        var entry = Entry(kind: .capture, project: "P")
        entry.imageFile = file
        store.add(entry)
        return entry
    }

    func testDeletedInOneCopyStaysDeletedWhenTheOtherSaves() throws {
        let a = store()
        let doomed = try capture(in: a, file: "doomed.png")
        let kept = try capture(in: a, file: "kept.png")
        let b = store()
        XCTAssertEqual(b.entries.count, 2)

        a.delete(doomed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.imageURL(forFile: "doomed.png").path))

        // The other copy, still holding both, changes something and saves.
        b.modify(kept.id) { $0.rationale = "why" }

        let fresh = store()
        XCTAssertNil(fresh.entry(id: doomed.id), "the deleted capture came back")
        XCTAssertEqual(fresh.entry(id: kept.id)?.rationale, "why")
        XCTAssertEqual(b.entries.map(\.id), [kept.id])
    }

    func testOneCopyKeepsWhatTheOtherAdded() throws {
        let a = store()
        let first = try capture(in: a, file: "first.png")
        let b = store()
        let second = try capture(in: a, file: "second.png")

        b.modify(first.id) { $0.rationale = "why" }

        let fresh = store()
        XCTAssertNotNil(fresh.entry(id: second.id), "the other copy's capture was lost")
        XCTAssertEqual(fresh.entry(id: first.id)?.rationale, "why")
    }

    func testEveryCaptureOnDiskHasItsPicture() throws {
        let a = store()
        let one = try capture(in: a, file: "one.png")
        _ = try capture(in: a, file: "two.png")
        let b = store()
        a.delete(one)
        b.add(Entry(kind: .note, project: "P"))

        for entry in store().entries {
            guard let file = entry.imageFile else { continue }
            XCTAssertTrue(FileManager.default.fileExists(atPath: base.appendingPathComponent("images/\(file)").path), "\(file) is missing")
        }
    }

    func testAPictureStillInUseIsNeverDeleted() throws {
        let a = store()
        let original = try capture(in: a, file: "shared.png")
        var copy = Entry(kind: .capture, project: "P")
        copy.imageFile = "shared.png"
        a.add(copy)

        a.delete(original)

        XCTAssertTrue(FileManager.default.fileExists(atPath: a.imageURL(forFile: "shared.png").path))
    }
}
