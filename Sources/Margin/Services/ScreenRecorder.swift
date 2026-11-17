import AppKit
import CoreMedia
import MarginKit
import ScreenCaptureKit
import SwiftUI

/// Records an area of the screen to an .mp4 with ScreenCaptureKit. Margin's
/// own windows (the frame and the stop button) are left out of the video.
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    enum RecorderError: Error, CustomStringConvertible {
        case noDisplay
        case nothingRecorded
        var description: String {
            switch self {
            case .noDisplay: return "no display under that area"
            case .nothingRecorded: return "no frames were recorded"
            }
        }
    }

    private let queue = DispatchQueue(label: "margin.recorder")
    private var stream: SCStream?
    private var writer: VideoWriter?
    private(set) var startedAt: Date?
    // For the export studio, out of sight: the same area without the
    // cursor, and where the cursor went and clicked.
    private var studioStream: SCStream?
    private var studioWriter: VideoWriter?
    private var studioSink: FrameSink?
    private var pointer: PointerRecorder?
    private var areaSize: CGSize = .zero
    /// Called on the main queue if the stream stops on its own (e.g. display gone).
    var onUnexpectedStop: ((Error) -> Void)?

    var isRecording: Bool { stream != nil }

    /// - Parameter area: Core Graphics global coordinates (top-left origin), in points.
    func start(area: CGRect, to url: URL) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let center = CGPoint(x: area.midX, y: area.midY)
        guard let display = content.displays.first(where: { CGDisplayBounds($0.displayID).contains(center) }) ?? content.displays.first else {
            throw RecorderError.noDisplay
        }
        let bounds = CGDisplayBounds(display.displayID)
        let local = area.intersection(bounds).offsetBy(dx: -bounds.minX, dy: -bounds.minY)
        let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])

        let scale = await MainActor.run { Self.scale(of: display.displayID) }
        let size = RegionMath.videoSize(for: local.size, scale: scale)
        let config = SCStreamConfiguration()
        config.sourceRect = local
        config.width = size.width
        config.height = size.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        config.queueDepth = 6

        let writer = try VideoWriter(url: url, width: size.width, height: size.height)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        queue.sync { self.writer = writer }
        try await stream.startCapture()
        self.stream = stream
        startedAt = Date()
        await startStudio(filter: filter, config: config, size: size, area: local.offsetBy(dx: bounds.minX, dy: bounds.minY), url: url)
        MarginLog.info("Recording \(Int(local.width))×\(Int(local.height)) pt at \(size.width)×\(size.height) px")
    }

    /// The cursorless copy and the pointer's path. If any of it fails, the
    /// recording itself goes on as before.
    private func startStudio(filter: SCContentFilter, config: SCStreamConfiguration, size: (width: Int, height: Int), area: CGRect, url: URL) async {
        areaSize = area.size
        pointer = await MainActor.run { PointerRecorder(area: area) }
        let clean = SCStreamConfiguration()
        clean.sourceRect = config.sourceRect
        clean.width = config.width
        clean.height = config.height
        clean.minimumFrameInterval = config.minimumFrameInterval
        clean.pixelFormat = config.pixelFormat
        clean.showsCursor = false
        clean.queueDepth = config.queueDepth
        do {
            let writer = try VideoWriter(url: CursorTrack.studioVideo(for: url), width: size.width, height: size.height)
            let sink = FrameSink { [weak self] sample in self?.studioWriter?.append(sample) }
            let stream = SCStream(filter: filter, configuration: clean, delegate: nil)
            try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: queue)
            queue.sync {
                self.studioWriter = writer
                self.studioSink = sink
            }
            try await stream.startCapture()
            studioStream = stream
        } catch {
            MarginLog.info("Studio copy not recorded: \(error)")
            queue.sync {
                self.studioWriter?.cancel()
                self.studioWriter = nil
            }
        }
    }

    /// Stops and returns the finished file.
    func stop() async throws -> URL {
        let stream = self.stream
        self.stream = nil
        startedAt = nil
        let studio = studioStream
        studioStream = nil
        let pointer = self.pointer
        self.pointer = nil
        try? await stream?.stopCapture()
        try? await studio?.stopCapture()
        let path = await MainActor.run { pointer?.finish() }
        let end = CMClockGetTime(CMClockGetHostTimeClock())
        let writer: VideoWriter? = queue.sync {
            let current = self.writer
            self.writer = nil
            return current
        }
        guard let writer else { throw RecorderError.nothingRecorded }
        guard await writer.finish(at: end), writer.frameCount > 0 else {
            writer.cancel()
            throw RecorderError.nothingRecorded
        }
        MarginLog.info("Recording saved: \(writer.frameCount) frames")
        await finishStudio(path: path, main: writer, end: end)
        return writer.url
    }

    private func finishStudio(path: (moves: [CursorTrack.Point], clicks: [CursorTrack.Point])?, main: VideoWriter, end: CMTime) async {
        let studio: VideoWriter? = queue.sync {
            let current = self.studioWriter
            self.studioWriter = nil
            self.studioSink = nil
            return current
        }
        var starts = ["main": main.startTime.seconds]
        if let studio {
            if await studio.finish(at: end), studio.frameCount > 0 {
                starts["studio"] = studio.startTime.seconds
            } else {
                studio.cancel()
            }
        }
        guard let path, !path.moves.isEmpty else { return }
        CursorTrack(areaWidth: Double(areaSize.width), areaHeight: Double(areaSize.height),
                    moves: path.moves, clicks: path.clicks, starts: starts).save(for: main.url)
    }

    func cancel() {
        let stream = self.stream
        self.stream = nil
        startedAt = nil
        let studio = studioStream
        studioStream = nil
        let pointer = self.pointer
        self.pointer = nil
        Task {
            try? await stream?.stopCapture()
            try? await studio?.stopCapture()
        }
        DispatchQueue.main.async { _ = pointer?.finish() }
        queue.async {
            self.writer?.cancel()
            self.writer = nil
            self.studioWriter?.cancel()
            self.studioWriter = nil
            self.studioSink = nil
        }
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete else { return }
        writer?.append(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        MarginLog.info("Recording stopped by the system: \(error)")
        DispatchQueue.main.async { self.onUnexpectedStop?(error) }
    }

    @MainActor
    private static func scale(of displayID: CGDirectDisplayID) -> CGFloat {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return NSScreen.screens.first { ($0.deviceDescription[key] as? NSNumber)?.uint32Value == displayID }?.backingScaleFactor ?? 2
    }
}

/// Hands a stream's frames to a closure: the studio copy's own output.
private final class FrameSink: NSObject, SCStreamOutput {
    let handle: (CMSampleBuffer) -> Void
    init(_ handle: @escaping (CMSampleBuffer) -> Void) { self.handle = handle }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete else { return }
        handle(sampleBuffer)
    }
}

/// Where the pointer is, 60 times a second, and where it clicks, across the
/// recorded area. Lives on the main thread.
final class PointerRecorder {
    /// The recorded area, global, top-left origin, in points.
    private let area: CGRect
    private var moves: [CursorTrack.Point] = []
    private var clicks: [CursorTrack.Point] = []
    private var timer: Timer?
    private var monitors: [Any] = []

    init(area: CGRect) {
        self.area = area
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.sample() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        sample()
        let kinds: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: kinds, handler: { [weak self] _ in self?.click() }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: kinds, handler: { [weak self] event in
            self?.click()
            return event
        }) {
            monitors.append(local)
        }
    }

    /// Stops listening; the path so far.
    func finish() -> (moves: [CursorTrack.Point], clicks: [CursorTrack.Point]) {
        timer?.invalidate()
        timer = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        return (moves, clicks)
    }

    private func point() -> CursorTrack.Point {
        let location = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let x = (location.x - area.minX) / max(area.width, 1)
        let y = (primaryHeight - location.y - area.minY) / max(area.height, 1)
        return CursorTrack.Point(t: CMClockGetTime(CMClockGetHostTimeClock()).seconds, x: Double(x), y: Double(y))
    }

    private func sample() {
        let now = point()
        // Still pointers make no new points, save one every half second.
        if let last = moves.last, last.x == now.x, last.y == now.y, now.t - last.t < 0.5 { return }
        moves.append(now)
    }

    private func click() {
        let now = point()
        moves.append(now)
        clicks.append(now)
    }
}

// MARK: - While recording

/// A thin frame around the recorded area and a small stop control under it.
/// Both are Margin windows, so they don't show up in the recording, and the
/// frame lets clicks through so you can use the prototype you're recording.
/// Esc stops the recording too, whichever app is in front.
@MainActor
final class RecordingHUD {
    private var frameWindow: NSWindow?
    private var controls: KeyablePanel?
    private let model = RecordingHUDModel()
    private var keyMonitors: [Any] = []

    /// - Parameter area: AppKit coordinates.
    func show(area: CGRect, limit: TimeInterval, onStop: @escaping () -> Void) {
        close()
        model.started = Date()
        model.limit = limit

        let outline = NSWindow(contentRect: area.insetBy(dx: -4, dy: -4), styleMask: [.borderless], backing: .buffered, defer: false)
        outline.level = .screenSaver
        outline.backgroundColor = .clear
        outline.isOpaque = false
        outline.hasShadow = false
        outline.ignoresMouseEvents = true
        outline.isReleasedWhenClosed = false
        outline.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        outline.contentView = NSHostingView(rootView: RecordingOutline())
        outline.orderFrontRegardless()
        frameWindow = outline

        // Top center, under the menu bar, like every other Margin surface.
        let size = RecordingControls.panelSize
        let screen = NSScreen.screens.first { $0.frame.intersects(area) } ?? TopCenter.screen
        let origin = screen.map { TopCenter.origin(for: size, on: $0) } ?? CGPoint(x: area.midX - size.width / 2, y: area.maxY + 10)

        let panel = KeyablePanel(contentRect: CGRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = FirstClickHostingView(rootView: RecordingControls(model: model, onStop: onStop))
        panel.orderFrontRegardless()
        controls = panel

        // Esc stops. Another app usually has the keyboard while you record, so
        // listen globally (needs Accessibility, like the double-tap shortcut),
        // and locally for when Margin itself is in front.
        let escape: UInt16 = 53
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { event in
            guard event.keyCode == escape else { return }
            Task { @MainActor in onStop() }
        }) { keyMonitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in
            guard event.keyCode == escape else { return event }
            Task { @MainActor in onStop() }
            return nil
        }) { keyMonitors.append(monitor) }
    }

    func close() {
        keyMonitors.forEach(NSEvent.removeMonitor)
        keyMonitors = []
        frameWindow?.orderOut(nil)
        controls?.orderOut(nil)
        frameWindow = nil
        controls = nil
    }
}

@MainActor
final class RecordingHUDModel: ObservableObject {
    @Published var started = Date()
    @Published var limit: TimeInterval = 60
}

private struct RecordingOutline: View {
    @State private var pulse = false
    var body: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .strokeBorder(Color.red.opacity(pulse ? 0.9 : 0.55), lineWidth: 2)
            .padding(1)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { pulse = true }
            }
    }
}

/// The timer and Stop, on the same island as the capture card and the
/// loading pill: white, the menu's corners, a hairline, its shadow.
private struct RecordingControls: View {
    @ObservedObject var model: RecordingHUDModel
    let onStop: () -> Void
    @State private var pulse = false
    @Environment(\.colorScheme) private var scheme

    /// Room around the island for its shadow.
    static let panelSize = CGSize(width: 280, height: 96)

    var body: some View {
        let ink = MenuInk(scheme)
        let shape = RoundedRectangle(cornerRadius: Island.cardRadius, style: .continuous)
        let shadow: (Double, Double) = scheme == .dark ? (0.5, 0.45) : (0.08, 0.16)
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let elapsed = context.date.timeIntervalSince(model.started)
            HStack(spacing: 9) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 7, height: 7)
                    .opacity(pulse ? 1 : 0.35)
                Text(RegionMath.duration(elapsed))
                    .font(Theme.Typography.ui(12, .medium))
                    .monospacedDigit()
                    .foregroundStyle(ink.text)
                Text("/ \(RegionMath.duration(model.limit))")
                    .font(Theme.Typography.ui(12))
                    .monospacedDigit()
                    .foregroundStyle(ink.muted)
                Button(action: onStop) {
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(ink.text)
                            .frame(width: 7, height: 7)
                        Text("Stop")
                            .font(Archive.sans(12))
                            .foregroundStyle(ink.text)
                            .fixedSize()
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(ink.hairline))
                    .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("Stop recording (esc, or the Margin shortcut)")
                // A little more room before Stop than between the timer's parts.
                .padding(.leading, 5)
            }
            // As wide as what's in it, so nothing is cut and nothing floats.
            .fixedSize()
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .frame(height: Island.pillHeight)
        .background(shape.fill(ink.surface))
        .shadow(color: .black.opacity(shadow.0), radius: 1.5, y: 1)
        .shadow(color: .black.opacity(shadow.1), radius: 18, y: 8)
        .padding(.top, 6)
        .frame(width: Self.panelSize.width, height: Self.panelSize.height, alignment: .top)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}
