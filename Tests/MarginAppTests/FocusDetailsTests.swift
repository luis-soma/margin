import XCTest
@testable import Margin

final class FocusDetailsTests: XCTestCase {
    /// Minutes within the hour, hours within the day, days within the week,
    /// then the date itself.
    func testCaptureTimeReadsLikeYouWouldSayIt() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 18))!
        func ago(_ seconds: TimeInterval) -> String { FocusView.captured(now.addingTimeInterval(-seconds), now: now, calendar: calendar) }
        XCTAssertEqual(ago(20), "Just now")
        XCTAssertEqual(ago(60), "1 minute ago")
        XCTAssertEqual(ago(25 * 60), "25 minutes ago")
        XCTAssertEqual(ago(3600), "1 hour ago")
        XCTAssertEqual(ago(5 * 3600), "5 hours ago")
        XCTAssertEqual(ago(26 * 3600), "Yesterday")
        XCTAssertEqual(ago(3 * 86_400), "3 days ago")
        XCTAssertFalse(ago(30 * 86_400).contains("ago"))
        XCTAssertTrue(ago(30 * 86_400).contains("18") || ago(30 * 86_400).contains("Sep"))
    }

    func testLinksDropTheSchemeAndWWW() {
        XCTAssertEqual(FocusView.shortLink(URL(string: "https://www.figma.com/design/abc")!), "figma.com/design/abc")
        XCTAssertEqual(FocusView.shortLink(URL(string: "https://are.na/")!), "are.na")
    }
}

extension FocusDetailsTests {
    /// Figma links to the frame; a captured link is its own source; otherwise the app.
    func testSourceSaysWhereItCameFrom() {
        var figma = Entry(kind: .figma, project: "T")
        figma.link = "https://www.figma.com/design/abc?node-id=1-2"
        figma.sourceApp = "Figma"
        XCTAssertEqual(FocusView.source(of: figma)?.name, "Figma")
        XCTAssertNotNil(FocusView.source(of: figma)?.link)

        var page = Entry(kind: .link, project: "T")
        page.link = "https://www.are.na/block/29243586"
        page.sourceApp = "Arc"
        XCTAssertEqual(FocusView.source(of: page)?.name, "are.na/block/29243586")

        var note = Entry(kind: .capture, project: "T")
        note.sourceApp = "Notes"
        XCTAssertEqual(FocusView.source(of: note)?.name, "Notes")
        XCTAssertNil(FocusView.source(of: note)?.link)
    }
}

extension FocusDetailsTests {
    /// A Claude capture opens its conversation in the Claude app.
    func testClaudeLinksOpenInTheApp() {
        var shot = Entry(kind: .capture, project: "T")
        shot.sourceApp = "Claude"
        shot.link = "https://claude.ai/epitaxy/local_45abc?artifact=69e"
        let source = FocusView.source(of: shot)
        XCTAssertEqual(source?.name, "Claude")
        XCTAssertEqual(source?.link?.absoluteString, "claude://claude.ai/epitaxy/local_45abc?artifact=69e")
    }
}
