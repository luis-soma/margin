import AppKit
import SwiftUI

// MARK: - Scales

/// The repo's five time scales, from close up to far out. One continuous
/// view: you always scroll through everything, and zooming only changes how
/// much of it fits on screen.
extension TimeScale {
    /// The span a section covers at this scale, for its headline.
    var level: String {
        switch self {
        // Close up and the days view both show single days, the same span,
        // so they share one title: only the pictures change size between them.
        case .day, .days: return "day"
        case .weeks: return "week"
        case .months: return "month"
        }
    }
}

enum TimeScale: Int, CaseIterable {
    /// One day at a time: each day a section, captures large, each with its
    /// title and description under it, lined up across the row like the
    /// names in Finder. The only scale with words under the pictures.
    case day
    /// Still a section per day, the captures smaller, so more days fit.
    case days
    /// A section per week.
    case weeks
    /// A section per month; captures smallest.
    case months

    /// The box a capture fits in at this scale (it keeps its own shape).
    /// The same whatever the window's width: a wider window fits more in a
    /// row, it doesn't make them bigger. Sizes come from `Archive.Timeline`.
    var maxSize: CGSize { Archive.Timeline.boxes[rawValue] }

    /// The note under each picture: its size, or nil where there's none.
    var annotationSize: CGFloat? { Archive.Size.annotation[rawValue] }
}

// MARK: - Layout

/// Where every capture and label sits at one scale, for one width.
struct TimeLayout {
    struct Label: Identifiable {
        enum Kind { case group, row }
        let id: String
        let kind: Kind
        let title: String
        var frame: CGRect
        /// The captures it names, for its AI line.
        let entries: [Entry]
        let wantsAI: Bool
        /// The time span, shown under the date where there's no AI line.
        var span: String? = nil
    }

    var scale: TimeScale = .day
    var frames: [UUID: CGRect] = [:]
    var labels: [Label] = []
    var height: CGFloat = 0
    /// Where the timeline's vertical line runs.
    var lineX: CGFloat = 0
    /// Where captures and headers start, right of the line.
    var contentX: CGFloat = 0
    /// Captures in the order they're laid out: newest first throughout.
    var order: [UUID] = []
    /// Where each day you worked sits on the timeline's line, by the start of
    /// that day: beside its section's date, so a week's days share one dot at
    /// the week scale, a month's at the month scale and so on.
    var dayAnchors: [Date: CGFloat] = [:]

    /// Left of the date column.
    static let leading = Archive.Timeline.leading
    /// The date and its count, left of the line.
    static var periodHeight: CGFloat {
        Archive.lineHeight(Archive.Size.date) + dateToCount + Archive.lineHeight(Archive.Size.count)
    }
    /// Between the date's line and the count's.
    static let dateToCount: CGFloat = 4
    /// A headline's line.
    static var headlineHeight: CGFloat { Archive.headlineLineHeight(Archive.Size.headline) }
    /// From the headline's line to the first row of pictures.
    static let headlineGap = Archive.Space.x3

    /// From the top of a line of text at `size` to the middle of its capitals.
    static func capCenter(_ size: CGFloat) -> CGFloat {
        let font = Archive.nsFont(size)
        return font.ascender - font.capHeight / 2
    }

    /// From the top of a line of text at `size` to the top of its capitals.
    static func capTop(_ size: CGFloat) -> CGFloat {
        let font = Archive.nsFont(size)
        return font.ascender - font.capHeight
    }

    /// From the top of a line of text at `size` to its baseline.
    static func baseline(_ size: CGFloat) -> CGFloat { Archive.nsFont(size).ascender }

    /// How far the date sits below the section's top, so it shares the
    /// larger headline's baseline.
    static var dateDrop: CGFloat { max(0, baseline(Archive.Size.headline) - baseline(Archive.Size.date)) }
    /// Shape of a capture whose picture size isn't known.
    static let defaultAspect: CGFloat = 1.5

    /// From a section's top to the middle of its date's capitals, where the
    /// tick on the line sits.
    static var tickOffset: CGFloat { dateDrop + capCenter(Archive.Size.date) }

    /// - Parameters:
    ///   - entries: oldest first.
    ///   - aspect: width over height of a capture's picture, when known.
    static func make(_ entries: [Entry], scale: TimeScale, width: CGFloat, aspect: (Entry) -> CGFloat? = { _ in nil }) -> TimeLayout {
        place(groups(entries, scale: scale, calendar: .current), scale: scale, width: width, aspect: aspect)
    }

    /// Places already-grouped captures. Grouping is the slow part and only
    /// changes with the captures; placing is quick enough to redo for every
    /// step of a pinch.
    static func place(_ groups: [Group], scale: TimeScale, width: CGFloat, aspect: (Entry) -> CGFloat?) -> TimeLayout {
        let T = Archive.Timeline.self
        // Close up and the days view label the same days, so their labels
        // share ids and carry across the zoom between them.
        let s = scale == .days ? TimeScale.day.rawValue : scale.rawValue
        var layout = TimeLayout()
        layout.scale = scale
        // The date column, 16 pt, the line, 16 pt, the work.
        let lineX = T.lineX
        let contentX = lineX + T.gutter
        layout.lineX = lineX
        layout.contentX = contentX
        let available = max(120, width - contentX - T.trailing)
        let box = scale.maxSize
        let tick = tickOffset
        // An artifact with a note takes the note's line under it too.
        // At the day scale every artifact has its title and two lines of description under it.
        let noteRoom = scale == .day ? DetailNote.height : 0

        let calendar = Calendar.current
        // One section per day, week, month or year: the date and how much was
        // captured on the left, what happened level with it on the right, and
        // the captures under that headline, newest first like the timeline,
        // each in its own shape, rows top-aligned.
        var y = T.top
        for (groupIndex, group) in groups.enumerated() {
            if groupIndex > 0 { y += T.sectionGap }
            layout.labels.append(Label(
                id: "r\(s)-\(group.key)", kind: .row, title: group.title,
                frame: CGRect(x: leading, y: y + dateDrop, width: lineX - T.gutter - leading, height: periodHeight),
                entries: group.entries, wantsAI: false, span: fact(about: group.entries, scale: scale, calendar: calendar)
            ))
            layout.labels.append(Label(
                id: "g\(s)-\(group.key)", kind: .group, title: group.title,
                frame: CGRect(x: contentX, y: y, width: available, height: headlineHeight),
                entries: group.entries, wantsAI: true
            ))
            // The section's tick on the line, level with its date.
            for entry in group.entries { layout.dayAnchors[calendar.startOfDay(for: entry.createdAt)] = y + tick }
            // Justified rows, like a photo grid: every capture in a row
            // shares one height and keeps its own shape, and each full row
            // runs exactly from the line to the right margin. No cells, so
            // no empty space boxed around a wide or tall picture. The last
            // row keeps the scale's height rather than stretching.
            var rowTop = y + headlineHeight + headlineGap, rowHeight: CGFloat = 0
            var row: [(id: UUID, aspect: CGFloat)] = []
            func flush(full: Bool) {
                guard !row.isEmpty else { return }
                let gaps = T.itemGap * CGFloat(row.count - 1)
                let aspects = row.reduce(0) { $0 + $1.aspect }
                let fit = (available - gaps) / aspects
                let h = (full ? fit : min(box.height, fit)).rounded()
                var x = contentX
                for (index, item) in row.enumerated() {
                    var w = (h * item.aspect).rounded()
                    // The last one in a full row ends right on the margin.
                    if full, index == row.count - 1 { w = max(1, contentX + available - x) }
                    layout.frames[item.id] = CGRect(x: x, y: rowTop, width: w, height: h)
                    layout.order.append(item.id)
                    x += w + T.itemGap
                }
                rowHeight = h + noteRoom
                rowTop += rowHeight + T.rowGap
                row = []
            }
            for entry in group.entries.reversed() {
                let a = min(max(aspect(entry) ?? defaultAspect, 0.25), 5)
                row.append((entry.id, a))
                let natural = row.reduce(0) { $0 + box.height * $1.aspect } + T.itemGap * CGFloat(row.count - 1)
                if natural >= available { flush(full: true) }
            }
            flush(full: false)
            // `rowTop` has moved past the last row's gap; step back to its bottom.
            rowTop -= T.rowGap + rowHeight
            y = max(y + dateDrop + periodHeight, rowTop + rowHeight)
        }
        layout.height = y + T.sectionGap
        return layout
    }

    struct Row { var key: String; var title: String; var entries: [Entry] }
    struct Group { var key: String; var title: String; var rows: [Row]; var entries: [Entry] }

    /// Groups and rows, newest first; entries in a row oldest first.
    static func groups(_ entries: [Entry], scale: TimeScale, calendar: Calendar) -> [Group] {
        let (groupUnit, rowUnit): (Calendar.Component, Calendar.Component?) = {
            switch scale {
            case .day, .days: return (.day, nil)   // rows are sessions
            case .weeks: return (.weekOfYear, .day)
            case .months: return (.month, .weekOfYear)
            }
        }()
        func start(_ date: Date, _ unit: Calendar.Component) -> Date {
            calendar.dateInterval(of: unit, for: date)?.start ?? date
        }
        let byGroup = Dictionary(grouping: entries) { start($0.createdAt, groupUnit) }
        // Within one year the year goes without saying.
        let showsYear = Set(entries.map { calendar.component(.year, from: $0.createdAt) }).count > 1
        return byGroup.keys.sorted(by: >).map { groupStart in
            let members = byGroup[groupStart]!.sorted { $0.createdAt < $1.createdAt }
            var rows: [Row]
            if let rowUnit {
                let byRow = Dictionary(grouping: members) { start($0.createdAt, rowUnit) }
                rows = byRow.keys.sorted(by: >).map { rowStart in
                    Row(key: key(rowStart), title: rowTitle(rowStart, unit: rowUnit, calendar: calendar), entries: byRow[rowStart]!)
                }
            } else {
                // A day's sessions: a pause over 20 minutes starts a new one.
                // The day's date is its header; each session row shows only its times.
                rows = Session.group(members, gap: 20 * 60).reversed().map { session in
                    Row(key: key(session.start), title: span(of: session.entries) ?? "", entries: session.entries)
                }
            }
            return Group(key: key(groupStart), title: groupTitle(groupStart, unit: groupUnit, calendar: calendar, showsYear: showsYear), rows: rows, entries: members)
        }
    }

    private static func key(_ date: Date) -> String { String(Int(date.timeIntervalSince1970)) }

    /// The fact under a section's date: how many artifacts it holds.
    static func fact(about entries: [Entry], scale: TimeScale, calendar: Calendar) -> String? {
        entries.isEmpty ? nil : Archive.count(entries.count)
    }

    private static func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate(pattern)
        return formatter.string(from: date)
    }

    /// A section's date: "TODAY", "OCT 15", "SEP 26 - OCT 2", "OCTOBER", "2026".
    /// - Parameter showsYear: false when the whole project falls within one
    ///   year: "OCT" rather than "OCT 2026".
    static func groupTitle(_ start: Date, unit: Calendar.Component, calendar: Calendar, showsYear: Bool = true) -> String {
        switch unit {
        case .day: return Archive.day(start, calendar: calendar)
        case .weekOfYear: return Archive.week(start, calendar: calendar)
        // Written out in full; the year only when the project spans years.
        case .month: return Archive.fullMonth(start, calendar: calendar) + (showsYear ? " \(calendar.component(.year, from: start))" : "")
        default: return String(calendar.component(.year, from: start))
        }
    }

    /// A day as the archive writes it: "Today", "Yesterday", "Oct 15".
    static func dayLabel(_ date: Date) -> String {
        Archive.day(date)
    }

    /// "10:02 AM – 12:01 PM", or one time for a single moment.
    static func span(of entries: [Entry]) -> String? {
        guard let first = entries.first?.createdAt, let last = entries.last?.createdAt else { return nil }
        let start = first.formatted(date: .omitted, time: .shortened)
        guard last.timeIntervalSince(first) > 60 else { return start }
        return "\(start) – \(last.formatted(date: .omitted, time: .shortened))"
    }

    static func rowTitle(_ start: Date, unit: Calendar.Component, calendar: Calendar) -> String {
        switch unit {
        case .day: return dayLabel(start)
        case .weekOfYear: return weekTitle(start, calendar: calendar)
        default: return format(start, "MMMM")
        }
    }

    /// "Oct 12 – 18", or "Sep 28 – Oct 4" across a month boundary.
    static func weekTitle(_ start: Date, calendar: Calendar) -> String {
        let end = calendar.date(byAdding: .day, value: 6, to: start) ?? start
        let sameMonth = calendar.component(.month, from: start) == calendar.component(.month, from: end)
        return "\(format(start, "MMMd")) – \(sameMonth ? format(end, "d") : format(end, "MMMd"))"
    }
}

// MARK: - Zoom state

/// The zoom (a continuous value from 0, day, to 3, year) and the scroll
/// offset. Pinching moves the zoom freely and the layout morphs between the
/// scales on either side of it; letting go settles on the nearest scale.
/// Whatever is under the pointer stays under it, so you can see where you
/// zoom to.
@MainActor
final class TimeZoomModel: ObservableObject {
    @Published private(set) var zoom: CGFloat
    @Published private(set) var offset: CGFloat = 0
    /// The scale zooming is heading for, or resting on.
    private(set) var settled: Int
    var onSettle: ((Int) -> Void)?

    private(set) var entries: [Entry] = []
    private(set) var byID: [UUID: Entry] = [:]
    private(set) var size: CGSize = .zero
    /// Width over height of a capture's picture, when known.
    var aspect: (Entry) -> CGFloat? = { _ in nil }
    private var cache: [Int: TimeLayout] = [:]
    private var cacheKey = ""
    private var animation: Timer?

    /// When the window's width changes how many captures fit across, the
    /// rows reflow: every capture, date and dot glides from where it was to
    /// its new place on the zoom's own curve, instead of jumping there.
    private struct Reflow {
        let scale: TimeScale
        let frames: [UUID: CGRect]
        let labels: [String: CGRect]
        let anchors: [Date: CGFloat]
        let height: CGFloat
        let started: Date
    }
    private var reflow: Reflow?
    private var reflowTimer: Timer?
    static let reflowDuration: TimeInterval = 0.45

    init(level: Int) {
        zoom = CGFloat(level)
        settled = level
    }

    /// Picture sizes changed under the same captures: lay out again.
    func relayout() {
        guard size.width > 0 else { return }
        cacheKey = ""
        update(entries: entries, size: size)
    }

    func update(entries: [Entry], size: CGSize) {
        let key = "\(Int(size.width))|\(entries.count)|\(entries.first?.id.uuidString ?? "")|\(entries.last?.id.uuidString ?? "")|\(entries.last?.createdAt.timeIntervalSince1970 ?? 0)"
        self.entries = entries
        byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let widthChanged = Int(size.width) != Int(self.size.width) && self.size.width > 0
        // Where everything is on screen now, in case the new width reflows the rows.
        let before: TimeLayout? = widthChanged && zoom == CGFloat(settled) && !cache.isEmpty
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? layout(settled) : nil
        self.size = size
        if key != cacheKey {
            cacheKey = key
            cache = [:]
            if let before { startReflow(old: before, new: layout(settled)) }
            offset = clamped(offset)
            objectWillChange.send()
        }
    }

    /// Starts the glide when a capture has moved to another row; while one
    /// runs, small changes in spacing just follow the window.
    private func startReflow(old: TimeLayout, new: TimeLayout) {
        // Rows changed between the old width's layout and the new one's
        // (not just where a glide in progress has got to).
        let moved = new.frames.contains { id, rect in
            guard let was = old.frames[id] else { return false }
            return abs(was.minY - rect.minY) > 1
        }
        guard moved else { return }
        // From wherever things are on screen now, mid-glide included.
        let before = shown(old)
        reflow = Reflow(
            scale: before.scale, frames: before.frames,
            labels: Dictionary(before.labels.map { ($0.id, $0.frame) }, uniquingKeysWith: { a, _ in a }),
            anchors: before.dayAnchors, height: before.height, started: Date()
        )
        guard reflowTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, let reflow = self.reflow,
                      Date().timeIntervalSince(reflow.started) < Self.reflowDuration else {
                    self?.reflow = nil
                    self?.reflowTimer = nil
                    timer.invalidate()
                    self?.objectWillChange.send()
                    return
                }
                self.objectWillChange.send()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        reflowTimer = timer
    }

    /// `layout` as it shows right now: partway from the old rows to the new
    /// ones while the rows reflow, otherwise as it is.
    func shown(_ layout: TimeLayout) -> TimeLayout {
        guard let reflow, reflow.scale == layout.scale else { return layout }
        let t = Self.ease(CGFloat(min(1, Date().timeIntervalSince(reflow.started) / Self.reflowDuration)))
        guard t < 1 else { return layout }
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * t }
        func mix(_ a: CGRect, _ b: CGRect) -> CGRect {
            CGRect(x: mix(a.minX, b.minX), y: mix(a.minY, b.minY), width: mix(a.width, b.width), height: mix(a.height, b.height))
        }
        var result = layout
        for (id, rect) in layout.frames { if let old = reflow.frames[id] { result.frames[id] = mix(old, rect) } }
        result.labels = layout.labels.map { label in
            var label = label
            if let old = reflow.labels[label.id] { label.frame = mix(old, label.frame) }
            return label
        }
        for (day, y) in layout.dayAnchors { if let old = reflow.anchors[day] { result.dayAnchors[day] = mix(old, y) } }
        result.height = mix(reflow.height, layout.height)
        return result
    }

    func layout(_ scale: Int) -> TimeLayout {
        let index = min(max(scale, 0), TimeScale.allCases.count - 1)
        if let cached = cache[index] { return cached }
        let made = TimeLayout.make(entries, scale: TimeScale(rawValue: index)!, width: max(size.width, 200), aspect: aspect)
        cache[index] = made
        return made
    }

    /// The two scales around the zoom and how far between them it is.
    var blend: (low: TimeLayout, high: TimeLayout, fraction: CGFloat) {
        let low = Int(zoom.rounded(.down))
        let fraction = zoom - CGFloat(low)
        return (layout(low), layout(low + 1), fraction)
    }

    /// Eases the morph so it starts and ends gently.
    static func ease(_ t: CGFloat) -> CGFloat { t * t * (3 - 2 * t) }

    /// The grid moves as one, like Photos: every capture follows the zoom
    /// directly, so a pinch tracks your fingers.
    func progress(of id: UUID, in blend: (low: TimeLayout, high: TimeLayout, fraction: CGFloat)) -> CGFloat {
        blend.fraction
    }

    /// Slow out, quick through the middle, slow in (cubic); no overshoot.
    nonisolated static func easeInOut(_ t: Double) -> Double {
        t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    func frame(of id: UUID, in blend: (low: TimeLayout, high: TimeLayout, fraction: CGFloat)) -> CGRect? {
        guard let a = blend.low.frames[id] else { return nil }
        guard let b = blend.high.frames[id], blend.fraction > 0 else { return a }
        let t = progress(of: id, in: blend)
        return CGRect(
            x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
            width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t
        )
    }

    var contentHeight: CGFloat {
        let b = blend
        return b.low.height + (b.high.height - b.low.height) * b.fraction
    }

    private func clamped(_ value: CGFloat) -> CGFloat {
        min(max(0, value), max(0, contentHeight - size.height))
    }

    // MARK: Input

    func scroll(by delta: CGFloat) {
        offset = clamped(offset - delta)
    }

    /// Pinching past the closest or farthest scale: the whole page gives a
    /// little, growing or shrinking about your fingers, and springs back
    /// when you let go (Photos does the same).
    @Published private(set) var stretch: CGFloat = 1
    private(set) var stretchAnchor = UnitPoint.center
    private var overPinch: CGFloat = 0

    /// Pinch: spread to zoom in (toward a day), pinch to zoom out (toward a year).
    func pinch(by magnification: CGFloat, at point: CGPoint) {
        stopAnimating()
        let last = CGFloat(TimeScale.allCases.count - 1)
        let delta = magnification * 1.6 // positive: in, toward a day
        if overPinch == 0 {
            let raw = zoom - delta
            // Reaching an end: zoom up to it; what's left stretches the page.
            if raw < 0 { overPinch = -raw } else if raw > last { overPinch = last - raw }
            setZoom(min(max(raw, 0), last), anchor: point)
        } else {
            // Past the closest scale overPinch is positive, past the farthest negative.
            let past = overPinch + delta
            if overPinch > 0, past < 0 {
                overPinch = 0
                setZoom(min(last, -past), anchor: point)
            } else if overPinch < 0, past > 0 {
                overPinch = 0
                setZoom(max(0, last - past), anchor: point)
            } else {
                overPinch = past
            }
        }
        let give = 0.12 * (1 - 1 / (1 + abs(overPinch) * 1.5))
        stretch = 1 + (overPinch > 0 ? give : -give)
        stretchAnchor = UnitPoint(x: point.x / max(1, size.width), y: point.y / max(1, size.height))
    }

    func endPinch(at point: CGPoint) {
        if overPinch != 0 || stretch != 1 {
            overPinch = 0
            withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) { stretch = 1 }
        }
        settle(on: Int(zoom.rounded()), anchor: point)
    }

    /// Animates to a scale, keeping what's at `anchor` in place.
    func settle(on level: Int, anchor: CGPoint? = nil) {
        let target = min(max(level, 0), TimeScale.allCases.count - 1)
        settled = target
        onSettle?(target)
        let point = anchor ?? CGPoint(x: size.width / 2, y: size.height / 2)
        let from = zoom, to = CGFloat(target)
        guard abs(from - to) > 0.001 else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            setZoom(to, anchor: point)
            return
        }
        stopAnimating()
        let started = Date()
        // Eased in and out, no bounce; a little longer for a longer way.
        let duration = 0.42 + 0.14 * Double(min(abs(to - from), 3) - 1)
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let t = min(1, Date().timeIntervalSince(started) / duration)
                self.setZoom(from + (to - from) * CGFloat(Self.easeInOut(t)), anchor: point)
                if t >= 1 { self.stopAnimating() }
            }
        }
        // Every run loop mode, so it keeps going while you drag the slider.
        RunLoop.main.add(timer, forMode: .common)
        animation = timer
    }

    private func stopAnimating() {
        animation?.invalidate()
        animation = nil
        reflow = nil
    }

    /// Changes the zoom while the capture nearest `anchor` stays put on
    /// screen; at the very top of the timeline, it stays at the top.
    private func setZoom(_ newZoom: CGFloat, anchor: CGPoint) {
        let z = min(max(newZoom, 0), CGFloat(TimeScale.allCases.count - 1))
        // Scrolled all the way up: every scale opens at its top too, whether
        // by slider or pinch, so you never land somewhere unexpected.
        if offset <= 0.5 {
            zoom = z
            offset = 0
            return
        }
        let before = blend
        let point = CGPoint(x: anchor.x, y: anchor.y + offset)
        var anchorID: UUID?
        var best = CGFloat.infinity
        for id in before.low.order {
            guard let rect = frame(of: id, in: before) else { continue }
            let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
            let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
            let distance = dx * dx + dy * dy * 4 // rows matter more than columns
            if distance < best { best = distance; anchorID = id }
        }
        let oldRect = anchorID.flatMap { frame(of: $0, in: before) }
        zoom = z
        if let anchorID, let oldRect, let newRect = frame(of: anchorID, in: blend) {
            // Keep the same spot of that capture under the pointer.
            let within = oldRect.height > 0 ? (point.y - oldRect.minY) / oldRect.height : 0.5
            let fraction = min(max(within, 0), 1)
            offset = clamped(newRect.minY + fraction * newRect.height - anchor.y)
        } else {
            offset = clamped(offset)
        }
    }
}

// MARK: - View

/// The repo's captures on a timeline you zoom from a day to a year, by
/// pinching or with the slider, and scroll through continuously.
struct TimeZoomView: View {
    let entries: [Entry]
    @Binding var level: Int
    /// The zoom while you pinch (nil otherwise), for the slider to follow.
    @Binding var pinchZoom: CGFloat?
    /// Off while something covers the timeline (the focus view, a menu).
    let interactive: Bool
    /// The cluster view: the artifacts lifted onto a canvas over the timeline.
    var clustering = false
    /// The map's zoom, continuous.
    @Binding var mapDepth: CGFloat
    @StateObject private var model: TimeZoomModel
    /// The canvas is up (from the moment clustering starts until the
    /// artifacts have landed back on the timeline).
    @State private var canvasUp = false
    @EnvironmentObject private var intelligence: Intelligence
    @EnvironmentObject private var store: EntryStore

    init(entries: [Entry], level: Binding<Int>, pinchZoom: Binding<CGFloat?> = .constant(nil), interactive: Bool, clustering: Bool = false,
         mapDepth: Binding<CGFloat> = .constant(0)) {
        _mapDepth = mapDepth
        self.entries = entries
        _level = level
        _pinchZoom = pinchZoom
        self.interactive = interactive
        self.clustering = clustering
        _model = StateObject(wrappedValue: TimeZoomModel(level: level.wrappedValue))
    }

    var body: some View {
        GeometryReader { geo in
            content(size: geo.size)
                .onAppear {
                    model.aspect = { [store] in store.aspectRatio(for: $0) }
                    model.update(entries: entries, size: geo.size)
                }
                .onChange(of: geo.size) { model.update(entries: entries, size: $0) }
        }
        // Use the new list handed in: the closure's own `entries` can still be
        // the previous one, which made toggles show the state before.
        .onChange(of: entries) { new in model.update(entries: new, size: model.size) }
        // Picture sizes that were in iCloud arrived: lay out with the real ones.
        .onChange(of: store.aspectsVersion) { _ in model.relayout() }
        .onChange(of: level) { new in
            if new != model.settled { model.settle(on: new) }
        }
        .onAppear { model.onSettle = { level = $0 } }
        .onChange(of: clustering) { on in if on { canvasUp = true } }
        // The welcome tour zooms for you: the timeline glides to the scale and
        // the slider rides the very same zoom, frame by frame, like a pinch.
        .onReceive(NotificationCenter.default.publisher(for: OnboardingTour.zoomTo)) { note in
            guard let target = note.object as? Int else { return }
            model.settle(on: target)
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { timer in
                MainActor.assumeIsolated {
                    pinchZoom = model.zoom
                    if abs(model.zoom - CGFloat(target)) < 0.002 {
                        timer.invalidate()
                        pinchZoom = nil
                    }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    @ViewBuilder
    private func content(size: CGSize) -> some View {
        let raw = model.blend
        let blend = (low: model.shown(raw.low), high: model.shown(raw.high), fraction: raw.fraction)
        let t = TimeZoomModel.ease(blend.fraction)
        let top = model.offset - 60, bottom = model.offset + size.height + 60
        let visible = blend.low.order.compactMap { id -> (Entry, CGRect)? in
            guard let rect = model.frame(of: id, in: blend), rect.maxY >= top, rect.minY <= bottom,
                  let entry = model.byID[id] else { return nil }
            return (entry, rect)
        }
        let labels = labelsInView(blend: blend, t: t, top: top, bottom: bottom)
        // Titles and descriptions under the pictures: only at the day scale,
        // and only while the pictures are all but in their places there, so
        // they never drift about mid-zoom. Out: gone in the first stretch.
        // In: they come in over the last.
        let noteOpacity: CGFloat = blend.low.scale == .day ? max(0, 1 - t / 0.12) : 0
        // The link mark on linked artifacts: only at the detail and day
        // scales, fading as you zoom out to the weeks.
        let closeUp = { (scale: TimeScale) -> CGFloat in scale.rawValue <= TimeScale.days.rawValue ? 1 : 0 }
        let linkOpacity = closeUp(blend.low.scale) * (1 - t) + closeUp(blend.high.scale) * t

        ZStack(alignment: .topLeading) {
            // The timeline's line with a tick beside every section's date.
            TimeRail(low: blend.low, high: blend.high, fraction: blend.fraction, offset: model.offset)
                .frame(width: size.width, height: size.height)
            ForEach(labels, id: \.label.id) { item in
                TimeLabel(label: item.label, scale: item.scale)
                    .frame(width: item.label.frame.width, height: item.label.frame.height, alignment: .topLeading)
                    .offset(x: item.label.frame.minX, y: item.label.frame.minY - model.offset)
                    .opacity(item.opacity)
            }
            ForEach(visible, id: \.0.id) { entry, rect in
                ZoomThumb(entry: entry, size: rect.size)
                    .overlay(alignment: .topTrailing) {
                        // Mark top right: where it lives (Figma, a build, a link).
                        // No screenshot mark on plain captures.
                        if linkOpacity > 0.01, let mark = CornerMark.of(entry) {
                            mark
                                .padding(6)
                                .opacity(linkOpacity)
                        }
                    }
                    .offset(x: rect.minX, y: rect.minY - model.offset)
                if noteOpacity > 0.01 {
                    // Under the picture, as wide as it (rows are justified,
                    // so the picture's edge is the note's edge).
                    DetailNote(entry: entry)
                        .frame(width: max(rect.width, 1), alignment: .leading)
                        .offset(x: rect.minX, y: rect.maxY + Archive.Timeline.annotationGap - model.offset)
                        .opacity(noteOpacity)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        // Pinched past the closest or farthest scale: the page gives a little.
        .scaleEffect(model.stretch, anchor: model.stretchAnchor)
        // Under the canvas while it's up: its artifacts start and end exactly here.
        // Fades out under the canvas; back, it's there at once, exactly
        // where the artifacts landed, so nothing flashes.
        .opacity(canvasUp ? 0 : 1)
        .animation(canvasUp ? .easeInOut(duration: 0.25) : nil, value: canvasUp)
        .overlay(alignment: .topLeading) {
            if canvasUp {
                ClusterCanvas(entries: entries, start: timelineFrames(blend: blend), size: size, active: clustering, level: $level, pinchZoom: $pinchZoom,
                              mapDepth: $mapDepth) {
                    canvasUp = false
                }
            }
        }
        .clipped()
        .contentShape(Rectangle())
        .background(ZoomEvents(
            enabled: interactive && !canvasUp,
            scroll: { model.scroll(by: $0) },
            pinch: {
                model.pinch(by: $0, at: $1)
                pinchZoom = model.zoom
            },
            pinchEnded: {
                pinchZoom = nil
                model.endPinch(at: $0)
            }
        ))
        .overlay(alignment: .trailing) { scrollIndicator(size: size) }
        // Ask for the AI lines of the labels in view.
        .task(id: labels.filter(\.label.wantsAI).map(\.label.id).joined(separator: ",")) {
            for item in labels where item.label.wantsAI && item.opacity > 0.5 {
                intelligence.requestSummary(for: item.label.entries, level: item.scale.level)
            }
        }
    }

    /// Where every artifact is on the timeline right now, in this view's
    /// coordinates (those off screen too): where the canvas picks them up.
    private func timelineFrames(blend: (low: TimeLayout, high: TimeLayout, fraction: CGFloat)) -> [UUID: CGRect] {
        var frames: [UUID: CGRect] = [:]
        for id in blend.low.order {
            if let rect = model.frame(of: id, in: blend) { frames[id] = rect.offsetBy(dx: 0, dy: -model.offset) }
        }
        return frames
    }

    private struct PlacedLabel {
        let label: TimeLayout.Label
        let scale: TimeScale
        let opacity: CGFloat
    }

    /// Labels of the scale you're leaving fade out as those of the next fade in.
    private func labelsInView(blend: (low: TimeLayout, high: TimeLayout, fraction: CGFloat), t: CGFloat, top: CGFloat, bottom: CGFloat) -> [PlacedLabel] {
        let lowScale = blend.low.scale, highScale = blend.high.scale
        var result: [PlacedLabel] = []
        // Close up and the days view label the same days with the same words:
        // between them the labels don't fade, they stay and move with the
        // pictures under them.
        if lowScale == .day, highScale == .days {
            let f = blend.fraction
            let targets = Dictionary(blend.high.labels.map { ($0.id, $0.frame) }, uniquingKeysWith: { a, _ in a })
            for var label in blend.low.labels {
                if f > 0, let b = targets[label.id] {
                    let a = label.frame
                    label.frame = CGRect(x: a.minX + (b.minX - a.minX) * f, y: a.minY + (b.minY - a.minY) * f,
                                         width: a.width + (b.width - a.width) * f, height: a.height + (b.height - a.height) * f)
                }
                if label.frame.maxY >= top && label.frame.minY <= bottom {
                    result.append(PlacedLabel(label: label, scale: lowScale, opacity: 1))
                }
            }
            return result
        }
        // Fade quickly so two sets of words never sit on top of each other for
        // long: the old ones are gone a third of the way in, the new ones
        // arrive in the last third.
        let lowOpacity = max(0, 1 - t * 3), highOpacity = max(0, t * 3 - 2)
        // Each section's words ride with its bead while they fade: they move
        // by as much as the bead of their newest day has moved from its own
        // spot, on the beads' merge curve.
        let g = TimeRail.merge(blend.fraction)
        let calendar = Calendar.current
        func riding(_ label: TimeLayout.Label, from own: TimeLayout) -> TimeLayout.Label {
            guard blend.fraction > 0, let newest = label.entries.map(\.createdAt).max() else { return label }
            let day = calendar.startOfDay(for: newest)
            guard let a = blend.low.dayAnchors[day], let anchor = own.dayAnchors[day] else { return label }
            let bead = a + ((blend.high.dayAnchors[day] ?? a) - a) * g
            var moved = label
            moved.frame.origin.y += bead - anchor
            return moved
        }
        for label in blend.low.labels.map({ riding($0, from: blend.low) })
        where label.frame.maxY >= top && label.frame.minY <= bottom && lowOpacity > 0 {
            result.append(PlacedLabel(label: label, scale: lowScale, opacity: lowOpacity))
        }
        if blend.fraction > 0, highScale != lowScale {
            for label in blend.high.labels.map({ riding($0, from: blend.high) })
            where label.frame.maxY >= top && label.frame.minY <= bottom && highOpacity > 0 {
                result.append(PlacedLabel(label: label, scale: highScale, opacity: highOpacity))
            }
        }
        return result
    }

    /// A thin bar on the right showing where you are in everything.
    @ViewBuilder
    private func scrollIndicator(size: CGSize) -> some View {
        let total = model.contentHeight
        if total > size.height + 1 {
            let height = max(24, size.height * size.height / total)
            let y = (size.height - height) * model.offset / max(1, total - size.height)
            Capsule()
                .fill(Color.primary.opacity(0.18))
                .frame(width: 4, height: height)
                .offset(y: y - (size.height - height) / 2)
                .padding(.trailing, 4)
        }
    }
}

/// A small mark in a pale, slightly rounded square, top right of an
/// artifact, saying where it lives: the Figma mark on a Figma frame, a code
/// mark on a build (a Claude Code version or a copied site), a chain link on
/// anything else that links somewhere (a website, a chat).
struct CornerMark: View {
    enum Glyph: Equatable {
        case symbol(String)
        case figma
    }

    let glyph: Glyph
    let help: String

    init(symbol: String, help: String) {
        glyph = .symbol(symbol)
        self.help = help
    }

    init(glyph: Glyph, help: String) {
        self.glyph = glyph
        self.help = help
    }

    /// The mark for a capture, or nil when it has none.
    static func of(_ entry: Entry) -> CornerMark? {
        let link = entry.link.lowercased()
        if entry.kind == .figma || link.contains("figma.com") {
            return CornerMark(glyph: .figma, help: "From Figma")
        }
        if entry.kind == .iteration || entry.siteFolder != nil {
            return CornerMark(symbol: "chevron.left.forwardslash.chevron.right", help: "A build you can run")
        }
        if !entry.link.isEmpty {
            return CornerMark(symbol: "link", help: "Links to its source")
        }
        return nil
    }

    var body: some View {
        Group {
            switch glyph {
            case .symbol(let name):
                Image(systemName: name)
                    .font(.system(size: 9, weight: .medium))
            case .figma:
                FigmaGlyph()
                    .frame(width: 7, height: 10.5)
            }
        }
        .foregroundStyle(Archive.ink)
        .frame(width: 18, height: 18)
        .background(Archive.paper.opacity(0.88), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
        .help(help)
        .allowsHitTesting(false)
    }
}

/// Figma's mark in one ink, like the other corner marks: five pieces on a
/// 2 × 3 grid, a hairline apart so it still reads small.
struct FigmaGlyph: View {
    var body: some View {
        Canvas { context, size in
            let u = min(size.width / 2, size.height / 3)
            let r = u / 2
            let gap = max(0.35, u * 0.06)
            let ox = (size.width - 2 * u) / 2, oy = (size.height - 3 * u) / 2
            func cell(_ col: CGFloat, _ row: CGFloat) -> CGRect {
                CGRect(x: ox + col * u + gap / 2, y: oy + row * u + gap / 2, width: u - gap, height: u - gap)
            }
            // Left column: rounded on the left; the bottom one is a drop.
            context.fill(Path(roundedRect: cell(0, 0), cornerSize: .zero).leftRounded(r - gap / 2, in: cell(0, 0)), with: .foreground)
            context.fill(Path(roundedRect: cell(0, 1), cornerSize: .zero).leftRounded(r - gap / 2, in: cell(0, 1)), with: .foreground)
            context.fill(Path.drop(in: cell(0, 2), radius: r - gap / 2), with: .foreground)
            // Right column: rounded on the right, then a circle.
            context.fill(Path(roundedRect: cell(1, 0), cornerSize: .zero).rightRounded(r - gap / 2, in: cell(1, 0)), with: .foreground)
            context.fill(Path(ellipseIn: cell(1, 1)), with: .foreground)
        }
        .accessibilityLabel("Figma")
    }
}

private extension Path {
    /// A cell with its left side fully round (a half-pill).
    func leftRounded(_ r: CGFloat, in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.minY))
        p.addArc(center: CGPoint(x: rect.minX + r, y: rect.midY), radius: r, startAngle: .degrees(270), endAngle: .degrees(90), clockwise: true)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.closeSubpath()
        return p
    }

    /// A cell with its right side fully round.
    func rightRounded(_ r: CGFloat, in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        p.addArc(center: CGPoint(x: rect.maxX - r, y: rect.midY), radius: r, startAngle: .degrees(270), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }

    /// Figma's bottom piece: round on the left and bottom, square top right.
    static func drop(in rect: CGRect, radius r: CGFloat) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        p.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: r, startAngle: .degrees(0), endAngle: .degrees(270), clockwise: false)
        p.closeSubpath()
        return p
    }
}

/// The timeline's line and its ticks: one short dash across the line per
/// section, level with its date. At the day scale that's a tick per day you
/// worked; zooming out, a week's ticks slide together into one, then a
/// month's, then a year's. Zooming in, they hold together until near the
/// end, then split.
struct TimeRail: View {
    let low: TimeLayout
    let high: TimeLayout
    /// How far the zoom is from `low` toward `high`.
    let fraction: CGFloat
    let offset: CGFloat

    /// How far the ticks have travelled toward the farther scale's places.
    static func merge(_ fraction: CGFloat) -> CGFloat {
        let x = min(max(fraction / 0.65, 0), 1)
        return x * x * (3 - 2 * x)
    }

    /// How far the beads have travelled. Between close up and the days view
    /// nothing merges: each bead stays level with its date and headline,
    /// moving exactly as they and the pictures do.
    static func travel(low: TimeLayout, high: TimeLayout, fraction: CGFloat) -> CGFloat {
        low.scale == .day && high.scale == .days ? fraction : merge(fraction)
    }

    /// Where each day's dot is, in content coordinates, at this point of the zoom.
    static func dots(low: TimeLayout, high: TimeLayout, fraction: CGFloat) -> [CGFloat] {
        let g = travel(low: low, high: high, fraction: fraction)
        return low.dayAnchors.map { day, a in
            let b = high.dayAnchors[day] ?? a
            return a + (b - a) * g
        }
    }

    /// Bead size per scale: day, days, weeks, months. A bead grows as
    /// it gathers more days, so the line itself tells the scale.
    static let radius: [CGFloat] = [2.4, 3.2, 4.0, 4.8]

    var body: some View {
        Canvas { context, size in
            let t = TimeZoomModel.ease(fraction)
            let x = low.lineX + (high.lineX - low.lineX) * t + 0.5
            let dots = Self.dots(low: low, high: high, fraction: fraction)
            // The line starts at the top bead: nothing above the newest day.
            let top = max(0, (dots.min() ?? Archive.Timeline.lineTop) - offset)
            context.fill(Path(CGRect(x: x - 0.5, y: top, width: 1, height: max(0, size.height - top))), with: .color(Archive.rule))
            // One bead per day you worked; beads travel together and merge
            // into one as days gather into weeks, months and years.
            let g = Self.travel(low: low, high: high, fraction: fraction)
            let r0 = Self.radius[low.scale.rawValue], r1 = Self.radius[high.scale.rawValue]
            let r = r0 + (r1 - r0) * g
            // One path, so merging beads join into one shape instead of darkening.
            var path = Path()
            for y in dots {
                let cy = y - offset
                guard cy > -10, cy < size.height + 10 else { continue }
                path.addEllipse(in: CGRect(x: x - r, y: cy - r, width: r * 2, height: r * 2))
            }
            context.fill(path, with: .color(Archive.ink))
        }
        .allowsHitTesting(false)
    }
}

/// A group header (a day, week, month or year) or a row label in the gutter.
/// Weeks, months and years carry a line on what happened in them: Margin's
/// summary title once it's written, and until then the topics Margin noted
/// most often.
private struct TimeLabel: View {
    @EnvironmentObject private var intelligence: Intelligence
    let label: TimeLayout.Label
    let scale: TimeScale

    var body: some View {
        switch label.kind {
        case .group:
            // What happened in this period, level with its date.
            // Sentence case, as written: it reads as a line, not a label.
            Text(headline ?? "")
                .font(Archive.headline(Archive.Size.headline))
                .foregroundStyle(Archive.ink)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .row:
            // The date, and how many artifacts it holds.
            VStack(alignment: .trailing, spacing: TimeLayout.dateToCount) {
                Text(label.title)
                    .font(Archive.font(Archive.Size.date))
                    .foregroundStyle(Archive.ink)
                    .lineLimit(1)
                if let span = label.span {
                    // The count, data like the date, lighter in colour.
                    Text(span)
                        .font(Archive.mono(Archive.Size.count))
                        .foregroundStyle(Archive.faint)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    /// Margin's summary title once it's written; until then the topics it
    /// noted most, or the designer's first words in the period.
    private var headline: String? {
        // Each zoom level has its own title: a day names its move, a week its
        // step, a month its phase.
        if let summary = intelligence.summary(for: label.entries, level: scale.level), !summary.hidden, !summary.title.isEmpty {
            return summary.title
        }
        // Until it's written: for a day (close up or among its week), the
        // day's own words (a decision first); further out, the topics it covered.
        let words = (label.entries.first { $0.kind == .decision && $0.hasWords } ?? label.entries.first(where: \.hasWords))
            .map { $0.rationale.trimmed.isEmpty ? $0.displayTitle : $0.rationale.trimmed }
            .map { $0.split(separator: "\n").first.map(String.init) ?? $0 }
        if scale.level == "day" { return words ?? trend }
        return trend ?? words
    }

    /// What happened, in a few words; nil where the scale doesn't ask for it.
    private var trend: String? {
        let topics = label.entries.compactMap { $0.tab ?? $0.ai?.topic }
        let counts = Dictionary(grouping: topics, by: { $0 }).mapValues(\.count)
        let top = counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(2).map(\.key)
        return top.isEmpty ? nil : top.joined(separator: " · ")
    }
}

/// Under a picture at the day scale: its title in the archive's header face,
/// then two lines of description in Helvetica Neue (your why when you wrote
/// one, otherwise what Margin saw).
struct DetailNote: View {
    let entry: Entry

    static let titleSize = Theme.Typography.caption
    static let bodySize = Theme.Typography.caption
    static let bodyLines = 2
    static var bodyLineHeight: CGFloat {
        let font = Theme.Typography.nsUI(bodySize)
        return ceil(font.ascender - font.descender + font.leading) + 2
    }
    /// Room it takes under the picture (gap included).
    static var height: CGFloat {
        Archive.Timeline.annotationGap + Archive.headlineLineHeight(titleSize) + Archive.Space.x1 + bodyLineHeight * CGFloat(bodyLines) + Archive.Space.x2
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Archive.Space.x1) {
            Text(entry.displayTitle)
                .font(Archive.headline(Self.titleSize))
                .foregroundStyle(Archive.ink)
                .lineLimit(1)
                .truncationMode(.tail)
            if let text = description {
                Text(text)
                    // The artifact page's description face, one weight lighter.
                    .font(Archive.sansLight(Self.bodySize))
                    .foregroundStyle(Archive.muted)
                    .lineSpacing(2)
                    .lineLimit(Self.bodyLines)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Only what you wrote, the same as the artifact's own page: never a
    /// line Margin generated or pulled from the capture.
    private var description: String? {
        let why = entry.rationale.trimmed
        return why.isEmpty ? nil : why
    }
}

extension Entry {
    /// The designer's note under a picture on the timeline: the first line
    /// of their why, if they wrote one.
    var annotation: String? {
        let why = rationale.trimmed
        guard !why.isEmpty else { return nil }
        return why.split(whereSeparator: \.isNewline).first.map(String.init) ?? why
    }
}

/// One capture on the timeline, in its own shape, as large as the scale
/// allows. Click to open it.
private struct ZoomThumb: View {
    @EnvironmentObject private var store: EntryStore
    @Environment(\.focusMoment) private var focusMoment
    @Environment(\.colorScheme) private var scheme
    let entry: Entry
    let size: CGSize
    /// The pointer has rested on it. Lights up only after a short rest, so
    /// cards passing under a still pointer while you scroll stay quiet.
    @State private var hovering = false
    @State private var pendingHover: DispatchWorkItem?

    var body: some View {
        ZStack {
            // The artifact in its own shape (its frame already has it),
            // decoded off the main thread so fast scrolling never waits.
            if let file = entry.imageFile {
                AsyncThumbnail(store: store, file: file, interpolation: size.height < 40 ? .low : .medium) {
                    Archive.paper
                }
            } else {
                // No picture: its words, never a grey block with an icon.
                WordsThumb(entry: entry, size: size)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        // The same for every artifact, whatever its pixels: a hairline just
        // outside its edge and no shadow, so a row of work reads as work on
        // a table, not as cards. On hover the hairline darkens a step:
        // nothing moves or grows, so scrolling past a row stays calm.
        .overlay(Rectangle().stroke(hovering ? Archive.ink.opacity(scheme == .dark ? 0.34 : 0.2) : Archive.frame, lineWidth: 1).padding(-0.5))
        .background(Rectangle().fill(Archive.paper))
        // A stack (a slide deck, several frames): more cards peek out
        // behind it, down and to the right.
        .background(alignment: .topLeading) {
            if entry.frameCount > 1 {
                let step = max(2, min(4, size.height * 0.035))
                ZStack(alignment: .topLeading) {
                    ForEach((1...min(entry.frameCount - 1, 2)).reversed(), id: \.self) { layer in
                        // The deck's next slides, so it reads as a stack of them.
                        Group {
                            if let file = entry.frames?[layer].imageFile {
                                AsyncThumbnail(store: store, file: file) { Archive.paper }
                            } else {
                                Archive.paper
                            }
                        }
                            .frame(width: size.width, height: size.height)
                            .clipped()
                            .overlay(Rectangle().stroke(Archive.frame, lineWidth: 1).padding(-0.5))
                            .frame(width: size.width, height: size.height)
                            .offset(x: step * CGFloat(layer), y: step * CGFloat(layer))
                    }
                }
            }
        }
        .onTapGesture { focusMoment(entry) }
        .onHover { inside in
            pendingHover?.cancel()
            pendingHover = nil
            if inside {
                let rest = DispatchWorkItem { withAnimation(.easeOut(duration: 0.16)) { hovering = true } }
                pendingHover = rest
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: rest)
            } else if hovering {
                withAnimation(.easeOut(duration: 0.22)) { hovering = false }
            }
        }
        .onDisappear { pendingHover?.cancel() }
        .help(entry.displayTitle)
    }
}

/// A capture without a picture, as a thumbnail: its own words on paper. A
/// quote shows the quoted text; anything else its title and what Margin saw.
struct WordsThumb: View {
    let entry: Entry
    let size: CGSize
    @Environment(\.colorScheme) private var scheme

    /// The quoted text, or the title with Margin's note under it.
    static func words(_ entry: Entry) -> (lead: String, rest: String?) {
        let body = entry.body.trimmed
        if entry.kind == .text, !body.isEmpty { return (body, nil) }
        let seen = entry.ai?.seen.trimmed ?? ""
        let why = entry.rationale.trimmed
        let rest = [why, seen].first { !$0.isEmpty && $0 != entry.displayTitle }
        return (entry.displayTitle, rest ?? (body.isEmpty || body == entry.displayTitle ? nil : body))
    }

    var body: some View {
        let words = Self.words(entry)
        let quote = entry.kind == .text && !entry.body.trimmed.isEmpty
        // Set to the thumbnail's size, so a small one still reads as a page.
        let type = max(5, min(13, size.height * 0.075))
        let inset = max(4, min(14, size.width * 0.07))
        ZStack(alignment: .topLeading) {
            Archive.paper
            if size.height > 16 {
                VStack(alignment: .leading, spacing: type * 0.5) {
                    Text(words.lead)
                        .font(quote ? Archive.sans(type) : Archive.font(type).weight(.medium))
                        .foregroundStyle(quote ? (scheme == .dark ? Color.white : Color.black) : Archive.ink)
                        .lineSpacing(type * 0.25)
                    if let rest = words.rest {
                        Text(rest)
                            .font(Archive.sans(type * 0.9))
                            .foregroundStyle(Archive.muted)
                            .lineSpacing(type * 0.2)
                    }
                }
                .multilineTextAlignment(.leading)
                .padding(inset)
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .clipped()
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

// MARK: - Trackpad and mouse

/// Takes the timeline's scrolling and pinching before anything else, so it
/// can scroll continuously and zoom around the pointer.
private struct ZoomEvents: NSViewRepresentable {
    let enabled: Bool
    let scroll: (CGFloat) -> Void
    let pinch: (CGFloat, CGPoint) -> Void
    let pinchEnded: (CGPoint) -> Void

    func makeNSView(context: Context) -> EventView { EventView() }

    func updateNSView(_ view: EventView, context: Context) {
        view.enabled = enabled
        view.onScroll = scroll
        view.onPinch = pinch
        view.onPinchEnded = pinchEnded
    }

    final class EventView: NSView {
        var enabled = true
        var onScroll: ((CGFloat) -> Void)?
        var onPinch: ((CGFloat, CGPoint) -> Void)?
        var onPinchEnded: ((CGPoint) -> Void)?
        private var monitor: Any?

        override var isFlipped: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
                guard let self, self.enabled, event.window === self.window else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(point) else { return event }
                switch event.type {
                case .scrollWheel:
                    let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 12
                    self.onScroll?(delta)
                case .magnify:
                    self.onPinch?(event.magnification, point)
                    if event.phase == .ended || event.phase == .cancelled { self.onPinchEnded?(point) }
                default:
                    return event
                }
                return nil
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
