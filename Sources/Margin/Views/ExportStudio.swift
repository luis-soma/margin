import AppKit
import AVFoundation
import CoreImage
import MarginKit
import SwiftUI
import UniformTypeIdentifiers

/// Dressing a capture for documentation, the way CleanShot does: a
/// backdrop, room, rounded corners, a shadow, a frame shape and a crop; for
/// recordings also zoom on clicks, a smooth cursor and click ripples, saved
/// as MP4 or GIF. Opens from the pencil under a capture's details, in place
/// of the focus panel; Esc goes back.
struct ExportStudio: View {
    let entry: Entry
    let source: URL
    let close: () -> Void

    enum Format: String { case mp4, gif }

    @State private var style = ExportStyle.saved
    @State private var crop: CGRect
    @State private var cropping = false
    @State private var format: Format = Format(rawValue: UserDefaults.standard.string(forKey: "exportFormat") ?? "") ?? .mp4

    /// A picture, or a recording's frame, small: for the preview, the crop
    /// and the blurred swatch.
    @State private var small: CIImage?
    @State private var smallImage: CGImage?
    /// A picture's styled preview.
    @State private var preview: CGImage?
    @State private var fullSize: CGSize?
    @State private var failed = false
    @State private var progress: Double?
    @State private var busy = false
    @State private var flash: String?
    @State private var renderID = 0

    // Recordings
    @State private var track: CursorTrack?
    @State private var duration: Double = 0
    @State private var plans = PlanCache()
    @StateObject private var player = PreviewPlayer()

    init(entry: Entry, source: URL, close: @escaping () -> Void) {
        self.entry = entry
        self.source = source
        self.close = close
        _crop = State(initialValue: ExportCrops.crop(for: entry.id))
    }

    private var isVideo: Bool { ["mp4", "mov", "m4v"].contains(source.pathExtension.lowercased()) }
    private var F: Archive.Focus.Type { Archive.Focus.self }

    /// The cursorless copy, when the recording has one.
    private var studioURL: URL? {
        guard isVideo, track?.starts["studio"] != nil else { return nil }
        let url = CursorTrack.studioVideo(for: source)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    private var drawsCursor: Bool { style.smoothCursor && studioURL != nil }
    private var videoSource: URL { drawsCursor ? (studioURL ?? source) : source }
    private var plan: MotionPlan? {
        guard let track else { return nil }
        return plans.plan(track: track, file: drawsCursor ? "studio" : "main", duration: duration, depth: ExportRenderer.zoomDepth(style))
    }
    private var setup: ExportRenderer.VideoSetup {
        ExportRenderer.VideoSetup(plan: plan, drawCursor: drawsCursor, crop: crop)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: F.radius, style: .continuous)
        HStack(spacing: 0) {
            stage
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Rectangle()
                .fill(Archive.rule)
                .frame(width: 1)
                .frame(maxHeight: .infinity)
                .padding(.vertical, F.ruleInset)
            controls
                .frame(width: F.sidebarWidth)
                .padding(.leading, F.gap / 2)
                .padding(.trailing, F.trailing)
        }
        .overlay(alignment: .topTrailing) {
            NavIcon(symbol: "xmark", action: close)
                .pointingHand()
                .help("Back to the capture (esc)")
                .padding(.top, F.navTop)
                .padding(.trailing, F.navTrailing)
        }
        .background(Archive.paper, in: shape)
        .clipShape(shape)
        .background(
            shape.fill(Archive.paper)
                .shadow(color: .black.opacity(0.05), radius: 1.5, y: 1)
                .shadow(color: .black.opacity(0.10), radius: 28, y: 10)
        )
        .overlay(alignment: .bottom) {
            if let flash {
                FloatingNote(text: flash)
                    .padding(.bottom, 22)
                    .transition(.opacity.combined(with: .offset(y: 8)).combined(with: .scale(scale: 0.96, anchor: .bottom)))
            }
        }
        .animation(Brand.motion, value: flash)
        .task { await load() }
        .onChange(of: style) { new in
            ExportStyle.saved = new
            refresh()
        }
        .onChange(of: crop) { new in
            ExportCrops.set(new, for: entry.id)
            refresh()
        }
        .onChange(of: format) { new in UserDefaults.standard.set(new.rawValue, forKey: "exportFormat") }
        .onDisappear { player.stop() }
    }

    // MARK: The preview

    private var stage: some View {
        GeometryReader { geo in
            let timeline: CGFloat = isVideo && !cropping ? 60 : 0
            let room = CGSize(width: max(80, geo.size.width - 2 * F.leading),
                              height: max(80, geo.size.height - 2 * F.verticalMargin * 0.75 - timeline))
            ZStack {
                if cropping, let smallImage {
                    let size = fitted(CGSize(width: smallImage.width, height: smallImage.height), in: room)
                    Image(decorative: smallImage, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: size.width, height: size.height)
                        .overlay(CropOverlay(crop: $crop))
                        .transition(.opacity)
                } else if isVideo, player.renderSize != .zero {
                    let size = fitted(player.renderSize, in: room)
                    PlayerLayerView(player: player.player)
                        .frame(width: size.width, height: size.height)
                        .overlay(Rectangle().strokeBorder(Archive.rule, lineWidth: 1))
                        .animation(Theme.Motion.settle, value: size)
                        .offset(y: -timeline / 2)
                        .transition(.opacity)
                } else if !isVideo, let preview {
                    let size = fitted(CGSize(width: preview.width, height: preview.height), in: room)
                    ZStack {
                        if style.backdrop == .none { Checkerboard() }
                        Image(decorative: preview, scale: 1)
                            .resizable()
                            .interpolation(.high)
                    }
                    .frame(width: size.width, height: size.height)
                    // The edge of the exported picture, so a white one still
                    // shows where it ends.
                    .overlay(Rectangle().strokeBorder(Archive.rule, lineWidth: 1))
                    .animation(Theme.Motion.settle, value: size)
                    .transition(.opacity)
                } else if failed {
                    Text("This capture can't be opened here.")
                        .font(Archive.sans(F.valueSize))
                        .foregroundStyle(Archive.faint)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .animation(Theme.Motion.settle, value: cropping)
            .overlay(alignment: .topLeading) { stageTools.padding(.top, F.navTop).padding(.leading, F.navTop) }
            .overlay(alignment: .bottom) {
                if isVideo, !cropping, player.duration > 0 {
                    Scrubber(time: player.time, playing: player.playing, duration: player.duration,
                             clicks: plan?.clicks.map(\.t) ?? [],
                             seek: { player.seek($0) }, togglePlay: { player.toggle() })
                        .frame(maxWidth: 520)
                        .padding(.horizontal, F.leading)
                        .padding(.bottom, Theme.Space.x6)
                        .transition(.opacity)
                }
            }
        }
    }

    /// Crop, and while cropping: Reset and Done.
    private var stageTools: some View {
        HStack(spacing: Theme.Space.x2) {
            if cropping {
                ChipButton(title: "Reset", disabled: crop == ExportCrops.full) {
                    withAnimation(Theme.Motion.snappy) { crop = ExportCrops.full }
                }
                ChipButton(title: "Done", primary: true) { finishCropping() }
            } else {
                ChipButton(title: crop == ExportCrops.full ? "Crop" : "Cropped", symbol: "crop") { startCropping() }
                    .disabled(small == nil)
            }
        }
        .animation(Theme.Motion.snappy, value: cropping)
    }

    private func fitted(_ size: CGSize, in room: CGSize) -> CGSize {
        let scale = min(room.width / max(size.width, 1), room.height / max(size.height, 1))
        return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }

    // MARK: The controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: Theme.Space.x4) {
            ScrollView(.vertical, showsIndicators: false) {
                settings
                    .padding(.top, F.verticalMargin * 0.75)
                    .padding(.bottom, Theme.Space.x2)
            }
            footer
        }
        .padding(.bottom, F.trailing)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: Theme.Space.x6) {
            Text("Edit")
                .font(Archive.headline(F.titleSize))
                .foregroundStyle(Archive.ink)
            group("Background") {
                Swatches(style: $style, options: ExportStyle.Backdrop.available(video: isVideo), capture: small)
            }
            group("Frame") {
                VStack(spacing: Theme.Space.x1 + 2) {
                    StyleSlider(title: "Padding", value: $style.padding)
                    StyleSlider(title: "Corners", value: $style.radius)
                    StyleSlider(title: "Shadow", value: $style.shadow)
                }
            }
            group("Size") {
                VStack(alignment: .leading, spacing: Theme.Space.x2) {
                    RatioSwitch(selection: $style.ratio)
                    if style.ratio == .custom {
                        RatioFields(width: $style.ratioWidth, height: $style.ratioHeight)
                            .transition(.opacity.combined(with: .offset(y: -4)))
                    }
                }
                .animation(Theme.Motion.snappy, value: style.ratio == .custom)
            }
            if isVideo, track != nil {
                group("Motion") { motion }
            }
            Button("Reset to default") { withAnimation(Theme.Motion.settle) { style = ExportStyle() } }
                .buttonStyle(.plain)
                .font(Archive.sans(F.valueSize))
                .foregroundStyle(Archive.faint)
                .pointingHand()
                .opacity(style == ExportStyle() ? 0 : 1)
                .disabled(style == ExportStyle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var motion: some View {
        VStack(alignment: .leading, spacing: Theme.Space.x1 + 2) {
            StyleToggle(title: "Zoom on clicks", isOn: $style.zoom)
            if style.zoom {
                StyleSlider(title: "Zoom", value: $style.zoomAmount)
                    .transition(.opacity)
            }
            if studioURL != nil {
                StyleToggle(title: "Smooth cursor", isOn: $style.smoothCursor)
                if style.smoothCursor {
                    StyleSlider(title: "Cursor size", value: $style.cursorSize)
                        .transition(.opacity)
                }
            }
            StyleToggle(title: "Show clicks", isOn: $style.showClicks)
            if plan?.hasClicks == false {
                Text("No clicks in this recording, so nothing to zoom to.")
                    .font(Archive.sans(F.valueSize))
                    .foregroundStyle(Archive.faint)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Theme.Space.x1)
            }
        }
        .animation(Theme.Motion.snappy, value: style.zoom)
        .animation(Theme.Motion.snappy, value: style.smoothCursor)
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.x2) {
            Text(title)
                .font(Archive.font(F.labelSize))
                .foregroundStyle(Archive.faint)
            content()
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: Theme.Space.x3) {
            HStack(spacing: Theme.Space.x2) {
                if let size = outputSize {
                    Text("\(Int(size.width)) × \(Int(size.height))")
                        .monospacedDigit()
                        .font(Archive.sans(F.valueSize))
                        .foregroundStyle(Archive.faint)
                }
                Spacer(minLength: 0)
                if isVideo {
                    FormatSwitch(selection: $format)
                } else {
                    Text("PNG")
                        .font(Archive.sans(F.valueSize))
                        .foregroundStyle(Archive.faint)
                }
            }
            HStack(spacing: Theme.Space.x2) {
                if !isVideo {
                    StudioButton(title: "Copy", primary: false, action: copy)
                        .disabled(busy || small == nil)
                }
                StudioButton(title: saveTitle, primary: true, progress: progress, action: save)
                    .disabled(busy || small == nil)
            }
        }
    }

    private var saveTitle: String {
        if let progress { return "Exporting \(Int(progress * 100))%" }
        return "Save to Downloads"
    }

    /// The exported picture's size in pixels.
    private var outputSize: CGSize? {
        guard let fullSize else { return nil }
        if isVideo {
            return ExportRenderer.videoSize(for: fullSize, style: style, crop: crop, longest: format == .gif ? 960 : 3840)
        }
        return ExportRenderer.layout(for: ExportRenderer.cropRect(crop, in: fullSize).size, style: style).canvas
    }

    // MARK: Work

    private func load() async {
        let url = source
        if isVideo {
            track = CursorTrack.load(for: url)
            duration = (await VideoTools.duration(of: url)) ?? 0
            fullSize = await FrameGrabber.naturalSize(of: url)
            guard duration > 0, fullSize != nil else {
                failed = true
                return
            }
            prepareCursor()
            let start = plan?.firstMoment.map { min($0, max(duration - 0.05, 0)) } ?? 0
            player.show(url: videoSource, style: style, setup: setup, at: start)
            await grabFrame(at: start)
            return
        }
        let content: CIImage? = await Task.detached { ExportRenderer.picture(at: url) }.value
        guard let content else {
            failed = true
            return
        }
        fullSize = content.extent.size
        setSmall(ExportRenderer.downsized(content, longest: 1600))
        rerender()
    }

    private func setSmall(_ image: CIImage) {
        small = image
        smallImage = ExportRenderer.cgImage(image)
    }

    /// A raw frame of the recording, for the crop and the blurred swatch.
    private func grabFrame(at seconds: Double) async {
        if let frame = await FrameGrabber(url: source).frame(at: seconds) {
            setSmall(frame.transformed(by: CGAffineTransform(translationX: -frame.extent.minX, y: -frame.extent.minY)))
        }
    }

    private func refresh() {
        if isVideo {
            prepareCursor()
            player.show(url: videoSource, style: style, setup: setup, at: nil)
        } else {
            rerender()
        }
    }

    /// The drawn cursor is made once on the main thread, at the size the
    /// recording's frames need, before any frame asks for it.
    private func prepareCursor() {
        guard drawsCursor, let width = fullSize?.width, let plan else { return }
        _ = ExportRenderer.arrow(height: 24 * width / max(plan.area.width, 1) * CGFloat(0.7 + 1.3 * style.cursorSize))
    }

    private func rerender() {
        guard let small else { return }
        renderID += 1
        let id = renderID
        let style = style
        let crop = crop
        Task {
            let image = await Task.detached(priority: .userInitiated) {
                ExportRenderer.cgImage(ExportRenderer.render(ExportRenderer.cropped(small, to: crop), style: style))
            }.value
            if id == renderID, let image { preview = image }
        }
    }

    private func startCropping() {
        if isVideo {
            player.pause()
            let moment = player.time
            Task {
                await grabFrame(at: moment)
                withAnimation(Theme.Motion.settle) { cropping = true }
            }
        } else {
            withAnimation(Theme.Motion.settle) { cropping = true }
        }
    }

    private func finishCropping() {
        withAnimation(Theme.Motion.settle) { cropping = false }
    }

    private func copy() {
        let url = source
        let style = style
        let crop = crop
        busy = true
        Task.detached(priority: .userInitiated) {
            let png = ExportRenderer.picture(at: url).flatMap { ExportRenderer.png(ExportRenderer.cropped($0, to: crop), style: style) }
            await MainActor.run {
                busy = false
                guard let png else { return show("Couldn't copy the picture") }
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                let item = NSPasteboardItem()
                item.setData(png, forType: .png)
                if let tiff = NSBitmapImageRep(data: png)?.tiffRepresentation { item.setData(tiff, forType: .tiff) }
                pasteboard.writeObjects([item])
                show("Copied")
            }
        }
    }

    private func save() {
        guard let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return }
        let ext = isVideo ? format.rawValue : "png"
        let destination = Self.freeName(in: folder, base: FocusView.fileName(for: entry, extension: ""), ext: ext)
        let style = style
        let crop = crop
        busy = true
        if isVideo {
            progress = 0
            player.pause()
            prepareCursor()
            let url = videoSource
            let setup = setup
            let gif = format == .gif
            Task {
                do {
                    if gif {
                        try await ExportRenderer.exportGIF(from: url, style: style, setup: setup, to: destination) { value in progress = value }
                    } else {
                        try await ExportRenderer.exportVideo(from: url, style: style, setup: setup, to: destination) { value in progress = value }
                    }
                    finishSave(destination, ok: true)
                } catch {
                    finishSave(destination, ok: false, error.localizedDescription)
                }
            }
        } else {
            let url = source
            Task.detached(priority: .userInitiated) {
                let png = ExportRenderer.picture(at: url).flatMap { ExportRenderer.png(ExportRenderer.cropped($0, to: crop), style: style) }
                let ok = (try? png?.write(to: destination, options: .atomic)) != nil
                await MainActor.run { finishSave(destination, ok: ok) }
            }
        }
    }

    private func finishSave(_ destination: URL, ok: Bool, _ why: String? = nil) {
        busy = false
        progress = nil
        if ok {
            let bytes = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            show(bytes > 0 ? "Saved to Downloads · \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))" : "Saved to Downloads")
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } else {
            show(why ?? "Couldn't save the picture")
        }
    }

    private func show(_ message: String) {
        flash = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            if flash == message { flash = nil }
        }
    }

    /// `base.ext` in `folder`, or `base 2.ext` and on if that's taken.
    static func freeName(in folder: URL, base: String, ext: String) -> URL {
        var url = folder.appendingPathComponent("\(base).\(ext)")
        var copy = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(copy).\(ext)")
            copy += 1
        }
        return url
    }
}

// MARK: - Keeping things

/// Each capture's crop, kept so the studio opens as you left it.
enum ExportCrops {
    static let full = CGRect(x: 0, y: 0, width: 1, height: 1)
    private static let key = "exportCrops"

    static func crop(for id: UUID) -> CGRect {
        guard let all = UserDefaults.standard.dictionary(forKey: key) as? [String: [Double]],
              let v = all[id.uuidString], v.count == 4 else { return full }
        return CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
    }

    static func set(_ crop: CGRect, for id: UUID) {
        var all = (UserDefaults.standard.dictionary(forKey: key) as? [String: [Double]]) ?? [:]
        all[id.uuidString] = crop == full ? nil : [crop.minX, crop.minY, crop.width, crop.height].map(Double.init)
        UserDefaults.standard.set(all, forKey: key)
    }
}

/// The motion plan for the current settings, worked out again only when
/// they change.
final class PlanCache {
    private var key: String?
    private var cached: MotionPlan?

    func plan(track: CursorTrack, file: String, duration: Double, depth: CGFloat) -> MotionPlan? {
        let key = "\(file)|\(duration)|\(Int(depth * 100))"
        if key == self.key { return cached }
        self.key = key
        cached = MotionPlan(track: track, file: file, duration: duration, depth: depth)
        return cached
    }
}

/// The recording's preview, played through the same frames the export
/// writes, so it moves as smoothly as the result will.
@MainActor
final class PreviewPlayer: ObservableObject {
    let player = AVPlayer()
    @Published var time: Double = 0
    @Published var duration: Double = 0
    @Published var playing = false
    @Published var renderSize: CGSize = .zero
    private var url: URL?
    private var item: AVPlayerItem?
    private var observer: Any?
    private var ended: NSObjectProtocol?
    private var build = 0

    init() {
        player.isMuted = true
        player.actionAtItemEnd = .pause
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self, self.playing else { return }
                self.time = time.seconds
            }
        }
    }

    /// Shows `url` in `style`; `at` moves to a moment, nil keeps the current one.
    func show(url: URL, style: ExportStyle, setup: ExportRenderer.VideoSetup, at: Double?) {
        build += 1
        let id = build
        let asset = (url == self.url ? item?.asset : nil) ?? AVURLAsset(url: url)
        Task {
            guard let composition = try? await ExportRenderer.composition(for: asset, style: style, setup: setup, longest: 1400),
                  id == build else { return }
            if url != self.url || item == nil {
                let item = AVPlayerItem(asset: asset)
                item.videoComposition = composition
                self.item = item
                self.url = url
                player.replaceCurrentItem(with: item)
                if let ended { NotificationCenter.default.removeObserver(ended) }
                ended = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.loop() }
                }
                duration = (try? await asset.load(.duration).seconds) ?? 0
            } else {
                item?.videoComposition = composition
            }
            renderSize = composition.renderSize
            seek(at ?? time)
            if playing { player.play() }
        }
    }

    func seek(_ seconds: Double) {
        time = min(max(seconds, 0), max(duration, 0))
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func toggle() {
        if playing {
            pause()
        } else {
            if duration > 0, time >= duration - 0.05 { seek(0) }
            playing = true
            player.play()
        }
    }

    func pause() {
        playing = false
        player.pause()
        time = player.currentTime().seconds
    }

    func stop() {
        pause()
        player.replaceCurrentItem(with: nil)
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
        if let ended { NotificationCenter.default.removeObserver(ended) }
        ended = nil
    }

    private func loop() {
        guard playing else { return }
        player.seek(to: .zero) { [weak self] _ in
            Task { @MainActor in self?.player.play() }
        }
    }
}

/// An AVPlayerLayer in SwiftUI.
private struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = .clear
        view.layer = layer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view.layer as? AVPlayerLayer)?.player = player
    }
}

/// The crop box over the picture: drag a corner or an edge to resize, the
/// inside to move. Outside it the picture dims.
private struct CropOverlay: View {
    @Binding var crop: CGRect
    @State private var start: CGRect?

    private enum Grip: CaseIterable { case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left }
    private let minimum: CGFloat = 0.05

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let box = CGRect(x: crop.minX * size.width, y: crop.minY * size.height,
                             width: crop.width * size.width, height: crop.height * size.height)
            ZStack(alignment: .topLeading) {
                // The dimmed outside.
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: size))
                    path.addRect(box)
                }
                .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)

                // Thirds, faintly, and the box's edge.
                Path { path in
                    for i in 1...2 {
                        let x = box.minX + box.width * CGFloat(i) / 3
                        let y = box.minY + box.height * CGFloat(i) / 3
                        path.move(to: CGPoint(x: x, y: box.minY)); path.addLine(to: CGPoint(x: x, y: box.maxY))
                        path.move(to: CGPoint(x: box.minX, y: y)); path.addLine(to: CGPoint(x: box.maxX, y: y))
                    }
                }
                .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
                .allowsHitTesting(false)
                Rectangle()
                    .strokeBorder(Color.white, lineWidth: 1.5)
                    .frame(width: box.width, height: box.height)
                    .offset(x: box.minX, y: box.minY)
                    .shadow(color: .black.opacity(0.25), radius: 1)
                    .allowsHitTesting(false)

                // Moving the box.
                Rectangle()
                    .fill(Color.white.opacity(0.001))
                    .frame(width: box.width, height: box.height)
                    .offset(x: box.minX, y: box.minY)
                    .onHover { inside in if inside { NSCursor.openHand.push() } else { NSCursor.pop() } }
                    .gesture(DragGesture().onChanged { drag in
                        let from = start ?? crop
                        start = from
                        var moved = from.offsetBy(dx: drag.translation.width / size.width, dy: drag.translation.height / size.height)
                        moved.origin.x = min(max(moved.minX, 0), 1 - moved.width)
                        moved.origin.y = min(max(moved.minY, 0), 1 - moved.height)
                        crop = moved
                    }.onEnded { _ in start = nil })

                ForEach(Grip.allCases, id: \.self) { grip in
                    handle(grip, box: box, size: size)
                }
            }
        }
    }

    @ViewBuilder
    private func handle(_ grip: Grip, box: CGRect, size: CGSize) -> some View {
        let point = position(grip, box)
        let corner = [Grip.topLeft, Grip.topRight, Grip.bottomRight, Grip.bottomLeft].contains(grip)
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(Color.white)
            .frame(width: corner ? 12 : (grip == .top || grip == .bottom ? 22 : 5),
                   height: corner ? 12 : (grip == .left || grip == .right ? 22 : 5))
            .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
            .position(point)
            .gesture(DragGesture().onChanged { drag in
                let from = start ?? crop
                start = from
                crop = resized(from, grip: grip, dx: drag.translation.width / size.width, dy: drag.translation.height / size.height)
            }.onEnded { _ in start = nil })
    }

    private func position(_ grip: Grip, _ box: CGRect) -> CGPoint {
        switch grip {
        case .topLeft: return CGPoint(x: box.minX, y: box.minY)
        case .top: return CGPoint(x: box.midX, y: box.minY)
        case .topRight: return CGPoint(x: box.maxX, y: box.minY)
        case .right: return CGPoint(x: box.maxX, y: box.midY)
        case .bottomRight: return CGPoint(x: box.maxX, y: box.maxY)
        case .bottom: return CGPoint(x: box.midX, y: box.maxY)
        case .bottomLeft: return CGPoint(x: box.minX, y: box.maxY)
        case .left: return CGPoint(x: box.minX, y: box.midY)
        }
    }

    private func resized(_ r: CGRect, grip: Grip, dx: CGFloat, dy: CGFloat) -> CGRect {
        var minX = r.minX, minY = r.minY, maxX = r.maxX, maxY = r.maxY
        switch grip {
        case .topLeft, .left, .bottomLeft: minX = min(max(minX + dx, 0), maxX - minimum)
        case .topRight, .right, .bottomRight: maxX = max(min(maxX + dx, 1), minX + minimum)
        default: break
        }
        switch grip {
        case .topLeft, .top, .topRight: minY = min(max(minY + dy, 0), maxY - minimum)
        case .bottomLeft, .bottom, .bottomRight: maxY = max(min(maxY + dy, 1), minY + minimum)
        default: break
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// A small button over the preview: Crop, Reset, Done.
private struct ChipButton: View {
    let title: String
    var symbol: String? = nil
    var primary = false
    var disabled = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                }
                Text(title)
            }
            .font(Theme.Typography.ui(Theme.Typography.control, .medium))
            .foregroundStyle(primary ? Theme.Palette.paper : Theme.Palette.ink)
            .padding(.horizontal, Theme.Space.x3)
            .frame(height: 28)
            .background(shape.fill(primary ? Theme.Palette.ink.opacity(hovering ? 0.86 : 1) : (hovering ? Theme.Palette.fillHover : Theme.Palette.fill)))
            .contentShape(shape)
            .opacity(disabled ? 0.4 : 1)
        }
        .buttonStyle(PressStyle())
        .disabled(disabled)
        .onHover { inside in withAnimation(Theme.Motion.hover) { hovering = inside } }
    }
}

/// MP4 or GIF, as Margin's switch.
private struct FormatSwitch: View {
    @Binding var selection: ExportStudio.Format
    @Namespace private var thumb

    var body: some View {
        let S = Theme.Segmented.self
        HStack(spacing: 0) {
            ForEach([ExportStudio.Format.mp4, .gif], id: \.self) { format in
                Button {
                    withAnimation(Theme.Motion.snappy) { selection = format }
                } label: {
                    Text(format == .mp4 ? "MP4" : "GIF")
                        .font(Theme.Typography.ui(Theme.Typography.caption, selection == format ? .medium : .regular))
                        .foregroundStyle(S.label(selection == format, hovered: false))
                        .frame(width: 42, height: 22)
                        .background {
                            if selection == format { SegmentThumb().matchedGeometryEffect(id: "thumb", in: thumb) }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(SegmentTrack())
    }
}

/// Under a recording's preview: play, the timeline with a tick at every
/// click, the time.
private struct Scrubber: View {
    let time: Double
    let playing: Bool
    let duration: Double
    let clicks: [Double]
    let seek: (Double) -> Void
    let togglePlay: () -> Void
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
        HStack(spacing: Theme.Space.x2) {
            Button(action: togglePlay) {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.Palette.ink)
                    .frame(width: 28, height: 28)
                    .background(shape.fill(Theme.Palette.fill))
                    .contentShape(shape)
            }
            .buttonStyle(PressStyle())
            .keyboardShortcut(.space, modifiers: [])
            .toolTip(playing ? "Pause" : "Play", "Space", align: .center)

            GeometryReader { geo in
                let width = geo.size.width
                let x = CGFloat(time / max(duration, 0.01)) * width
                ZStack(alignment: .leading) {
                    shape.fill(Theme.Palette.fill)
                    Rectangle()
                        .fill(Theme.Palette.ink.opacity(hovering ? 0.065 : 0.05))
                        .frame(width: max(0, x))
                    ForEach(Array(clicks.enumerated()), id: \.offset) { _, click in
                        Circle()
                            .fill(Theme.Palette.ink3)
                            .frame(width: 4, height: 4)
                            .offset(x: CGFloat(click / max(duration, 0.01)) * width - 2)
                    }
                    Rectangle()
                        .fill(Theme.Palette.ink)
                        .frame(width: 2, height: 14)
                        .offset(x: min(max(x - 1, 0), width - 2))
                }
                .clipShape(shape)
                .contentShape(shape)
                .gesture(
                    DragGesture(minimumDistance: 0).onChanged { drag in
                        seek(Double(min(max(drag.location.x / max(width, 1), 0), 1)) * duration)
                    }
                )
                .onHover { inside in withAnimation(Theme.Motion.hover) { hovering = inside } }
            }
            .frame(height: 28)

            Text("\(Self.clock(time)) / \(Self.clock(duration))")
                .font(Theme.Typography.ui(Theme.Typography.caption))
                .monospacedDigit()
                .foregroundStyle(Theme.Palette.ink3)
                .fixedSize()
        }
    }

    static func clock(_ seconds: Double) -> String {
        let whole = Int(max(seconds, 0))
        return String(format: "%d:%02d.%d", whole / 60, whole % 60, Int((max(seconds, 0) - Double(whole)) * 10))
    }
}

// MARK: - Pieces

/// The backdrops, as small squares: the built-in ones, then your own
/// pictures and a square to add one (or drop pictures on the grid). The
/// chosen one is ringed in ink.
private struct Swatches: View {
    @Binding var style: ExportStyle
    let options: [ExportStyle.Backdrop]
    /// For "From the capture": the capture itself, blurred.
    let capture: CIImage?
    @State private var thumbnail: NSImage?
    @State private var pictures: [String] = ExportBackgrounds.all()
    @State private var pictureThumbs: [String: NSImage] = [:]
    @State private var dropping = false

    private let columns = Array(repeating: GridItem(.fixed(32), spacing: 8), count: 6)

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(options) { option in
                Swatch(option: option, selected: style.backdrop == option, image: option == .blur ? thumbnail : nil) {
                    withAnimation(Theme.Motion.snappy) { style.backdrop = option }
                }
            }
            ForEach(pictures, id: \.self) { name in
                Swatch(option: .picture, selected: style.backdrop == .picture && style.picture == name, image: pictureThumbs[name]) {
                    withAnimation(Theme.Motion.snappy) {
                        style.picture = name
                        style.backdrop = .picture
                    }
                }
                .contextMenu {
                    Button("Remove This Background") { remove(name) }
                }
                .onAppear { loadThumb(name) }
            }
            AddSwatch(highlighted: dropping, action: choose)
        }
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { add([url]) }
                }
            }
            return true
        }
        .onAppear(perform: makeThumbnail)
        .onChange(of: capture == nil) { _ in makeThumbnail() }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose pictures to use as backgrounds"
        panel.prompt = "Add"
        panel.begin { response in
            guard response == .OK else { return }
            add(panel.urls)
        }
    }

    private func add(_ urls: [URL]) {
        let images = urls.filter { NSImage(contentsOf: $0) != nil }
        var last: String?
        for url in images { last = ExportBackgrounds.add(url) ?? last }
        pictures = ExportBackgrounds.all()
        if let last {
            withAnimation(Theme.Motion.snappy) {
                style.picture = last
                style.backdrop = .picture
            }
        }
    }

    private func remove(_ name: String) {
        ExportBackgrounds.remove(name)
        pictures = ExportBackgrounds.all()
        pictureThumbs[name] = nil
        if style.backdrop == .picture, style.picture == name {
            style.picture = nil
            style.backdrop = ExportStyle().backdrop
        }
    }

    private func loadThumb(_ name: String) {
        guard pictureThumbs[name] == nil else { return }
        let url = ExportBackgrounds.url(name)
        Task.detached(priority: .utility) {
            let small = ExportRenderer.picture(at: url).map { ExportRenderer.downsized($0, longest: 96) }
            let image = small.flatMap(ExportRenderer.cgImage)
            await MainActor.run {
                if let image { pictureThumbs[name] = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)) }
            }
        }
    }

    private func makeThumbnail() {
        guard thumbnail == nil, let capture else { return }
        let small = ExportRenderer.downsized(capture, longest: 96)
        if let image = ExportRenderer.cgImage(small) {
            thumbnail = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }
    }
}

/// The square that adds a picture: a plus on the grey track.
private struct AddSwatch: View {
    var highlighted = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hovering || highlighted ? Theme.Palette.ink : Theme.Palette.ink2)
                .frame(width: 32, height: 32)
                .background(shape.fill(hovering || highlighted ? Theme.Palette.fillSelected : Theme.Palette.fill))
                .contentShape(shape)
        }
        .buttonStyle(PressStyle(scale: 0.94))
        .onHover { inside in withAnimation(Theme.Motion.hover) { hovering = inside } }
        .toolTip("Add a background", "A picture of your own, or drop one here", align: .center)
        .accessibilityLabel("Add a background")
    }
}

/// Width to height for a custom frame: two numbers either side of a colon.
private struct RatioFields: View {
    @Binding var width: Double
    @Binding var height: Double

    var body: some View {
        HStack(spacing: Theme.Space.x2) {
            NumberField(value: $width, label: "Width")
            Text(":")
                .font(Theme.Typography.ui(Theme.Typography.control, .medium))
                .foregroundStyle(Theme.Palette.ink3)
            NumberField(value: $height, label: "Height")
            Button {
                let old = width
                width = height
                height = old
            } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.Palette.ink2)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(Theme.Palette.fill))
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .toolTip("Swap width and height", align: .center)
        }
    }
}

/// A number on the grey track; Return or leaving the field takes it.
private struct NumberField: View {
    @Binding var value: Double
    let label: String
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(label, text: $text)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.center)
            .font(Theme.Typography.ui(Theme.Typography.control))
            .monospacedDigit()
            .foregroundStyle(Theme.Palette.ink)
            .focused($focused)
            .frame(height: 28)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(focused ? Theme.Palette.fillSelected : Theme.Palette.fill))
            .onAppear { text = Self.format(value) }
            .onChange(of: value) { new in if !focused { text = Self.format(new) } }
            .onChange(of: focused) { now in if !now { commit() } }
            .onSubmit(commit)
            .accessibilityLabel(label)
    }

    private func commit() {
        let cleaned = text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        if let number = Double(cleaned), number > 0, number <= 10_000 { value = number }
        text = Self.format(value)
    }

    static func format(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%g", value)
    }
}

private struct Swatch: View {
    let option: ExportStyle.Backdrop
    let selected: Bool
    /// The capture (blurred) or your picture.
    let image: NSImage?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
        Button(action: action) {
            fill
                .frame(width: 32, height: 32)
                .clipShape(shape)
                .overlay(shape.strokeBorder(Theme.Palette.hairline, lineWidth: 1))
                .padding(2)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.chip + 2, style: .continuous)
                        .strokeBorder(Theme.Palette.ink, lineWidth: 1.5)
                        .opacity(selected ? 1 : 0)
                )
                .padding(-2)
                .scaleEffect(hovering && !selected ? 1.04 : 1)
                .contentShape(shape)
        }
        .buttonStyle(PressStyle(scale: 0.94))
        .onHover { inside in withAnimation(Theme.Motion.hover) { hovering = inside } }
        .toolTip(option.name, align: .center)
        .accessibilityLabel(option.name)
    }

    @ViewBuilder
    private var fill: some View {
        switch option {
        case .none:
            Checkerboard(square: 6)
        case .blur:
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: 4)
                    .scaleEffect(1.3)
            } else {
                Theme.Palette.fill
            }
        case .picture:
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Theme.Palette.fill
            }
        default:
            if let pair = option.colors {
                LinearGradient(colors: [Color(nsColor: ExportRenderer.color(pair.0)), Color(nsColor: ExportRenderer.color(pair.1))],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
    }
}

/// A row you drag across: the name on the left, the amount on the right,
/// the part up to the handle a shade deeper, the handle a thin ink line.
private struct StyleSlider: View {
    let title: String
    @Binding var value: Double
    @State private var hovering = false
    @State private var dragging = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
        GeometryReader { geo in
            let width = geo.size.width
            let x = CGFloat(value) * width
            ZStack(alignment: .leading) {
                shape.fill(Theme.Palette.fill)
                Rectangle()
                    .fill(Theme.Palette.ink.opacity(dragging ? 0.08 : hovering ? 0.065 : 0.05))
                    .frame(width: max(0, x))
                Rectangle()
                    .fill(Theme.Palette.ink)
                    .frame(width: 2, height: 14)
                    .offset(x: min(max(x - 1, 6), width - 8))
                    .opacity(value > 0.005 ? 1 : 0.35)
                HStack {
                    Text(title)
                        .foregroundStyle(Theme.Palette.ink)
                    Spacer()
                    Text("\(Int((value * 100).rounded()))")
                        .monospacedDigit()
                        .foregroundStyle(Theme.Palette.ink3)
                }
                .font(Theme.Typography.ui(Theme.Typography.control))
                .padding(.horizontal, Theme.Space.x3)
                .allowsHitTesting(false)
            }
            .clipShape(shape)
            .contentShape(shape)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        dragging = true
                        value = Double(min(max(drag.location.x / max(width, 1), 0), 1))
                    }
                    .onEnded { _ in dragging = false }
            )
            .onHover { inside in withAnimation(Theme.Motion.hover) { hovering = inside } }
        }
        .frame(height: 28)
        .accessibilityElement()
        .accessibilityLabel(title)
        .accessibilityValue("\(Int(value * 100)) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(1, value + 0.05)
            case .decrement: value = max(0, value - 0.05)
            @unknown default: break
            }
        }
    }
}

/// A row that's on or off: the name on the grey track, a small switch at
/// the end, ink when on.
private struct StyleToggle: View {
    let title: String
    @Binding var isOn: Bool
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
        Button {
            withAnimation(Theme.Motion.snappy) { isOn.toggle() }
        } label: {
            HStack {
                Text(title)
                    .foregroundStyle(Theme.Palette.ink)
                Spacer()
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule()
                        .fill(isOn ? Theme.Palette.ink : Theme.Palette.ink.opacity(0.14))
                        .frame(width: 26, height: 16)
                    Circle()
                        .fill(Theme.Palette.paper)
                        .frame(width: 12, height: 12)
                        .padding(2)
                        .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
                }
            }
            .font(Theme.Typography.ui(Theme.Typography.control))
            .padding(.leading, Theme.Space.x3)
            .padding(.trailing, Theme.Space.x2)
            .frame(height: 28)
            .background(shape.fill(hovering ? Theme.Palette.fillHover : Theme.Palette.fill))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { inside in withAnimation(Theme.Motion.hover) { hovering = inside } }
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

/// Auto, 16:9, 4:3, 1:1: Margin's switch, the chosen one in ink.
private struct RatioSwitch: View {
    @Binding var selection: ExportStyle.Ratio
    @Namespace private var thumb
    @State private var hovered: ExportStyle.Ratio?

    var body: some View {
        let S = Theme.Segmented.self
        HStack(spacing: 0) {
            ForEach(ExportStyle.Ratio.allCases) { ratio in
                Button {
                    withAnimation(Theme.Motion.snappy) { selection = ratio }
                } label: {
                    Text(ratio.name)
                        .font(Theme.Typography.ui(Theme.Typography.control, selection == ratio ? .medium : .regular))
                        .monospacedDigit()
                        .foregroundStyle(S.label(selection == ratio, hovered: hovered == ratio))
                        .frame(maxWidth: .infinity)
                        .frame(height: S.segment)
                        .background {
                            if selection == ratio {
                                SegmentThumb().matchedGeometryEffect(id: "thumb", in: thumb)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { inside in hovered = inside ? ratio : (hovered == ratio ? nil : hovered) }
            }
        }
        .padding(S.padding)
        .background(SegmentTrack())
    }
}

/// Save and Copy: 32 tall, corners of 8; Save in ink, Copy on the grey track.
private struct StudioButton: View {
    let title: String
    let primary: Bool
    var progress: Double? = nil
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
        Button(action: action) {
            Text(title)
                .font(Theme.Typography.ui(Theme.Typography.body, .medium))
                .monospacedDigit()
                .foregroundStyle(primary ? Theme.Palette.paper : Theme.Palette.ink)
                .frame(maxWidth: primary ? .infinity : nil)
                .padding(.horizontal, Theme.Space.x4)
                .frame(height: 32)
                .background {
                    if primary {
                        ZStack(alignment: .leading) {
                            shape.fill(Theme.Palette.ink.opacity(hovering && enabled ? 0.86 : 1))
                            if let progress {
                                GeometryReader { geo in
                                    Rectangle()
                                        .fill(Theme.Palette.paper.opacity(0.16))
                                        .frame(width: geo.size.width * progress)
                                }
                                .clipShape(shape)
                            }
                        }
                    } else {
                        shape.fill(hovering && enabled ? Theme.Palette.fillHover : Theme.Palette.fill)
                    }
                }
                .opacity(enabled || progress != nil ? 1 : 0.45)
                .contentShape(shape)
        }
        .buttonStyle(PressStyle())
        .onHover { inside in withAnimation(Theme.Motion.hover) { hovering = inside } }
    }
}

/// See-through, the way image editors show it: soft grey squares.
private struct Checkerboard: View {
    var square: CGFloat = 8

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.Palette.paper))
            let columns = Int(ceil(size.width / square)), rows = Int(ceil(size.height / square))
            var path = Path()
            for row in 0..<rows {
                for column in 0..<columns where (row + column) % 2 == 0 {
                    path.addRect(CGRect(x: CGFloat(column) * square, y: CGFloat(row) * square, width: square, height: square))
                }
            }
            context.fill(path, with: .color(Theme.Palette.ink.opacity(0.06)))
        }
    }
}
