import AVFoundation
import CoreGraphics
import Foundation

/// What's done to a recording's time and framing before it's exported: the
/// ends trimmed, parts cut out, parts sped up or slowed down (easing from
/// one speed into the next) and moments framed closer. Everything is in
/// the recording's own seconds, so it stays put when speeds change.
struct ClipEdit: Codable, Equatable {
    /// A stretch of the recording between two splits.
    struct Segment: Codable, Equatable, Identifiable {
        var id = UUID()
        var from: Double
        var to: Double
        /// 2 plays twice as fast.
        var rate: Double = 1
        /// Cut out.
        var removed = false
    }

    /// A moment framed closer: it eases in, holds, and eases out.
    struct Zoom: Codable, Equatable, Identifiable {
        var id = UUID()
        var from: Double
        var to: Double
        /// The middle of what's framed, 0 to 1 from the picture's top left
        /// (after the crop).
        var x: Double = 0.5
        var y: Double = 0.5
        /// How close: 2 shows half the width.
        var depth: Double = 1.8
    }

    /// Where it starts and ends (trimmed).
    var start: Double = 0
    var end: Double?
    /// The recording split into stretches; empty until the first split.
    var segments: [Segment] = []
    var zooms: [Zoom] = []

    /// The speeds offered, slowest first.
    static let rates: [Double] = [0.5, 1, 2, 4, 8]
    /// How long a change of speed takes to ease in, either side of a split.
    static let ramp = 0.35
    static let zoomRamp = 0.7

    func end(_ duration: Double) -> Double { min(end ?? duration, duration) }

    /// The whole recording as one stretch, before any split.
    static let whole = UUID(uuidString: "6D617267-696E-0000-0000-000000000001")!

    /// The stretches, covering the whole recording.
    func pieces(_ duration: Double) -> [Segment] {
        segments.isEmpty ? [Segment(id: Self.whole, from: 0, to: duration)] : segments
    }

    /// Changes one stretch, splitting the recording into stretches first if
    /// it hasn't been.
    mutating func change(_ id: UUID, duration: Double, _ body: (inout Segment) -> Void) {
        var all = pieces(duration)
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        body(&all[index])
        segments = all
    }

    /// What decides the edited video's timing, for knowing when to build it again.
    func timeKey(_ duration: Double) -> String {
        guard !keepsTime(duration) else { return "" }
        let parts = pieces(duration).map { "\($0.from)-\($0.to)-\($0.rate)-\($0.removed)" }
        return "\(start)|\(end(duration))|" + parts.joined(separator: ",")
    }

    /// Nothing changes the recording's time.
    func keepsTime(_ duration: Double) -> Bool {
        start <= 0.001 && end(duration) >= duration - 0.001
            && segments.allSatisfy { $0.rate == 1 && !$0.removed }
    }

    func isEmpty(_ duration: Double) -> Bool { keepsTime(duration) && zooms.isEmpty }

    /// Splits the stretch under `t` in two; returns the new right half.
    @discardableResult
    mutating func split(at t: Double, duration: Double) -> UUID? {
        var all = pieces(duration)
        guard let index = all.firstIndex(where: { t > $0.from + 0.1 && t < $0.to - 0.1 }) else { return nil }
        var right = all[index]
        right.id = UUID()
        right.from = t
        all[index].to = t
        all.insert(right, at: index + 1)
        segments = all
        return right.id
    }

    /// A zoom starting at `t`, a couple of seconds long, where there's room.
    mutating func addZoom(at t: Double, duration: Double) -> UUID? {
        let length = min(2.4, duration)
        guard length > 0.5 else { return nil }
        var from = min(max(t, 0), duration - length)
        // Not on top of another one.
        for zoom in zooms.sorted(by: { $0.from < $1.from }) where from < zoom.to && from + length > zoom.from {
            from = zoom.to
        }
        guard from + 0.6 <= duration else { return nil }
        let zoom = Zoom(from: from, to: min(from + length, duration))
        zooms.append(zoom)
        zooms.sort { $0.from < $1.from }
        return zoom.id
    }

    /// How closely `s` is framed by a zoom: its middle, its depth, and how far
    /// in (0 to 1) as it eases in and out.
    func framing(at s: Double) -> (center: CGPoint, depth: CGFloat, weight: CGFloat)? {
        var best: (center: CGPoint, depth: CGFloat, weight: CGFloat)?
        for zoom in zooms where s > zoom.from && s < zoom.to {
            let ramp = min(Self.zoomRamp, (zoom.to - zoom.from) / 3)
            let weight = min(Self.smooth((s - zoom.from) / ramp), Self.smooth((zoom.to - s) / ramp))
            if weight > (best?.weight ?? 0) {
                best = (CGPoint(x: zoom.x, y: zoom.y), CGFloat(zoom.depth), CGFloat(weight))
            }
        }
        return best
    }

    /// Slow out, slow in, with no jolt at either end (smootherstep).
    static func smooth(_ x: Double) -> Double {
        let x = min(max(x, 0), 1)
        return x * x * x * (x * (x * 6 - 15) + 10)
    }
}

/// Recording seconds to exported seconds and back, for a `ClipEdit`. The
/// kept parts in order, each walked in small steps so speed can change
/// smoothly inside it.
struct TimeMap {
    struct Piece {
        let from: Double
        let to: Double
        /// Where it starts in the export.
        let outFrom: Double
        /// Export seconds at each step from `from`, starting at 0.
        let outs: [Double]
        var length: Double { outs.last ?? 0 }
    }

    static let step = 1.0 / 240

    let pieces: [Piece]
    /// The export's length.
    let duration: Double

    init(edit: ClipEdit, duration source: Double) {
        let start = max(edit.start, 0), end = edit.end(source)
        // The kept stretches, joined where they touch.
        var runs: [[ClipEdit.Segment]] = []
        for var segment in edit.pieces(source) where !segment.removed {
            segment.from = max(segment.from, start)
            segment.to = min(segment.to, end)
            guard segment.to - segment.from > 0.01 else { continue }
            if let last = runs.last?.last, abs(last.to - segment.from) < 0.001 {
                runs[runs.count - 1].append(segment)
            } else {
                runs.append([segment])
            }
        }
        var pieces: [Piece] = []
        var out = 0.0
        for run in runs {
            guard let first = run.first, let last = run.last else { continue }
            let from = first.from, to = last.to
            let count = Int(((to - from) / Self.step).rounded(.up))
            var outs = [0.0]
            outs.reserveCapacity(count + 1)
            var total = 0.0
            for k in 0..<count {
                let a = from + Double(k) * Self.step
                let b = min(a + Self.step, to)
                total += (b - a) / Self.rate(at: (a + b) / 2, in: run)
                outs.append(total)
            }
            pieces.append(Piece(from: from, to: to, outFrom: out, outs: outs))
            out += total
        }
        self.pieces = pieces
        duration = out
    }

    /// The speed at `s` inside a run of touching stretches, easing (in
    /// steps of speed, not of time) across each split where it changes.
    private static func rate(at s: Double, in run: [ClipEdit.Segment]) -> Double {
        guard let index = run.firstIndex(where: { s < $0.to }) ?? run.indices.last else { return 1 }
        let here = run[index]
        if index + 1 < run.count {
            let next = run[index + 1]
            let r = min(ClipEdit.ramp, (here.to - here.from) / 2, (next.to - next.from) / 2)
            if r > 0, s > here.to - r { return blend(here.rate, next.rate, (s - (here.to - r)) / (2 * r)) }
        }
        if index > 0 {
            let before = run[index - 1]
            let r = min(ClipEdit.ramp, (here.to - here.from) / 2, (before.to - before.from) / 2)
            if r > 0, s < here.from + r { return blend(before.rate, here.rate, (s - (here.from - r)) / (2 * r)) }
        }
        return here.rate
    }

    private static func blend(_ a: Double, _ b: Double, _ x: Double) -> Double {
        guard a != b else { return a }
        let w = ClipEdit.smooth(x)
        return exp(log(a) * (1 - w) + log(b) * w)
    }

    /// The recording second shown at export second `t`.
    func source(at t: Double) -> Double {
        guard let piece = pieces.last(where: { $0.outFrom <= t }) ?? pieces.first else { return t }
        let local = min(max(t - piece.outFrom, 0), piece.length)
        let outs = piece.outs
        var low = 0, high = outs.count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if outs[mid] <= local { low = mid } else { high = mid }
        }
        let span = outs[high] - outs[low]
        let share = span > 0 ? (local - outs[low]) / span : 0
        return min(piece.from + (Double(low) + share) * Self.step, piece.to)
    }

    /// The export second that shows recording second `s`; a cut-out second
    /// gives the next one kept.
    func output(at s: Double) -> Double {
        for piece in pieces {
            if s < piece.from { return piece.outFrom }
            if s <= piece.to {
                let exact = (s - piece.from) / Self.step
                let k = min(Int(exact), piece.outs.count - 2)
                guard k >= 0 else { return piece.outFrom }
                let share = exact - Double(k)
                return piece.outFrom + piece.outs[k] + (piece.outs[k + 1] - piece.outs[k]) * share
            }
        }
        return duration
    }

    /// Whether `s` is kept.
    func keeps(_ s: Double) -> Bool { pieces.contains { s >= $0.from && s <= $0.to } }

    /// The recording cut into stretches of nearly one speed, for building
    /// the edited video: long where the speed holds, short where it eases.
    func chunks() -> [(from: Double, to: Double, out: Double)] {
        var result: [(from: Double, to: Double, out: Double)] = []
        for piece in pieces {
            let outs = piece.outs
            let cells = outs.count - 1
            guard cells > 0 else { continue }
            func speed(_ k: Int) -> Double {
                let a = piece.from + Double(k) * Self.step, b = min(a + Self.step, piece.to)
                let out = outs[k + 1] - outs[k]
                return out > 0 ? (b - a) / out : 1
            }
            var first = 0
            var base = speed(0)
            for k in 1...cells {
                if k == cells || abs(speed(k) / base - 1) > 0.025 {
                    let from = piece.from + Double(first) * Self.step
                    let to = min(piece.from + Double(k) * Self.step, piece.to)
                    result.append((from, to, outs[k] - outs[first]))
                    first = k
                    if k < cells { base = speed(k) }
                }
            }
        }
        return result
    }
}

extension ExportRenderer {
    /// The recording with its edit applied: cut, trimmed and retimed, sound
    /// kept in step. The recording itself when nothing changes its time.
    static func timeline(for asset: AVAsset, map: TimeMap?) async throws -> AVAsset {
        guard let map else { return asset }
        guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw VideoError.noVideo }
        let sound = try await asset.loadTracks(withMediaType: .audio).first
        let length = try await asset.load(.duration)
        let transform = try await video.load(.preferredTransform)
        let soundRange = try await sound?.load(.timeRange)

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw VideoError.cantExport("the edit can't be made")
        }
        videoTrack.preferredTransform = transform
        let soundTrack = sound == nil ? nil : composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)

        func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 60_000) }
        var cursor = CMTime.zero
        for chunk in map.chunks() {
            let range = CMTimeRange(start: time(chunk.from), end: CMTimeMinimum(time(chunk.to), length))
            guard range.duration > .zero else { continue }
            let out = time(chunk.out)
            guard out > .zero else { continue }
            try videoTrack.insertTimeRange(range, of: video, at: cursor)
            let placed = CMTimeRange(start: cursor, duration: range.duration)
            if range.duration != out { videoTrack.scaleTimeRange(placed, toDuration: out) }

            if let sound, let soundTrack {
                let heard = soundRange.map { range.intersection($0) } ?? .invalid
                if heard.isValid, heard.duration == range.duration,
                   (try? soundTrack.insertTimeRange(range, of: sound, at: cursor)) != nil {
                    if range.duration != out { soundTrack.scaleTimeRange(placed, toDuration: out) }
                } else {
                    soundTrack.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: out))
                }
            }
            cursor = cursor + out
        }
        guard cursor > .zero else { throw VideoError.cantExport("nothing is left after the cuts") }
        return (composition.copy() as? AVComposition) ?? composition
    }
}
