import XCTest
@testable import MarginKit

final class FigmaLinkTests: XCTestCase {
    func testCopyLinkToSelection() throws {
        let link = try XCTUnwrap(FigmaLink.parse("https://www.figma.com/design/tEO3GjK8Jcijru2LYcHvIL/SVSD-Competition?node-id=98-46&t=Wbd7TI4DogbKq0ht-1"))
        XCTAssertEqual(link.kind, "design")
        XCTAssertEqual(link.fileKey, "tEO3GjK8Jcijru2LYcHvIL")
        XCTAssertEqual(link.nodeID, "98:46")
        XCTAssertEqual(link.fileName, "SVSD Competition")
    }

    /// Copied by Luis in Figma's motion timeline.
    func testMotionLink() throws {
        let link = try XCTUnwrap(FigmaLink.parse("https://www.figma.com/design/tEO3GjK8Jcijru2LYcHvIL/SVSD-Competition?timeline=keyframe&timeline-playback-time=950199&node-id=139-218&t=jOltGnnMxnQkMeSA-11"))
        XCTAssertTrue(link.isMotion)
        XCTAssertEqual(link.nodeID, "139:218")
        XCTAssertFalse(try XCTUnwrap(FigmaLink.parse("https://www.figma.com/design/tEO3GjK8Jcijru2LYcHvIL/X?node-id=1-2")).isMotion)
    }

    func testMotionReplies() {
        // Verbatim from Figma (October 2026).
        let animated = #"{"nodes":[{"nodeId":"139:223","nodeName":"margin","nodeType":"FRAME","codeSnippets":{"css":"animation: kf_139_223_opacity_0 2s linear;","motionDev":"<motion.div />"}}]}"#
        XCTAssertEqual(FigmaMotion.parse(animated)?.animated, true)
        let still = #"{"nodes":[{"nodeId":"139:218","nodeName":"desktop","nodeType":"FRAME","timelineDurationMs":null,"transformOrigin":{"x":0.5,"y":0.5},"motionSummary":null,"codeSnippets":{}}]}"#
        XCTAssertEqual(FigmaMotion.parse(still)?.animated, false)
        XCTAssertEqual(FigmaMotion.parse(#"{"nodes":[],"timelineCohorts":[{"rootNodeId":"139:218"}]}"#), FigmaMotion.Info(animated: true, timelineRoot: "139:218"))
        XCTAssertNil(FigmaMotion.parse("You currently have nothing selected."))

        let done = FigmaMotion.videoReply(#"{"downloadUrl":"https://www.figma.com/blobs/us/download/x?X-Amz-Expires=604800","availableUntil":"2026-10-17T17:38:11Z"}"#)
        XCTAssertEqual(done.downloadURL?.host, "www.figma.com")
        XCTAssertNil(done.jobID)
        let waiting = FigmaMotion.videoReply(#"{"jobId":"0b6a1f3e-1111-4222-8333-444455556666","status":"processing"}"#)
        XCTAssertNil(waiting.downloadURL)
        XCTAssertEqual(waiting.jobID, "0b6a1f3e-1111-4222-8333-444455556666")
        XCTAssertTrue(FigmaMotion.isVideo(Data([0, 0, 0, 24]) + Data("ftypisom".utf8) + Data(count: 8)))
        XCTAssertFalse(FigmaMotion.isVideo(Data("<html></html>".utf8)))
    }

    func testEncodedColonAndOldFileURLs() throws {
        let link = try XCTUnwrap(FigmaLink.parse("https://figma.com/file/abcdefghij1234567890AB/Old?node-id=12%3A34"))
        XCTAssertEqual(link.kind, "file")
        XCTAssertEqual(link.nodeID, "12:34")
    }

    func testBranchUsesBranchKey() throws {
        let link = try XCTUnwrap(FigmaLink.parse("https://www.figma.com/design/abcdefghij1234567890AB/branch/ZYXWVUTSRQ0987654321zy/Name?node-id=1-2"))
        XCTAssertEqual(link.fileKey, "ZYXWVUTSRQ0987654321zy")
        XCTAssertEqual(link.fileName, "Name")
    }

    func testNoNodeAndOtherKinds() throws {
        XCTAssertNil(try XCTUnwrap(FigmaLink.parse("https://www.figma.com/design/abcdefghij1234567890AB/Name")).nodeID)
        XCTAssertEqual(FigmaLink.parse("https://www.figma.com/proto/abcdefghij1234567890AB/Name?node-id=3-4&starting-point-node-id=3%3A4")?.kind, "proto")
        XCTAssertEqual(FigmaLink.parse("https://www.figma.com/board/abcdefghij1234567890AB/Jam?node-id=0-1")?.kind, "board")
        XCTAssertEqual(FigmaLink.parse("  https://www.figma.com/design/abcdefghij1234567890AB/X?node-id=I5-6;7-8  \n")?.nodeID, "I5:6;7:8")
    }

    func testRejectsOtherText() {
        XCTAssertNil(FigmaLink.parse(nil))
        XCTAssertNil(FigmaLink.parse(""))
        XCTAssertNil(FigmaLink.parse("hello world"))
        XCTAssertNil(FigmaLink.parse("https://example.com/design/abcdefghij1234567890AB/X"))
        XCTAssertNil(FigmaLink.parse("https://www.figma.com/community/file/123"))
        XCTAssertNil(FigmaLink.parse("https://www.figma.com/design/short/X"))
        XCTAssertNil(FigmaLink.apiNodeID("abc"))
    }
}

final class FigmaMetadataTests: XCTestCase {
    func testXMLRoot() {
        let node = FigmaMetadata.root(in: #"<frame id="12:34" name="Home &amp; Hero" x="0" y="0" width="1440" height="900"><text id="12:35" name="Title"/></frame>"#)
        XCTAssertEqual(node, FigmaNodeInfo(id: "12:34", name: "Home & Hero", type: "frame"))
    }

    func testSelectionBlock() {
        let text = "Currently selected nodes:\n- 12:34 Home & Hero (FRAME)\n- 12:40 Card (COMPONENT)\n\n<canvas id=\"0:1\" name=\"Page 1\" />"
        let selected = FigmaMetadata.selected(in: text)
        XCTAssertEqual(selected.map(\.id), ["12:34", "12:40"])
        XCTAssertEqual(selected.first?.name, "Home & Hero")
        XCTAssertEqual(selected.first?.type, "frame")
    }

    /// Several frames selected, as Figma's desktop server lists them, with the first one's outline after.
    func testSeveralSelectedBeforeOutline() {
        let text = "Currently selected nodes:\n- 139:878: Frame 17\n- 139:861: Frame 16\n  <frame id=\"139:878\" name=\"Frame 17\" x=\"0\" y=\"0\" width=\"3035\" height=\"1909\">\n  <vector id=\"139:891\" name=\"Rectangle 13\" />\n</frame>"
        XCTAssertEqual(FigmaMetadata.selected(in: text).map(\.id), ["139:878", "139:861"])
        XCTAssertEqual(FigmaMetadata.selected(in: text).last?.name, "Frame 16")
    }

    func testSelectionBlockAsXML() {
        let text = "Currently selected nodes:\n<frame guid=\"7:8\" name=\"Pricing\" />\n\n<canvas id=\"0:1\" name=\"Page\" />"
        XCTAssertEqual(FigmaMetadata.selected(in: text).first?.id, "7:8")
        XCTAssertEqual(FigmaMetadata.selected(in: text).first?.name, "Pricing")
    }

    func testSelectionInlineWithKeys() {
        let text = #"Currently selected nodes: id: "3:9", name: "Modal""#
        XCTAssertEqual(FigmaMetadata.selected(in: text).first, FigmaNodeInfo(id: "3:9", name: "Modal", type: nil))
    }

    /// Verbatim from Figma's MCP server (October 2026): the selection block,
    /// then the page list as a second content item.
    func testRealServerOutput() {
        let text = """
        Currently selected nodes:
        - 111:7: things to capture figma frames (select frame, press button) includes motions? text (selected, press button) general screenshots (press button)

        No nodeId was provided. Listing the top-level pages of the document. Call get_metadata again with one of the page ids below (or any node id underneath) to get the XML metadata for that subtree.

        Top-level pages of the document:
        - 0:1: Ideation
        """
        let node = FigmaMetadata.target(in: text, requested: nil)
        XCTAssertEqual(node?.id, "111:7")
        XCTAssertEqual(node?.name, "things to capture figma frames (select frame, press button) includes motions? text (selected, press button) general screenshots (press button)")
        XCTAssertNil(node?.type)

        let nothingSelected = """
        No nodeId was provided. Listing the top-level pages of the document.

        Top-level pages of the document:
        - 0:1: Ideation
        - 5:2: Archive
        """
        XCTAssertNil(FigmaMetadata.target(in: nothingSelected, requested: nil))
    }

    func testNamesWithParenthesesKeepThem() {
        let nodes = FigmaMetadata.selected(in: "Currently selected nodes:\n- 4:5: Card (hover)\n- 4:6 Button (COMPONENT)")
        XCTAssertEqual(nodes.first?.name, "Card (hover)")
        XCTAssertNil(nodes.first?.type)
        XCTAssertEqual(nodes.last?.type, "component")
    }

    func testRealScreenshotReplyURL() {
        let reply = #"{"image_url":"https://www.figma.com/api/mcp/asset/366b7979-6a1c-4aa0-b5c1-3caaab2363d5.png","width":512,"height":418,"format":"png"}"#
        XCTAssertEqual(ImageData.urls(in: reply).first?.absoluteString, "https://www.figma.com/api/mcp/asset/366b7979-6a1c-4aa0-b5c1-3caaab2363d5.png")
    }

    func testTarget() {
        // A frame link: the frame.
        XCTAssertEqual(FigmaMetadata.target(in: #"<frame id="1:2" name="A" />"#, requested: "1:2")?.id, "1:2")
        // A page link with a selection: the selection.
        let page = "Currently selected nodes:\n- 9:9 B (FRAME)\n\n<canvas id=\"0:1\" name=\"Page\" />"
        XCTAssertEqual(FigmaMetadata.target(in: page, requested: "0:1")?.id, "9:9")
        // A page and nothing selected: nothing.
        XCTAssertNil(FigmaMetadata.target(in: #"<canvas id="0:1" name="Page 1" />"#, requested: "0:1"))
        XCTAssertNil(FigmaMetadata.target(in: #"<canvas id="0:1" name="Page 1" /><canvas id="5:0" name="Two" />"#, requested: nil))
        XCTAssertNil(FigmaMetadata.target(in: "No pages", requested: nil))
    }
}

final class FigmaRESTTests: XCTestCase {
    func testRequests() {
        let image = FigmaREST.imageRequest(fileKey: "KEYKEYKEYKEY", nodeID: "1:2", token: "figd_x")
        XCTAssertEqual(image.value(forHTTPHeaderField: "X-Figma-Token"), "figd_x")
        XCTAssertEqual(image.url?.absoluteString, "https://api.figma.com/v1/images/KEYKEYKEYKEY?ids=1:2&format=png&scale=2")
        XCTAssertEqual(FigmaREST.nodesRequest(fileKey: "K", nodeID: "1:2", token: "t").url?.path, "/v1/files/K/nodes")
    }

    func testParsing() throws {
        let images = Data(#"{"err":null,"images":{"1:2":"https://figma-alpha.s3/x.png"}}"#.utf8)
        XCTAssertEqual(try FigmaREST.parseImageURL(images, nodeID: "1:2").absoluteString, "https://figma-alpha.s3/x.png")
        XCTAssertThrowsError(try FigmaREST.parseImageURL(Data(#"{"err":"Invalid"}"#.utf8), nodeID: "1:2"))
        XCTAssertThrowsError(try FigmaREST.parseImageURL(Data(#"{"images":{"1:2":null}}"#.utf8), nodeID: "1:2"))

        let nodes = Data(#"{"nodes":{"0:1":{"document":{"id":"0:1","name":"Page 1","type":"CANVAS"}}}}"#.utf8)
        let node = try XCTUnwrap(FigmaREST.parseNode(nodes, nodeID: "0:1"))
        XCTAssertEqual(node.name, "Page 1")
        XCTAssertTrue(node.isPage)
    }

    func testImageSniffing() {
        XCTAssertTrue(ImageData.isImage(Data([0x89, 0x50, 0x4E, 0x47, 0, 0])))
        XCTAssertTrue(ImageData.isImage(Data([0xFF, 0xD8, 0xFF, 0xE0])))
        XCTAssertFalse(ImageData.isImage(Data("<html>".utf8)))
        XCTAssertEqual(ImageData.urls(in: "Ready: https://a.b/c.png.\ncurl -o x 'https://a.b/d.png'").map(\.absoluteString), ["https://a.b/c.png", "https://a.b/d.png"])
    }
}
