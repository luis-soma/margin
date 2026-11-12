import CoreGraphics
import Foundation

/// Geometry for the capture overlay. AppKit puts the origin at the bottom
/// left of the primary display, Core Graphics and `screencapture` at the top
/// left. Both use points.
public enum RegionMath {
    /// The rectangle spanned by a drag, whatever direction it went.
    public static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// Flips between AppKit and Core Graphics global coordinates. The same
    /// formula works both ways.
    public static func flip(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Whole points, grown outward so nothing selected is cut off.
    public static func integral(_ rect: CGRect) -> CGRect {
        rect.standardized.integral
    }

    /// Argument for `screencapture -R`.
    public static func screencaptureArgument(_ rect: CGRect) -> String {
        let r = integral(rect)
        return "\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height))"
    }

    /// A drag this small counts as a click.
    public static func isClick(_ rect: CGRect) -> Bool {
        rect.width < 5 || rect.height < 5
    }

    /// Pixel size for a recording: the region at screen resolution, capped so
    /// the H.264 encoder accepts it, and even in both directions.
    public static func videoSize(for points: CGSize, scale: CGFloat, maxDimension: CGFloat = 3840) -> (width: Int, height: Int) {
        var width = max(points.width * scale, 2)
        var height = max(points.height * scale, 2)
        let longest = max(width, height)
        if longest > maxDimension {
            let factor = maxDimension / longest
            width *= factor
            height *= factor
        }
        func even(_ value: CGFloat) -> Int { max(2, Int(value.rounded(.down)) & ~1) }
        return (even(width), even(height))
    }

    /// "0:07", "1:00"
    public static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Where the size label goes: just below the selection's bottom right,
    /// or inside it when that would leave the screen. AppKit coordinates.
    public static func labelOrigin(for selection: CGRect, labelSize: CGSize, in screen: CGRect, gap: CGFloat = 8) -> CGPoint {
        var x = selection.maxX - labelSize.width
        var y = selection.minY - gap - labelSize.height
        if y < screen.minY + 4 { y = selection.minY + gap }
        x = min(max(x, screen.minX + 4), screen.maxX - labelSize.width - 4)
        y = min(max(y, screen.minY + 4), screen.maxY - labelSize.height - 4)
        return CGPoint(x: x, y: y)
    }
}
