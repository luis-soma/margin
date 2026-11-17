import AppKit
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins

/// How a capture is dressed for export: a backdrop, room around it, rounded
/// corners, a shadow and the frame's shape. One look for screenshots and
/// recordings, kept between exports.
struct ExportStyle: Codable, Equatable {
    var backdrop: Backdrop = .mist
    /// With `.picture`: one of your own backgrounds (see `ExportBackgrounds`).
    var picture: String?
    /// 0 to 1: the room around the capture.
    var padding: Double = 0.45
    /// 0 to 1: how round the capture's corners are.
    var radius: Double = 0.3
    /// 0 to 1: how far the capture lifts off the backdrop.
    var shadow: Double = 0.5
    var ratio: Ratio = .auto
    /// With `.custom`: the frame's width to its height.
    var ratioWidth: Double = 3
    var ratioHeight: Double = 2

    // Recordings with a cursor path (made since the export studio came).
    /// Zoom in where you click, following the pointer.
    var zoom = true
    /// 0 to 1: how far in.
    var zoomAmount: Double = 0.4
    /// Draw a smooth cursor in place of the recorded one.
    var smoothCursor = true
    /// 0 to 1: the drawn cursor's size.
    var cursorSize: Double = 0.35
    /// A soft ripple where you click.
    var showClicks = true

    init() {}

    enum Backdrop: String, Codable, CaseIterable, Identifiable {
        case none, white, mist, graphite, ink, sand, sky, sage, rose, dusk, blur, picture

        var id: String { rawValue }

        var name: String {
            switch self {
            case .none: return "None"
            case .white: return "White"
            case .mist: return "Mist"
            case .graphite: return "Graphite"
            case .ink: return "Ink"
            case .sand: return "Sand"
            case .sky: return "Sky"
            case .sage: return "Sage"
            case .rose: return "Rose"
            case .dusk: return "Dusk"
            case .blur: return "From the capture"
            case .picture: return "Your picture"
            }
        }

        /// Top left to bottom right; the same twice for a solid.
        var colors: (Int, Int)? {
            switch self {
            case .white: return (0xFFFFFF, 0xFFFFFF)
            case .mist: return (0xF4F4F2, 0xE2E2DF)
            case .graphite: return (0x5C5C5C, 0x262626)
            case .ink: return (0x141414, 0x141414)
            case .sand: return (0xF2EADF, 0xD8C6AD)
            case .sky: return (0xE2ECF7, 0xA8C2E4)
            case .sage: return (0xE6EDE2, 0xB3C6AB)
            case .rose: return (0xF6E5E2, 0xDDB2AC)
            case .dusk: return (0x40455F, 0x181A28)
            case .none, .blur, .picture: return nil
            }
        }

        /// The built-in ones. A recording has no see-through: no "None" for it.
        static func available(video: Bool) -> [Backdrop] {
            allCases.filter { $0 != .picture && !(video && $0 == .none) }
        }
    }

    enum Ratio: String, Codable, CaseIterable, Identifiable {
        case auto, wide, classic, square, custom

        var id: String { rawValue }
        var name: String {
            switch self {
            case .auto: return "Auto"
            case .wide: return "16:9"
            case .classic: return "4:3"
            case .square: return "1:1"
            case .custom: return "Custom"
            }
        }
    }

    /// The frame's width over its height, or nil to follow the capture.
    var ratioValue: CGFloat? {
        switch ratio {
        case .auto: return nil
        case .wide: return 16.0 / 9
        case .classic: return 4.0 / 3
        case .square: return 1
        case .custom:
            guard ratioWidth > 0, ratioHeight > 0 else { return nil }
            return CGFloat(min(max(ratioWidth / ratioHeight, 0.1), 10))
        }
    }

    // Older saved styles lack the newer settings: those take their defaults.
    private enum CodingKeys: String, CodingKey {
        case backdrop, picture, padding, radius, shadow, ratio, ratioWidth, ratioHeight
        case zoom, zoomAmount, smoothCursor, cursorSize, showClicks
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = ExportStyle()
        backdrop = (try? c.decodeIfPresent(Backdrop.self, forKey: .backdrop)) ?? fallback.backdrop
        picture = try? c.decodeIfPresent(String.self, forKey: .picture)
        padding = (try? c.decodeIfPresent(Double.self, forKey: .padding)) ?? fallback.padding
        radius = (try? c.decodeIfPresent(Double.self, forKey: .radius)) ?? fallback.radius
        shadow = (try? c.decodeIfPresent(Double.self, forKey: .shadow)) ?? fallback.shadow
        ratio = (try? c.decodeIfPresent(Ratio.self, forKey: .ratio)) ?? fallback.ratio
        ratioWidth = (try? c.decodeIfPresent(Double.self, forKey: .ratioWidth)) ?? fallback.ratioWidth
        ratioHeight = (try? c.decodeIfPresent(Double.self, forKey: .ratioHeight)) ?? fallback.ratioHeight
        zoom = (try? c.decodeIfPresent(Bool.self, forKey: .zoom)) ?? fallback.zoom
        zoomAmount = (try? c.decodeIfPresent(Double.self, forKey: .zoomAmount)) ?? fallback.zoomAmount
        smoothCursor = (try? c.decodeIfPresent(Bool.self, forKey: .smoothCursor)) ?? fallback.smoothCursor
        cursorSize = (try? c.decodeIfPresent(Double.self, forKey: .cursorSize)) ?? fallback.cursorSize
        showClicks = (try? c.decodeIfPresent(Bool.self, forKey: .showClicks)) ?? fallback.showClicks
        if backdrop == .picture, picture.map(ExportBackgrounds.exists) != true { backdrop = fallback.backdrop }
    }

    // MARK: Kept between exports

    private static let key = "exportStyle"

    static var saved: ExportStyle {
        get {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let style = try? JSONDecoder().decode(ExportStyle.self, from: data) else { return ExportStyle() }
            return style
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(data, forKey: key) }
        }
    }
}

/// Your own backgrounds: pictures you add in the export studio, copied into
/// Margin's support folder so they stay put.
enum ExportBackgrounds {
    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Margin/Backgrounds", isDirectory: true)
    }

    static func url(_ name: String) -> URL { folder.appendingPathComponent(name) }

    static func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: url(name).path) }

    /// The pictures, oldest first.
    static func all() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])) ?? []
        return files
            .sorted { ((try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) < ((try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) }
            .map(\.lastPathComponent)
    }

    /// Copies a picture in; its new name.
    static func add(_ source: URL) -> String? {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ext = source.pathExtension.isEmpty ? "png" : source.pathExtension.lowercased()
        let name = UUID().uuidString.prefix(8) + "." + ext
        do {
            try FileManager.default.copyItem(at: source, to: url(String(name)))
            return String(name)
        } catch {
            return nil
        }
    }

    static func remove(_ name: String) {
        try? FileManager.default.removeItem(at: url(name))
        ExportRenderer.forget(name)
    }
}

/// Draws a capture in its export style with Core Image: the live preview and
/// the exported file come from the same code, so what you see is what you get.
enum ExportRenderer {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    static let context = CIContext(options: [.workingColorSpace: sRGB, .cacheIntermediates: false])

    /// Where things go: the whole picture, the capture inside it, its corners.
    struct Layout {
        var canvas: CGSize
        var frame: CGRect
        var radius: CGFloat
        /// A length that grows with the capture, so the look holds at any size.
        var unit: CGFloat
    }

    static func layout(for size: CGSize, style: ExportStyle) -> Layout {
        let unit = sqrt(max(size.width, 1) * max(size.height, 1))
        let pad = CGFloat(style.padding) * 0.18 * unit
        var canvas = CGSize(width: size.width + 2 * pad, height: size.height + 2 * pad)
        if let ratio = style.ratioValue {
            if canvas.width / canvas.height < ratio {
                canvas.width = canvas.height * ratio
            } else {
                canvas.height = canvas.width / ratio
            }
        }
        canvas = CGSize(width: canvas.width.rounded(), height: canvas.height.rounded())
        let frame = CGRect(x: ((canvas.width - size.width) / 2).rounded(),
                           y: ((canvas.height - size.height) / 2).rounded(),
                           width: size.width, height: size.height)
        return Layout(canvas: canvas, frame: frame, radius: CGFloat(style.radius) * 0.05 * unit, unit: unit)
    }

    /// The capture `content` in `style`, with its origin at zero.
    static func render(_ content: CIImage, style: ExportStyle) -> CIImage {
        let image = content.transformed(by: CGAffineTransform(translationX: -content.extent.minX, y: -content.extent.minY))
        let layout = layout(for: image.extent.size, style: style)
        let bounds = CGRect(origin: .zero, size: layout.canvas)
        let clear = CIImage(color: .clear).cropped(to: bounds)

        // The capture's shape, rounded or not.
        let shape: CIImage
        if layout.radius >= 0.5 {
            let rounded = CIFilter.roundedRectangleGenerator()
            rounded.extent = layout.frame
            rounded.radius = Float(min(layout.radius, min(layout.frame.width, layout.frame.height) / 2))
            rounded.color = .white
            shape = rounded.outputImage?.cropped(to: layout.frame) ?? CIImage(color: .white).cropped(to: layout.frame)
        } else {
            shape = CIImage(color: .white).cropped(to: layout.frame)
        }

        let placed = image.transformed(by: CGAffineTransform(translationX: layout.frame.minX, y: layout.frame.minY))
        let blend = CIFilter.blendWithMask()
        blend.inputImage = placed
        blend.backgroundImage = clear
        blend.maskImage = shape
        let capture = (blend.outputImage ?? placed).cropped(to: bounds)

        var result = backdrop(style, bounds: bounds, capture: image)
        if style.shadow > 0.01 {
            let s = CGFloat(style.shadow)
            // A soft, wide shadow under a close one, the way a card lifts.
            let wide = shadow(of: shape, alpha: 0.10 + 0.22 * s, blur: (0.008 + 0.03 * s) * layout.unit, drop: 0.012 * s * layout.unit)
            let close = shadow(of: shape, alpha: 0.06 + 0.08 * s, blur: 0.003 * layout.unit, drop: 0.002 * layout.unit)
            result = close.composited(over: wide.composited(over: result))
        }
        return capture.composited(over: result).cropped(to: bounds)
    }

    private static func shadow(of shape: CIImage, alpha: CGFloat, blur: CGFloat, drop: CGFloat) -> CIImage {
        let black = shape.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        ])
        return black
            .applyingGaussianBlur(sigma: max(blur, 0.1))
            .transformed(by: CGAffineTransform(translationX: 0, y: -drop))
    }

    private static func backdrop(_ style: ExportStyle, bounds: CGRect, capture: CIImage) -> CIImage {
        switch style.backdrop {
        case .none:
            return CIImage(color: .clear).cropped(to: bounds)
        case .blur:
            // The capture itself, filling the frame, softly out of focus.
            return covering(bounds, with: capture, zoom: 1.15)
                .clampedToExtent()
                .applyingGaussianBlur(sigma: 0.07 * max(bounds.width, bounds.height))
                .applyingFilter("CIColorControls", parameters: ["inputSaturation": 1.2, "inputBrightness": 0.02])
                .cropped(to: bounds)
        case .picture:
            // Your own picture, filling the frame, its middle kept.
            guard let name = style.picture, let picture = backgroundPicture(name) else {
                return CIImage(color: .white).cropped(to: bounds)
            }
            return covering(bounds, with: picture, zoom: 1).clampedToExtent().cropped(to: bounds)
        default:
            guard let pair = style.backdrop.colors else { return CIImage(color: .white).cropped(to: bounds) }
            let (from, to) = pair
            if from == to { return CIImage(color: ciColor(from)).cropped(to: bounds) }
            let gradient = CIFilter.linearGradient()
            gradient.point0 = CGPoint(x: bounds.minX, y: bounds.maxY)
            gradient.point1 = CGPoint(x: bounds.maxX, y: bounds.minY)
            gradient.color0 = ciColor(from)
            gradient.color1 = ciColor(to)
            return (gradient.outputImage ?? CIImage(color: ciColor(from))).cropped(to: bounds)
        }
    }

    /// `image` scaled to cover `bounds` (times `zoom`), centred on it.
    private static func covering(_ bounds: CGRect, with image: CIImage, zoom: CGFloat) -> CIImage {
        let size = image.extent.size
        let scale = max(bounds.width / max(size.width, 1), bounds.height / max(size.height, 1)) * zoom
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return scaled.transformed(by: CGAffineTransform(
            translationX: bounds.midX - scaled.extent.midX,
            y: bounds.midY - scaled.extent.midY))
    }

    // Your backgrounds, read once.
    private static var pictures: [String: CIImage] = [:]
    private static let picturesLock = NSLock()

    static func backgroundPicture(_ name: String) -> CIImage? {
        picturesLock.lock()
        defer { picturesLock.unlock() }
        if let cached = pictures[name] { return cached }
        guard let image = picture(at: ExportBackgrounds.url(name)) else { return nil }
        // Big enough for a 4K frame; smaller is quicker to fill with.
        let fitted = downsized(image, longest: 4096)
        pictures[name] = fitted
        return fitted
    }

    static func forget(_ name: String) {
        picturesLock.lock()
        pictures[name] = nil
        picturesLock.unlock()
    }

    static func ciColor(_ hex: Int) -> CIColor {
        CIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1, colorSpace: sRGB) ?? .white
    }

    static func color(_ hex: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    // MARK: Pictures

    /// The capture's picture, upright.
    static func picture(at url: URL) -> CIImage? {
        CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
    }

    /// A moment of a recording, for the preview.
    static func poster(of url: URL, at seconds: Double = 0.4) async -> CIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 60)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 60)
        guard let image = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image else { return nil }
        return CIImage(cgImage: image)
    }

    /// `content` made small enough to restyle on every slider move.
    static func downsized(_ content: CIImage, longest: CGFloat) -> CIImage {
        let size = content.extent.size
        let scale = min(1, longest / max(size.width, size.height, 1))
        guard scale < 1 else { return content }
        return content.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
    }

    static func cgImage(_ image: CIImage) -> CGImage? {
        context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: sRGB)
    }

    /// The styled picture as a PNG at the capture's own resolution: lossless,
    /// without the see-through channel when nothing is see-through, which
    /// makes the file about a quarter smaller.
    static func png(_ content: CIImage, style: ExportStyle) -> Data? {
        let styled = render(content, style: style)
        guard var image = cgImage(styled) else { return nil }
        if style.backdrop != .none,
           let opaque = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
            opaque.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            if let flat = opaque.makeImage() { image = flat }
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    // MARK: Recordings

    enum VideoError: LocalizedError {
        case noVideo, cantExport(String)
        var errorDescription: String? {
            switch self {
            case .noVideo: return "There's no video in this recording."
            case .cantExport(let why): return "Couldn't export: \(why)"
            }
        }
    }

    /// A bitrate that keeps screen work crisp without waste: about 0.045 bits
    /// a pixel a frame, between 2 and 10 Mbit/s. Screens are mostly still,
    /// so H.264 spends it where things move.
    static func videoBitrate(_ size: CGSize, fps: Double) -> Int {
        let bits = size.width * size.height * CGFloat(min(max(fps, 24), 60)) * 0.045
        return Int(min(max(bits, 2_000_000), 10_000_000))
    }

    /// The recording in `style`, every frame, as an .mp4 at `output`: H.264
    /// High at a bitrate chosen for screens (much smaller than the system's
    /// "highest quality" export at no visible cost), sound as AAC. Kept
    /// within 4K so every player opens it.
    static func exportVideo(from url: URL, style: ExportStyle, motion: (plan: MotionPlan, drawCursor: Bool)? = nil, to output: URL,
                            progress: @escaping @MainActor (Double) -> Void) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw VideoError.noVideo }
        let (natural, transform, frameRate) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let duration = try await asset.load(.duration).seconds
        let upright = natural.applying(transform)
        let size = CGSize(width: abs(upright.width), height: abs(upright.height))

        let full = layout(for: size, style: style)
        let fit = min(1, 3840 / max(full.canvas.width, full.canvas.height))
        let scaled = CGSize(width: size.width * fit, height: size.height * fit)
        let canvas = layout(for: scaled, style: style).canvas
        let renderSize = CGSize(width: floor(canvas.width / 2) * 2, height: floor(canvas.height / 2) * 2)
        let crop = CGRect(origin: .zero, size: renderSize)

        let composition = AVMutableVideoComposition(asset: asset) { request in
            var source = request.sourceImage
            source = source.transformed(by: CGAffineTransform(translationX: -source.extent.minX, y: -source.extent.minY))
            if let motion {
                source = moving(source, at: request.compositionTime.seconds, plan: motion.plan, style: style, drawCursor: motion.drawCursor)
            }
            let frame = source.transformed(by: CGAffineTransform(scaleX: fit, y: fit))
            request.finish(with: render(frame, style: style).cropped(to: crop), context: context)
        }
        composition.renderSize = renderSize

        try? FileManager.default.removeItem(at: output)
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        let videoOut = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        videoOut.videoComposition = composition
        videoOut.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOut) else { throw VideoError.cantExport("the frames can't be read") }
        reader.add(videoOut)

        let fps = Double(frameRate > 0 ? frameRate : 30)
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(renderSize.width),
            AVVideoHeightKey: Int(renderSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: videoBitrate(renderSize, fps: fps),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoH264EntropyModeKey: AVVideoH264EntropyModeCABAC,
                AVVideoAllowFrameReorderingKey: true,
                AVVideoMaxKeyFrameIntervalDurationKey: 4,
                AVVideoExpectedSourceFrameRateKey: Int(min(fps, 60).rounded()),
            ] as [String: Any],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ])
        videoIn.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoIn) else { throw VideoError.cantExport("the video can't be written") }
        writer.add(videoIn)

        // The sound, if there is any, as AAC.
        var audio: (source: AVAssetReaderTrackOutput, sink: AVAssetWriterInput)?
        if let sound = try await asset.loadTracks(withMediaType: .audio).first {
            let description = try await sound.load(.formatDescriptions).first
            let basic = description.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
            let rate = basic.map { $0.mSampleRate > 0 ? $0.mSampleRate : 48_000 } ?? 48_000
            let channels = min(max(Int(basic?.mChannelsPerFrame ?? 2), 1), 2)
            let out = AVAssetReaderTrackOutput(track: sound, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: rate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: channels == 1 ? 96_000 : 128_000,
            ])
            input.expectsMediaDataInRealTime = false
            if reader.canAdd(out), writer.canAdd(input) {
                reader.add(out)
                writer.add(input)
                audio = (source: out, sink: input)
            }
        }

        guard reader.startReading() else {
            throw VideoError.cantExport(reader.error?.localizedDescription ?? "the recording can't be read")
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw VideoError.cantExport(writer.error?.localizedDescription ?? "the file can't be written")
        }
        writer.startSession(atSourceTime: .zero)

        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let group = DispatchGroup()
            let total = max(duration, 0.1)
            var reported = -1.0

            group.enter()
            var videoDone = false
            videoIn.requestMediaDataWhenReady(on: DispatchQueue(label: "margin.export.video")) {
                while videoIn.isReadyForMoreMediaData, !videoDone {
                    guard let sample = videoOut.copyNextSampleBuffer() else {
                        videoDone = true
                        videoIn.markAsFinished()
                        group.leave()
                        return
                    }
                    let seconds = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                    if !videoIn.append(sample) {
                        videoDone = true
                        reader.cancelReading()
                        videoIn.markAsFinished()
                        group.leave()
                        return
                    }
                    if seconds - reported >= 0.2 {
                        reported = seconds
                        let share = min(seconds / total, 0.99)
                        Task { @MainActor in progress(share) }
                    }
                }
            }

            if let audio {
                group.enter()
                var audioDone = false
                audio.sink.requestMediaDataWhenReady(on: DispatchQueue(label: "margin.export.audio")) {
                    while audio.sink.isReadyForMoreMediaData, !audioDone {
                        guard let sample = audio.source.copyNextSampleBuffer(), audio.sink.append(sample) else {
                            audioDone = true
                            audio.sink.markAsFinished()
                            group.leave()
                            return
                        }
                    }
                }
            }

            group.notify(queue: .global()) {
                if reader.status == .failed || writer.status == .failed {
                    writer.cancelWriting()
                    done.resume()
                } else {
                    writer.finishWriting { done.resume() }
                }
            }
        }

        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: output)
            throw VideoError.cantExport(writer.error?.localizedDescription ?? reader.error?.localizedDescription ?? "the export stopped")
        }
        await progress(1)
    }
}
