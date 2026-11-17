import AppKit
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins

/// How a capture is dressed for export: a backdrop, room around it, rounded
/// corners, a shadow and the frame's shape. One look for screenshots and
/// recordings, kept between exports.
struct ExportStyle: Codable, Equatable {
    var backdrop: Backdrop = .mist
    /// 0 to 1: the room around the capture.
    var padding: Double = 0.45
    /// 0 to 1: how round the capture's corners are.
    var radius: Double = 0.3
    /// 0 to 1: how far the capture lifts off the backdrop.
    var shadow: Double = 0.5
    var ratio: Ratio = .auto

    enum Backdrop: String, Codable, CaseIterable, Identifiable {
        case none, white, mist, graphite, ink, sand, sky, sage, rose, dusk, blur

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
            case .none, .blur: return nil
            }
        }

        /// A recording has no see-through: no "None" for it.
        static func available(video: Bool) -> [Backdrop] {
            video ? allCases.filter { $0 != .none } : allCases
        }
    }

    enum Ratio: String, Codable, CaseIterable, Identifiable {
        case auto, wide, classic, square

        var id: String { rawValue }
        var name: String {
            switch self {
            case .auto: return "Auto"
            case .wide: return "16:9"
            case .classic: return "4:3"
            case .square: return "1:1"
            }
        }
        var value: CGFloat? {
            switch self {
            case .auto: return nil
            case .wide: return 16.0 / 9
            case .classic: return 4.0 / 3
            case .square: return 1
            }
        }
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
        if let ratio = style.ratio.value {
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

        var result = backdrop(style.backdrop, bounds: bounds, capture: image, unit: layout.unit)
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

    private static func backdrop(_ backdrop: ExportStyle.Backdrop, bounds: CGRect, capture: CIImage, unit: CGFloat) -> CIImage {
        switch backdrop {
        case .none:
            return CIImage(color: .clear).cropped(to: bounds)
        case .blur:
            // The capture itself, filling the frame, softly out of focus.
            let size = capture.extent.size
            let scale = max(bounds.width / max(size.width, 1), bounds.height / max(size.height, 1)) * 1.15
            let scaled = capture.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let centered = scaled.transformed(by: CGAffineTransform(
                translationX: (bounds.width - scaled.extent.width) / 2 - scaled.extent.minX,
                y: (bounds.height - scaled.extent.height) / 2 - scaled.extent.minY))
            return centered
                .clampedToExtent()
                .applyingGaussianBlur(sigma: 0.07 * max(bounds.width, bounds.height))
                .applyingFilter("CIColorControls", parameters: ["inputSaturation": 1.2, "inputBrightness": 0.02])
                .cropped(to: bounds)
        default:
            guard let pair = backdrop.colors else { return CIImage(color: .white).cropped(to: bounds) }
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

    /// The first moment of a recording, for the preview.
    static func poster(of url: URL) async -> CIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        guard let image = try? await generator.image(at: CMTime(seconds: 0.4, preferredTimescale: 600)).image else { return nil }
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

    /// The styled picture as a PNG, at the capture's own resolution.
    static func png(_ content: CIImage, style: ExportStyle) -> Data? {
        let styled = render(content, style: style)
        return context.pngRepresentation(of: styled, format: .RGBA8, colorSpace: sRGB)
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

    /// The recording in `style`, every frame, as an .mp4 at `output`. Kept
    /// within 4K so every player opens it.
    static func exportVideo(from url: URL, style: ExportStyle, to output: URL,
                            progress: @escaping @MainActor (Double) -> Void) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw VideoError.noVideo }
        let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
        let upright = natural.applying(transform)
        let size = CGSize(width: abs(upright.width), height: abs(upright.height))

        let full = layout(for: size, style: style)
        let fit = min(1, 3840 / max(full.canvas.width, full.canvas.height))
        let scaled = CGSize(width: size.width * fit, height: size.height * fit)
        let canvas = layout(for: scaled, style: style).canvas
        let renderSize = CGSize(width: floor(canvas.width / 2) * 2, height: floor(canvas.height / 2) * 2)
        let crop = CGRect(origin: .zero, size: renderSize)

        let composition = AVMutableVideoComposition(asset: asset) { request in
            let frame = request.sourceImage.transformed(by: CGAffineTransform(scaleX: fit, y: fit))
            request.finish(with: render(frame, style: style).cropped(to: crop), context: context)
        }
        composition.renderSize = renderSize

        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw VideoError.cantExport("this recording can't be re-encoded")
        }
        try? FileManager.default.removeItem(at: output)
        session.outputURL = output
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        session.videoComposition = composition

        let watcher = Task { @MainActor in
            while !Task.isCancelled {
                progress(Double(session.progress))
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { done.resume() }
        }
        watcher.cancel()
        guard session.status == .completed else {
            throw VideoError.cantExport(session.error?.localizedDescription ?? "the export stopped")
        }
        await progress(1)
    }
}
