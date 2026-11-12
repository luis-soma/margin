import AppKit
import XCTest
import MarginKit
@testable import Margin

/// A Claude chat that builds in the cloud: the prompt is sent, the agent
/// pushes, Margin's copy of the project fetches and records the iteration.
@MainActor
final class ChatSessionsTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory.appendingPathComponent("margin-chat-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func git(_ args: [String], in dir: URL) -> String {
        let out = Shell.run("/usr/bin/git", ["-c", "user.name=T", "-c", "user.email=t@t", "-c", "init.defaultBranch=main"] + args, in: dir)
        XCTAssertTrue(out.ok, "git \(args.joined(separator: " ")): \(out.stderr)")
        return out.text
    }

    private func waitFor(_ condition: () -> Bool, timeout: TimeInterval = 30) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 200_000_000) }
    }

    func testPushedCommitsBecomeAnIterationAndQuestionsLeaveNothing() async throws {
        let remote = root.appendingPathComponent("remote.git")
        git(["init", "-q", "--bare", remote.path], in: root)
        let agent = root.appendingPathComponent("cloud")
        git(["clone", "-q", remote.path, agent.path], in: root)
        try "<h1>One</h1>\n".write(to: agent.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        git(["add", "-A"], in: agent)
        git(["commit", "-q", "-m", "First"], in: agent)
        git(["push", "-q", "origin", "HEAD:main"], in: agent)
        let mine = root.appendingPathComponent("mine")
        git(["clone", "-q", remote.path, mine.path], in: root)

        let store = EntryStore(baseURL: root.appendingPathComponent("Margin"))
        let coding = CodingSessions(store: store, cards: QuickCaptureController())
        let chats = ChatSessions(store: store, coding: coding)
        chats.watch(mine)

        // A question: nothing arrives, nothing is kept.
        chats.send("What does the page say?")
        await waitFor { chats.activeTurn?.baselineReady == true }
        chats.endActiveTurn()
        try await Task.sleep(nanoseconds: 3_000_000_000)
        XCTAssertTrue(store.entries.isEmpty)

        // A build request: the cloud session pushes a change.
        chats.send("Make the heading say Two")
        await waitFor { chats.activeTurn?.baselineReady == true }
        try "<h1>Two</h1>\n".write(to: agent.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        git(["commit", "-q", "-am", "Heading says Two"], in: agent)
        git(["push", "-q", "origin", "HEAD:main"], in: agent)
        chats.endActiveTurn()
        await waitFor { store.entries.contains { $0.kind == .iteration } }

        let iteration = try XCTUnwrap(store.entries.first { $0.kind == .iteration })
        XCTAssertEqual(iteration.prompt, "Make the heading say Two")
        XCTAssertEqual(iteration.summary, "Heading says Two")
        XCTAssertEqual(iteration.snapshotSource, "repo")
        XCTAssertEqual(iteration.diffStat, "1 file · +1 −1")
        XCTAssertEqual(iteration.agent, "Claude")
        XCTAssertNotNil(iteration.imageFile)

        let diff = await coding.diff(for: iteration)
        XCTAssertTrue(diff.contains("+<h1>Two</h1>"), diff)
        let folder = try await coding.exportVersion(iteration)
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("index.html"), encoding: .utf8), "<h1>Two</h1>\n")
        // The designer's own checkout wasn't changed.
        XCTAssertEqual(try String(contentsOf: mine.appendingPathComponent("index.html"), encoding: .utf8), "<h1>One</h1>\n")
    }
}
