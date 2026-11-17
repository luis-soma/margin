import AppKit
import AVFoundation
import MarginKit
import ScreenCaptureKit
import SwiftUI

/// Team builds only: Margin films itself for the case study's hero. One
/// borderless window at the hero card's shape shows a wallpaper and
/// Margin's real views: the actual capture card (CardHost and
/// CaptureCardView) and the actual archive (RepoView), driven by a fixed
/// script so every take is the same and the end meets the start. The
/// window is recorded with ScreenCaptureKit at the screen's full
/// resolution and 60 fps.
///
/// The film changes nothing in your archive. It opens a second, read-only
/// view of it with its own scale, shows your newest capture and types the
/// note you wrote for it; nothing is saved.
///
/// The loop (about 12 s): wallpaper; the card hangs in from the top; the
/// pointer clicks into its field; the note types (the pointer hides, as it
/// does while you type); return; the card leaves the way it does; the
/// archive opens at the weeks, the capture first in line; the pointer goes
/// to it and the timeline zooms in to the day, as a pinch would; the
/// pointer goes to the window's close button and closes it; wallpaper
/// again.
@MainActor
final class FilmStudio: NSObject {
    static let shared = FilmStudio()

    /// The hero card's shape (about 1.9 to 1), in points.
    static let size = CGSize(width: 1400, height: 735)

    private var window: FilmWindow?
    private var recorder: FilmRecorder?
    private var model: FilmModel?
    private var events: [DispatchWorkItem] = []

    @objc func previewHero() { start(record: false) }
    @objc func recordHero() { start(record: true) }
    @objc func stopFilm() { finish(save: recorder != nil) }

    // MARK: Setup

    private func start(record: Bool) {
        finish(save: false)
        let real = AppModel.shared.store
        // A second view of the same archive, with its own open project,
        // so nothing you have open changes.
        let store = EntryStore(baseURL: real.baseURL, projectKey: "filmProject")
        store.isReadOnly = true
        let projects = Set(store.entries.map(\.project))
        store.currentProject = projects.contains("Margin") ? "Margin" : real.currentProject
        guard let entry = Self.heroEntry(in: store), let picture = store.thumbnail(for: entry) else {
            MarginLog.info("Film: no capture with a picture and a short note in \(store.currentProject)")
            NSSound.beep()
            return
        }
        MarginLog.info("Film: \(entry.displayTitle) (\(entry.id)), note \"\(entry.rationale)\"")
        // As a capture you just made: today, first in the archive.
        store.restage(entry.id, at: Date())

        let model = FilmModel(store: store, entry: entry, picture: picture,
                              loop: Self.loop(for: Self.keystrokes(for: entry.rationale.trimmed)))
        self.model = model
        let window = FilmWindow(size: Self.size)
        window.onEscape = { [weak self] in self?.stopFilm() }
        let root = FilmStage(model: model)
            .environmentObject(store)
            .environmentObject(AppModel.shared.intelligence)
            .environmentObject(AppModel.shared.coding)
            .environmentObject(AppModel.shared.chats)
            .environmentObject(AppModel.shared.autoCapture)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: Self.size)
        window.contentView = host
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window

        if record {
            // Give the archive a moment to lay out and read its pictures.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.beginRecording(loops: 2) }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.run(loops: 50) }
        }
    }

    /// The capture to film: the newest from Figma with a picture and a
    /// note, shown as made just now (a capture you just made is first in
    /// the archive). A defaults key picks another.
    private static func heroEntry(in store: EntryStore) -> Entry? {
        let entries = store.entries(in: store.currentProject).filter { !$0.isAutomatic }
        if let wanted = UserDefaults.standard.string(forKey: "filmEntryID").flatMap(UUID.init(uuidString:)),
           let entry = entries.first(where: { $0.id == wanted }) {
            return entry
        }
        let usable = entries.filter { $0.imageFile != nil && !$0.rationale.trimmed.isEmpty }
        return usable.first { $0.kind == .figma || $0.link.lowercased().contains("figma.com") } ?? usable.first
    }

    private func beginRecording(loops: Int) {
        guard let window else { return }
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Movies/Margin Films", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        let url = folder.appendingPathComponent("hero-\(stamp).mp4")
        let scale = window.backingScaleFactor
        let pixels = CGSize(width: Self.size.width * scale, height: Self.size.height * scale)
        let recorder = FilmRecorder()
        self.recorder = recorder
        Task { @MainActor in
            do {
                try await recorder.start(windowID: CGWindowID(window.windowNumber), pixels: pixels, to: url)
                // The script starts with the first frame on file, so the
                // recording's own clock lines up with the loop.
                MarginLog.info("Film: recording \(Int(pixels.width))×\(Int(pixels.height)) to \(url.path)")
                run(loops: loops) { [weak self] in self?.finish(save: true) }
            } catch {
                MarginLog.info("Film: couldn't record: \(error)")
                NSSound.beep()
                finish(save: false)
            }
        }
    }

    // MARK: The script

    /// When typing starts, from the top of the loop.
    static let typeStart: TimeInterval = 1.95

    /// The loop's length: the typing, then a fixed eight seconds for the
    /// archive, to the tenth of a second.
    static func loop(for keys: [TimeInterval]) -> TimeInterval {
        ((typeStart + (keys.last ?? 0) + 8.0) * 10).rounded(.up) / 10
    }

    /// Plays the loop `loops` times from now, then calls `done`.
    private func run(loops: Int, done: (() -> Void)? = nil) {
        guard let model else { return }
        let start = Date()
        model.clockStart = start
        let note = model.entry.rationale.trimmed
        let keys = Self.keystrokes(for: note)
        for loop in 0..<loops {
            let base = Double(loop) * model.loop
            at(base) { model.reset() }
            // The card hangs in from the top, as under the menu bar.
            at(base + 0.7) { model.showCard() }
            // The pointer goes to the field and clicks into it.
            at(base + 1.05) { model.moveToField() }
            at(base + 1.7) { model.click() }
            // The note, typed at a person's pace. The pointer hides on the
            // first key, as macOS hides it while you type.
            for (index, time) in keys.enumerated() {
                at(base + Self.typeStart + time) {
                    if index == 0 { model.cursorHidden = true }
                    model.typed = String(note.prefix(index + 1))
                }
            }
            let typed = Self.typeStart + (keys.last ?? 0)
            // Return: the card leaves the way it does in the app.
            at(base + typed + 0.55) { model.closeCard() }
            at(base + typed + 0.55 + 0.26) { model.card = nil }
            // The archive opens at the weeks, the capture first in line.
            at(base + typed + 0.9) { model.openArchive() }
            // The pointer goes to it; the timeline zooms in to the day.
            at(base + typed + 1.3) { model.moveToCapture() }
            at(base + typed + 2.25) { model.zoomIn() }
            // To the close button, and closed.
            at(base + typed + 4.5) { model.moveToClose() }
            at(base + typed + 5.5) { model.click() }
            at(base + typed + 5.6) { model.closeArchive() }
            // While it's gone: back to the weeks, the pointer back to rest.
            at(base + typed + 6.7) { model.zoomOut() }
            at(base + typed + 6.6) { model.moveToRest() }
        }
        at(Double(loops) * model.loop + 0.05) { done?() }
    }

    private func at(_ time: TimeInterval, _ action: @escaping @MainActor () -> Void) {
        let item = DispatchWorkItem { MainActor.assumeIsolated { action() } }
        events.append(item)
        DispatchQueue.main.asyncAfter(deadline: .now() + time, execute: item)
    }

    /// When each character lands, in seconds from the first: a steady pace
    /// with a little unevenness (the same every take), a beat after words,
    /// about 2.4 s in all.
    static func keystrokes(for text: String) -> [TimeInterval] {
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed >> 33) / Double(UInt64(1) << 31)
        }
        var times: [TimeInterval] = []
        var t = 0.0
        var previous: Character = " "
        for character in text {
            times.append(t)
            var gap = 0.045 + next() * 0.04
            if previous == " " { gap += 0.03 }
            if character == " " { gap += 0.05 }
            if ",.".contains(character) { gap += 0.12 }
            t += gap
            previous = character
        }
        let total = times.last ?? 0
        let target = min(2.6, max(1.4, Double(text.count) * 0.06))
        return total > 0 ? times.map { $0 * target / total } : times
    }

    // MARK: Ending

    private func finish(save: Bool) {
        events.forEach { $0.cancel() }
        events = []
        let recorder = self.recorder
        self.recorder = nil
        let window = self.window
        self.window = nil
        model = nil
        guard let recorder else {
            window?.orderOut(nil)
            return
        }
        Task { @MainActor in
            if save, let url = try? await recorder.stop() {
                MarginLog.info("Film: saved \(url.path)")
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else {
                recorder.cancel()
            }
            window?.orderOut(nil)
        }
    }
}

// MARK: - State

@MainActor
final class FilmModel: ObservableObject {
    enum Archive { case before, shown, leaving }
    enum Pointer { case arrow, beam }

    let store: EntryStore
    let entry: Entry
    let picture: NSImage
    /// One take, in seconds; the wallpaper's drift has the same period.
    let loop: TimeInterval
    @Published var clockStart = Date()
    @Published var card: CardStage?
    /// The card has come down from the top edge to where it rests.
    @Published var cardDown = false
    @Published var typed = ""
    @Published var archive: Archive = .before
    /// The archive's time scale: the weeks (2) to the day (0), and how long
    /// the zoom there takes.
    @Published var zoom = FilmZoom(scale: 2, duration: nil)

    /// The pointer, in the stage's points (where its tip is).
    @Published var cursor = FilmModel.rest
    @Published var pointer: Pointer = .arrow
    @Published var cursorHidden = false
    @Published var pressed = false
    /// The pointer is over the window's buttons: they show their marks.
    @Published var overLights = false

    /// Where things are, from the views themselves.
    var field: CGRect = .zero
    var target: CGRect = .zero
    var close: CGRect = .zero

    /// Where the pointer rests between takes: low and to the right, off
    /// everything.
    static let rest = CGPoint(x: 1030, y: 610)

    init(store: EntryStore, entry: Entry, picture: NSImage, loop: TimeInterval) {
        self.store = store
        self.entry = entry
        self.picture = picture
        self.loop = loop
    }

    func reset() {
        var quiet = Transaction()
        quiet.disablesAnimations = true
        withTransaction(quiet) {
            card = nil
            cardDown = false
            typed = ""
            archive = .before
            cursor = Self.rest
            pointer = .arrow
            cursorHidden = false
            pressed = false
            overLights = false
        }
    }

    /// The real card, as a fresh capture shows it: "Captured", the picture,
    /// the field for why.
    func showCard() {
        card = CardStage(.card(AnyView(FilmCard(model: self))))
        // Down from behind the frame's top edge, settling softly.
        DispatchQueue.main.async { [weak self] in
            withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.6)) { self?.cardDown = true }
        }
    }

    /// As QuickCaptureController.close: the card rises a little and fades.
    func closeCard() {
        withAnimation(.timingCurve(0.4, 0, 0.7, 0.2, duration: 0.22)) { card?.closing = true }
    }

    /// A window opening: up from a little smaller, out of a soft blur.
    func openArchive() {
        withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.55)) { archive = .shown }
    }

    /// Closed with its button: gone quickly, as a window goes.
    func closeArchive() {
        withAnimation(.timingCurve(0.4, 0, 0.6, 1, duration: 0.32)) { archive = .leaving }
    }

    /// Into the day, slowly, as a pinch on the trackpad would.
    func zoomIn() {
        zoom = FilmZoom(scale: 0, duration: 1.4)
    }

    /// Back to the weeks while nothing shows.
    func zoomOut() {
        zoom = FilmZoom(scale: 2, duration: 0.5)
    }

    // MARK: The pointer

    /// A hand on a trackpad: quick to leave, slow to land.
    private func move(to point: CGPoint, duration: TimeInterval) {
        cursorHidden = false
        withAnimation(.timingCurve(0.3, 0.05, 0.15, 1, duration: duration)) { cursor = point }
    }

    /// Into the card's field, a little way in from its start; the pointer
    /// turns to the text beam as it lands, as over any field.
    func moveToField() {
        let point = field == .zero
            ? CGPoint(x: FilmStudio.size.width / 2 - 120, y: 300 + FilmStage.cardTop)
            : CGPoint(x: field.minX + min(150, field.width * 0.4), y: field.midY)
        move(to: point, duration: 0.6)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.pointer = .beam }
    }

    /// Onto the capture, a little off its middle, as a hand would rest.
    func moveToCapture() {
        pointer = .arrow
        let point = target == .zero
            ? CGPoint(x: 400, y: 220)
            : CGPoint(x: target.midX + target.width * 0.1, y: target.midY + target.height * 0.12)
        move(to: point, duration: 0.85)
    }

    /// To the red button; its mark shows as the pointer arrives.
    func moveToClose() {
        let point = close == .zero ? CGPoint(x: 196, y: 101) : CGPoint(x: close.midX, y: close.midY)
        move(to: point, duration: 0.9)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.72) { [weak self] in
            withAnimation(.easeOut(duration: 0.12)) { self?.overLights = true }
        }
    }

    func moveToRest() {
        pointer = .arrow
        overLights = false
        move(to: Self.rest, duration: 1.3)
    }

    /// A press: the pointer dips and comes back.
    func click() {
        withAnimation(.easeOut(duration: 0.07)) { pressed = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            withAnimation(.easeOut(duration: 0.12)) { self?.pressed = false }
        }
    }
}

/// The film archive's time scale, and how long the zoom to it takes.
struct FilmZoom: Equatable {
    var scale: Int
    var duration: Double?
}

// MARK: - The stage

/// Wallpaper, the archive window in the middle, the card hanging from the
/// top, the pointer over all of it: everything the film shows, at the
/// hero's shape.
struct FilmStage: View {
    @ObservedObject var model: FilmModel

    static let archiveSize = CGSize(width: 1060, height: 620)
    /// The card's distance from the top of the frame.
    static let cardTop: CGFloat = 40
    /// The stage's own coordinates, before the camera.
    static let space = "filmStage"

    var body: some View {
        ZStack {
            FilmWallpaper(start: model.clockStart, period: model.loop)
            scene
        }
        .frame(width: FilmStudio.size.width, height: FilmStudio.size.height)
        .clipped()
        .environment(\.colorScheme, .light)
    }

    private var scene: some View {
        ZStack(alignment: .top) {
            archive
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, 36)

            if let stage = model.card {
                // Still hanging from the top, with a little air above it,
                // and dropping in from the edge so it reads as coming down.
                CardHost.film(stage)
                    .frame(width: 640, height: 520, alignment: .top)
                    .padding(.top, FilmStage.cardTop)
                    .offset(y: model.cardDown ? 0 : -(FilmStage.cardTop + 36))
                    .id(ObjectIdentifier(stage))
            }

            FilmCursor(model: model)
        }
        .frame(width: FilmStudio.size.width, height: FilmStudio.size.height)
        .coordinateSpace(name: Self.space)
        .onPreferenceChange(FilmFieldKey.self) { [model] rect in
            MainActor.assumeIsolated { if rect != .zero { model.field = rect } }
        }
        .onPreferenceChange(FilmTargetKey.self) { [model] rect in
            MainActor.assumeIsolated { if rect != .zero { model.target = rect } }
        }
        .onPreferenceChange(FilmCloseKey.self) { [model] rect in
            MainActor.assumeIsolated { if rect != .zero { model.close = rect } }
        }
    }

    private var archive: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        let state = model.archive
        return RepoView()
            .environment(\.filmTarget, model.entry.id)
            .environment(\.filmZoom, model.zoom)
            .overlay(alignment: .topLeading) {
                TrafficLightDots(marks: model.overLights, pressed: model.overLights && model.pressed)
                    .offset(x: RepoHeader.trafficLights.x, y: RepoHeader.trafficLights.y - 6)
            }
            .frame(width: Self.archiveSize.width, height: Self.archiveSize.height)
            .background(Brand.background)
            .clipShape(shape)
            // A macOS window's edge and shadow.
            .overlay(shape.strokeBorder(Color.black.opacity(0.18), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.22), radius: 1, x: 0, y: 0.5)
            .shadow(color: .black.opacity(0.32), radius: 28, x: 0, y: 18)
            .scaleEffect(state == .before ? 0.94 : state == .leaving ? 0.99 : 1)
            .blur(radius: state == .before ? 8 : 0)
            .opacity(state == .shown ? 1 : 0)
            .allowsHitTesting(false)
    }
}

/// The pointer, drawn from macOS's own arrow and text beam (a window
/// recording leaves the real one out). Its tip sits on `model.cursor`.
private struct FilmCursor: View {
    @ObservedObject var model: FilmModel

    var body: some View {
        let cursor: NSCursor = model.pointer == .beam ? .iBeam : .arrow
        let image = cursor.image
        let size = image.size
        let hot = cursor.hotSpot
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .frame(width: size.width, height: size.height)
            .scaleEffect(model.pressed ? 0.86 : 1, anchor: UnitPoint(x: hot.x / max(size.width, 1), y: hot.y / max(size.height, 1)))
            .position(x: model.cursor.x - hot.x + size.width / 2, y: model.cursor.y - hot.y + size.height / 2)
            .opacity(model.cursorHidden ? 0 : 1)
            .frame(width: FilmStudio.size.width, height: FilmStudio.size.height)
            .allowsHitTesting(false)
    }
}

/// The window's three buttons, as an active window shows them. With the
/// pointer over them they show their marks; the red one darkens pressed.
private struct TrafficLightDots: View {
    var marks = false
    var pressed = false

    private static let colors = [Color(red: 1, green: 0.373, blue: 0.341), Color(red: 0.996, green: 0.737, blue: 0.18),
                                 Color(red: 0.157, green: 0.784, blue: 0.251)]
    private static let symbols = ["xmark", "minus", "plus"]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Self.colors[index])
                    .overlay(Circle().fill(Color.black.opacity(index == 0 && pressed ? 0.22 : 0)))
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5))
                    .overlay(
                        Image(systemName: Self.symbols[index])
                            .font(.system(size: 6.5, weight: .heavy))
                            .foregroundStyle(Color.black.opacity(0.5))
                            .opacity(marks ? 1 : 0)
                    )
                    .frame(width: 12, height: 12)
                    .background {
                        if index == 0 {
                            GeometryReader { geo in
                                Color.clear.preference(key: FilmCloseKey.self, value: geo.frame(in: .named(FilmStage.space)))
                            }
                        }
                    }
            }
        }
    }
}

/// The wallpaper, drifting very slowly on a cycle exactly one loop long,
/// so the last frame meets the first.
struct FilmWallpaper: View {
    let start: Date
    let period: TimeInterval

    private static let image: NSImage? = Bundle.main.url(forResource: "Film/hero-wallpaper", withExtension: "jpg")
        .flatMap(NSImage.init(contentsOf:))

    var body: some View {
        TimelineView(.animation) { timeline in
            let t: Double = timeline.date.timeIntervalSince(start)
            let phase: Double = (t / period).truncatingRemainder(dividingBy: 1) * 2 * .pi
            ZStack {
                Color(white: 0.12)
                if let image = Self.image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                        .scaleEffect(1.08 + 0.02 * cos(phase))
                        .offset(x: 18 * sin(phase), y: 8 * sin(2 * phase))
                }
            }
        }
        .frame(width: FilmStudio.size.width, height: FilmStudio.size.height)
        .clipped()
    }
}

// MARK: - Window

final class FilmWindow: NSWindow {
    var onEscape: (() -> Void)?

    init(size: CGSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        hasShadow = false
        isOpaque = true
        backgroundColor = .black
        level = .floating
        appearance = NSAppearance(named: .aqua)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

// MARK: - Recording

/// Records one window, without its shadow, at `pixels` and 60 fps.
final class FilmRecorder: NSObject, SCStreamOutput {
    private let queue = DispatchQueue(label: "margin.film")
    private var stream: SCStream?
    private var writer: VideoWriter?

    func start(windowID: CGWindowID, pixels: CGSize, to url: URL) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw ScreenRecorder.RecorderError.noDisplay
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = Int(pixels.width)
        config.height = Int(pixels.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.queueDepth = 8
        if #available(macOS 14.0, *) {
            config.ignoreShadowsSingleWindow = true
            config.shouldBeOpaque = true
            config.captureResolution = .best
        }
        let writer = try VideoWriter(url: url, width: Int(pixels.width), height: Int(pixels.height),
                                     frameRate: 60, bitRate: 60_000_000)
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        queue.sync { self.writer = writer }
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async throws -> URL {
        let stream = self.stream
        self.stream = nil
        try? await stream?.stopCapture()
        let end = CMClockGetTime(CMClockGetHostTimeClock())
        let writer: VideoWriter? = queue.sync {
            let current = self.writer
            self.writer = nil
            return current
        }
        guard let writer, await writer.finish(at: end), writer.frameCount > 0 else {
            throw ScreenRecorder.RecorderError.nothingRecorded
        }
        return writer.url
    }

    func cancel() {
        let stream = self.stream
        self.stream = nil
        Task { try? await stream?.stopCapture() }
        queue.async {
            self.writer?.cancel()
            self.writer = nil
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete else { return }
        writer?.append(sampleBuffer)
    }
}

/// The capture card with the film's typing: watches the model so each
/// keystroke shows, as typing in the field would.
private struct FilmCard: View {
    @ObservedObject var model: FilmModel

    var body: some View {
        CaptureCardView.film(store: model.store, entryID: model.entry.id, image: model.picture, text: $model.typed)
    }
}

private struct FilmFocusKey: EnvironmentKey {
    static let defaultValue: UUID? = nil
}

extension EnvironmentValues {
    /// The capture the film studio outlines in the timeline.
    var filmFocus: UUID? {
        get { self[FilmFocusKey.self] }
        set { self[FilmFocusKey.self] = newValue }
    }
}


extension EnvironmentValues {
    /// The capture whose place the film studio's pointer needs.
    var filmTarget: UUID? {
        get { self[FilmTargetEnvKey.self] }
        set { self[FilmTargetEnvKey.self] = newValue }
    }

    /// Team builds: the film studio's archive scale. Set, the archive keeps
    /// its own scale and zooms to this one.
    var filmZoom: FilmZoom? {
        get { self[FilmZoomKey.self] }
        set { self[FilmZoomKey.self] = newValue }
    }
}

private struct FilmTargetEnvKey: EnvironmentKey {
    static let defaultValue: UUID? = nil
}

private struct FilmZoomKey: EnvironmentKey {
    static let defaultValue: FilmZoom? = nil
}

/// Where the film's capture is in the stage, reported by the timeline.
struct FilmTargetKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

/// Where the card's field is in the stage, reported by the card.
struct FilmFieldKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

/// Where the window's close button is in the stage.
struct FilmCloseKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}
