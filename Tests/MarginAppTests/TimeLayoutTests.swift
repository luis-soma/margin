import XCTest
@testable import Margin

final class TimeLayoutTests: XCTestCase {
    /// Captures over about four months: a few each working day, in bursts.
    private func sampleEntries() -> [Entry] {
        let calendar = Calendar.current
        let start = calendar.date(from: DateComponents(year: 2026, month: 6, day: 1, hour: 9))!
        var entries: [Entry] = []
        for day in stride(from: 0, to: 120, by: 2) {
            for burst in 0..<3 {
                for shot in 0..<2 {
                    var entry = Entry(kind: .snapshot, project: "Test")
                    entry.createdAt = start.addingTimeInterval(TimeInterval(day * 86_400 + burst * 3 * 3600 + shot * 120))
                    entries.append(entry)
                }
            }
        }
        return entries
    }

    func testEveryCaptureIsPlacedAtEveryScale() {
        let entries = sampleEntries()
        for scale in TimeScale.allCases {
            let layout = TimeLayout.make(entries, scale: scale, width: 1000)
            XCTAssertEqual(layout.frames.count, entries.count, "\(scale)")
            XCTAssertEqual(Set(layout.order), Set(entries.map(\.id)), "\(scale)")
            // Captures sit right of the timeline's line; row labels left of it.
            XCTAssertGreaterThan(layout.contentX, layout.lineX)
            for rect in layout.frames.values {
                XCTAssertGreaterThanOrEqual(rect.minX, layout.contentX - 0.5)
                XCTAssertLessThanOrEqual(rect.maxX, 1000 - Archive.Timeline.trailing + 0.5)
            }
            for label in layout.labels where label.kind == .row {
                XCTAssertLessThan(label.frame.maxX, layout.lineX)
            }
        }
    }

    func testZoomingOutShrinksCapturesAndShortensTheTimeline() {
        let entries = sampleEntries()
        let layouts = TimeScale.allCases.map { TimeLayout.make(entries, scale: $0, width: 1000) }
        for (closer, farther) in zip(layouts, layouts.dropFirst()) {
            let a = closer.frames.values.first!.height, b = farther.frames.values.first!.height
            XCTAssertLessThan(b, a)
            XCTAssertLessThan(farther.height, closer.height)
        }
    }

    func testGroupsRunNewestFirstAndRowsReadOldestToNewest() {
        let entries = sampleEntries()
        let groups = TimeLayout.groups(entries, scale: .months, calendar: .current)
        XCTAssertEqual(groups.count, 4) // June to September
        let starts = groups.map { $0.entries.first!.createdAt }
        XCTAssertEqual(starts, starts.sorted(by: >))
        for row in groups.flatMap(\.rows) {
            XCTAssertEqual(row.entries.map(\.createdAt), row.entries.map(\.createdAt).sorted())
        }
        // Every section has a headline on the right; the date column has none.
        for scale in TimeScale.allCases {
            let layout = TimeLayout.make(entries, scale: scale, width: 900)
            XCTAssertTrue(layout.labels.filter { $0.kind == .group }.allSatisfy(\.wantsAI))
            XCTAssertFalse(layout.labels.filter { $0.kind == .row }.contains(where: \.wantsAI))
        }
    }

    /// One dot per section: a day (at both day scales), a week, a month.
    func testTheRailHasADotPerSectionThatMergesWhenZoomingOut() {
        let entries = sampleEntries()
        let calendar = Calendar.current
        let days = Set(entries.map { calendar.startOfDay(for: $0.createdAt) })
        let layouts = TimeScale.allCases.map { TimeLayout.make(entries, scale: $0, width: 1000) }
        for layout in layouts { XCTAssertEqual(Set(layout.dayAnchors.keys), days, "\(layout.scale)") }

        func distinct(_ layout: TimeLayout) -> Int { Set(layout.dayAnchors.values.map { Int($0.rounded()) }).count }
        let weeks = Set(days.map { calendar.dateInterval(of: .weekOfYear, for: $0)!.start })
        let months = Set(days.map { calendar.dateInterval(of: .month, for: $0)!.start })
        XCTAssertEqual(distinct(layouts[TimeScale.day.rawValue]), days.count)
        XCTAssertEqual(distinct(layouts[TimeScale.days.rawValue]), days.count)
        XCTAssertEqual(distinct(layouts[TimeScale.weeks.rawValue]), weeks.count)
        XCTAssertEqual(distinct(layouts[TimeScale.months.rawValue]), months.count)

        // Early in the zoom from days to weeks the dots haven't gathered; at the end they have.
        let d = TimeScale.days.rawValue
        let early = Set(TimeRail.dots(low: layouts[d], high: layouts[d + 1], fraction: 0.3).map { Int($0.rounded()) }).count
        XCTAssertGreaterThan(early, weeks.count)
        let end = Set(TimeRail.dots(low: layouts[d], high: layouts[d + 1], fraction: 1).map { Int($0.rounded()) }).count
        XCTAssertEqual(end, weeks.count)
    }

    /// Each section: the period on the left and its headline on the right, level
    /// with each other, the captures below the headline.
    func testSectionsPutThePeriodLevelWithTheHeadline() {
        let entries = sampleEntries()
        for scale in TimeScale.allCases {
            let layout = TimeLayout.make(entries, scale: scale, width: 1000)
            let periods = layout.labels.filter { $0.kind == .row }
            let headlines = layout.labels.filter { $0.kind == .group }
            XCTAssertEqual(periods.count, headlines.count)
            for (period, headline) in zip(periods, headlines) {
                // The date on the headline's baseline.
                XCTAssertEqual(period.frame.minY + TimeLayout.baseline(Archive.Size.date),
                               headline.frame.minY + TimeLayout.baseline(Archive.Size.headline), accuracy: 0.5)
                XCTAssertNotNil(period.span)
            }
        }
        // Under every date: how many artifacts it holds.
        let day = TimeLayout.make(entries, scale: .day, width: 1000).labels.first(where: { $0.kind == .row })!
        XCTAssertEqual(day.span, Archive.count(day.entries.count))
        XCTAssertTrue(day.span!.hasSuffix("artifacts"))
    }

    /// Every artifact keeps its own shape, fitted to its scale's cell and
    /// centered in it; cells sit on one grid.
    func testPicturesKeepTheirShapeInsideTheBox() {
        let entries = sampleEntries()
        let shapes: [CGFloat] = [1.5, 0.6, 1, 3]
        let aspect: (Entry) -> CGFloat? = { entry in shapes[abs(entry.id.hashValue) % shapes.count] }
        for scale in TimeScale.allCases {
            let layout = TimeLayout.make(entries, scale: scale, width: 1080, aspect: aspect)
            let box = scale.maxSize
            // The cells share the row's leftover room, so full rows end at the margin.
            let available = 1080 - layout.contentX - Archive.Timeline.trailing
            let columns = max(1, Int((available + Archive.Timeline.itemGap) / (box.width + Archive.Timeline.itemGap)))
            let gap = columns > 1 ? (available - CGFloat(columns) * box.width) / CGFloat(columns - 1) : Archive.Timeline.itemGap
            for entry in entries {
                let rect = layout.frames[entry.id]!
                XCTAssertLessThanOrEqual(rect.width, box.width + 0.5)
                XCTAssertLessThanOrEqual(rect.height, box.height + 0.5)
                // Its own shape, within a point of rounding.
                XCTAssertEqual(rect.width, rect.height * aspect(entry)!, accuracy: max(1.5, aspect(entry)!))
                // Centered in its cell: the cell's left edge is on the grid.
                let cellX = rect.midX - box.width / 2 - layout.contentX
                let step = box.width + gap
                let off = cellX.truncatingRemainder(dividingBy: step)
                XCTAssertEqual(min(off, step - off), 0, accuracy: 1)
                XCTAssertLessThanOrEqual(rect.maxX, 1080 - Archive.Timeline.trailing + 0.5)
            }
        }
    }

    /// Stepping in with the slider from the very top of the timeline ends at
    /// the top, not wherever the middle capture happened to land.
    @MainActor
    func testSteppingInFromTheTopStaysAtTheTop() {
        let model = TimeZoomModel(level: 1)
        model.update(entries: sampleEntries(), size: CGSize(width: 1000, height: 700))
        XCTAssertEqual(model.offset, 0)
        model.settle(on: 0)
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        XCTAssertEqual(model.zoom, 0)
        XCTAssertEqual(model.offset, 0)
    }

    /// Pinching past the closest scale stretches the page a little instead
    /// of zooming further; letting go springs it back.
    @MainActor
    func testPinchingPastTheEndStretchesThenSpringsBack() {
        let model = TimeZoomModel(level: 0)
        model.update(entries: sampleEntries(), size: CGSize(width: 1000, height: 700))
        model.pinch(by: 0.5, at: CGPoint(x: 500, y: 300))
        XCTAssertEqual(model.zoom, 0)
        XCTAssertGreaterThan(model.stretch, 1)
        XCTAssertLessThan(model.stretch, 1.13)
        model.pinch(by: -0.6, at: CGPoint(x: 500, y: 300)) // back, and a little way out
        XCTAssertEqual(model.stretch, 1)
        XCTAssertGreaterThan(model.zoom, 0)
        model.endPinch(at: CGPoint(x: 500, y: 300))
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        XCTAssertEqual(model.zoom, 0, accuracy: 0.001)
    }

    /// Changing scale eases in and out and never goes past where it's heading.
    func testTheZoomEasesWithoutOvershooting() {
        let samples = stride(from: 0.0, through: 1.0, by: 0.01).map { TimeZoomModel.easeInOut($0) }
        XCTAssertEqual(samples.first!, 0)
        XCTAssertEqual(samples.last!, 1, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(samples.max()!, 1)
        XCTAssertEqual(samples, samples.sorted())
    }

    /// From the very top, every step in and out ends at the top.
    @MainActor
    func testEveryStepInAndOutFromTheTopEndsAtTheTop() {
        let model = TimeZoomModel(level: 3)
        model.update(entries: sampleEntries(), size: CGSize(width: 1000, height: 700))
        for level in [2, 1, 0, 1, 2, 3, 0, 3] {
            model.settle(on: level)
            RunLoop.main.run(until: Date().addingTimeInterval(1))
            XCTAssertEqual(model.zoom, CGFloat(level))
            XCTAssertEqual(model.offset, 0, "at \(level)")
        }
        for spread in [0.4, 0.4, 0.4, -0.4, -0.4, -0.4] {
            model.pinch(by: spread, at: CGPoint(x: 700, y: 600))
            XCTAssertEqual(model.offset, 0)
        }
    }

    /// From the very top, pinching keeps you at the top too.
    @MainActor
    func testPinchingFromTheTopStaysAtTheTop() {
        let model = TimeZoomModel(level: 1)
        model.update(entries: sampleEntries(), size: CGSize(width: 1000, height: 700))
        model.pinch(by: 0.3, at: CGPoint(x: 600, y: 500))
        XCTAssertEqual(model.offset, 0)
        model.endPinch(at: CGPoint(x: 600, y: 500))
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        XCTAssertEqual(model.offset, 0)
    }

    /// Days read "Today", "Yesterday", then the month's first three letters
    /// and the day ("Oct 15", set in capitals on screen).
    func testDaysReadTodayYesterdayThenMonthAndDay() {
        let calendar = Calendar.current
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 10))!
        func day(_ d: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: d, hour: 15))! }
        XCTAssertEqual(Archive.day(day(19), now: now), "Today")
        XCTAssertEqual(Archive.day(day(18), now: now), "Yesterday")
        XCTAssertEqual(Archive.day(day(15), now: now), "Oct 15")
        XCTAssertEqual(Archive.day(calendar.date(from: DateComponents(year: 2026, month: 9, day: 3))!, now: now), "Sep 3")
    }

    /// Months are written out in full, in sentence case, with the year only
    /// when the project spans years.
    func testMonthTitlesDropTheYearWithinOneYear() {
        let calendar = Calendar.current
        func entry(_ year: Int, _ month: Int) -> Entry {
            var e = Entry(kind: .snapshot, project: "Test")
            e.createdAt = calendar.date(from: DateComponents(year: year, month: month, day: 10, hour: 12))!
            return e
        }
        let full = DateFormatter(); full.setLocalizedDateFormatFromTemplate("MMMM")
        let october = full.string(from: calendar.date(from: DateComponents(year: 2026, month: 10, day: 1))!)

        let oneYear = TimeLayout.groups([entry(2026, 9), entry(2026, 10)], scale: .months, calendar: calendar)
        XCTAssertEqual(oneYear.first?.title, october)

        let twoYears = TimeLayout.groups([entry(2025, 12), entry(2026, 10)], scale: .months, calendar: calendar)
        XCTAssertTrue(twoYears.first!.title.hasPrefix(october) || twoYears.first!.title.contains(october))
        XCTAssertTrue(twoYears.first!.title.contains("2026"))
    }

    /// Narrowing the window so fewer fit across: the captures glide from
    /// their old rows to the new ones instead of jumping, and end there.
    @MainActor
    func testNarrowingTheWindowGlidesCapturesToTheirNewRows() {
        let entries = sampleEntries()
        let model = TimeZoomModel(level: 1)
        model.update(entries: entries, size: CGSize(width: 1400, height: 800))
        let wide = model.layout(1)
        model.update(entries: entries, size: CGSize(width: 900, height: 800))
        let narrow = model.layout(1)
        let id = narrow.order.first { abs(narrow.frames[$0]!.minY - wide.frames[$0]!.minY) > 1 }!
        // Just after: still near where it was, not yet at its new row.
        let now = model.shown(narrow).frames[id]!
        XCTAssertLessThan(abs(now.minY - wide.frames[id]!.minY), abs(now.minY - narrow.frames[id]!.minY))
        // Once the glide is over: exactly the new layout.
        RunLoop.main.run(until: Date().addingTimeInterval(TimeZoomModel.reflowDuration + 0.1))
        XCTAssertEqual(model.shown(narrow).frames[id], narrow.frames[id])
    }

    /// The window's width changes how many pictures fit in a row, never how
    /// big they are; and each step out makes them smaller.
    func testPictureSizeDoesNotFollowTheWindowWidth() {
        let entries = sampleEntries()
        for scale in TimeScale.allCases {
            let narrow = TimeLayout.make(entries, scale: scale, width: 700)
            let wide = TimeLayout.make(entries, scale: scale, width: 1600)
            for entry in entries {
                XCTAssertEqual(narrow.frames[entry.id]!.size, wide.frames[entry.id]!.size, "\(scale)")
            }
        }
        let sizes = TimeScale.allCases.map(\.maxSize.width)
        XCTAssertEqual(sizes, sizes.sorted(by: >))
    }
}
