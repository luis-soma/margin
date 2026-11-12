import XCTest
@testable import MarginKit

/// Runs the Python stand-in for Figma's desktop MCP server.
final class MockFigmaServer {
    let process = Process()
    let input = Pipe()
    let output = Pipe()
    let endpoint: URL

    init(_ arguments: [String] = []) throws {
        guard let script = Bundle.module.url(forResource: "mock_mcp", withExtension: "py", subdirectory: "Fixtures") else {
            throw XCTSkip("mock server script missing from test bundle")
        }
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { throw XCTSkip("python3 not installed") }
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path] + arguments
        process.standardInput = input
        process.standardOutput = output
        try process.run()

        // First line of output is the port.
        var line = Data()
        let handle = output.fileHandleForReading
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            let byte = handle.readData(ofLength: 1)
            if byte.isEmpty || byte == Data("\n".utf8) { break }
            line.append(byte)
        }
        guard let port = Int(String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespaces)) else {
            process.terminate()
            throw XCTSkip("mock server didn't start (python3 may need the Xcode tools)")
        }
        endpoint = URL(string: "http://127.0.0.1:\(port)/mcp")!
    }

    deinit {
        try? input.fileHandleForWriting.close()
        process.terminate()
    }
}

final class MCPClientTests: XCTestCase {
    func testSSEParsing() {
        let stream = "event: message\ndata: {\"a\":\ndata: 1}\n\n: comment\ndata: {\"b\":2}\r\n\r\n"
        XCTAssertEqual(MCPClient.sseEvents(stream), ["{\"a\":\n1}", "{\"b\":2}"])
    }

    func testFindsReplyAmongNotifications() throws {
        let body = Data("data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\"}\n\ndata: {\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"ok\":true}}\n\n".utf8)
        let result = try MCPClient.response(id: 3, in: body, contentType: "text/event-stream")
        XCTAssertEqual(result?["ok"] as? Bool, true)
        XCTAssertNil(try MCPClient.response(id: 4, in: body, contentType: "text/event-stream"))
    }

    func testRPCErrorsThrow() {
        let body = Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32602,\"message\":\"bad node\"}}".utf8)
        XCTAssertThrowsError(try MCPClient.response(id: 1, in: body, contentType: "application/json")) { error in
            XCTAssertEqual(error as? MCPClient.MCPError, .rpc(-32602, "bad node"))
        }
    }

    func testToolResultContent() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        let result = MCPClient.toolResult([
            "content": [
                ["type": "text", "text": "hello"],
                ["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"],
                ["type": "resource", "resource": ["uri": "file:///x.png", "mimeType": "image/png", "blob": png.base64EncodedString()]],
                ["type": "resource_link", "uri": "https://example.com/a.png"],
            ],
        ])
        XCTAssertEqual(result.texts, ["hello"])
        XCTAssertEqual(result.images.count, 2)
        XCTAssertEqual(result.images.first?.data, png)
        XCTAssertEqual(result.links, ["https://example.com/a.png"])
        XCTAssertFalse(result.isError)
    }

    func testToolSchema() {
        let tool = MCPClient.tool(["name": "get_screenshot", "inputSchema": ["properties": ["nodeId": [:], "maxDimension": [:]], "required": ["nodeId"]]])
        XCTAssertEqual(tool?.properties, ["nodeId", "maxDimension"])
        XCTAssertEqual(tool?.required, ["nodeId"])
    }

    // MARK: Against the mock server

    func testJSONSession() async throws {
        let server = try MockFigmaServer()
        let client = MCPClient(endpoint: server.endpoint)
        let tools = try await client.connect()
        XCTAssertEqual(tools.map(\.name), ["get_motion_context", "get_design_context", "get_metadata", "get_screenshot"])
        XCTAssertEqual(client.serverName, "Figma Dev Mode MCP (mock)")
        let result = try await client.call("get_metadata", arguments: ["nodeId": "1:2"])
        XCTAssertEqual(FigmaMetadata.root(in: result.text)?.name, "Home & Hero")
    }

    func testSSEStreamThatStaysOpen() async throws {
        let server = try MockFigmaServer(["--sse"])
        let client = MCPClient(endpoint: server.endpoint)
        let start = Date()
        try await client.connect()
        _ = try await client.call("get_metadata", arguments: [:])
        // The server keeps each stream open for 4s; the client must not wait for that.
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testUnreachableServer() async {
        let client = MCPClient(endpoint: URL(string: "http://127.0.0.1:9/mcp")!)
        do {
            try await client.connect(timeout: 2)
            XCTFail("should not connect")
        } catch let error as MCPClient.MCPError {
            guard case .unreachable = error else { return XCTFail("\(error)") }
        } catch {
            XCTFail("\(error)")
        }
    }
}

final class FigmaDesktopExporterTests: XCTestCase {
    func testExportsSelectionAsBase64() async throws {
        let server = try MockFigmaServer()
        let export = try await FigmaDesktopExporter(endpoint: server.endpoint).export(nodeID: nil, fileKey: nil)
        XCTAssertTrue(ImageData.isImage(export.image))
        XCTAssertEqual(export.node.id, "12:34")
        XCTAssertEqual(export.node.name, "Home & Hero")
    }

    func testPageLinkUsesSelection() async throws {
        let server = try MockFigmaServer(["--sse"])
        let export = try await FigmaDesktopExporter(endpoint: server.endpoint).export(nodeID: "0:1", fileKey: "abcdefghij1234567890AB")
        XCTAssertEqual(export.node.id, "12:34")
    }

    func testFrameLink() async throws {
        // Older servers answer get_metadata with the selection's XML.
        let server = try MockFigmaServer(["--selection", "xml"])
        let export = try await FigmaDesktopExporter(endpoint: server.endpoint).export(nodeID: "12:34", fileKey: nil)
        XCTAssertEqual(export.node.id, "12:34")
        XCTAssertEqual(export.node.name, "Home & Hero")
    }

    func testDownloadsURLResponses() async throws {
        let server = try MockFigmaServer(["--images", "url"])
        let export = try await FigmaDesktopExporter(endpoint: server.endpoint).export(nodeID: nil, fileKey: nil)
        XCTAssertTrue(ImageData.isImage(export.image))
    }

    func testLegacyGetImage() async throws {
        let server = try MockFigmaServer(["--legacy", "--selection", "xml"])
        let export = try await FigmaDesktopExporter(endpoint: server.endpoint).export(nodeID: nil, fileKey: nil)
        XCTAssertTrue(ImageData.isImage(export.image))
    }

    func testNothingSelected() async throws {
        let server = try MockFigmaServer(["--selection", "none"])
        do {
            _ = try await FigmaDesktopExporter(endpoint: server.endpoint).export(nodeID: nil, fileKey: nil)
            XCTFail("should report no selection")
        } catch let error as FigmaExportError {
            XCTAssertEqual(error, .noSelection)
        }
        do {
            _ = try await FigmaDesktopExporter(endpoint: server.endpoint).export(nodeID: "0:1", fileKey: nil)
            XCTFail("a page link with nothing selected is no selection")
        } catch let error as FigmaExportError {
            XCTAssertEqual(error, .noSelection)
        }
    }

    func testServerOff() async {
        do {
            _ = try await FigmaDesktopExporter(endpoint: URL(string: "http://127.0.0.1:9/mcp")!).export(nodeID: nil, fileKey: nil)
            XCTFail("should be unavailable")
        } catch let error as FigmaExportError {
            guard case .unavailable = error else { return XCTFail("\(error)") }
        } catch {
            XCTFail("\(error)")
        }
    }

    func testStillFrameHasNoMotion() async throws {
        let server = try MockFigmaServer(["--video"])
        let export = try await FigmaDesktopExporter(endpoint: server.endpoint).export(nodeID: nil, fileKey: "abcdefghij1234567890AB")
        XCTAssertFalse(export.hasMotion)
        XCTAssertNil(export.video)
    }

    func testMotionFrameBecomesAVideo() async throws {
        let server = try MockFigmaServer(["--motion", "--video"])
        let exporter = FigmaDesktopExporter(endpoint: server.endpoint)
        let export = try await exporter.export(nodeID: nil, fileKey: "abcdefghij1234567890AB")
        XCTAssertTrue(export.hasMotion)
        let video = try XCTUnwrap(export.video)
        XCTAssertTrue(FigmaMotion.isVideo(video))
        XCTAssertTrue(ImageData.isImage(export.image)) // the still comes along
    }

    func testMotionWithoutVideoExport() async throws {
        let server = try MockFigmaServer(["--motion"])
        let export = try await FigmaDesktopExporter(endpoint: server.endpoint).export(nodeID: nil, fileKey: nil)
        XCTAssertTrue(export.hasMotion)
        XCTAssertNil(export.video)
    }

    func testMotionHintFromTheLink() async throws {
        // A server without motion tools: the link's timeline flag decides.
        let server = try MockFigmaServer(["--legacy", "--selection", "xml"])
        let export = try await FigmaDesktopExporter(endpoint: server.endpoint).export(nodeID: nil, fileKey: nil, motionHint: true)
        XCTAssertFalse(export.hasMotion, "get_motion_context exists in the mock and says the frame itself isn't animated")
    }

    func testStatus() async throws {
        let server = try MockFigmaServer()
        let status = await FigmaDesktopExporter(endpoint: server.endpoint).status()
        XCTAssertEqual(try status.get().contains("get_screenshot"), true)
    }
}
