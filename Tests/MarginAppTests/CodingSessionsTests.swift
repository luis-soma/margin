import AppKit
import XCTest
import MarginKit
@testable import Margin

/// The whole path from Claude Code's hook script to a saved iteration,
/// with the payloads Claude Code sends (recorded from version 2.1.302).
@MainActor
final class CodingSessionsTests: XCTestCase {
    private var temp: URL!
    private var project: URL!

    override func setUp() async throws {
        _ = NSApplication.shared
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("margin-e2e-\(UUID().uuidString)").resolvingSymlinksInPath()
        project = temp.appendingPathComponent("landing-page")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "<body style='background:#2244ff'><h1>One</h1></body>\n".write(to: project.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: temp)
    }

    /// Sends an event the way Claude Code does: JSON on stdin of the hook script.
    private func send(_ payload: [String: Any], home: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: payload)
        let out = Shell.run("/bin/sh", ["-c", "/bin/sh \"$HOME/.margin/claude-hook.sh\""], environment: ["HOME": home.path], input: data, timeout: 10)
        XCTAssertEqual(out.status, 0)
    }

    private func event(_ name: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        var payload: [String: Any] = [
            "session_id": "e2e-session",
            "transcript_path": temp.appendingPathComponent("none.jsonl").path,
            "cwd": project.path,
            "hook_event_name": name,
            "permission_mode": "acceptEdits",
        ]
        for (key, value) in extra { payload[key] = value }
        return payload
    }

    private func waitFor(_ condition: () -> Bool, timeout: TimeInterval = 30) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    func testCodingTurnBecomesAnIterationAndResearchLeavesNothing() async throws {
        let store = EntryStore(baseURL: temp.appendingPathComponent("Margin"))
        let coding = CodingSessions(store: store, cards: QuickCaptureController())
        coding.start()
        let port = try XCTUnwrap(coding.port)
        let home = temp.appendingPathComponent("home")
        let connector = ClaudeCodeConnector(settingsURL: home.appendingPathComponent(".claude/settings.json"), supportDirectory: home.appendingPathComponent(".margin"))
        try connector.writeSupportFiles(port: port)

        // 1. "Make the heading say Two": Claude edits index.html.
        try send(event("UserPromptSubmit", ["prompt": "Make the heading say Two"]), home: home)
        await waitFor({ coding.activeTurn != nil })
        XCTAssertEqual(coding.activeTurn?.prompt, "Make the heading say Two")
        try await Task.sleep(nanoseconds: 1_000_000_000) // before snapshot
        try "<body style='background:#2244ff'><h1>Two</h1></body>\n".write(to: project.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try send(event("PostToolUse", [
            "tool_name": "Edit",
            "tool_input": ["file_path": project.appendingPathComponent("index.html").path, "old_string": "One", "new_string": "Two"],
            "tool_response": ["filePath": project.appendingPathComponent("index.html").path],
        ]), home: home)
        try send(event("Stop", ["last_assistant_message": "Changed the heading to Two.", "stop_hook_active": false]), home: home)

        await waitFor({ store.entries.contains { $0.kind == .iteration } })
        let iteration = try XCTUnwrap(store.entries.first { $0.kind == .iteration })
        XCTAssertEqual(iteration.prompt, "Make the heading say Two")
        XCTAssertEqual(iteration.summary, "Changed the heading to Two.")
        XCTAssertEqual(iteration.diffStat, "1 file · +1 −1")
        XCTAssertEqual(iteration.codeRoot, project.path)
        XCTAssertEqual(iteration.windowTitle, "landing-page")
        XCTAssertNotNil(iteration.snapshot)
        XCTAssertNil(coding.activeTurn)

        // The picture is the page itself (blue background), not a code card.
        let image = try XCTUnwrap(store.imageURL(for: iteration).flatMap { NSImage(contentsOf: $0) })
        let rep = try XCTUnwrap(image.representations.first as? NSBitmapImageRep ?? NSBitmapImageRep(data: image.tiffRepresentation!))
        let color = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide - 4, y: rep.pixelsHigh - 4)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(color.blueComponent, 0.8)
        XCTAssertLessThan(color.redComponent, 0.3)

        // The version is kept: its files and its change.
        let folder = try await coding.exportVersion(iteration)
        XCTAssertTrue(try String(contentsOf: folder.appendingPathComponent("index.html")).contains("<h1>Two</h1>"))
        let diff = await coding.diff(for: iteration)
        XCTAssertTrue(diff.contains("-<body style='background:#2244ff'><h1>One</h1></body>"), diff)
        XCTAssertTrue(diff.contains("+<body style='background:#2244ff'><h1>Two</h1></body>"), diff)

        // 2. A question in the same project: no files change, nothing is saved.
        let count = store.entries.count
        try send(event("UserPromptSubmit", ["prompt": "What does this page do?"]), home: home)
        await waitFor({ coding.activeTurn?.prompt == "What does this page do?" })
        try send(event("Stop", ["last_assistant_message": "It shows a heading."]), home: home)
        await waitFor({ coding.activeTurn == nil })
        try await Task.sleep(nanoseconds: 3_000_000_000)
        XCTAssertEqual(store.entries.count, count)
    }

    func testCodeCardWhenThereIsNothingToPicture() throws {
        var stat = CodeSnapshots.DiffStat()
        stat.files = ["Sources/App.swift", "README.md"]
        stat.insertions = 12
        stat.deletions = 3
        let png = try XCTUnwrap(CodingSessions.codeCard(prompt: "Add a settings screen", stat: stat))
        XCTAssertTrue(ImageData.isImage(png))
    }
}
