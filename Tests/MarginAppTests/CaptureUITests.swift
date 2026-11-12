import AppKit
import AVFoundation
import SwiftUI
import XCTest
import MarginKit
@testable import Margin

/// Exercises the capture UI headlessly on the CI Mac: the overlay's
/// geometry and keys, the screenshot and recording paths (skipped when the
/// runner has no Screen Recording access), and the moment and settings views.
@MainActor
final class CaptureUITests: XCTestCase {
    override func setUp() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        guard !NSScreen.screens.isEmpty else { throw XCTSkip("no screens") }
    }

    func testOverlayDragBecomesATopLeftArea() throws {
        let overlay = RegionOverlay()
        var result: RegionOverlay.Result?
        var finished = false
        overlay.begin(mode: .image, hint: "Figma export isn't set up.") {
            result = $0
            finished = true
        }
        XCTAssertTrue(overlay.isShowing)
        overlay.redrawNow()

        let screen = NSScreen.screens[0].frame
        let start = CGPoint(x: screen.minX + 100, y: screen.minY + 100)
        overlay.mouseDown(at: start)
        overlay.mouseDragged(to: CGPoint(x: start.x + 200, y: start.y + 150))
        XCTAssertEqual(overlay.dragRect?.size, CGSize(width: 200, height: 150))
        overlay.redrawNow()
        overlay.mouseUp(at: CGPoint(x: start.x + 200, y: start.y + 150))

        XCTAssertTrue(finished)
        XCTAssertFalse(overlay.isShowing)
        guard case .area(let rect)? = result?.selection else { return XCTFail("expected an area, got \(String(describing: result))") }
        XCTAssertEqual(rect, CGRect(x: screen.minX + 100, y: screen.height - 250, width: 200, height: 150))
        XCTAssertEqual(result?.mode, .image)
    }

    func testTabSwitchesToRecordingAndEscCancels() {
        let overlay = RegionOverlay()
        var results: [RegionOverlay.Result?] = []
        overlay.begin(mode: .image, hint: nil) { results.append($0) }
        XCTAssertTrue(overlay.handleKey(48))
        XCTAssertEqual(overlay.state.mode, .recording)
        XCTAssertTrue(overlay.handleKey(53))
        XCTAssertFalse(overlay.isShowing)
        XCTAssertEqual(results.count, 1)
        XCTAssertNil(results[0] ?? nil)
    }

    func testClickWithoutDragTakesAWindowOrTheScreen() {
        let overlay = RegionOverlay()
        var result: RegionOverlay.Result?
        overlay.begin(mode: .image, hint: nil) { result = $0 }
        let screen = NSScreen.screens[0].frame
        let point = CGPoint(x: screen.midX, y: screen.midY)
        overlay.mouseDown(at: point)
        overlay.mouseUp(at: point)
        switch result?.selection {
        case .window(_, let frame)?: XCTAssertGreaterThan(frame.width, 40)
        case .area(let rect)?: XCTAssertEqual(rect.size, screen.size)
        case nil: XCTFail("a click should select something")
        }
    }

    func testScreenshotOfAnArea() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("margin-shot-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let ok = await ScreenCapture.captureArea(CGRect(x: 10, y: 40, width: 120, height: 80), to: url)
        guard ok else { throw XCTSkip("screencapture couldn't capture here (no Screen Recording access)") }
        let image = try XCTUnwrap(NSImage(contentsOf: url))
        let rep = try XCTUnwrap(image.representations.first)
        // Points times the screen's scale.
        XCTAssertEqual(Double(rep.pixelsWide) / Double(rep.pixelsHigh), 1.5, accuracy: 0.05)
    }

    func testRecordingAnArea() async throws {
        let recorder = ScreenRecorder()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("margin-rec-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try await recorder.start(area: CGRect(x: 0, y: 0, width: 320, height: 200), to: url)
        } catch {
            throw XCTSkip("ScreenCaptureKit unavailable here: \(error)")
        }
        // Something on screen should change: show and move a window.
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 120), styleMask: [.borderless], backing: .buffered, defer: false)
        window.backgroundColor = .systemRed
        window.orderFrontRegardless()
        for step in 0..<15 {
            window.setFrameOrigin(CGPoint(x: CGFloat(step * 8), y: NSScreen.screens[0].frame.height - 200))
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        window.orderOut(nil)
        let saved = try await recorder.stop()
        let measured = await VideoTools.duration(of: saved)
        let duration = try XCTUnwrap(measured)
        XCTAssertGreaterThan(duration, 1.0)
        let poster = await VideoTools.poster(for: saved)
        XCTAssertNotNil(poster)
    }

    func testMomentAndSettingsViewsRender() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("margin-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = EntryStore(baseURL: base)

        // A text capture with its rich text and paper preview.
        let html = Data("<h1>Onboarding tone</h1><p>Calm, <b>direct</b>, no hype.</p>".utf8)
        var text = store.newEntry(.text)
        text.mediaFile = store.saveFile(html, ext: "html")
        text.body = "Onboarding tone\nCalm, direct, no hype."
        text.label = "Onboarding tone"
        let attributed = try XCTUnwrap(RichText.load(html, format: .html))
        text.imageFile = RichText.preview(attributed).flatMap { store.saveFile($0, ext: "png") }
        store.add(text)
        XCTAssertNotNil(store.thumbnail(for: text))

        var figma = store.newEntry(.figma)
        figma.link = "https://www.figma.com/design/abcdefghij1234567890AB/File?node-id=1-2"
        figma.label = "Home"
        figma.imageFile = text.imageFile
        store.add(figma)

        var iteration = store.newEntry(.iteration)
        iteration.prompt = "Make the cards denser"
        iteration.expectation = "Three columns"
        iteration.verdict = "notQuite"
        iteration.summary = "Changed the grid to three columns."
        iteration.diffStat = "2 files · +12 −4"
        iteration.imageFile = text.imageFile
        store.add(iteration)

        var website = store.newEntry(.link)
        website.link = "https://arc.net/"
        website.label = "Arc from The Browser Company"
        website.imageFile = text.imageFile
        store.add(website)
        XCTAssertEqual(website.displayTitle, "Arc from The Browser Company")

        var multi = store.newEntry(.figma)
        multi.imageFile = text.imageFile
        multi.frames = [
            FrameRef(imageFile: text.imageFile, name: "desktop", nodeID: "139:218", link: "https://www.figma.com/design/abcdefghij1234567890AB/F?node-id=139-218"),
            FrameRef(imageFile: text.imageFile, name: "mobile", nodeID: "139:2"),
            FrameRef(imageFile: text.imageFile, name: "tablet", nodeID: "139:3"),
        ]
        store.add(multi)
        XCTAssertEqual(multi.frameCount, 3)

        // Margin's notes and a suggested tab render next to the designer's words.
        for id in [figma.id, multi.id] {
            store.modify(id) { $0.ai = CaptureNote(seen: "Chat reply with a slim filter banner above it", changed: "Border removed; banner moved above the reply", tags: ["chat", "banner"], topic: "Filter overlay", sameThingAsBefore: 0.9, changeSize: 2.4) }
        }
        store.modify(website.id) { $0.tab = "References" }

        let coding = CodingSessions(store: store, cards: QuickCaptureController())
        for entry in [text, figma, iteration, website, multi] {
            render(MomentView(entryID: entry.id).environmentObject(store).environmentObject(coding).environmentObject(Intelligence(store: store, config: AIConfig())))
        }
        render(SettingsView().environmentObject(coding).environmentObject(ChatSessions(store: store, coding: coding)).environmentObject(Intelligence(store: store, config: AIConfig())).environmentObject(AutoCapture(store: store, context: AppContextTracker())))
        render(RepoView().environmentObject(store).environmentObject(Intelligence(store: store, config: AIConfig())))

        // The opened view shows Margin's topic and tags, wrapping when narrow; loading is a thinking pill.
        let tagged = CaptureNote(seen: "A banner over a chat reply", tags: ["banner", "chat", "tooltip", "warning"], topic: "Filter overlay")
        render(MarginSaw(note: tagged, showsTags: true).frame(width: 160))
        render(MarginNote(entry: store.entry(id: figma.id)!).environmentObject(Intelligence(store: store, config: AIConfig())).frame(width: 300))
        render(ThinkingPill(text: "Looking"))
    }

    /// The capture card and its loading pill render, and even the fullest
    /// card fits the panel it hangs from (nothing clipped).
    func testCaptureCardRendersAndFits() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("margin-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = EntryStore(baseURL: base)
        let image = NSImage(size: NSSize(width: 640, height: 400), flipped: false) { rect in
            NSColor.systemTeal.setFill(); rect.fill(); return true
        }
        var multi = store.newEntry(.figma)
        multi.frames = [FrameRef(imageFile: nil, name: "a", nodeID: "1:1"), FrameRef(imageFile: nil, name: "b", nodeID: "1:2"), FrameRef(imageFile: nil, name: "c", nodeID: "1:3")]
        store.add(multi)

        let fullest = CaptureCardView(
            store: store, entryID: multi.id, image: image, status: "Saved",
            prompt: "Claude finished. How did it go? This prompt is long on purpose so it wraps onto a second line.",
            detail: "Couldn't export from Figma: the Margin plugin isn't running in this file. Start it from Plugins, Development, Margin.",
            quote: "Rewrite the reply in a neutral tone and keep the indicator visible while the filter runs.",
            beforeImage: nil,
            choices: [("keep", "Keep"), ("notQuite", "Not quite"), ("deadEnd", "Dead end")],
            onChoice: { _, _ in }, onSave: { _ in }, onDismiss: {}
        )
        let host = NSHostingView(rootView: fullest)
        let size = host.fittingSize
        XCTAssertEqual(size.width, QuickCaptureController.cardWidth, accuracy: 1)
        XCTAssertLessThan(size.height, 520 - 12, "the fullest card must fit its panel")

        let beforeAfter = CaptureCardView(store: store, entryID: nil, image: image, status: nil, prompt: "Why this?", detail: nil, beforeImage: image, onSave: { _ in }, onDismiss: {})
        render(CardHost(stage: CardStage(.loading("Exporting from Figma…"))))
        render(CardHost(stage: CardStage(.card(AnyView(fullest)))))
        render(CardHost(stage: CardStage(.card(AnyView(beforeAfter)))))
    }

    private func render<V: View>(_ view: V, file: StaticString = #filePath, line: UInt = #line) {
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            return XCTFail("couldn't render", file: file, line: line)
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        XCTAssertGreaterThan(rep.pixelsWide, 0, file: file, line: line)
    }
}

@MainActor
final class ImagePreviewTests: XCTestCase {
    /// Clicking a card picture opens it large; stepping wraps through frames;
    /// closing removes it and gives the keyboard back.
    func testPreviewOpensPagesAndCloses() async throws {
        guard !NSScreen.screens.isEmpty else { throw XCTSkip("no screen") }
        let image = NSImage(size: NSSize(width: 80, height: 40))
        image.lockFocus(); NSColor.systemBlue.setFill(); NSRect(x: 0, y: 0, width: 80, height: 40).fill(); image.unlockFocus()
        let preview = ImagePreview.shared
        preview.show([image, image, image], at: 2, on: NSScreen.screens[0])
        XCTAssertTrue(preview.isOpen)
        XCTAssertEqual(preview.index, 2)
        preview.step(1)
        XCTAssertEqual(preview.index, 0)
        preview.step(-1)
        XCTAssertEqual(preview.index, 2)
        preview.close()
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertFalse(preview.isOpen)

        // With a note: closing hands the text back to the card.
        var handedBack: String?
        preview.show([image], note: "Removed", onNote: { handedBack = $0 }, onSubmit: { _ in XCTFail("not submitted") })
        XCTAssertTrue(preview.takesNote)
        preview.note = "Removed the border"
        preview.close()
        XCTAssertEqual(handedBack, "Removed the border")
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertFalse(preview.isOpen)
        XCTAssertFalse(preview.takesNote)
    }
}
