import AppKit
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import MarginKit

/// What the export studio does with a recording's cursor path: zoom in where
/// you click and follow the pointer gently, draw a smoothed cursor in place
/// of the recorded one, and ripple where you click. Worked out once, for the
/// whole recording, 60 steps a second; then asked per frame.
struct MotionPlan {
    static let rate = 60.0

    /// Pointer, smoothed a little: steady without lagging.
    let cursor: [CGPoint]
    /// Where the camera looks: the pointer, smoothed a lot.
    let camera: [CGPoint]
    /// 0 when showing everything, 1 when fully zoomed in.
    let zoom: [CGFloat]
    /// Video seconds and where.
    let clicks: [(t: Double, at: CGPoint)]
    /// The recorded area in points.
    let area: CGSize

    /// - Parameter file: "main" or "studio": whose first frame is time zero.
    init?(track: CursorTrack, file: String, duration: Double) {
        guard let start = track.starts[file] ?? track.starts["main"], !track.moves.isEmpty, duration > 0 else { return nil }
        area = CGSize(width: track.areaWidth, height: track.areaHeight)
        let count = Int(duration * Self.rate) + 2
        let moves = track.moves.sorted { $0.t < $1.t }

        // Where the pointer was at each step, between the points we have.
        var raw = [CGPoint](repeating: .zero, count: count)
        var index = 0
        for step in 0..<count {
            let t = start + Double(step) / Self.rate
            while index + 1 < moves.count, moves[index + 1].t <= t { index += 1 }
            let a = moves[index]
            if index + 1 < moves.count, t > a.t {
                let b = moves[index + 1]
                let share = min(max((t - a.t) / max(b.t - a.t, 0.0001), 0), 1)
                raw[step] = CGPoint(x: a.x + (b.x - a.x) * share, y: a.y + (b.y - a.y) * share)
            } else {
                raw[step] = CGPoint(x: a.x, y: a.y)
            }
        }

        cursor = Self.smoothed(raw, sigma: 0.05)
        camera = Self.smoothed(raw, sigma: 0.45)
        var found: [(t: Double, at: CGPoint)] = []
        for click in track.clicks {
            let t: Double = click.t - start
            let inTime = t >= -0.5 && t <= duration + 0.5
            let inArea = click.x >= -0.02 && click.x <= 1.02 && click.y >= -0.02 && click.y <= 1.02
            if inTime && inArea { found.append((t: t, at: CGPoint(x: click.x, y: click.y))) }
        }
        clicks = found

        // Zoomed in from just before a click until a while after the last of
        // a run of them, easing in and out.
        var spans: [(from: Double, to: Double)] = []
        for click in found {
            if let last = spans.last, click.t - last.to < 1.2 {
                spans[spans.count - 1].to = click.t + 1.8
            } else {
                spans.append((click.t - 0.3, click.t + 1.8))
            }
        }
        zoom = (0..<count).map { step in
            let t = Double(step) / Self.rate
            var level: Double = 0
            for span in spans {
                let rise = Self.ease((t - (span.from - 0.7)) / 0.7)
                let fall = 1 - Self.ease((t - span.to) / 0.9)
                level = max(level, min(rise, fall))
            }
            return CGFloat(level)
        }
    }

    var hasClicks: Bool { !clicks.isEmpty }

    func cursor(at t: Double) -> CGPoint { Self.sample(cursor, at: t) }
    func camera(at t: Double) -> CGPoint { Self.sample(camera, at: t) }
    func zoom(at t: Double) -> CGFloat {
        guard !zoom.isEmpty else { return 0 }
        let step = min(max(t * Self.rate, 0), Double(zoom.count - 1))
        let low = Int(step), high = min(low + 1, zoom.count - 1)
        let share = CGFloat(step - Double(low))
        return zoom[low] + (zoom[high] - zoom[low]) * share
    }

    /// A good moment to show in the preview: the first click, zoomed in.
    var firstMoment: Double? { clicks.first.map { max($0.t + 0.4, 0) } }

    private static func sample(_ path: [CGPoint], at t: Double) -> CGPoint {
        guard !path.isEmpty else { return CGPoint(x: 0.5, y: 0.5) }
        let step = min(max(t * rate, 0), Double(path.count - 1))
        let low = Int(step), high = min(low + 1, path.count - 1)
        let share = CGFloat(step - Double(low))
        return CGPoint(x: path[low].x + (path[high].x - path[low].x) * share,
                       y: path[low].y + (path[high].y - path[low].y) * share)
    }

    private static func ease(_ x: Double) -> Double {
        let x = min(max(x, 0), 1)
        return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
    }

    /// A Gaussian blur along time: it looks ahead as much as back, so the
    /// smoothing doesn't drag behind the hand.
    private static func smoothed(_ path: [CGPoint], sigma: Double) -> [CGPoint] {
        let s = sigma * rate
        let radius = Int(ceil(s * 3))
        guard radius > 0 else { return path }
        let weights = (-radius...radius).map { exp(-Double($0 * $0) / (2 * s * s)) }
        return path.indices.map { i in
            var x = 0.0, y = 0.0, total = 0.0
            for (k, offset) in (-radius...radius).enumerated() {
                let j = min(max(i + offset, 0), path.count - 1)
                x += Double(path[j].x) * weights[k]
                y += Double(path[j].y) * weights[k]
                total += weights[k]
            }
            return CGPoint(x: x / total, y: y / total)
        }
    }
}

extension ExportRenderer {
    /// Frame `content` (its origin at zero) at video second `t`: the drawn
    /// cursor and click ripples first, so they zoom with the picture, then
    /// the camera.
    static func moving(_ content: CIImage, at t: Double, plan: MotionPlan, style: ExportStyle, drawCursor: Bool) -> CIImage {
        let size = content.extent.size
        let pointScale = size.width / max(plan.area.width, 1)
        var image = content

        if style.showClicks {
            for click in plan.clicks where t >= click.t && t - click.t < 0.6 {
                image = ripple(at: location(click.at, in: size), age: (t - click.t) / 0.6, scale: pointScale)
                    .composited(over: image)
            }
        }
        if drawCursor, let arrow = arrow(height: 24 * pointScale * CGFloat(0.7 + 1.3 * style.cursorSize)) {
            let tip = location(plan.cursor(at: t), in: size)
            let placed = arrow.image.transformed(by: CGAffineTransform(translationX: tip.x - arrow.hotSpot.x, y: tip.y - arrow.hotSpot.y))
            image = placed.composited(over: image)
        }
        image = image.cropped(to: CGRect(origin: .zero, size: size))

        let level = style.zoom ? plan.zoom(at: t) : 0
        guard level > 0.001 else { return image }
        let deepest = 1.3 + 1.4 * CGFloat(style.zoomAmount)
        let z = 1 + (deepest - 1) * level
        let view = CGSize(width: size.width / z, height: size.height / z)
        let target = location(plan.camera(at: t), in: size)
        let origin = CGPoint(x: min(max(target.x - view.width / 2, 0), size.width - view.width),
                             y: min(max(target.y - view.height / 2, 0), size.height - view.height))
        return image
            .cropped(to: CGRect(origin: origin, size: view))
            .transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
            .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: z, kCIInputAspectRatioKey: 1])
            .cropped(to: CGRect(origin: .zero, size: size))
    }

    /// 0 to 1 from the top left, as pixels from the bottom left.
    private static func location(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: point.x * size.width, y: (1 - point.y) * size.height)
    }

    /// A soft ink circle that grows and fades where you clicked.
    private static func ripple(at center: CGPoint, age: Double, scale: CGFloat) -> CIImage {
        let grow = 1 - pow(1 - age, 3)
        let radius = (12 + 22 * CGFloat(grow)) * scale
        let alpha = 0.28 * pow(1 - age, 1.6)
        let gradient = CIFilter.radialGradient()
        gradient.center = center
        gradient.radius0 = Float(radius * 0.55)
        gradient.radius1 = Float(radius)
        gradient.color0 = CIColor(red: 0.08, green: 0.08, blue: 0.08, alpha: alpha)
        gradient.color1 = CIColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 0)
        let disc = (gradient.outputImage ?? CIImage.empty())
        return disc.cropped(to: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    // The macOS arrow, drawn sharp at the size asked for, once.
    private static var arrows: [Int: (image: CIImage, hotSpot: CGPoint)] = [:]
    private static let arrowsLock = NSLock()

    static func arrow(height: CGFloat) -> (image: CIImage, hotSpot: CGPoint)? {
        let key = Int(height.rounded())
        arrowsLock.lock()
        defer { arrowsLock.unlock() }
        if let cached = arrows[key] { return cached }
        let cursor = NSCursor.arrow
        let source = cursor.image
        guard source.size.height > 0 else { return nil }
        let scale = CGFloat(key) / source.size.height
        let width = Int((source.size.width * scale).rounded(.up)), pixels = max(key, 1)
        guard let context = CGContext(data: nil, width: width, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        source.draw(in: CGRect(x: 0, y: 0, width: width, height: pixels), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { return nil }
        // The hot spot is from the image's top left; ours is from the bottom.
        let hot = CGPoint(x: cursor.hotSpot.x * scale, y: CGFloat(pixels) - cursor.hotSpot.y * scale)
        let result = (CIImage(cgImage: image), hot)
        arrows[key] = result
        return result
    }
}

/// Frames of a recording on request, small enough to restyle quickly.
final class FrameGrabber {
    let url: URL
    private let generator: AVAssetImageGenerator

    init(url: URL) {
        self.url = url
        generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1600, height: 1600)
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 60)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 60)
    }

    func frame(at seconds: Double) async -> CIImage? {
        let time = CMTime(seconds: max(seconds, 0), preferredTimescale: 600)
        guard let image = try? await generator.image(at: time).image else { return nil }
        return CIImage(cgImage: image)
    }

    /// The video's own size in pixels, upright.
    static func naturalSize(of url: URL) async -> CGSize? {
        guard let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
              let loaded = try? await track.load(.naturalSize, .preferredTransform) else { return nil }
        let upright = loaded.0.applying(loaded.1)
        return CGSize(width: abs(upright.width), height: abs(upright.height))
    }
}
