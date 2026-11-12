import AppKit
import SwiftUI
import XCTest
import MarginKit
@testable import Margin

@MainActor
final class RepoHeaderTests: XCTestCase {
    var base: URL!
    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("margin-header-\(UUID().uuidString)")
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: base) }

    /// A tag, a tab, Margin's topic or typed words narrow the repo.
    func testFiltersMatchTabsTopicsTagsAndWords() {
        let store = EntryStore(baseURL: base)
        var tabbed = store.newEntry(.figma)
        tabbed.tab = "Deck"
        tabbed.ai = CaptureNote(seen: "Title slide with the Umbrella name", tags: ["slide", "title"], topic: "Deck")
        var suggested = store.newEntry(.figma)
        suggested.ai = CaptureNote(seen: "Banner over a chat reply", tags: ["banner", "chat"], topic: "Filter overlay")
        suggested.rationale = "slimmer so it reads as a hint"
        let confirmed: Set<String> = ["Deck"]

        XCTAssertTrue(RepoView.matches(tabbed, filter: "deck", confirmed: confirmed))
        XCTAssertFalse(RepoView.matches(suggested, filter: "Deck", confirmed: confirmed))
        XCTAssertTrue(RepoView.matches(suggested, filter: "Filter overlay", confirmed: confirmed))
        XCTAssertTrue(RepoView.matches(suggested, filter: "Banner", confirmed: confirmed))
        XCTAssertFalse(RepoView.matches(tabbed, filter: "banner", confirmed: confirmed))

        XCTAssertTrue(RepoView.matches(suggested, query: "chat hint"))
        XCTAssertFalse(RepoView.matches(suggested, query: "chat slide"))
        XCTAssertTrue(RepoView.matches(tabbed, query: "  "))
    }

    /// The header and the open field, menu and tokens render; long tag lists wrap.
    func testHeaderPiecesRender() {
        let options = FilterOptions(
            tabs: ["Research", "Deck", "Filter overlay"],
            suggested: [(name: "Escalating popups", count: 4)],
            tags: (0..<14).map { (name: "tag\($0)", count: $0 + 1) }
        )
        for view in [
            AnyView(RepoSearch(query: .constant(""), filters: .constant([]), open: .constant(false), menuOpen: .constant(false), submit: {})),
            AnyView(RepoSearch(query: .constant("ban"), filters: .constant(["Deck"]), open: .constant(true), menuOpen: .constant(true), submit: {})),
            AnyView(FilterMenu(query: "", filters: [], options: options, pick: { _ in }, accept: { _ in }, dismiss: { _ in })),
            AnyView(FilterMenu(query: "zzz", filters: [], options: options, pick: { _ in }, accept: { _ in }, dismiss: { _ in })),
        ] {
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
            host.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(host.fittingSize.height, 0)
        }
        // The menu keeps its width and grows down as tags wrap.
        let menu = NSHostingView(rootView: FilterMenu(query: "", filters: [], options: options, pick: { _ in }, accept: { _ in }, dismiss: { _ in }))
        XCTAssertEqual(menu.fittingSize.width, 300, accuracy: 1)
        XCTAssertGreaterThan(menu.fittingSize.height, 120)
    }

    /// In the real window: the traffic lights sit where the design puts them,
    /// stay there after a resize, and clicks on the header reach the header
    /// (not the title bar), even in the band the title bar used to own.
    func testTrafficLightsAndHeaderClicksInTheWindow() throws {
        let store = EntryStore(baseURL: base)
        let manager = WindowManager()
        let id = "repo-test-\(UUID().uuidString)"
        manager.show(id: id, title: "Margin", size: NSSize(width: 1080, height: 760), chromeless: true, trafficLights: RepoHeader.trafficLights) {
            RepoView()
                .environmentObject(store)
                .environmentObject(Intelligence(store: store, config: AIConfig()))
        }
        let window = try XCTUnwrap(manager.window(id: id))
        defer { window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))

        func checkLights(_ when: String) throws {
            let close = try XCTUnwrap(window.standardWindowButton(.closeButton))
            let rect = close.convert(close.bounds, to: nil)
            let fromTop = window.frame.height - rect.midY
            XCTAssertEqual(rect.minX, RepoHeader.trafficLights.x, accuracy: 1.5, "close button x \(when)")
            XCTAssertEqual(fromTop, RepoHeader.trafficLights.y, accuracy: 1.5, "close button center from top \(when)")
            let zoom = try XCTUnwrap(window.standardWindowButton(.zoomButton))
            XCTAssertGreaterThan(zoom.convert(zoom.bounds, to: nil).minX, rect.maxX, "buttons stay in order \(when)")
        }
        try checkLights("at open")

        window.setContentSize(NSSize(width: 1240, height: 820))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        try checkLights("after a resize")

        // Clicks in the header row land in the SwiftUI content.
        let content = try XCTUnwrap(window.contentView)
        let frameView = try XCTUnwrap(content.superview)
        for (x, what) in [(CGFloat(120), "project name"), (window.frame.width / 2, "slider"), (window.frame.width - 30, "search")] {
            let fromTop = RepoHeader.trafficLights.y
            let point = NSPoint(x: x, y: frameView.isFlipped ? fromTop : frameView.bounds.height - fromTop)
            let hit = frameView.hitTest(point)
            XCTAssertNotNil(hit, what)
            XCTAssertTrue(hit?.isDescendant(of: content) == true, "\(what) click went to \(hit.map { String(describing: type(of: $0)) } ?? "nothing")")
        }
        // The close button itself still takes its click.
        let close = try XCTUnwrap(window.standardWindowButton(.closeButton))
        let center = close.convert(NSPoint(x: close.bounds.midX, y: close.bounds.midY), to: frameView)
        XCTAssertTrue(frameView.hitTest(center).map { $0 === close || $0.isDescendant(of: close) } == true)
    }

    /// A press on the slider's drag surface goes to the slider, even in the
    /// title bar row of a chromeless window; elsewhere the window behaves normally.
    func testDragSurfaceTakesPressesBeforeTheTitleBar() {
        var xs: [CGFloat] = []
        var ended = 0
        // Edge to edge, like the repo: the header row sits under the title bar.
        let view = VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: 100)
                DragSurface(changed: { xs.append($0) }, ended: { ended += 1 })
                    .frame(width: 200, height: 30)
                Spacer()
            }
            .frame(height: 48)
            Spacer()
        }
        .ignoresSafeArea()
        let window = MarginWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                                  styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.contentViewController = NSHostingController(rootView: view)
        window.setContentSize(NSSize(width: 600, height: 400))
        window.orderFrontRegardless()
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let start = window.frame.origin

        // Window coordinates have y going up: the header is the top 48 pt.
        func send(_ type: NSEvent.EventType, x: CGFloat, y: CGFloat = 376) {
            let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: y), modifierFlags: [], timestamp: 0,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            window.sendEvent(event)
        }
        send(.leftMouseDown, x: 150)
        send(.leftMouseDragged, x: 220)
        send(.leftMouseUp, x: 220)

        XCTAssertEqual(xs.count, 2, "press and drag reach the surface")
        XCTAssertEqual(xs.first ?? 0, 50, accuracy: 1)
        XCTAssertEqual(xs.last ?? 0, 120, accuracy: 1)
        XCTAssertEqual(ended, 1)
        XCTAssertEqual(window.frame.origin, start, "the window didn't move")

        // A press outside the surface isn't taken.
        send(.leftMouseDown, x: 450)
        send(.leftMouseUp, x: 450)
        XCTAssertEqual(xs.count, 2)
        window.close()
    }

    /// With a drag zone the window only moves from that corner: it isn't
    /// movable from the title bar or the background.
    func testDragZoneLocksTheRestOfTheWindow() {
        let window = MarginWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                                  styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        XCTAssertTrue(window.isMovable)
        window.dragZone = CGRect(x: 0, y: 0, width: 96, height: 48)
        XCTAssertFalse(window.isMovable)
        XCTAssertFalse(window.isMovableByWindowBackground)
        window.dragZone = nil
        XCTAssertTrue(window.isMovable)
        window.close()
    }
}
