import AppKit
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins

/// How a capture is dressed for export: a backdrop, room around it, rounded
/// corners, a shadow and the frame's shape. One look for screenshots and
/// recordings, kept between exports.
struct ExportStyle: Codable, Equatable {
    var backdrop: Backdrop = .paper
    /// With `.picture`: one of your own backgrounds (see `ExportBackgrounds`).
    var picture: String?
    /// 0 to 1: the room around the capture.
    var padding: Double = 0.45
    /// 0 to 1: how round the capture's corners are.
    var radius: Double = 0.3
    /// 0 to 1: how dark the shadow under the capture is.
    var shadow: Double = 0.5
    /// 0 to 1: how far the shadow spreads, crisp to very soft.
    var shadowSoftness: Double = 0.5
    /// 0 to 1: how far below the capture it falls.
    var shadowDistance: Double = 0.5
    /// With `.color`: the flat colour, as 0xRRGGBB.
    var color: Int = 0xEBEBEB
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
        // Soft light, like a photo out of focus.
        case paper, fog, dawn, silver, dusk, smoke, cobalt, aurora
        // Plain.
        case white, mist, ink
        /// One flat colour of your choosing.
        case color
        case blur, none, picture

        var id: String { rawValue }

        var name: String {
            switch self {
            case .paper: return "Paper"
            case .fog: return "Fog"
            case .dawn: return "Dawn"
            case .silver: return "Silver"
            case .dusk: return "Dusk"
            case .smoke: return "Smoke"
            case .cobalt: return "Cobalt"
            case .aurora: return "Aurora"
            case .white: return "White"
            case .mist: return "Mist"
            case .ink: return "Ink"
            case .color: return "Color"
            case .blur: return "From the capture"
            case .none: return "None"
            case .picture: return "Your picture"
            }
        }

        /// The plain ones: top left to bottom right.
        var colors: (Int, Int)? {
            switch self {
            case .white: return (0xFFFFFF, 0xFFFFFF)
            case .mist: return (0xF4F4F2, 0xE4E4E1)
            case .ink: return (0x161616, 0x0E0E0E)
            default: return nil
            }
        }

        var textured: Bool { Texture.of(self) != nil }

        /// The built-in ones, in order. A recording has no see-through.
        static func available(video: Bool) -> [Backdrop] {
            allCases.filter { $0 != .picture && !(video && $0 == .none) }
        }
    }

    /// A textured backdrop: a top-to-bottom wash, soft light laid over it,
    /// blurred, then the faintest dither so it stays smooth.
    struct Texture {
        struct Light {
            /// 0 to 1 from the top left.
            var x: CGFloat
            var y: CGFloat
            /// Of the longer side.
            var radius: CGFloat
            var color: Int
            var alpha: CGFloat
            /// Width and height of the light, stretched.
            var stretch: (CGFloat, CGFloat) = (1, 1)
            /// Degrees.
            var angle: CGFloat = 0
        }

        var top: Int
        var bottom: Int
        var lights: [Light]
        var grain: CGFloat = 0.008

        static func of(_ backdrop: Backdrop) -> Texture? {
            switch backdrop {
            case .paper:
                return Texture(top: 0xF7F6F3, bottom: 0xE8E6E1, lights: [
                    Light(x: 0.72, y: 0.22, radius: 0.55, color: 0xFFFFFF, alpha: 0.8, stretch: (1.6, 0.9), angle: -15),
                    Light(x: 0.2, y: 0.9, radius: 0.45, color: 0xDCD8D0, alpha: 0.6),
                ])
            case .fog:
                return Texture(top: 0xEEF1F3, bottom: 0x0B1420, lights: [
                    Light(x: 0.5, y: 0.5, radius: 0.55, color: 0x8FA7B7, alpha: 0.85, stretch: (2.6, 0.55)),
                    Light(x: 0.5, y: 0.08, radius: 0.5, color: 0xF6F8F9, alpha: 0.7, stretch: (2.2, 0.6)),
                ])
            case .dawn:
                return Texture(top: 0xF4ECE4, bottom: 0xB6C1D1, lights: [
                    Light(x: 0.28, y: 0.72, radius: 0.45, color: 0xE9CBB6, alpha: 0.65, stretch: (1.8, 0.8), angle: 12),
                    Light(x: 0.78, y: 0.25, radius: 0.4, color: 0xFFFFFF, alpha: 0.6),
                ])
            case .silver:
                return Texture(top: 0x2C2E30, bottom: 0x141516, lights: [
                    Light(x: 0.42, y: 0.62, radius: 0.48, color: 0xE4E6E8, alpha: 0.75, stretch: (1.7, 0.85), angle: -28),
                    Light(x: 0.85, y: 0.15, radius: 0.35, color: 0x55595D, alpha: 0.6),
                ])
            case .dusk:
                return Texture(top: 0xC8CFDA, bottom: 0x1C2638, lights: [
                    Light(x: 0.3, y: 0.32, radius: 0.38, color: 0xF3F5F8, alpha: 0.65, stretch: (1.9, 0.6), angle: -8),
                    Light(x: 0.72, y: 0.7, radius: 0.42, color: 0x0D1524, alpha: 0.75, stretch: (1.6, 0.8)),
                ])
            case .smoke:
                return Texture(top: 0x0B0B0B, bottom: 0x1B1B1B, lights: [
                    Light(x: 0.6, y: 0.38, radius: 0.45, color: 0xD9D9D9, alpha: 0.8, stretch: (2.3, 0.32), angle: -35),
                    Light(x: 0.24, y: 0.82, radius: 0.32, color: 0xF1EEE6, alpha: 0.55, stretch: (1.7, 0.55), angle: 22),
                ])
            case .cobalt:
                return Texture(top: 0x2F60CC, bottom: 0x0A1120, lights: [
                    Light(x: 0.26, y: 0.3, radius: 0.42, color: 0x79A2EC, alpha: 0.7, stretch: (2.1, 0.6), angle: 18),
                    Light(x: 0.82, y: 0.88, radius: 0.5, color: 0x04070D, alpha: 0.9, stretch: (1.8, 0.9), angle: 25),
                ])
            case .aurora:
                return Texture(top: 0x4A4038, bottom: 0x0E1420, lights: [
                    Light(x: 0.35, y: 0.32, radius: 0.36, color: 0x8C7B67, alpha: 0.7),
                    Light(x: 0.74, y: 0.45, radius: 0.28, color: 0x5A8FE0, alpha: 0.7, stretch: (0.6, 2.0), angle: 10),
                    Light(x: 0.4, y: 0.84, radius: 0.32, color: 0xE8904A, alpha: 0.5, stretch: (2.0, 0.5), angle: 8),
                    Light(x: 0.58, y: 0.66, radius: 0.24, color: 0xE9E3D7, alpha: 0.4),
                ])
            default:
                return nil
            }
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
        case backdrop, picture, padding, radius, shadow, shadowSoftness, shadowDistance, color, ratio, ratioWidth, ratioHeight
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
        shadowSoftness = (try? c.decodeIfPresent(Double.self, forKey: .shadowSoftness)) ?? fallback.shadowSoftness
        shadowDistance = (try? c.decodeIfPresent(Double.self, forKey: .shadowDistance)) ?? fallback.shadowDistance
        color = (try? c.decodeIfPresent(Int.self, forKey: .color)) ?? fallback.color
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
        if style.shadow > 0.005 {
            // A soft, wide shadow under a close one, the way a card lifts.
            // Strength goes all the way down to barely there; softness
            // spreads the wide one; distance moves it down.
            let s = CGFloat(style.shadow)
            let soft = CGFloat(style.shadowSoftness), far = CGFloat(style.shadowDistance)
            let wide = shadow(of: shape, alpha: 0.42 * s, blur: (0.004 + 0.06 * soft * soft + 0.02 * soft) * layout.unit,
                              drop: 0.024 * far * layout.unit)
            let close = shadow(of: shape, alpha: 0.2 * s * (1 - 0.4 * soft), blur: 0.003 * layout.unit,
                               drop: 0.004 * far * layout.unit)
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
        case .color:
            return CIImage(color: ciColor(style.color)).cropped(to: bounds)
        case .picture:
            // Your own picture, filling the frame, its middle kept.
            guard let name = style.picture, let picture = backgroundPicture(name) else {
                return CIImage(color: .white).cropped(to: bounds)
            }
            return covering(bounds, with: picture, zoom: 1).clampedToExtent().cropped(to: bounds)
        default:
            if let texture = ExportStyle.Texture.of(style.backdrop) {
                return textured(style.backdrop, texture, size: bounds.size)
            }
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

    // Textured backdrops are drawn once per size and kept: a recording asks
    // for the same one every frame.
    private static var textures: [String: CIImage] = [:]
    private static let texturesLock = NSLock()

    private static func textured(_ backdrop: ExportStyle.Backdrop, _ texture: ExportStyle.Texture, size: CGSize) -> CIImage {
        let key = "\(backdrop.rawValue)|\(Int(size.width))x\(Int(size.height))"
        texturesLock.lock()
        if let cached = textures[key] {
            texturesLock.unlock()
            return cached
        }
        texturesLock.unlock()
        let drawn = drawTexture(texture, size: size)
        let image = cgImage(drawn).map { CIImage(cgImage: $0) } ?? drawn
        texturesLock.lock()
        if textures.count > 24 { textures.removeAll() }
        textures[key] = image
        texturesLock.unlock()
        return image
    }

    /// A texture at `size`, origin zero.
    static func drawTexture(_ texture: ExportStyle.Texture, size: CGSize) -> CIImage {
        let bounds = CGRect(origin: .zero, size: size)
        let longest = max(size.width, size.height)
        let wash = CIFilter.linearGradient()
        wash.point0 = CGPoint(x: 0, y: size.height)
        wash.point1 = CGPoint(x: 0, y: 0)
        wash.color0 = ciColor(texture.top)
        wash.color1 = ciColor(texture.bottom)
        var image = (wash.outputImage ?? CIImage(color: ciColor(texture.top))).cropped(to: bounds)

        for light in texture.lights {
            let radius = light.radius * longest
            let glow = CIFilter.radialGradient()
            glow.center = .zero
            glow.radius0 = 0
            glow.radius1 = Float(radius)
            let color = ciColor(light.color)
            glow.color0 = CIColor(red: color.red, green: color.green, blue: color.blue, alpha: light.alpha)
            glow.color1 = CIColor(red: color.red, green: color.green, blue: color.blue, alpha: 0)
            let shaped = (glow.outputImage ?? CIImage.empty())
                .cropped(to: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2))
                .transformed(by: CGAffineTransform(scaleX: light.stretch.0, y: light.stretch.1)
                    .concatenating(CGAffineTransform(rotationAngle: light.angle * .pi / 180))
                    .concatenating(CGAffineTransform(translationX: light.x * size.width, y: (1 - light.y) * size.height)))
            image = shaped.composited(over: image)
        }
        // Soft all over, as if out of focus.
        image = image.clampedToExtent().applyingGaussianBlur(sigma: 0.06 * longest).cropped(to: bounds)

        // The faintest dither, a step or two of 255: no visible grain, but
        // the soft gradients don't band, not even in a GIF or an MP4.
        let amount = texture.grain
        let shifted = image.applyingFilter("CIColorMatrix", parameters: [
            "inputBiasVector": CIVector(x: -amount / 2, y: -amount / 2, z: -amount / 2, w: 0),
        ])
        if let noise = CIFilter.randomGenerator().outputImage?
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: amount, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: amount, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: amount, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            ]) {
            image = noise.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: shifted]).cropped(to: bounds)
        }
        return image
    }

    /// A small picture of a backdrop, for its swatch.
    static func swatch(_ backdrop: ExportStyle.Backdrop, size: CGSize) -> CGImage? {
        guard let texture = ExportStyle.Texture.of(backdrop) else { return nil }
        return cgImage(drawTexture(texture, size: size))
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

    /// What a recording export needs beyond the style: the motion plan (if
    /// the recording has a cursor path), whether to draw the cursor, and the
    /// crop (0 to 1, top-left origin).
    struct VideoSetup {
        var plan: MotionPlan?
        var drawCursor = false
        var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
        /// Trims, cuts, speeds and zooms; nil when there are none.
        var edit: ClipEdit?
        /// Export seconds to recording seconds, when the edit changes time.
        var map: TimeMap?
    }

    /// The crop as pixels in Core Image's frame (bottom-left origin).
    static func cropRect(_ crop: CGRect, in size: CGSize) -> CGRect {
        CGRect(x: (crop.minX * size.width).rounded(), y: ((1 - crop.maxY) * size.height).rounded(),
               width: max((crop.width * size.width).rounded(), 2), height: max((crop.height * size.height).rounded(), 2))
    }

    /// `image` (origin zero) cut to `crop`, back at origin zero.
    static func cropped(_ image: CIImage, to crop: CGRect) -> CIImage {
        guard crop != CGRect(x: 0, y: 0, width: 1, height: 1) else { return image }
        let rect = cropRect(crop, in: image.extent.size)
        return image.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
    }

    /// One frame of a recording, all the way: motion and crop, scaled by
    /// `fit`, on its backdrop.
    static func videoFrame(_ source: CIImage, at t: Double, style: ExportStyle, setup: VideoSetup, fit: CGFloat) -> CIImage {
        var image = source.transformed(by: CGAffineTransform(translationX: -source.extent.minX, y: -source.extent.minY))
        let s = setup.map?.source(at: t) ?? t
        let framing = setup.edit?.framing(at: s)
        if setup.plan != nil || framing != nil {
            image = moving(image, at: s, plan: setup.plan, style: style, drawCursor: setup.drawCursor, crop: setup.crop, framing: framing)
        } else {
            image = cropped(image, to: setup.crop)
        }
        if fit < 0.999 {
            image = image.transformed(by: CGAffineTransform(scaleX: fit, y: fit))
        }
        return render(image, style: style)
    }

    /// The recording's frames in `style`, at most `longest` pixels on the
    /// longer side (even, for the encoders): for the preview and every export.
    static func composition(for asset: AVAsset, style: ExportStyle, setup: VideoSetup, longest: CGFloat,
                            frameDuration: CMTime? = nil) async throws -> AVMutableVideoComposition {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw VideoError.noVideo }
        let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
        let upright = natural.applying(transform)
        let full = CGSize(width: abs(upright.width), height: abs(upright.height))
        let size = cropRect(setup.crop, in: full).size
        let canvas = layout(for: size, style: style).canvas
        let fit = min(1, longest / max(canvas.width, canvas.height))
        let scaledCanvas = layout(for: CGSize(width: size.width * fit, height: size.height * fit), style: style).canvas
        let renderSize = CGSize(width: max(floor(scaledCanvas.width / 2) * 2, 2), height: max(floor(scaledCanvas.height / 2) * 2, 2))
        let bounds = CGRect(origin: .zero, size: renderSize)

        let composition = AVMutableVideoComposition(asset: asset) { request in
            let frame = videoFrame(request.sourceImage, at: request.compositionTime.seconds, style: style, setup: setup, fit: fit)
            request.finish(with: frame.cropped(to: bounds), context: context)
        }
        composition.renderSize = renderSize
        if let frameDuration {
            composition.frameDuration = frameDuration
        } else if setup.edit != nil {
            // Zooms and speed changes move between the recording's frames.
            composition.frameDuration = CMTime(value: 1, timescale: 60)
        }
        return composition
    }

    /// The exported size for a recording of `full` pixels.
    static func videoSize(for full: CGSize, style: ExportStyle, crop: CGRect, longest: CGFloat) -> CGSize {
        let size = cropRect(crop, in: full).size
        let canvas = layout(for: size, style: style).canvas
        let fit = min(1, longest / max(canvas.width, canvas.height))
        let scaled = layout(for: CGSize(width: size.width * fit, height: size.height * fit), style: style).canvas
        return CGSize(width: floor(scaled.width / 2) * 2, height: floor(scaled.height / 2) * 2)
    }

    /// The recording in `style`, every frame, as an .mp4 at `output`: H.264
    /// High at a bitrate chosen for screens (much smaller than the system's
    /// "highest quality" export at no visible cost), sound as AAC. Kept
    /// within 4K so every player opens it.
    static func exportVideo(from url: URL, style: ExportStyle, setup: VideoSetup = VideoSetup(), to output: URL,
                            progress: @escaping @MainActor (Double) -> Void) async throws {
        let asset = try await timeline(for: AVURLAsset(url: url), map: setup.map)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw VideoError.noVideo }
        let recorded = try await track.load(.nominalFrameRate)
        let frameRate: Float = setup.edit != nil ? 60 : recorded
        let duration = try await asset.load(.duration).seconds
        let composition = try await Self.composition(for: asset, style: style, setup: setup, longest: 3840)
        let renderSize = composition.renderSize

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
            // Sped up or slowed down, it keeps its pitch.
            if setup.map != nil { out.audioTimePitchAlgorithm = .spectral }
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

    /// The recording as a looping GIF, for places that won't play video:
    /// 20 frames a second, at most 960 pixels on the longer side.
    static func exportGIF(from url: URL, style: ExportStyle, setup: VideoSetup = VideoSetup(), to output: URL,
                          progress: @escaping @MainActor (Double) -> Void) async throws {
        let fps = 20.0
        let asset = try await timeline(for: AVURLAsset(url: url), map: setup.map)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw VideoError.noVideo }
        let duration = try await asset.load(.duration).seconds
        let composition = try await Self.composition(for: asset, style: style, setup: setup, longest: 960,
                                                frameDuration: CMTime(value: 1, timescale: CMTimeScale(fps)))
        let reader = try AVAssetReader(asset: asset)
        let frames = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        frames.videoComposition = composition
        frames.alwaysCopiesSampleData = false
        guard reader.canAdd(frames) else { throw VideoError.cantExport("the frames can't be read") }
        reader.add(frames)
        guard reader.startReading() else {
            throw VideoError.cantExport(reader.error?.localizedDescription ?? "the recording can't be read")
        }

        // The GIF is told its frame count up front: exactly that many go in.
        let count = max(Int((duration * fps).rounded(.up)), 1)
        try? FileManager.default.removeItem(at: output)
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, "com.compuserve.gif" as CFString, count, nil) else {
            reader.cancelReading()
            throw VideoError.cantExport("the GIF can't be written")
        }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        let delay = 1 / fps
        let frameProperties = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay],
        ] as CFDictionary

        var written = 0
        var last: CGImage?
        while written < count, let sample = frames.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let image = CIImage(cvPixelBuffer: buffer)
            guard let frame = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: sRGB) else { continue }
            CGImageDestinationAddImage(destination, frame, frameProperties)
            last = frame
            written += 1
            if written % 4 == 0 { await progress(min(Double(written) / Double(count), 0.97)) }
        }
        reader.cancelReading()
        guard let last else { throw VideoError.cantExport("no frames came out") }
        while written < count {
            CGImageDestinationAddImage(destination, last, frameProperties)
            written += 1
        }
        guard CGImageDestinationFinalize(destination) else { throw VideoError.cantExport("the GIF can't be finished") }
        await progress(1)
    }
}
