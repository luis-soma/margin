import AppKit
import XCTest
@testable import MarginKit

/// A throwaway project folder.
final class TempProject {
    let root: URL
    init(files: [String: String] = ["index.html": "<h1>One</h1>"]) throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("margin-proj-\(UUID().uuidString)")
        root = base.standardizedFileURL.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        for (path, text) in files { try write(path, text) }
    }
    func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
}

final class CodeSnapshotsTests: XCTestCase {
    var store: CodeSnapshots!
    var storeURL: URL!

    override func setUp() {
        storeURL = FileManager.default.temporaryDirectory.appendingPathComponent("margin-code-\(UUID().uuidString)")
        store = CodeSnapshots(base: storeURL)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: storeURL)
    }

    func testVersionsChangesAndExport() throws {
        let project = try TempProject(files: [
            "index.html": "<h1>One</h1>\n",
            "src/app.js": "console.log(1)\n",
            "node_modules/dep/index.js": "big\n",
            ".env": "SECRET=1\n",
            ".gitignore": "private.txt\n",
            "private.txt": "mine\n",
        ])
        let first = try store.snapshot(root: project.root, message: "one")
        XCTAssertTrue(first.changed)

        // Nothing changed: same version.
        let same = try store.snapshot(root: project.root, message: "again")
        XCTAssertFalse(same.changed)
        XCTAssertEqual(same.commit, first.commit)

        try project.write("index.html", "<h1>Two</h1>\n<p>New</p>\n")
        let second = try store.snapshot(root: project.root, message: "two")
        XCTAssertTrue(second.changed)
        XCTAssertNotEqual(second.tree, first.tree)

        let stat = store.diffStat(root: project.root, from: first.commit, to: second.commit)
        XCTAssertEqual(stat.files, ["index.html"])
        XCTAssertEqual(stat.insertions, 2)
        XCTAssertEqual(stat.deletions, 1)
        XCTAssertEqual(stat.summary, "1 file · +2 −1")
        XCTAssertTrue(store.diff(root: project.root, from: first.commit, to: second.commit).contains("+<h1>Two</h1>"))

        // The first version, without dependencies, secrets or ignored files.
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("margin-export-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: out) }
        try store.export(root: project.root, commit: first.commit, to: out)
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("index.html")), "<h1>One</h1>\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("src/app.js").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent("node_modules").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent(".env").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent("private.txt").path))

        // The project's own folder is untouched: no .git appeared.
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.root.appendingPathComponent(".git").path))
    }

    func testProjectRoot() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertNil(CodeSnapshots.projectRoot(for: home))
        XCTAssertNil(CodeSnapshots.projectRoot(for: URL(fileURLWithPath: "/")))

        let project = try TempProject(files: ["package.json": "{}", "src/components/Card.tsx": "x"])
        XCTAssertEqual(CodeSnapshots.projectRoot(for: project.root)?.path, project.root.path)

        // Inside a git repository: its top level.
        Shell.run("/usr/bin/git", ["init", "-q"], in: project.root)
        XCTAssertEqual(CodeSnapshots.projectRoot(for: project.root.appendingPathComponent("src/components"))?.path, project.root.path)

        // A folder with nothing project-like isn't one.
        let notes = try TempProject(files: ["notes.txt": "hi"])
        XCTAssertNil(CodeSnapshots.projectRoot(for: notes.root))
    }
}

final class DevServerTests: XCTestCase {
    func testURLsInOutput() {
        let text = """
          VITE v5.4.0  ready in 210 ms
          ➜  Local:   http://localhost:5173/
          ➜  Network: use --host to expose
        ▲ Next.js 15 - Local: http://127.0.0.1:3000, also http://0.0.0.0:8080/app.
        https://example.com:443/ isn't local
        """
        XCTAssertEqual(DevServer.urls(in: text).map(\.absoluteString), [
            "http://localhost:5173/", "http://localhost:3000/", "http://localhost:8080/app",
        ])
    }

    func testFindsTheServerRunningFromTheProject() async throws {
        let project = try TempProject(files: ["index.html": "<h1>Served</h1>"])
        let port = DevServer.freePort(from: 4700)
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-m", "http.server", String(port), "--bind", "127.0.0.1"]
        server.currentDirectoryURL = project.root
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try server.run()
        defer { server.terminate() }
        for _ in 0..<50 where !DevServer.isListening(port: port) { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertTrue(DevServer.isListening(port: port))

        let found = DevServer.listening(under: project.root)
        XCTAssertEqual(found.compactMap(\.port), [port])
        XCTAssertEqual(DevServer.best(mentioned: [URL(string: "http://localhost:1/")!], root: project.root)?.port, port)

        let other = try TempProject()
        XCTAssertTrue(DevServer.listening(under: other.root).isEmpty)
    }
}

@MainActor
final class PagePreviewTests: XCTestCase {
    func testPicturesALocalPage() async throws {
        _ = NSApplication.shared
        let project = try TempProject(files: ["index.html": "<body style='margin:0;background:#ff0000'><h1>Margin</h1></body>"])
        let png = await PagePreview.capture(project.root.appendingPathComponent("index.html"), size: CGSize(width: 400, height: 300), settle: 0.3)
        let data = try XCTUnwrap(png)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(Double(rep.pixelsWide) / Double(rep.pixelsHigh), 4.0 / 3.0, accuracy: 0.02)
        let color = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide - 5, y: rep.pixelsHigh - 5)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(color.redComponent, 0.8)
        XCTAssertLessThan(color.greenComponent, 0.3)
    }

    func testUnreachablePageGivesNothing() async {
        _ = NSApplication.shared
        let png = await PagePreview.capture(URL(string: "http://localhost:9/")!, size: CGSize(width: 200, height: 200), timeout: 5)
        XCTAssertNil(png)
    }
}

final class VersionRunnerTests: XCTestCase {
    func testDetect() throws {
        let node = try TempProject(files: ["package.json": #"{"scripts":{"build":"x","dev":"vite"}}"#, "pnpm-lock.yaml": ""])
        XCTAssertEqual(VersionRunner.detect(node.root), .node(manager: "pnpm", script: "dev"))
        let site = try TempProject(files: ["public/index.html": "<p>hi</p>"])
        XCTAssertEqual(VersionRunner.detect(site.root), .staticSite(folder: "public"))
        let other = try TempProject(files: ["main.py": "print(1)"])
        XCTAssertEqual(VersionRunner.detect(other.root), .unknown)
        XCTAssertEqual(VersionRunner.command(for: .node(manager: "npm", script: "dev"), port: 4100), "PORT=4100 BROWSER=none exec npm run dev -- --port 4100")
    }

    func testRunsAStaticVersion() async throws {
        let version = try TempProject(files: ["index.html": "<h1>Version 3</h1>"])
        let runner = VersionRunner()
        let running = try await runner.start(directory: version.root, original: version.root, timeout: 30)
        defer { runner.stopAll() }
        let (data, _) = try await URLSession.shared.data(from: running.url)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("Version 3"))
        runner.stop(version.root)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertFalse(DevServer.isListening(port: running.port))
    }

    func testRunsANodeVersionWithBorrowedDependencies() async throws {
        let which = Shell.run("/bin/zsh", ["-lc", "command -v npm"])
        guard which.ok else { throw XCTSkip("npm not installed") }
        let live = try TempProject(files: [
            "node_modules/greeting/index.js": "module.exports = 'from node_modules'",
            ".env": "WORD=env-ok",
        ])
        let version = try TempProject(files: [
            "package.json": #"{"name":"v","scripts":{"dev":"node server.js"}}"#,
            "server.js": """
            const http = require('http');
            const fs = require('fs');
            const greeting = require('greeting');
            const env = fs.readFileSync('.env', 'utf8').trim();
            http.createServer((q, r) => r.end(greeting + ' ' + env)).listen(process.env.PORT, '127.0.0.1');
            """,
        ])
        let runner = VersionRunner()
        let running = try await runner.start(directory: version.root, original: live.root, timeout: 60)
        defer { runner.stopAll() }
        let (data, _) = try await URLSession.shared.data(from: running.url)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "from node_modules WORD=env-ok")
    }
}

final class HookServerTests: XCTestCase {
    func testParsesSplitRequests() {
        let request = Data("POST /hooks/claude-code HTTP/1.1\r\nHost: x\r\nContent-Length: 11\r\n\r\n{\"a\":true}\n".utf8)
        XCTAssertNil(HookServer.parse(request.prefix(30)))
        XCTAssertNil(HookServer.parse(request.prefix(request.count - 3)))
        let parsed = HookServer.parse(request)
        XCTAssertEqual(parsed?.path, "/hooks/claude-code")
        XCTAssertEqual(parsed?.body, Data("{\"a\":true}\n".utf8))
    }

    func testReceivesPosts() async throws {
        let received = expectation(description: "event")
        var body = Data()
        let server = HookServer { path, data in
            XCTAssertEqual(path, "/hooks/claude-code")
            body = data
            received.fulfill()
        }
        let port = try server.start(ports: [0])
        defer { server.stop() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/hooks/claude-code")!)
        request.httpMethod = "POST"
        request.httpBody = Data(String(repeating: "x", count: 5000).utf8)
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        await fulfillment(of: [received], timeout: 5)
        XCTAssertEqual(body.count, 5000)
    }

    func testFallsBackWhenAPortIsTaken() throws {
        let first = HookServer { _, _ in }
        let port = try first.start(ports: [0])
        defer { first.stop() }
        let second = HookServer { _, _ in }
        let other = try second.start(ports: [port, 0])
        defer { second.stop() }
        XCTAssertNotEqual(other, port)
    }
}

final class ClaudeCodeConnectorTests: XCTestCase {
    func testConnectKeepsOtherSettingsAndDisconnectsCleanly() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("margin-claude-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = dir.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = """
        {"model": "opus", "hooks": {"PostToolUse": [{"matcher": "Edit", "hooks": [{"type": "command", "command": "prettier --write"}]}]}}
        """
        try existing.write(to: settings, atomically: true, encoding: .utf8)
        let connector = ClaudeCodeConnector(settingsURL: settings, supportDirectory: dir.appendingPathComponent(".margin"))
        XCTAssertFalse(connector.isConnected)

        try connector.connect(port: 47821)
        try connector.connect(port: 47822) // twice: still one hook per event
        XCTAssertTrue(connector.isConnected)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "opus")
        let hooks = try XCTUnwrap(json["hooks"] as? [String: Any])
        let post = try XCTUnwrap(hooks["PostToolUse"] as? [[String: Any]])
        guard post.count == 2 else { return XCTFail("PostToolUse groups: \(post)") }
        XCTAssertEqual(post[0]["matcher"] as? String, "Edit")
        let ours = try XCTUnwrap((post[1]["hooks"] as? [[String: Any]])?.first)
        XCTAssertEqual(ours["command"] as? String, "/bin/sh \"$HOME/.margin/claude-hook.sh\"")
        XCTAssertEqual(ours["async"] as? Bool, true)
        XCTAssertEqual((hooks["UserPromptSubmit"] as? [[String: Any]])?.count, 1)

        // Support files: an executable script and the port.
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: connector.scriptURL.path))
        XCTAssertEqual(try String(contentsOf: connector.portURL).trimmingCharacters(in: .whitespacesAndNewlines), "47822")
        let script = try String(contentsOf: connector.scriptURL)
        XCTAssertTrue(script.contains("--data-binary @-"))
        XCTAssertTrue(script.contains("-H 'Expect:' \\\n"))

        // A backup of the original was kept.
        XCTAssertTrue(FileManager.default.fileExists(atPath: settings.appendingPathExtension("before-margin").path))

        try connector.disconnect()
        XCTAssertFalse(connector.isConnected)
        let after = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        let left = try XCTUnwrap(after["hooks"] as? [String: Any])
        XCTAssertEqual(Array(left.keys), ["PostToolUse"])
        XCTAssertEqual(after["model"] as? String, "opus")
    }

    func testRefusesBrokenSettings() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("margin-claude-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = dir.appendingPathComponent("settings.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "{ not json".write(to: settings, atomically: true, encoding: .utf8)
        let connector = ClaudeCodeConnector(settingsURL: settings, supportDirectory: dir.appendingPathComponent(".margin"))
        XCTAssertThrowsError(try connector.connect(port: 1))
        XCTAssertEqual(try String(contentsOf: settings), "{ not json")
    }

    func testTheScriptForwardsToMargin() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("margin-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let received = expectation(description: "forwarded")
        let server = HookServer { _, body in
            if HookEvent.claudeCode(body)?.prompt == "Make the cards denser" { received.fulfill() }
        }
        let port = try server.start(ports: [0])
        defer { server.stop() }
        let connector = ClaudeCodeConnector(settingsURL: dir.appendingPathComponent(".claude/settings.json"), supportDirectory: dir.appendingPathComponent(".margin"))
        try connector.writeSupportFiles(port: port)
        let payload = Data(#"{"session_id":"s","hook_event_name":"UserPromptSubmit","cwd":"/tmp","prompt":"Make the cards denser"}"#.utf8)
        // Run it the way Claude Code does, with HOME pointing at our folder.
        let out = Shell.run("/bin/sh", ["-c", "/bin/sh \"$HOME/.margin/claude-hook.sh\""], environment: ["HOME": dir.path], input: payload, timeout: 10)
        XCTAssertEqual(out.status, 0)
        await fulfillment(of: [received], timeout: 5)

        // With Margin gone, it still exits cleanly and quickly.
        server.stop()
        let start = Date()
        let quiet = Shell.run("/bin/sh", ["-c", "/bin/sh \"$HOME/.margin/claude-hook.sh\""], environment: ["HOME": dir.path], input: payload, timeout: 10)
        XCTAssertEqual(quiet.status, 0)
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
    }
}

final class HookEventTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/claude-code"))
        return try Data(contentsOf: url)
    }

    /// Payloads recorded from Claude Code 2.1.302.
    func testRealPayloads() throws {
        let prompt = try XCTUnwrap(HookEvent.claudeCode(try fixture("UserPromptSubmit")))
        XCTAssertEqual(prompt.name, "UserPromptSubmit")
        XCTAssertTrue(prompt.prompt?.hasPrefix("Change the h1") == true)
        XCTAssertNotNil(prompt.cwd)
        XCTAssertNotNil(prompt.promptID)

        let edit = try XCTUnwrap(HookEvent.claudeCode(try fixture("PostToolUse-2")))
        XCTAssertTrue(edit.isEdit)
        XCTAssertTrue(edit.filePath?.hasSuffix("index.html") == true)

        let bash = try XCTUnwrap(HookEvent.claudeCode(try fixture("PostToolUse-3")))
        XCTAssertFalse(bash.isEdit)
        XCTAssertEqual(DevServer.urls(in: bash.toolOutput ?? "").first?.absoluteString, "http://localhost:5173/")

        let stop = try XCTUnwrap(HookEvent.claudeCode(try fixture("Stop")))
        XCTAssertTrue(stop.lastAssistantMessage?.contains("Hello Margin") == true)
        XCTAssertNil(HookEvent.claudeCode(Data("{}".utf8)))
    }

    func testTranscript() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("t-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"hi"}}"#,
            #"{"type":"ai-title","aiTitle":"Index.html h1 greeting","sessionId":"s"}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"First answer"}]}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Edit","input":{}}]}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Changed the heading."}]}}"#,
            #"{"type":"system"}"#,
        ]
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(Transcript.title(at: url), "Index.html h1 greeting")
        XCTAssertEqual(Transcript.lastAssistantText(at: url), "Changed the heading.")
    }
}

@MainActor
final class CodingTurnTrackerTests: XCTestCase {
    func testKeepsCodingTurnsAndDropsResearch() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("margin-code-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let tracker = CodingTurnTracker(snapshots: CodeSnapshots(base: base))
        let project = try TempProject(files: ["index.html": "<h1>One</h1>"])

        var finished: [(CodingTurn, Bool)] = []
        var done = expectation(description: "turn 1")
        tracker.onTurnFinished = { turn, kept in
            finished.append((turn, kept))
            done.fulfill()
        }
        var edits = 0
        tracker.onEdit = { _ in edits += 1 }

        func event(_ name: String, _ fill: (inout HookEvent) -> Void = { _ in }) -> HookEvent {
            var e = HookEvent(name: name, sessionID: "s1")
            e.cwd = project.root
            fill(&e)
            return e
        }

        // 1. A coding turn.
        tracker.handle(event("UserPromptSubmit") { $0.prompt = "Make the heading say Two" })
        try await Task.sleep(nanoseconds: 800_000_000) // the before snapshot
        try project.write("index.html", "<h1>Two</h1>")
        tracker.handle(event("PostToolUse") { $0.toolName = "Edit"; $0.filePath = project.root.appendingPathComponent("index.html").path })
        tracker.handle(event("PostToolUse") { $0.toolName = "Bash"; $0.toolOutput = "Local: http://localhost:5173/" })
        tracker.handle(event("Stop") { $0.lastAssistantMessage = "Changed it." })
        await fulfillment(of: [done], timeout: 20)
        guard finished.count == 1 else { return XCTFail("expected one finished turn, got \(finished.count)") }
        let first = finished[0].0
        XCTAssertTrue(finished[0].1)
        XCTAssertTrue(first.edited)
        XCTAssertEqual(edits, 1)
        XCTAssertEqual(first.summary, "Changed it.")
        XCTAssertEqual(first.mentionedURLs.map(\.absoluteString), ["http://localhost:5173/"])
        XCTAssertEqual(first.root?.path, project.root.path)
        XCTAssertNotNil(first.before)
        XCTAssertNotNil(first.after)

        // 2. A question: nothing changes, nothing is kept.
        done = expectation(description: "turn 2")
        tracker.handle(event("UserPromptSubmit") { $0.prompt = "What does this page do?" })
        tracker.handle(event("Stop") { $0.lastAssistantMessage = "It shows a heading." })
        await fulfillment(of: [done], timeout: 20)
        guard finished.count == 2 else { return XCTFail("expected two finished turns, got \(finished.count)") }
        XCTAssertFalse(finished[1].1)

        // 3. Interrupted: a new prompt closes the open turn first.
        done = expectation(description: "turn 3")
        done.expectedFulfillmentCount = 1
        tracker.handle(event("UserPromptSubmit") { $0.prompt = "Add a footer" })
        try await Task.sleep(nanoseconds: 800_000_000)
        try project.write("index.html", "<h1>Two</h1><footer>f</footer>")
        tracker.handle(event("UserPromptSubmit") { $0.prompt = "Actually make it dark" })
        await fulfillment(of: [done], timeout: 20)
        guard finished.count == 3 else { return XCTFail("expected three finished turns, got \(finished.count)") }
        XCTAssertTrue(finished[2].0.interrupted)
        XCTAssertTrue(finished[2].1)
        XCTAssertNotNil(tracker.active["s1"])
    }

    func testSessionsOutsideProjectsLeaveNothing() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("margin-code-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let tracker = CodingTurnTracker(snapshots: CodeSnapshots(base: base))
        let done = expectation(description: "turn")
        var kept: Bool?
        tracker.onTurnFinished = { _, k in kept = k; done.fulfill() }
        var start = HookEvent(name: "UserPromptSubmit", sessionID: "s2")
        start.cwd = FileManager.default.homeDirectoryForCurrentUser
        start.prompt = "Research CSS container queries"
        tracker.handle(start)
        tracker.handle(HookEvent(name: "Stop", sessionID: "s2"))
        await fulfillment(of: [done], timeout: 20)
        XCTAssertEqual(kept, false)
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
        XCTAssertTrue(contents.isEmpty, "\(contents)")
    }
}

final class LinkDetectorTests: XCTestCase {
    func testAddressBarsAndSelectedLinks() {
        XCTAssertEqual(LinkDetector.url(in: "https://arc.net/blog?ref=x")?.absoluteString, "https://arc.net/blog?ref=x")
        XCTAssertEqual(LinkDetector.url(in: "  github.com/luis-soma/SVSD_Competition \n")?.absoluteString, "https://github.com/luis-soma/SVSD_Competition")
        XCTAssertEqual(LinkDetector.url(in: "docs.figma.com")?.host, "docs.figma.com")
        XCTAssertEqual(LinkDetector.url(in: "http://localhost:5173/")?.port, 5173)
    }

    func testOrdinaryTextIsNotALink() {
        XCTAssertNil(LinkDetector.url(in: "Make the cards denser"))
        XCTAssertNil(LinkDetector.url(in: "see https://arc.net for more"))
        XCTAssertNil(LinkDetector.url(in: "index.html"))
        XCTAssertNil(LinkDetector.url(in: "App.swift"))
        XCTAssertNil(LinkDetector.url(in: "luis@example.com"))
        XCTAssertNil(LinkDetector.url(in: "e.g."))
        XCTAssertNil(LinkDetector.url(in: "3.14"))
        XCTAssertNil(LinkDetector.url(in: "/Users/luis/file.txt"))
        XCTAssertNil(LinkDetector.url(in: ""))
    }
}

@MainActor
final class PagePreviewTitleTests: XCTestCase {
    func testTitle() async throws {
        _ = NSApplication.shared
        let page = try TempProject(files: ["index.html": "<meta charset='utf-8'><title>Margin · Home</title><h1>Hi</h1>"])
        let shot = await PagePreview.shot(page.root.appendingPathComponent("index.html"), size: CGSize(width: 300, height: 200), settle: 0.2)
        XCTAssertEqual(shot?.title, "Margin · Home")
    }
}

private extension NSMutableArray {
    func prefixArray(_ n: Int) -> [String] { (self as? [String] ?? []).prefix(n).map { $0 } }
}

/// Margin's Figma plugin, run in Node with a fake `figma` object and its real
/// network code, against Margin's real local server.
final class FigmaPluginTests: XCTestCase {
    private func node() throws -> String {
        let which = Shell.run("/bin/zsh", ["-lc", "command -v node"])
        guard which.ok else { throw XCTSkip("node not installed") }
        return which.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testPluginFilesAreValid() throws {
        let node = try node()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("margin-plugin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let manifestURL = try FigmaPlugin.install(to: dir)
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        XCTAssertEqual(manifest["main"] as? String, "code.js")
        XCTAssertEqual(manifest["ui"] as? String, "ui.html")
        let network = try XCTUnwrap(manifest["networkAccess"] as? [String: Any])
        let dev = try XCTUnwrap(network["devAllowedDomains"] as? [String])
        XCTAssertTrue(dev.contains("http://localhost:47821"))
        // Figma rejects IP addresses in devAllowedDomains.
        XCTAssertFalse(dev.contains { $0.contains("127.0.0.1") })
        XCTAssertEqual(Shell.run(node, ["--check", dir.appendingPathComponent("code.js").path]).status, 0)
    }

    private func runPlugin(_ flags: [String], wantVideo: Bool, progress: ((Int, Int) -> Void)? = nil) async throws -> FigmaBridge.Export {
        let node = try node()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("margin-plugin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FigmaPlugin.install(to: dir)
        let harness = try XCTUnwrap(Bundle.module.url(forResource: "figma_plugin_harness", withExtension: "js", subdirectory: "Fixtures"))

        let bridge = FigmaBridge()
        let seen = NSMutableArray()
        let server = HookServer(router: { request in
            seen.add("\(request.method) \(request.path)?\(request.query.keys.sorted().joined(separator: "&"))")
            return bridge.handle(request) ?? .ok
        })
        server.deferred = { bridge.handleDeferred($0, reply: $1) }
        try server.start(ports: FigmaPlugin.ports)
        defer { server.stop() }

        let log = dir.appendingPathComponent("harness.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: log)
        // Through a login shell, like Margin runs node elsewhere.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        let quoted = ([harness.path, dir.path] + flags).map { "'\($0)'" }.joined(separator: " ")
        process.arguments = ["-lc", "exec node \(quoted)"]
        process.standardOutput = logHandle
        process.standardError = logHandle
        process.standardInput = FileHandle.nullDevice
        try process.run()
        defer { process.terminate() }

        for _ in 0..<100 where !bridge.isConnected { try await Task.sleep(nanoseconds: 100_000_000) }
        if !bridge.isConnected {
            let output = (try? String(contentsOf: log, encoding: .utf8)) ?? "(no log)"
            let version = Shell.run(node, ["--version"]).text
            XCTFail("the plugin didn't poll Margin on port \(server.port); server saw \(seen.count) requests \(seen.prefixArray(3)); node \(version) said: \(output.prefix(600))")
        }
        do {
            return try await bridge.export(wantVideo: wantVideo, timeout: 20, progress: progress)
        } catch {
            let output = (try? String(contentsOf: log, encoding: .utf8)) ?? "(no log)"
            XCTFail("export failed: \(error). Server saw \(seen.count) requests: \(seen.prefixArray(6)). Harness: \(output.suffix(1500))")
            throw error
        }
    }

    func testMotionFrameExportsAsVideo() async throws {
        let export = try await runPlugin([], wantVideo: true)
        XCTAssertEqual(export.nodeID, "139:218")
        XCTAssertEqual(export.nodeName, "desktop")
        XCTAssertTrue(ImageData.isImage(try XCTUnwrap(export.png)))
        XCTAssertTrue(FigmaMotion.isVideo(try XCTUnwrap(export.video)))
        XCTAssertEqual(export.link?.absoluteString, "https://www.figma.com/design/tEO3GjK8Jcijru2LYcHvIL/SVSD-Competition?node-id=139-218")
    }

    func testSeveralFramesExportOneByOne() async throws {
        let reports = NSMutableArray()
        let export = try await runPlugin(["--multi"], wantVideo: true) { done, total in
            reports.add("\(done)/\(total)")
        }
        // Each frame reports in as it finishes. The last report can land after
        // the result (then it's moot), so only the early ones are certain.
        XCTAssertTrue(reports.contains("0/3"), "progress: \(reports)")
        XCTAssertTrue((reports as? [String] ?? []).allSatisfy { $0.hasSuffix("/3") }, "progress: \(reports)")
        XCTAssertEqual(export.frames.map(\.nodeID), ["139:218", "139:2", "139:3"])
        XCTAssertEqual(export.frames.map(\.nodeName), ["desktop", "mobile", "tablet"])
        XCTAssertTrue(export.frames.allSatisfy { $0.png.map(ImageData.isImage) == true })
        XCTAssertNotNil(export.frames[0].video)
        XCTAssertNotNil(export.frames[1].video)
        XCTAssertNil(export.frames[2].video)
        XCTAssertEqual(export.selectionCount, 3)
        XCTAssertEqual(export.link(to: "139:2")?.absoluteString, "https://www.figma.com/design/tEO3GjK8Jcijru2LYcHvIL/SVSD-Competition?node-id=139-2")
    }

    func testChildSelectionExportsItsTopLevelFrame() async throws {
        let export = try await runPlugin(["--child"], wantVideo: true)
        XCTAssertEqual(export.nodeID, "139:218")
        XCTAssertNotNil(export.video)
    }

    func testStillFrameKeepsTheImage() async throws {
        let export = try await runPlugin(["--still"], wantVideo: true)
        XCTAssertNotNil(export.png)
        XCTAssertNil(export.video)
        XCTAssertTrue(export.videoError?.contains("animated") == true)
    }

    func testNothingSelected() async throws {
        let export = try await runPlugin(["--empty"], wantVideo: false)
        XCTAssertTrue(export.nothingSelected)
    }

    func testNotRunning() async {
        do {
            _ = try await FigmaBridge().export(wantVideo: true)
            XCTFail("should fail without the plugin")
        } catch let error as FigmaBridge.BridgeError {
            XCTAssertEqual(error.description, FigmaBridge.BridgeError.notRunning.description)
        } catch {
            XCTFail("\(error)")
        }
    }
}

/// Versions that arrive through git: an agent elsewhere pushes, Margin's
/// copy of the project fetches.
final class RepoWatcherTests: XCTestCase {
    private var root: URL!
    private let git = "/usr/bin/git"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("margin-repos-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func run(_ args: [String], in dir: URL) -> String {
        let out = Shell.run(git, ["-c", "user.name=T", "-c", "user.email=t@t", "-c", "init.defaultBranch=main"] + args, in: dir)
        XCTAssertTrue(out.ok, "git \(args.joined(separator: " ")): \(out.stderr)")
        return out.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testNoticesPushedCommits() throws {
        let remote = root.appendingPathComponent("remote.git")
        run(["init", "-q", "--bare", remote.path], in: root)
        // The agent's copy (a cloud session) …
        let agent = root.appendingPathComponent("agent")
        run(["clone", "-q", remote.path, agent.path], in: root)
        try "<h1>One</h1>\n".write(to: agent.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        run(["add", "-A"], in: agent)
        run(["commit", "-q", "-m", "First version"], in: agent)
        run(["push", "-q", "origin", "HEAD:main"], in: agent)
        // … and the designer's copy on this Mac.
        let mine = root.appendingPathComponent("mine")
        run(["clone", "-q", remote.path, mine.path], in: root)
        XCTAssertTrue(RepoWatcher.isRepository(mine))
        XCTAssertFalse(RepoWatcher.isRepository(root))

        let before = RepoWatcher.state(mine)
        XCTAssertEqual(before.refs.keys.sorted(), ["refs/remotes/origin/main"])

        // The agent pushes two commits and a new branch.
        try "<h1>Two</h1>\n<p>New</p>\n".write(to: agent.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        run(["commit", "-q", "-am", "Bigger heading"], in: agent)
        try "body { margin: 0 }\n".write(to: agent.appendingPathComponent("style.css"), atomically: true, encoding: .utf8)
        run(["add", "-A"], in: agent)
        run(["commit", "-q", "-m", "Add styles"], in: agent)
        run(["push", "-q", "origin", "HEAD:main", "HEAD:feature"], in: agent)

        XCTAssertTrue(RepoWatcher.fetch(mine))
        let after = RepoWatcher.state(mine)
        let changes = RepoWatcher.changes(mine, from: before, to: after)
        XCTAssertEqual(changes.map(\.branch), ["feature", "main"])
        let main = try XCTUnwrap(changes.first { $0.branch == "main" })
        XCTAssertEqual(main.commits.map(\.subject), ["Add styles", "Bigger heading"])
        XCTAssertEqual(main.base, before.refs["refs/remotes/origin/main"])

        let stat = RepoWatcher.diffStat(mine, from: main.base, to: main.to)
        XCTAssertEqual(stat.files.sorted(), ["index.html", "style.css"])
        XCTAssertTrue(RepoWatcher.diff(mine, from: main.base, to: main.to).contains("+<h1>Two</h1>"))

        let out = root.appendingPathComponent("export")
        try RepoWatcher.export(mine, commit: main.to, to: out)
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("style.css"), encoding: .utf8), "body { margin: 0 }\n")

        // The designer's own branch and files weren't touched.
        XCTAssertEqual(try String(contentsOf: mine.appendingPathComponent("index.html"), encoding: .utf8), "<h1>One</h1>\n")

        // Nothing new: no changes.
        XCTAssertTrue(RepoWatcher.changes(mine, from: after, to: RepoWatcher.state(mine)).isEmpty)
    }

    func testFetchFailsQuietlyWithoutARemote() throws {
        let lonely = root.appendingPathComponent("lonely")
        try FileManager.default.createDirectory(at: lonely, withIntermediateDirectories: true)
        run(["init", "-q"], in: lonely)
        _ = RepoWatcher.fetch(lonely, timeout: 10)
        XCTAssertTrue(RepoWatcher.state(lonely).refs.isEmpty)
    }
}
