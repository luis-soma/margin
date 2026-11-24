import AVFoundation
import SwiftUI

/// What's picked on a recording's timeline: a stretch between splits, or
/// a zoom.
enum EditSelection: Equatable {
    case segment(UUID)
    case zoom(UUID)
}

// MARK: - Keeping edits

/// Each recording's edit, kept so the studio opens as you left it.
enum ExportEdits {
    private static let key = "exportEdits"

    static func edit(for id: UUID) -> ClipEdit {
        guard let all = UserDefaults.standard.dictionary(forKey: key) as? [String: Data],
              let data = all[id.uuidString],
              let edit = try? JSONDecoder().decode(ClipEdit.self, from: data) else { return ClipEdit() }
        return edit
    }

    static func set(_ edit: ClipEdit, for id: UUID) {
        var all = (UserDefaults.standard.dictionary(forKey: key) as? [String: Data]) ?? [:]
        all[id.uuidString] = edit == ClipEdit() ? nil : try? JSONEncoder().encode(edit)
        UserDefaults.standard.set(all, forKey: key)
    }
}

/// ⌘Z and ⇧⌘Z for the edit.
final class EditHistory {
    private var past: [ClipEdit] = []
    private var future: [ClipEdit] = []

    var canUndo: Bool { !past.isEmpty }
    var canRedo: Bool { !future.isEmpty }

    func remember(_ edit: ClipEdit) {
        if past.last == edit { return }
        past.append(edit)
        if past.count > 80 { past.removeFirst() }
        future = []
    }

    func undo(_ current: ClipEdit) -> ClipEdit? {
        guard let last = past.popLast() else { return nil }
        future.append(current)
        return last
    }

    func redo(_ current: ClipEdit) -> ClipEdit? {
        guard let next = future.popLast() else { return nil }
        past.append(current)
        return next
    }
}

/// A strip of small frames from the recording, for the timeline.
@MainActor
final class ClipThumbnails: ObservableObject {
    @Published private(set) var images: [CGImage] = []
    private var loaded: URL?

    func load(_ url: URL, duration: Double, count: Int = 14) {
        guard loaded != url, duration > 0 else { return }
        loaded = url
        Task {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 180, height: 120)
            generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 4)
            generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 4)
            var found: [CGImage] = []
            for index in 0..<count {
                let seconds = (Double(index) + 0.5) / Double(count) * duration
                if let image = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image {
                    found.append(image)
                } else if let last = found.last {
                    found.append(last)
                }
            }
            images = found
        }
    }
}

// MARK: - The timeline

/// A recording's edit, under its preview: the clip as a strip of frames,
/// split into stretches you can speed up, slow down or cut, with handles at
/// both ends to trim; under it the zooms, each a bar you move and stretch.
/// All in the recording's own seconds.
struct EditTimeline: View {
    @Binding var edit: ClipEdit
    @Binding var selection: EditSelection?
    let duration: Double
    let playhead: Double
    let clicks: [Double]
    let thumbnails: [CGImage]
    let seek: (Double) -> Void
    let willChange: () -> Void

    static let clipHeight: CGFloat = 40
    static let zoomHeight: CGFloat = 22
    static let gap: CGFloat = 4
    static var height: CGFloat { clipHeight + gap + zoomHeight }

    @State private var zoomStart: ClipEdit.Zoom?
    @State private var trimStart: Double?

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            VStack(spacing: Self.gap) {
                clipLane(width)
                zoomLane(width)
            }
            .overlay(alignment: .topLeading) { playheadLine(width) }
        }
        .frame(height: Self.height)
    }

    private func x(_ seconds: Double, _ width: CGFloat) -> CGFloat {
        CGFloat(seconds / max(duration, 0.01)) * width
    }

    private func seconds(_ x: CGFloat, _ width: CGFloat) -> Double {
        Double(min(max(x / width, 0), 1)) * duration
    }

    // MARK: Clip

    private func clipLane(_ width: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
        let pieces = edit.pieces(duration)
        let end = edit.end(duration)
        return ZStack(alignment: .topLeading) {
            // The frames.
            HStack(spacing: 0) {
                if thumbnails.isEmpty {
                    Theme.Palette.fill
                } else {
                    ForEach(Array(thumbnails.enumerated()), id: \.offset) { _, image in
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: width / CGFloat(thumbnails.count), height: Self.clipHeight)
                            .clipped()
                    }
                }
            }
            .frame(width: width, height: Self.clipHeight)

            // Each stretch: cut ones faded and striped, sped ones labelled.
            ForEach(pieces) { piece in
                let left = x(piece.from, width), right = x(piece.to, width)
                ZStack(alignment: .topLeading) {
                    if piece.removed {
                        Rectangle().fill(Theme.Palette.paper.opacity(0.82))
                        Stripes().stroke(Theme.Palette.ink3.opacity(0.45), lineWidth: 1)
                    }
                    if piece.rate != 1, !piece.removed {
                        Text(Self.rateName(piece.rate))
                            .font(Theme.Typography.ui(Theme.Typography.caption, .medium))
                            .monospacedDigit()
                            .foregroundStyle(Theme.Palette.ink)
                            .padding(.horizontal, 5)
                            .frame(height: 16)
                            .background(Capsule().fill(Theme.Palette.paper.opacity(0.92)))
                            .padding(4)
                            .fixedSize()
                    }
                    if selection == .segment(piece.id) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(Theme.Palette.ink, lineWidth: 2)
                    }
                }
                .frame(width: max(right - left, 1), height: Self.clipHeight, alignment: .topLeading)
                .clipped()
                .offset(x: left)
                .allowsHitTesting(false)
            }

            // The splits.
            ForEach(pieces.dropFirst()) { piece in
                Rectangle()
                    .fill(Theme.Palette.paper)
                    .frame(width: 2, height: Self.clipHeight)
                    .offset(x: x(piece.from, width) - 1)
                    .allowsHitTesting(false)
            }

            // Trimmed off, faded.
            Rectangle()
                .fill(Theme.Palette.paper.opacity(0.78))
                .frame(width: max(x(edit.start, width), 0), height: Self.clipHeight)
                .allowsHitTesting(false)
            Rectangle()
                .fill(Theme.Palette.paper.opacity(0.78))
                .frame(width: max(width - x(end, width), 0), height: Self.clipHeight)
                .offset(x: x(end, width))
                .allowsHitTesting(false)

            // Clicks, as small dots along the bottom.
            ForEach(Array(clicks.enumerated()), id: \.offset) { _, click in
                Circle()
                    .fill(Theme.Palette.paper)
                    .overlay(Circle().strokeBorder(Theme.Palette.ink.opacity(0.6), lineWidth: 1))
                    .frame(width: 5, height: 5)
                    .offset(x: x(click, width) - 2.5, y: Self.clipHeight - 8)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: width, height: Self.clipHeight, alignment: .topLeading)
        .clipShape(shape)
        .contentShape(shape)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { drag in seek(seconds(drag.location.x, width)) }
                .onEnded { drag in
                    guard abs(drag.translation.width) < 3 else { return }
                    let t = seconds(drag.location.x, width)
                    guard let piece = pieces.first(where: { t >= $0.from && t <= $0.to }) else { return }
                    withAnimation(Theme.Motion.snappy) {
                        selection = selection == .segment(piece.id) ? nil : .segment(piece.id)
                    }
                }
        )
        .overlay(alignment: .topLeading) {
            trimHandle(at: edit.start, width: width, leading: true)
            trimHandle(at: end, width: width, leading: false)
        }
    }

    /// An ink handle at either end of what's kept: drag to trim.
    private func trimHandle(at seconds: Double, width: CGFloat, leading: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
        return shape
            .fill(Theme.Palette.ink)
            .overlay(Capsule().fill(Theme.Palette.paper.opacity(0.85)).frame(width: 2, height: 12))
            .frame(width: 8, height: Self.clipHeight)
            .frame(width: 18, height: Self.clipHeight)
            .contentShape(Rectangle())
            .offset(x: x(seconds, width) - (leading ? 1 : 17))
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        if trimStart == nil {
                            willChange()
                            trimStart = leading ? edit.start : edit.end(duration)
                        }
                        let moved = (trimStart ?? 0) + Double(drag.translation.width / width) * duration
                        if leading {
                            edit.start = min(max(moved, 0), edit.end(duration) - 0.3)
                            seek(edit.start)
                        } else {
                            let value = max(min(moved, duration), edit.start + 0.3)
                            edit.end = value >= duration - 0.01 ? nil : value
                            seek(value)
                        }
                    }
                    .onEnded { _ in trimStart = nil }
            )
            .help(leading ? "Drag to trim the start" : "Drag to trim the end")
    }

    // MARK: Zooms

    private func zoomLane(_ width: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
        return ZStack(alignment: .topLeading) {
            shape.fill(Theme.Palette.fill)
                .contentShape(shape)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in seek(seconds(drag.location.x, width)) }
                        .onEnded { _ in
                            if case .zoom = selection { withAnimation(Theme.Motion.snappy) { selection = nil } }
                        }
                )
            if edit.zooms.isEmpty {
                Text("Zooms you add show here")
                    .font(Theme.Typography.ui(Theme.Typography.caption))
                    .foregroundStyle(Theme.Palette.ink3)
                    .frame(width: width, height: Self.zoomHeight)
                    .allowsHitTesting(false)
            }
            ForEach(edit.zooms) { zoom in
                zoomBar(zoom, width: width)
            }
        }
        .frame(width: width, height: Self.zoomHeight, alignment: .topLeading)
    }

    private func zoomBar(_ zoom: ClipEdit.Zoom, width: CGFloat) -> some View {
        let left = x(zoom.from, width), right = x(zoom.to, width)
        let chosen = selection == .zoom(zoom.id)
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        return HStack(spacing: 4) {
            Image(systemName: "plus.magnifyingglass").font(.system(size: 9, weight: .semibold))
            if right - left > 52 {
                Text(String(format: "%.1f×", zoom.depth))
                    .font(Theme.Typography.ui(Theme.Typography.caption, .medium))
                    .monospacedDigit()
            }
        }
        .foregroundStyle(Theme.Palette.paper)
        .frame(width: max(right - left, 12), height: Self.zoomHeight - 4)
        .background(shape.fill(Theme.Palette.ink.opacity(chosen ? 1 : 0.62)))
        .overlay(alignment: .leading) { zoomEdge(zoom, width: width, leading: true) }
        .overlay(alignment: .trailing) { zoomEdge(zoom, width: width, leading: false) }
        .contentShape(shape)
        .offset(x: left, y: 2)
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { drag in
                    guard abs(drag.translation.width) >= 2 || zoomStart != nil else { return }
                    let from = begin(zoom)
                    let length = from.to - from.from
                    let shift = Double(drag.translation.width / width) * duration
                    let (low, high) = room(around: zoom.id)
                    let start = min(max(from.from + shift, low), high - length)
                    update(zoom.id) { $0.from = start; $0.to = start + length }
                }
                .onEnded { drag in
                    if zoomStart == nil {
                        withAnimation(Theme.Motion.snappy) { selection = chosen ? nil : .zoom(zoom.id) }
                    }
                    zoomStart = nil
                }
        )
        .help("Drag to move, drag an end to make it longer or shorter")
    }

    /// A zoom's end: drag to make it longer or shorter.
    private func zoomEdge(_ zoom: ClipEdit.Zoom, width: CGFloat, leading: Bool) -> some View {
        Color.white.opacity(0.001)
            .frame(width: 8, height: Self.zoomHeight)
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        let from = begin(zoom)
                        let shift = Double(drag.translation.width / width) * duration
                        let (low, high) = room(around: zoom.id)
                        if leading {
                            let value = min(max(from.from + shift, low), from.to - 0.6)
                            update(zoom.id) { $0.from = value }
                        } else {
                            let value = max(min(from.to + shift, high), from.from + 0.6)
                            update(zoom.id) { $0.to = value }
                        }
                    }
                    .onEnded { _ in zoomStart = nil }
            )
    }

    /// The zoom as it was when the drag began, remembered once for undo.
    private func begin(_ zoom: ClipEdit.Zoom) -> ClipEdit.Zoom {
        if let zoomStart { return zoomStart }
        willChange()
        zoomStart = zoom
        return zoom
    }

    /// How far a zoom can go before it meets its neighbours.
    private func room(around id: UUID) -> (Double, Double) {
        let sorted = edit.zooms.sorted { $0.from < $1.from }
        guard let index = sorted.firstIndex(where: { $0.id == id }) else { return (0, duration) }
        let low = index > 0 ? sorted[index - 1].to : 0
        let high = index + 1 < sorted.count ? sorted[index + 1].from : duration
        return (low, high)
    }

    private func update(_ id: UUID, _ change: (inout ClipEdit.Zoom) -> Void) {
        guard let index = edit.zooms.firstIndex(where: { $0.id == id }) else { return }
        change(&edit.zooms[index])
    }

    // MARK: Playhead

    private func playheadLine(_ width: CGFloat) -> some View {
        let at = min(max(x(playhead, width), 0), width)
        return VStack(spacing: 0) {
            Circle().fill(Theme.Palette.ink).frame(width: 7, height: 7)
            Rectangle().fill(Theme.Palette.ink).frame(width: 2, height: Self.height + 2)
        }
        .offset(x: at - 3.5, y: -5)
        .allowsHitTesting(false)
    }

    static func rateName(_ rate: Double) -> String {
        switch rate {
        case 0.5: return "½×"
        case 0.25: return "¼×"
        default: return rate == rate.rounded() ? "\(Int(rate))×" : String(format: "%.1f×", rate)
        }
    }

    static func clock(_ seconds: Double) -> String {
        let whole = Int(max(seconds, 0))
        return String(format: "%d:%02d.%d", whole / 60, whole % 60, Int((max(seconds, 0) - Double(whole)) * 10))
    }
}

/// Thin diagonal lines, for a cut stretch.
private struct Stripes: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        var x = rect.minX - rect.height
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += 6
        }
        return path
    }
}

// MARK: - Framing a zoom

/// Over a still of the recording while a zoom is picked: the box it frames,
/// the shape of the picture. Drag it to move, drag a corner to go closer or
/// further. Outside it the picture dims.
struct FramingOverlay: View {
    @Binding var zoom: ClipEdit.Zoom
    let willChange: () -> Void
    @State private var start: ClipEdit.Zoom?

    static let deepest = 5.0

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let box = Self.box(zoom, in: size)
            ZStack(alignment: .topLeading) {
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: size))
                    path.addRect(box)
                }
                .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)

                Rectangle()
                    .strokeBorder(Color.white, lineWidth: 1.5)
                    .frame(width: box.width, height: box.height)
                    .offset(x: box.minX, y: box.minY)
                    .shadow(color: .black.opacity(0.25), radius: 1)
                    .allowsHitTesting(false)

                Text(String(format: "%.1f×", zoom.depth))
                    .font(Theme.Typography.ui(Theme.Typography.caption, .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.Palette.ink)
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(Capsule().fill(Color.white))
                    .fixedSize()
                    .offset(x: box.minX + 6, y: box.minY + 6)
                    .allowsHitTesting(false)

                Rectangle()
                    .fill(Color.white.opacity(0.001))
                    .frame(width: box.width, height: box.height)
                    .offset(x: box.minX, y: box.minY)
                    .onHover { inside in if inside { NSCursor.openHand.push() } else { NSCursor.pop() } }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global).onChanged { drag in
                        let from = begin()
                        zoom.x = Self.clamped(from.x + drag.translation.width / size.width, depth: from.depth)
                        zoom.y = Self.clamped(from.y + drag.translation.height / size.height, depth: from.depth)
                    }.onEnded { _ in start = nil })

                ForEach(0..<4, id: \.self) { corner in
                    handle(corner, box: box, size: size)
                }
            }
        }
    }

    private func handle(_ corner: Int, box: CGRect, size: CGSize) -> some View {
        let point = CGPoint(x: corner % 2 == 0 ? box.minX : box.maxX, y: corner < 2 ? box.minY : box.maxY)
        return RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(Color.white)
            .frame(width: 12, height: 12)
            .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
            .position(point)
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global).onChanged { drag in
                let from = begin()
                // The corner moves away from the middle: a bigger box, less close.
                let outward = (corner % 2 == 0 ? -drag.translation.width : drag.translation.width) / size.width
                let width = max(1 / from.depth + 2 * outward, 1 / Self.deepest)
                zoom.depth = min(max(1 / width, 1.1), Self.deepest)
                zoom.x = Self.clamped(from.x, depth: zoom.depth)
                zoom.y = Self.clamped(from.y, depth: zoom.depth)
            }.onEnded { _ in start = nil })
    }

    private func begin() -> ClipEdit.Zoom {
        if let start { return start }
        willChange()
        start = zoom
        return zoom
    }

    static func box(_ zoom: ClipEdit.Zoom, in size: CGSize) -> CGRect {
        let w = size.width / zoom.depth, h = size.height / zoom.depth
        let x = clamped(zoom.x, depth: zoom.depth) * size.width - w / 2
        let y = clamped(zoom.y, depth: zoom.depth) * size.height - h / 2
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// A middle that keeps the box inside the picture.
    static func clamped(_ value: Double, depth: Double) -> Double {
        let half = 0.5 / max(depth, 1)
        return min(max(value, half), 1 - half)
    }
}

// MARK: - Small controls

/// The speeds, as Margin's switch.
struct SpeedSwitch: View {
    let rate: Double
    let choose: (Double) -> Void
    @Namespace private var thumb

    var body: some View {
        let S = Theme.Segmented.self
        HStack(spacing: 0) {
            ForEach(ClipEdit.rates, id: \.self) { option in
                Button {
                    withAnimation(Theme.Motion.snappy) { choose(option) }
                } label: {
                    Text(EditTimeline.rateName(option))
                        .font(Theme.Typography.ui(Theme.Typography.control))
                        .monospacedDigit()
                        .foregroundStyle(S.label(rate == option, hovered: false))
                        .frame(width: 34, height: S.segment)
                        .background {
                            if rate == option { SegmentThumb().matchedGeometryEffect(id: "thumb", in: thumb) }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(S.padding)
        .background(SegmentTrack())
        .toolTip("Speed", "Eases from one speed into the next", align: .center)
    }
}

/// Play and pause, beside the timeline.
struct PlayButton: View {
    let playing: Bool
    let toggle: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
        Button(action: toggle) {
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
    }
}
