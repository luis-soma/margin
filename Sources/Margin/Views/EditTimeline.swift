import AVFoundation
import SwiftUI

/// What's picked on a recording's timeline: a stretch between splits, or
/// a zoom.
enum EditSelection: Equatable {
    /// A stretch you dragged across, nothing done to it yet.
    case range(Double, Double)
    /// A stretch that's cut out or plays at another speed.
    case segment(UUID)
    case zoom(UUID)
}

/// What the small bar over a selection can do.
enum EditAction {
    case cut, keep, speed(Double), zoom, remove
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

/// A recording's edit, as one strip of its frames under the preview. Click
/// to move the playhead; drag across to pick a stretch, and a small bar over
/// it cuts it, changes its speed or zooms in on it. The ink frame around
/// what's kept has a handle at each end: drag one to trim. Zooms sit along
/// the bottom of the strip; drag one to move it, or its end to stretch it.
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
    let act: (EditAction) -> Void

    static let height: CGFloat = 48
    /// The bar over a selection, and room for it.
    static let barHeight: CGFloat = 30
    static let zoomBand: CGFloat = 16

    private enum Grab {
        case pending(Double)
        case range(Double)
        case trimStart(Double)
        case trimEnd(Double)
        case zoomMove(ClipEdit.Zoom)
        case zoomFrom(ClipEdit.Zoom)
        case zoomTo(ClipEdit.Zoom)
    }
    @State private var grab: Grab?

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            strip(width)
                .overlay(alignment: .topLeading) { bar(width) }
        }
        .frame(height: Self.height)
    }

    private func x(_ seconds: Double, _ width: CGFloat) -> CGFloat {
        CGFloat(seconds / max(duration, 0.01)) * width
    }

    private func seconds(_ x: CGFloat, _ width: CGFloat) -> Double {
        Double(min(max(x / width, 0), 1)) * duration
    }

    // MARK: Drawing

    private func strip(_ width: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
        let pieces = edit.pieces(duration)
        let start = x(edit.start, width), end = x(edit.end(duration), width)
        return ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                frames(width)

                // Cut parts faded and striped; sped-up or slowed parts labelled.
                ForEach(pieces.filter { $0.removed || $0.rate != 1 }) { piece in
                    let left = x(piece.from, width), right = x(piece.to, width)
                    ZStack(alignment: .topLeading) {
                        if piece.removed {
                            Rectangle().fill(Theme.Palette.paper.opacity(0.8))
                            Stripes().stroke(Theme.Palette.ink3.opacity(0.5), lineWidth: 1)
                        } else {
                            Rectangle().fill(Theme.Palette.ink.opacity(0.18))
                            label(Self.rateName(piece.rate)).padding(4)
                        }
                    }
                    .frame(width: max(right - left, 1), height: Self.height, alignment: .topLeading)
                    .clipped()
                    .overlay(alignment: .leading) { Rectangle().fill(Theme.Palette.paper).frame(width: 1) }
                    .overlay(alignment: .trailing) { Rectangle().fill(Theme.Palette.paper).frame(width: 1) }
                    .offset(x: left)
                }

                // Trimmed off, faded.
                Rectangle().fill(Theme.Palette.paper.opacity(0.75))
                    .frame(width: max(start, 0), height: Self.height)
                Rectangle().fill(Theme.Palette.paper.opacity(0.75))
                    .frame(width: max(width - end, 0), height: Self.height)
                    .offset(x: end)

                // Clicks, as small dots along the top.
                ForEach(Array(clicks.enumerated()), id: \.offset) { _, click in
                    Circle()
                        .fill(Theme.Palette.paper)
                        .overlay(Circle().strokeBorder(Theme.Palette.ink.opacity(0.55), lineWidth: 1))
                        .frame(width: 5, height: 5)
                        .offset(x: x(click, width) - 2.5, y: 4)
                }

                // The zooms, along the bottom.
                ForEach(edit.zooms) { zoom in zoomPill(zoom, width) }

                // What's picked.
                if let span = selectedSpan {
                    let left = x(span.0, width), right = x(span.1, width)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Theme.Palette.ink.opacity(0.08))
                        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Theme.Palette.ink, lineWidth: 2))
                        .frame(width: max(right - left, 2), height: Self.height)
                        .offset(x: left)
                }
            }
            .frame(width: width, height: Self.height, alignment: .topLeading)
            .clipShape(shape)

            // What's kept, framed in ink, a handle at each end.
            trimFrame(from: start, to: end)

            // The playhead.
            Rectangle()
                .fill(Theme.Palette.ink)
                .frame(width: 2, height: Self.height + 8)
                .overlay(alignment: .top) { Circle().fill(Theme.Palette.ink).frame(width: 7, height: 7).offset(y: -3) }
                .offset(x: min(max(x(playhead, width), 0), width) - 1, y: -4)
        }
        .frame(width: width, height: Self.height, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { drag in changed(drag, width) }
                .onEnded { drag in ended(drag, width) }
        )
        .onContinuousHover { phase in
            switch phase {
            case .active(let point): cursor(at: point, width).set()
            case .ended: NSCursor.arrow.set()
            }
        }
    }

    private func frames(_ width: CGFloat) -> some View {
        HStack(spacing: 0) {
            if thumbnails.isEmpty {
                Theme.Palette.fill
            } else {
                ForEach(Array(thumbnails.enumerated()), id: \.offset) { _, image in
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: width / CGFloat(thumbnails.count), height: Self.height)
                        .clipped()
                }
            }
        }
        .frame(width: width, height: Self.height)
    }

    private func trimFrame(from start: CGFloat, to end: CGFloat) -> some View {
        let handle: CGFloat = 7
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .strokeBorder(Theme.Palette.ink, lineWidth: 2)
            HStack(spacing: 0) {
                grip(width: handle)
                Spacer(minLength: 0)
                grip(width: handle)
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        }
        .frame(width: max(end - start, handle * 2 + 4), height: Self.height)
        .offset(x: start)
        .allowsHitTesting(false)
    }

    private func grip(width: CGFloat) -> some View {
        Rectangle()
            .fill(Theme.Palette.ink)
            .overlay(Capsule().fill(Theme.Palette.paper.opacity(0.9)).frame(width: 2, height: 14))
            .frame(width: width)
    }

    private func zoomPill(_ zoom: ClipEdit.Zoom, _ width: CGFloat) -> some View {
        let left = x(zoom.from, width), right = x(zoom.to, width)
        let chosen = selection == .zoom(zoom.id)
        return HStack(spacing: 3) {
            Image(systemName: "plus.magnifyingglass").font(.system(size: 8.5, weight: .bold))
            if right - left > 50 {
                Text(String(format: "%.1f×", zoom.depth))
                    .font(Theme.Typography.ui(10.5, .medium))
                    .monospacedDigit()
            }
        }
        .foregroundStyle(Theme.Palette.paper)
        .frame(width: max(right - left, 14), height: Self.zoomBand - 3)
        .background(Capsule().fill(Theme.Palette.ink.opacity(chosen ? 1 : 0.72)))
        .offset(x: left, y: Self.height - Self.zoomBand)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typography.ui(Theme.Typography.caption, .medium))
            .monospacedDigit()
            .foregroundStyle(Theme.Palette.ink)
            .padding(.horizontal, 5)
            .frame(height: 16)
            .background(Capsule().fill(Theme.Palette.paper.opacity(0.94)))
            .fixedSize()
    }

    /// The span that's picked, in seconds.
    private var selectedSpan: (Double, Double)? {
        switch selection {
        case .range(let a, let b): return (a, b)
        case .segment(let id): return edit.pieces(duration).first { $0.id == id }.map { ($0.from, $0.to) }
        case .zoom, nil: return nil
        }
    }

    // MARK: The bar over a selection

    @ViewBuilder
    private func bar(_ width: CGFloat) -> some View {
        if let content = barContent, let span = barSpan {
            let middle = (x(span.0, width) + x(span.1, width)) / 2
            content
                .fixedSize()
                .modifier(Centered(middle: middle, limit: width))
                .offset(y: -Self.barHeight - 12)
                .transition(.opacity.combined(with: .offset(y: 4)))
        }
    }

    private var barSpan: (Double, Double)? {
        if case .zoom(let id) = selection { return edit.zooms.first { $0.id == id }.map { ($0.from, $0.to) } }
        return selectedSpan
    }

    private var barContent: AnyView? {
        switch selection {
        case .range:
            return AnyView(actions(rate: 1))
        case .segment(let id):
            guard let piece = edit.pieces(duration).first(where: { $0.id == id }) else { return nil }
            if piece.removed {
                return AnyView(barShape { BarButton(title: "Keep", symbol: "arrow.uturn.backward") { act(.keep) } })
            }
            return AnyView(actions(rate: piece.rate))
        case .zoom:
            return AnyView(barShape {
                Text("Drag the box to frame it")
                    .font(Theme.Typography.ui(Theme.Typography.caption))
                    .foregroundStyle(Theme.Palette.ink3)
                    .padding(.horizontal, 6)
                BarButton(title: "Remove", symbol: "trash") { act(.remove) }
            })
        case nil:
            return nil
        }
    }

    private func actions(rate: Double) -> some View {
        barShape {
            BarButton(title: "Cut", symbol: "scissors") { act(.cut) }
            divider
            ForEach(ClipEdit.rates, id: \.self) { option in
                BarButton(title: Self.rateName(option), chosen: rate == option) { act(.speed(option)) }
            }
            divider
            BarButton(title: "Zoom", symbol: "plus.magnifyingglass") { act(.zoom) }
        }
    }

    private var divider: some View {
        Rectangle().fill(Theme.Palette.hairline).frame(width: 1, height: 16).padding(.horizontal, 2)
    }

    private func barShape<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.control + 2, style: .continuous)
        return HStack(spacing: 2) { content() }
            .padding(3)
            .frame(height: Self.barHeight + 4)
            .background(FloatingSurface(shape: shape))
    }

    // MARK: The one gesture

    /// What the pointer would grab at `point`: a trim handle, a zoom or its
    /// end, or the strip.
    private func target(at point: CGPoint, _ width: CGFloat) -> Grab {
        let start = x(edit.start, width), end = x(edit.end(duration), width)
        let toStart = abs(point.x - start), toEnd = abs(point.x - end)
        if min(toStart, toEnd) <= 10 {
            return toStart <= toEnd ? .trimStart(edit.start) : .trimEnd(edit.end(duration))
        }
        if point.y >= Self.height - Self.zoomBand - 2 {
            for zoom in edit.zooms {
                let left = x(zoom.from, width), right = x(zoom.to, width)
                guard point.x >= left - 5, point.x <= right + 5 else { continue }
                if right - left > 18 {
                    if point.x <= left + 5 { return .zoomFrom(zoom) }
                    if point.x >= right - 5 { return .zoomTo(zoom) }
                }
                return .zoomMove(zoom)
            }
        }
        return .pending(seconds(point.x, width))
    }

    private func cursor(at point: CGPoint, _ width: CGFloat) -> NSCursor {
        switch target(at: point, width) {
        case .trimStart, .trimEnd, .zoomFrom, .zoomTo: return .resizeLeftRight
        case .zoomMove: return .openHand
        default: return .arrow
        }
    }

    private func changed(_ drag: DragGesture.Value, _ width: CGFloat) {
        let current = grab ?? target(at: drag.startLocation, width)
        if grab == nil {
            grab = current
            switch current {
            case .trimStart, .trimEnd, .zoomMove, .zoomFrom, .zoomTo: willChange()
            default: break
            }
        }
        let shift = Double(drag.translation.width / width) * duration
        let here = seconds(drag.location.x, width)
        switch current {
        case .pending(let from):
            if abs(drag.translation.width) >= 4 {
                grab = .range(from)
                selection = .range(min(from, here), max(from, here))
            }
            seek(here)
        case .range(let from):
            selection = .range(min(from, here), max(from, here))
            seek(here)
        case .trimStart(let from):
            edit.start = min(max(from + shift, 0), edit.end(duration) - 0.3)
            seek(edit.start)
        case .trimEnd(let from):
            let value = max(min(from + shift, duration), edit.start + 0.3)
            edit.end = value >= duration - 0.01 ? nil : value
            seek(value)
        case .zoomMove(let zoom):
            let (low, high) = room(around: zoom.id)
            let length = zoom.to - zoom.from
            let from = min(max(zoom.from + shift, low), high - length)
            update(zoom.id) { $0.from = from; $0.to = from + length }
        case .zoomFrom(let zoom):
            let (low, _) = room(around: zoom.id)
            update(zoom.id) { $0.from = min(max(zoom.from + shift, low), zoom.to - 0.6) }
        case .zoomTo(let zoom):
            let (_, high) = room(around: zoom.id)
            update(zoom.id) { $0.to = max(min(zoom.to + shift, high), zoom.from + 0.6) }
        }
    }

    private func ended(_ drag: DragGesture.Value, _ width: CGFloat) {
        defer { grab = nil }
        let moved = abs(drag.translation.width) >= 4
        switch grab {
        case .pending(let t):
            // A click: on a cut or sped-up part, pick it; elsewhere, let go
            // of what's picked.
            let piece = edit.pieces(duration).first { t >= $0.from && t <= $0.to && ($0.removed || $0.rate != 1) }
            withAnimation(Theme.Motion.snappy) { selection = piece.map { .segment($0.id) } }
        case .range(let from):
            let to = seconds(drag.location.x, width)
            if abs(to - from) < 0.15 { selection = nil }
        case .zoomMove(let zoom) where !moved:
            withAnimation(Theme.Motion.snappy) { selection = selection == .zoom(zoom.id) ? nil : .zoom(zoom.id) }
        default:
            break
        }
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

/// Keeps the selection bar centred over the selection and inside the strip.
private struct Centered: ViewModifier {
    let middle: CGFloat
    let limit: CGFloat
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .background(GeometryReader { box in
                Color.clear
                    .onAppear { width = box.size.width }
                    .onChange(of: box.size.width) { width = $0 }
            })
            .offset(x: min(max(middle - width / 2, 0), max(limit - width, 0)))
    }
}

/// A word (and maybe an icon) in the selection bar; the chosen speed filled.
private struct BarButton: View {
    let title: String
    var symbol: String? = nil
    var chosen = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 10.5, weight: .medium)) }
                Text(title).monospacedDigit()
            }
            .font(Theme.Typography.ui(Theme.Typography.control, chosen ? .medium : .regular))
            .foregroundStyle(chosen ? Theme.Palette.paper : Theme.Palette.ink)
            .padding(.horizontal, symbol == nil ? 8 : 10)
            .frame(minWidth: 30)
            .frame(height: EditTimeline.barHeight - 2)
            .background(shape.fill(chosen ? Theme.Palette.ink : (hovering ? Theme.Palette.fillHover : .clear)))
            .contentShape(shape)
        }
        .buttonStyle(PressStyle())
        .onHover { inside in withAnimation(Theme.Motion.hover) { hovering = inside } }
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
