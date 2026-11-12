import AppKit

/// Text copied from somewhere, in the richest format that was offered.
public struct RichClip {
    public enum Format: String, Sendable {
        case rtf, html, plain
        public var fileExtension: String {
            switch self {
            case .rtf: return "rtf"
            case .html: return "html"
            case .plain: return "txt"
            }
        }
    }

    public var format: Format
    /// The bytes to store, in `format`.
    public var data: Data
    public var plain: String
    /// The page it came from, when the source app says so (Chrome, Arc…).
    public var sourceURL: URL?

    public init(format: Format, data: Data, plain: String, sourceURL: URL? = nil) {
        self.format = format
        self.data = data
        self.plain = plain
        self.sourceURL = sourceURL
    }

    public static func plain(_ text: String, sourceURL: URL? = nil) -> RichClip {
        RichClip(format: .plain, data: Data(text.utf8), plain: text, sourceURL: sourceURL)
    }
}

public enum RichText {
    /// Chromium-based browsers add the page URL to copies.
    public static let chromiumSourceURL = NSPasteboard.PasteboardType("org.chromium.source-url")

    /// Reads text from a pasteboard, preferring RTF, then HTML, then RTFD
    /// (stored as RTF), then plain text. Nil if there's no text.
    @MainActor
    public static func read(from pasteboard: NSPasteboard) -> RichClip? {
        let plain = pasteboard.string(forType: .string)
        let source = pasteboard.string(forType: chromiumSourceURL).flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }

        if let rtf = pasteboard.data(forType: .rtf), let text = NSAttributedString(rtf: rtf, documentAttributes: nil) {
            return RichClip(format: .rtf, data: rtf, plain: plain ?? text.string, sourceURL: source)
        }
        if let html = pasteboard.data(forType: .html), let text = attributed(html: html), !text.string.isEmpty {
            return RichClip(format: .html, data: html, plain: plain ?? text.string, sourceURL: source)
        }
        if let rtfd = pasteboard.data(forType: .rtfd), let text = NSAttributedString(rtfd: rtfd, documentAttributes: nil),
           let rtf = text.rtf(from: NSRange(location: 0, length: text.length), documentAttributes: [:]) {
            return RichClip(format: .rtf, data: rtf, plain: plain ?? text.string, sourceURL: source)
        }
        if let plain, !plain.isEmpty {
            return .plain(plain, sourceURL: source)
        }
        return nil
    }

    /// Loads stored text back as an attributed string.
    @MainActor
    public static func load(_ data: Data, format: RichClip.Format) -> NSAttributedString? {
        switch format {
        case .rtf: return NSAttributedString(rtf: data, documentAttributes: nil)
        case .html: return attributed(html: data)
        case .plain: return NSAttributedString(string: String(decoding: data, as: UTF8.self), attributes: [.font: defaultFont])
        }
    }

    @MainActor
    public static func load(contentsOf url: URL) -> NSAttributedString? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let format = RichClip.Format.allCases.first { $0.fileExtension == url.pathExtension.lowercased() } ?? .plain
        return load(data, format: format)
    }

    @MainActor
    static func attributed(html: Data) -> NSAttributedString? {
        try? NSAttributedString(
            data: html,
            options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil
        )
    }

    static var defaultFont: NSFont { .systemFont(ofSize: 13) }

    public static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    // MARK: Showing it

    /// The text, made legible on a plain "paper": light paper for dark text,
    /// dark paper for mostly light text (like a dark code editor), with
    /// stray colors fixed, background highlights removed and font sizes
    /// kept in a readable range.
    public struct Paper {
        public let text: NSAttributedString
        public let isDark: Bool
        /// Off-white in light mode, grey in dark mode.
        public var background: NSColor {
            isDark ? NSColor(srgbRed: 0x26 / 255, green: 0x26 / 255, blue: 0x26 / 255, alpha: 1) : NSColor(srgbRed: 0xF5 / 255, green: 0xF5 / 255, blue: 0xF3 / 255, alpha: 1)
        }
    }

    /// - Parameter dark: force a dark (or light) paper, e.g. to match the app's
    ///   mode; nil decides from the text's own colors.
    public static func paper(for source: NSAttributedString, minSize: CGFloat = 10, maxSize: CGFloat = 28, dark: Bool? = nil) -> Paper {
        let text = NSMutableAttributedString(attributedString: source)
        let full = NSRange(location: 0, length: text.length)

        // Mostly light text? Then it came from a dark UI: keep its look.
        var lightLength = 0
        var coloredLength = 0
        text.enumerateAttribute(.foregroundColor, in: full) { value, range, _ in
            guard let color = value as? NSColor, let l = luminance(color) else { return }
            coloredLength += range.length
            if l > 0.6 { lightLength += range.length }
        }
        let isDark = dark ?? (coloredLength > 0 && Double(lightLength) / Double(max(text.length, 1)) > 0.5)

        text.removeAttribute(.backgroundColor, range: full)
        let ink = isDark ? NSColor(white: 0.92, alpha: 1) : NSColor(white: 0.1, alpha: 1)
        text.enumerateAttribute(.foregroundColor, in: full) { value, range, _ in
            guard let color = value as? NSColor, let l = luminance(color) else {
                text.addAttribute(.foregroundColor, value: ink, range: range)
                return
            }
            if (isDark && l < 0.25) || (!isDark && l > 0.75) {
                text.addAttribute(.foregroundColor, value: ink, range: range)
            }
        }
        text.enumerateAttribute(.font, in: full) { value, range, _ in
            let font = (value as? NSFont) ?? defaultFont
            let size = min(max(font.pointSize, minSize), maxSize)
            let fitted = size == font.pointSize ? font : (NSFont(descriptor: font.fontDescriptor, size: size) ?? font)
            text.addAttribute(.font, value: fitted, range: range)
        }
        return Paper(text: text, isDark: isDark)
    }

    /// Relative luminance, 0 (black) to 1 (white). Nil for pattern colors.
    public static func luminance(_ color: NSColor) -> Double? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        func channel(_ c: CGFloat) -> Double {
            let v = Double(c)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        let l = 0.2126 * channel(rgb.redComponent) + 0.7152 * channel(rgb.greenComponent) + 0.0722 * channel(rgb.blueComponent)
        // Mostly transparent text reads like the paper behind it.
        return rgb.alphaComponent < 0.3 ? nil : l
    }

    /// A PNG of the text on its paper, used as the thumbnail everywhere a
    /// capture shows an image. Short text is set large and centered in the
    /// frame; long text gets as large as fits, centered, and fades out at the
    /// bottom when even the smallest size runs over.
    /// - Parameter dark: the app's mode: grey paper when dark, off-white when light.
    public static func preview(_ source: NSAttributedString, size: CGSize = CGSize(width: 480, height: 300), scale: CGFloat = 2, dark: Bool = false) -> Data? {
        let paper = paper(for: source, minSize: 10, maxSize: 60, dark: dark)
        let box = CGSize(width: size.width * 0.8, height: size.height * 0.74)
        let short = paper.text.length <= 140 && paper.text.string.components(separatedBy: .newlines).count <= 4
        let (text, needed) = fitted(paper.text, in: box, centered: short)

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale),
            pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = size

        NSGraphicsContext.saveGraphicsState()
        // Draw top-down, like a page, at the bitmap's full resolution (the
        // context works in pixels; without the scale only a quarter is drawn).
        let cg = context.cgContext
        cg.translateBy(x: 0, y: size.height * scale)
        cg.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        let bounds = CGRect(origin: .zero, size: size)
        paper.background.setFill()
        bounds.fill()

        let overflows = needed.height > box.height + 1
        let height = min(needed.height, box.height)
        let width = short ? box.width : min(box.width, ceil(needed.width) + 1)
        let origin = CGPoint(x: (size.width - width) / 2, y: overflows ? (size.height - box.height) / 2 : (size.height - height) / 2)
        text.draw(with: CGRect(origin: origin, size: CGSize(width: width, height: height)), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        if overflows {
            let fade = NSGradient(starting: paper.background.withAlphaComponent(0), ending: paper.background)
            fade?.draw(in: CGRect(x: 0, y: origin.y + box.height - 40, width: size.width, height: 40 + (size.height - box.height) / 2), angle: 90)
        }
        // A large, soft pair of quotation marks, as on the capture card: one
        // above the first line's start, one level with the last line's end
        // (left out when the text runs on under the fade).
        let markInk = (paper.isDark ? NSColor.white : NSColor.black).withAlphaComponent(paper.isDark ? 0.24 : 0.18)
        let markFont = NSFont(name: "Georgia", size: 56) ?? NSFont.systemFont(ofSize: 56)
        let mark: (String) -> NSAttributedString = { NSAttributedString(string: $0, attributes: [.font: markFont, .foregroundColor: markInk]) }
        let open = mark("\u{201C}"), close = mark("\u{201D}")
        open.draw(at: CGPoint(x: origin.x - open.size().width * 0.85, y: origin.y - markFont.ascender * 0.5))
        if !overflows {
            close.draw(at: CGPoint(x: origin.x + width - close.size().width * 0.05, y: origin.y + height - markFont.ascender * 0.85))
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    /// The text at the largest size that fits `box` (its biggest font at most
    /// 44 pt, its smallest at least 9 pt), and the size it then needs.
    static func fitted(_ text: NSAttributedString, in box: CGSize, centered: Bool) -> (NSAttributedString, CGSize) {
        var largest: CGFloat = 1, smallest: CGFloat = 100
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            let size = ((value as? NSFont) ?? defaultFont).pointSize
            largest = max(largest, size); smallest = min(smallest, size)
        }
        func scaled(_ k: CGFloat) -> NSAttributedString {
            let out = NSMutableAttributedString(attributedString: text)
            let full = NSRange(location: 0, length: out.length)
            out.enumerateAttribute(.font, in: full) { value, range, _ in
                let font = (value as? NSFont) ?? defaultFont
                out.addAttribute(.font, value: NSFont(descriptor: font.fontDescriptor, size: font.pointSize * k) ?? font, range: range)
            }
            if centered {
                out.enumerateAttribute(.paragraphStyle, in: full) { value, range, _ in
                    let style = ((value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
                    style.alignment = .center
                    out.addAttribute(.paragraphStyle, value: style, range: range)
                }
            }
            return out
        }
        func measure(_ t: NSAttributedString) -> CGSize {
            t.boundingRect(with: CGSize(width: box.width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading]).size
        }
        let minK = 9 / max(smallest, 1), maxK = max(minK, 44 / largest)
        var lo = minK, hi = maxK
        if measure(scaled(hi)).height <= box.height { lo = hi }
        else {
            for _ in 0..<14 {
                let mid = (lo + hi) / 2
                if measure(scaled(mid)).height <= box.height { lo = mid } else { hi = mid }
            }
        }
        let result = scaled(lo)
        return (result, measure(result))
    }
}

extension RichClip.Format: CaseIterable {}
