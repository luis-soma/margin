import AppKit
import XCTest
@testable import MarginKit

final class PasteboardSnapshotTests: XCTestCase {
    func testRestoresEveryTypeAndItem() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("margin-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let first = NSPasteboardItem()
        first.setString("plain", forType: .string)
        first.setData(Data("{\\rtf1 hi}".utf8), forType: .rtf)
        let second = NSPasteboardItem()
        second.setString("https://example.com", forType: .URL)
        XCTAssertTrue(pasteboard.writeObjects([first, second]))

        let snapshot = PasteboardSnapshot(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("borrowed", forType: .string)

        snapshot.restore(to: pasteboard)
        let items = try XCTUnwrap(pasteboard.pasteboardItems)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].string(forType: .string), "plain")
        XCTAssertEqual(items[0].data(forType: .rtf), Data("{\\rtf1 hi}".utf8))
        XCTAssertEqual(items[1].string(forType: .URL), "https://example.com")
    }

    func testWaitForChange() async {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("margin-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let count = pasteboard.changeCount
        let unchanged = await pasteboard.waitForChange(from: count, timeout: 0.1)
        XCTAssertFalse(unchanged)
        let name = pasteboard.name
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            let same = NSPasteboard(name: name)
            same.clearContents()
            same.setString("x", forType: .string)
        }
        let changed = await pasteboard.waitForChange(from: count, timeout: 2)
        XCTAssertTrue(changed)
    }
}

@MainActor
final class RichTextTests: XCTestCase {
    private func pasteboard() -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("margin-test-\(UUID().uuidString)"))
        pb.clearContents()
        return pb
    }

    func testPrefersHTMLWhenNoRTFAndKeepsSourceURL() throws {
        let pb = pasteboard()
        defer { pb.releaseGlobally() }
        let item = NSPasteboardItem()
        item.setString("Bold idea", forType: .string)
        item.setData(Data("<meta charset='utf-8'><b>Bold</b> idea".utf8), forType: .html)
        item.setString("https://example.com/article", forType: RichText.chromiumSourceURL)
        pb.writeObjects([item])

        let clip = try XCTUnwrap(RichText.read(from: pb))
        XCTAssertEqual(clip.format, .html)
        XCTAssertEqual(clip.plain, "Bold idea")
        XCTAssertEqual(clip.sourceURL?.absoluteString, "https://example.com/article")
        let loaded = try XCTUnwrap(RichText.load(clip.data, format: clip.format))
        let font = loaded.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.bold) ?? false)
    }

    func testRTFWins() throws {
        let pb = pasteboard()
        defer { pb.releaseGlobally() }
        let rich = NSAttributedString(string: "Hello", attributes: [.font: NSFont.boldSystemFont(ofSize: 20)])
        let rtf = try XCTUnwrap(rich.rtf(from: NSRange(location: 0, length: rich.length), documentAttributes: [:]))
        let item = NSPasteboardItem()
        item.setData(rtf, forType: .rtf)
        item.setData(Data("<i>Hello</i>".utf8), forType: .html)
        item.setString("Hello", forType: .string)
        pb.writeObjects([item])
        XCTAssertEqual(RichText.read(from: pb)?.format, .rtf)
    }

    func testPlainOnlyAndNothing() {
        let pb = pasteboard()
        defer { pb.releaseGlobally() }
        XCTAssertNil(RichText.read(from: pb))
        pb.setString("just text", forType: .string)
        XCTAssertEqual(RichText.read(from: pb)?.format, .plain)
    }

    func testPaperKeepsDarkEditorLook() {
        let code = NSAttributedString(string: "let x = 1", attributes: [.foregroundColor: NSColor(srgbRed: 0.61, green: 0.86, blue: 1, alpha: 1)])
        XCTAssertTrue(RichText.paper(for: code).isDark)

        let page = NSMutableAttributedString(string: "Black text and a white word", attributes: [.foregroundColor: NSColor.black])
        page.addAttribute(.foregroundColor, value: NSColor.white, range: NSRange(location: 17, length: 5))
        let paper = RichText.paper(for: page)
        XCTAssertFalse(paper.isDark)
        // The white word is made readable on light paper.
        let fixed = paper.text.attribute(.foregroundColor, at: 18, effectiveRange: nil) as? NSColor
        XCTAssertLessThan(RichText.luminance(fixed!)!, 0.2)
    }

    func testPaperClampsFontSizes() {
        let huge = NSAttributedString(string: "Headline", attributes: [.font: NSFont.systemFont(ofSize: 72)])
        let font = RichText.paper(for: huge).text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertEqual(font?.pointSize, 28)
    }

    func testPreviewIsAPNGAtTwoX() throws {
        let text = NSAttributedString(string: String(repeating: "A long paragraph about a design decision. ", count: 40))
        let png = try XCTUnwrap(RichText.preview(text))
        XCTAssertTrue(ImageData.isImage(png))
        let rep = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertEqual(rep.pixelsWide, 960)
        XCTAssertEqual(rep.pixelsHigh, 600)
    }

    /// Short text is set large: it fills most of the frame instead of a corner.
    func testShortTextFillsTheFrame() {
        let text = NSAttributedString(string: "Little Things\nCapture anything, repo opens up", attributes: [.font: NSFont.systemFont(ofSize: 12)])
        let box = CGSize(width: 384, height: 222)
        let (fitted, size) = RichText.fitted(text, in: box, centered: true)
        XCTAssertLessThanOrEqual(size.height, box.height + 0.5)
        XCTAssertGreaterThan(size.height, box.height * 0.3)
        let font = fitted.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertGreaterThan(font?.pointSize ?? 0, 20)
        // Dark mode gets grey paper with light text.
        let dark = RichText.paper(for: text, dark: true)
        XCTAssertTrue(dark.isDark)
        let ink = dark.text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertGreaterThan(RichText.luminance(ink ?? .black) ?? 0, 0.6)
    }

    /// The paper fills the whole picture: every corner is paper, not empty.
    func testPreviewPaperFillsTheFrame() throws {
        let text = NSAttributedString(string: "Little Things\nHow to delete this")
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(RichText.preview(text))))
        for (x, y) in [(2, 2), (rep.pixelsWide - 3, 2), (2, rep.pixelsHigh - 3), (rep.pixelsWide - 3, rep.pixelsHigh - 3)] {
            let color = try XCTUnwrap(rep.colorAt(x: x, y: y))
            XCTAssertGreaterThan(color.alphaComponent, 0.99, "corner \(x),\(y) is empty")
        }
    }

    func testWordCount() {
        XCTAssertEqual(RichText.wordCount("one  two\nthree"), 3)
    }
}
