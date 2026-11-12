import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Small image helpers for snapshots: loading, a tiny fingerprint to tell
/// whether the screen really changed, and writing compact JPEGs and HEICs.
enum ImageTools {
    static func load(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// A capture to show at full size, with square corners. Animated pictures
    /// are left as they are so they keep playing.
    static func picture(at url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        guard CGImageSourceGetCount(source) == 1,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return NSImage(contentsOf: url) }
        let squared = squareCorners(image)
        return NSImage(cgImage: squared, size: NSSize(width: squared.width, height: squared.height))
    }

    /// Captures always have raw, square edges. A window capture comes with
    /// the window's rounded corners as transparent pixels; those are filled
    /// with the color right beside them, so the corner is sharp. Pictures
    /// that are transparent along their edges (text drawn on clear) are left
    /// alone, since they have no corner to square.
    static func squareCorners(_ image: CGImage) -> CGImage {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return image
        default: break
        }
        let w = image.width, h = image.height
        guard w > 16, h > 16,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return image }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let pixels = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        func alpha(_ x: Int, _ y: Int) -> UInt8 { pixels[(y * w + x) * 4 + 3] }
        let solid: UInt8 = 250

        let corners = [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)]
        let edgesSolid = alpha(w / 2, 0) >= solid && alpha(w / 2, h - 1) >= solid
            && alpha(0, h / 2) >= solid && alpha(w - 1, h / 2) >= solid
        guard edgesSolid, corners.contains(where: { alpha($0.0, $0.1) < solid }) else { return image }
        // Only small corners like a window's: a round frame is left round.
        let reach = min(w, h) / 12
        let inset = min(w, h) / 20
        guard corners.allSatisfy({ alpha($0.0 == 0 ? inset : w - 1 - inset, $0.1 == 0 ? inset : h - 1 - inset) >= solid }) else { return image }

        // Each corner, row by row inward: everything before the first solid
        // pixel takes the color a couple of pixels past it (inside any
        // anti-aliased rim).
        for (cx, cy) in corners {
            let dx = cx == 0 ? 1 : -1, dy = cy == 0 ? 1 : -1
            for i in 0..<reach {
                let y = cy + dy * i
                guard let first = (0..<reach).first(where: { alpha(cx + dx * $0, y) >= solid }) else { continue }
                if first == 0 { break }
                let source = (y * w + cx + dx * min(first + 2, reach)) * 4
                for j in 0..<first {
                    let target = (y * w + cx + dx * j) * 4
                    pixels[target] = pixels[source]
                    pixels[target + 1] = pixels[source + 1]
                    pixels[target + 2] = pixels[source + 2]
                    pixels[target + 3] = 255
                }
            }
        }
        return context.makeImage() ?? image
    }

    /// A 16 × 16 grayscale thumbnail as raw bytes. Cheap to compare.
    static func fingerprint(_ image: CGImage, size: Int = 16) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: size * size)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: size,
                height: size,
                bitsPerComponent: 8,
                bytesPerRow: size,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
            return true
        }
        return drawn ? pixels : []
    }

    /// 0 means identical, 1 means completely different.
    static func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        var total = 0
        for index in a.indices {
            total += abs(Int(a[index]) - Int(b[index]))
        }
        return Double(total) / Double(a.count * 255)
    }

    /// Scales the image down to `maxWidth` and writes it as a HEIC, keeping
    /// transparency: a window's rounded corners stay rounded.
    static func writeHEIC(_ image: CGImage, maxWidth: Int, quality: Double, to url: URL) -> Bool {
        let scaled = resized(image, maxWidth: maxWidth, keepingAlpha: true) ?? image
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.heic.identifier as CFString, 1, nil
        ) else { return false }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, scaled, options as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }

    /// Scales the image down to `maxWidth` and writes it as a JPEG.
    static func writeJPEG(_ image: CGImage, maxWidth: Int, quality: Double, to url: URL) -> Bool {
        let scaled = resized(image, maxWidth: maxWidth) ?? image
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return false }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, scaled, options as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }

    static func resized(_ image: CGImage, maxWidth: Int, keepingAlpha: Bool = false) -> CGImage? {
        guard image.width > maxWidth else { return image }
        let scale = Double(maxWidth) / Double(image.width)
        let width = maxWidth
        let height = max(1, Int(Double(image.height) * scale))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: (keepingAlpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
