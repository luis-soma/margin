import AppKit
import CoreText
import SwiftUI

/// The archive's layout: the timeline, the focus view and the pages take
/// every size and space from here. Type, color and the base grid come from
/// `Theme`: Mona Sans for labels, headlines and your words, all in
/// sentence case; Geist Mono for data (dates, counts); one neutral ramp.
enum Archive {
    // MARK: Type

    /// The label face: Mona Sans regular in sentence case ("Captured",
    /// "From"). Dates and counts are data: use `mono`.
    static func font(_ size: CGFloat) -> Font {
        Theme.Typography.ui(size)
    }

    static func nsFont(_ size: CGFloat) -> NSFont {
        Theme.Typography.nsUI(size)
    }

    /// Headlines and titles: Mona Sans medium, in sentence case, as written.
    static func headline(_ size: CGFloat) -> Font {
        Theme.Typography.ui(size, .medium)
    }

    static func nsHeadline(_ size: CGFloat) -> NSFont {
        Theme.Typography.nsUI(size, .medium)
    }

    /// The breadcrumb ("Projects / Umbrella"), as written.
    static func crumbFont(_ size: CGFloat) -> Font {
        sans(size)
    }

    /// Data: dates, counts, sizes, file names. Geist Mono, never in capitals.
    static func mono(_ size: CGFloat) -> Font {
        Theme.Typography.mono(size)
    }

    static func nsMono(_ size: CGFloat) -> NSFont {
        Theme.Typography.nsMono(size)
    }

    /// Height of one line of the data face at `size`.
    static func monoLineHeight(_ size: CGFloat) -> CGFloat {
        let font = nsMono(size)
        return ceil(font.ascender - font.descender + font.leading)
    }

    /// What's read rather than labelled: descriptions under artifacts. The
    /// same face as `sans`; color, not a lighter weight, sets it back.
    static func sansLight(_ size: CGFloat) -> Font {
        Theme.Typography.ui(size)
    }

    /// What's read rather than labelled: detail values and your note.
    static func sans(_ size: CGFloat) -> Font {
        Theme.Typography.ui(size)
    }

    /// Height of one line of the label face at `size`.
    static func lineHeight(_ size: CGFloat) -> CGFloat {
        let font = nsFont(size)
        return ceil(font.ascender - font.descender + font.leading)
    }

    /// Height of one line of the headline face at `size`.
    static func headlineLineHeight(_ size: CGFloat) -> CGFloat {
        let font = nsHeadline(size)
        return ceil(font.ascender - font.descender + font.leading)
    }

    /// Type sizes, all on `Theme.Typography`'s scale (nothing under 10 pt).
    /// Capitals only for short mono labels; headlines and your words in
    /// sentence case.
    enum Size {
        /// Short labels: "PROJECTS", "FILES".
        static let title = Theme.Typography.caption
        /// Quiet labels and notes: footers, "Send to", tooltips.
        static let meta = Theme.Typography.caption
        /// A timeline section's date ("OCT 15") and its count ("14 ARTIFACTS"),
        /// in the mono.
        static let date = Theme.Typography.body
        static let count = Theme.Typography.caption
        /// The headline beside them, the largest words on the page.
        static let headline = Theme.Typography.heading
        /// The breadcrumb in the window's header: "Projects / Umbrella".
        static let crumb = Theme.Typography.body
        /// A page's title: "Umbrella" on the handoff page.
        static let pageTitle = Theme.Typography.title
        /// A page's heading: "PROJECTS".
        static let pageHeading = Theme.Typography.heading
        /// The note under a picture, per scale (day, days, weeks, months):
        /// only at the day.
        static let annotation: [CGFloat?] = [DetailNote.bodySize, nil, nil, nil]
    }

    // MARK: Color


    // The three main colors, from Theme's neutral ramp.

    /// Dates, headlines, and what you read.
    static let ink = Theme.Palette.ink
    /// Categories beside the details ("CAPTURED", "FROM"), descriptions.
    static let muted = Theme.Palette.ink2
    /// Section labels, artifact counts, ticks on the line.
    static let faint = Theme.Palette.ink3
    /// The timeline's vertical line.
    static let rule = Theme.Palette.hairline
    /// The hairline just outside each artifact: translucent, so it reads the
    /// same on light and dark pictures; a light grey on the page.
    static let frame = Color(nsColor: NSColor(name: "ArchiveFrame") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.09)
            : NSColor.black.withAlphaComponent(0.08)
    })
    /// The page.
    static let paper = Theme.Palette.paper

    // MARK: Space (4 pt grid)

    enum Space {
        static let x1 = Theme.Space.x1
        static let x2 = Theme.Space.x2
        static let x3 = Theme.Space.x3
        static let x4 = Theme.Space.x4
        static let x6 = Theme.Space.x6
        /// Off Theme's scale; kept while views still use it. Prefer x6 or x8.
        static let x7: CGFloat = 28
        static let x8 = Theme.Space.x8
    }

    // MARK: Timeline layout

    enum Timeline {
        /// Left margin of the page, where the dates start.
        static let leading = Theme.Space.x8
        /// The date column: room for the longest date, "SEPT 26 - OCT 2".
        static let dateWidth: CGFloat = 132
        /// From the line to the dates on its left and to the work on its right.
        static let gutter = Space.x4
        /// The vertical line, from the window's left edge.
        static let lineX = leading + dateWidth + gutter
        /// The dash on the line beside each section's date.
        static let tickWidth = Space.x2
        /// Where the line starts, above the first section.
        static let lineTop = Space.x4
        /// The first section's top.
        static let top: CGFloat = 48
        /// Right margin of the work: wider than the left side looks (the
        /// dates sit right-aligned, so the left reads as 90–120 pt).
        static let trailing = Theme.Space.x8
        /// The page width the picture sizes below are drawn for (a 1080 pt
        /// window); wider or narrower windows scale them.
        static let referenceWidth: CGFloat = 1080 - lineX - gutter - trailing
        /// From a headline's top to its pictures.
        static let headlineToWork = Space.x7
        /// Between pictures in a row.
        static let itemGap = Space.x3
        /// Between rows: from the bottom of one row's artifacts (their notes
        /// included) to the next row.
        static let rowGap = Space.x4
        /// From a section's last artifacts (notes included) to the next section.
        static let sectionGap: CGFloat = 96
        /// From a picture to its annotation.
        static let annotationGap = Space.x2
        /// Between a date and its count.
        static let metaGap = Space.x1
        /// Per scale (day, days, weeks, months): the height a row of
        /// captures aims for. Rows are justified, so full rows come out a
        /// little shorter to end exactly at the margin; the last row keeps
        /// this height. Widths follow each capture's own shape.
        static let boxes: [CGSize] = [
            CGSize(width: 324, height: 243),
            CGSize(width: 133, height: 100),
            CGSize(width: 86, height: 65),
            CGSize(width: 50, height: 38),
        ]
    }

    // MARK: Page layout

    /// The projects page and the handoff page.
    enum Page {
        /// Left and right, the same as the timeline's left margin.
        static let margin = Timeline.leading
        /// The first line's top, the same as the timeline's first section.
        static let top = Timeline.top
        /// From the page heading to the projects.
        static let headingGap = Theme.Space.x8
        /// Between the handoff page's sections (summary, files, artifacts, decisions).
        static let sectionGap = Theme.Space.x8
        /// From a section's label to what's in it, and how far that's indented.
        static let labelGap = Space.x4
        static let indent = Space.x4

        /// Project cards: up to three across, filling the page.
        static let maxColumns = 3
        static let minCardWidth: CGFloat = 220
        static let cardGap = Theme.Space.x12
        static let cardRowGap: CGFloat = 48
        /// Cover height for its width.
        static let coverRatio: CGFloat = 0.58
        /// From a cover to the project's name.
        static let coverGap = Space.x2

        /// The handoff page's date range, rule and count.
        static let metaGap = Theme.Space.x6
        static let ruleWidth: CGFloat = 20
        /// File rows: name column, height, spacing.
        static let fileNameWidth: CGFloat = 144
        static let rowHeight: CGFloat = 20
        static let rowGap = Space.x1
        /// The artifacts strip and the decisions' pictures.
        static let thumb = CGSize(width: 100, height: 58)
        static let thumbGap = Space.x1
        static let seeAllGap = Space.x8
        static let decisionThumb = CGSize(width: 64, height: 38)
        static let decisionGap = Space.x2
        /// File names in the mono, the same size as the section label above them.
        static let fileNameSize = Size.title
        /// Detail text in Helvetica Neue (file descriptions, decisions).
        static let detailSize = Theme.Typography.caption
        /// The project summary: like your note in the focus view.
        static let summarySize = Theme.Typography.body
        static let summaryLineSpacing = Space.x2
    }

    // MARK: Focus layout

    /// The panel a capture opens in, over the timeline.
    enum Focus {
        /// Around the panel, inside the window: the same 8 as the sidebar,
        /// so the panel holds the traffic lights in its corner instead of
        /// meeting them with its edge.
        static let inset = Theme.Space.x2
        static let insetTop = Theme.Space.x2
        static let radius = Theme.Radius.card
        /// Left of the picture, between it and the details, right of the details.
        static let leading = Theme.Space.x12
        static let gap = Space.x8
        static let trailing: CGFloat = 24
        static let sidebarWidth: CGFloat = 264
        /// Kept clear above and below the picture.
        static let verticalMargin: CGFloat = 96
        /// The details sit this far inside the picture's top and bottom.
        static let sidebarInset = Space.x1
        /// Between the title and description, the details, and share and save.
        static let blockGap = Space.x6
        /// From the title and description to the details below them.
        static let titleToDetails: CGFloat = 40
        /// The title over its description.
        static let titleGap = Space.x3
        /// The capture's title: the largest words beside it.
        static let titleSize = Theme.Typography.title
        /// The hairline between the capture and its details stops this short
        /// of the panel's top and bottom.
        static let ruleInset = Space.x8
        /// Kept clear left and right of the capture, inside its space.
        static let artMargin = Space.x8
        /// The narrow layout's details: one fixed height, so the capture's
        /// space is the same for every artifact.
        static let stackedDetailsHeight: CGFloat = 148
        /// One detail row, label column, row spacing.
        static let rowHeight = Space.x4
        static let labelWidth: CGFloat = 84
        static let rowGap = Space.x2
        /// A detail's value, in Helvetica Neue.
        static let valueSize = Theme.Typography.body
        /// The mono labels beside the values and above each section
        /// ("CAPTURED", "METADATA").
        static let labelSize = Theme.Typography.label
        /// Your note: the first thing you read beside the capture.
        static let noteSize = Theme.Typography.heading
        static let noteLineSpacing = Space.x2
        /// Previous, next, close.
        static let navSize: CGFloat = 24
        /// Arrows and close on the traffic lights' line (centred 24 down).
        static let navTop = Space.x1
        static let navTrailing = Space.x4
    }

    // MARK: Fonts

    private static var registered = false

    /// Registers any font in Resources/Fonts for this process (a signature
    /// mono, once one is bundled). The interface itself uses the system
    /// faces, so nothing depends on this. Call once at launch.
    static func registerFonts() {
        guard !registered else { return }
        registered = true
        let folders: [URL?] = [
            Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
            // A development build run from the package: the repo's copy.
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Resources/Fonts"),
        ]
        for case let folder? in folders {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for file in files where ["otf", "ttf"].contains(file.pathExtension.lowercased()) {
                CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil)
            }
        }
    }
}

// MARK: - Dates, as the archive writes them

extension Archive {
    /// Month names as the archive sets them: "SEPT", "JUNE".
    /// Each month's first three letters.
    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    static func month(_ date: Date, calendar: Calendar = .current) -> String {
        months[calendar.component(.month, from: date) - 1]
    }

    /// The month written out, for a month's own title: "October".
    static func fullMonth(_ date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.setLocalizedDateFormatFromTemplate("MMMM")
        return formatter.string(from: date)
    }

    /// The year, only when it isn't this one.
    private static func year(_ date: Date, calendar: Calendar) -> String {
        let year = calendar.component(.year, from: date)
        return year == calendar.component(.year, from: Date()) ? "" : " \(year)"
    }

    /// "TODAY", "YESTERDAY", otherwise the month's first three letters and
    /// the day: "OCT 15" (with the year when it isn't this one).
    static func day(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        return "\(month(date, calendar: calendar)) \(calendar.component(.day, from: date))\(year(date, calendar: calendar))"
    }

    /// "SEPT 9 - 15", or "SEPT 26 - OCT 2" across a month.
    static func week(_ start: Date, calendar: Calendar = .current) -> String {
        let end = calendar.date(byAdding: .day, value: 6, to: start) ?? start
        let from = "\(month(start, calendar: calendar)) \(calendar.component(.day, from: start))"
        let sameMonth = calendar.component(.month, from: start) == calendar.component(.month, from: end)
        let to = sameMonth ? "\(calendar.component(.day, from: end))" : "\(month(end, calendar: calendar)) \(calendar.component(.day, from: end))"
        return "\(from) - \(to)\(year(end, calendar: calendar))"
    }

    /// "OCT", or "OCT 2025" in another year.
    static func monthTitle(_ start: Date, calendar: Calendar = .current) -> String {
        month(start, calendar: calendar) + year(start, calendar: calendar)
    }

    /// "14 artifacts".
    static func count(_ n: Int) -> String {
        "\(n) artifact\(n == 1 ? "" : "s")"
    }
}
