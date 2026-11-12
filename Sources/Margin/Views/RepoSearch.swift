import AppKit
import SwiftUI

/// Measures of the repo's header row. Everything is centered 24 pt from the
/// top, and what sits in a corner is as far from the side as from the top:
/// the traffic lights 18 pt from the left (their dots are 18 pt from the
/// top), the tools' buttons 10 pt from the right (10 pt from the top).
enum RepoHeader {
    static let height: CGFloat = 48
    /// The traffic lights: left edge (inside the floating sidebar), and centre line of the row.
    static let trafficLights = CGPoint(x: 18, y: 24)
    /// Where the project name starts.
    static let titleX: CGFloat = 90
    /// From the project name to the slider, and from the slider to search:
    /// the slider's track sits centered between the words and the
    /// magnifier, the same clear space on each side (the breadcrumb's own
    /// inset and the handle make up the difference between the two).
    static let titleGap: CGFloat = 25
    static let searchGap: CGFloat = 26
    /// Right edge, to the tools' buttons: the same as their top edge (24 pt
    /// center minus half of 28), so the corner reads square.
    static let inset: CGFloat = 10
    /// Same height as the slider's track, so the row reads as one line.
    static let controlHeight: CGFloat = 18
    static let controlRadius: CGFloat = 5.4
    static let searchClosed: CGFloat = toolWidth
    static let searchOpen: CGFloat = 220
    /// The slider's width, centred over the archive.
    static let sliderWidth: CGFloat = 400
    /// The controls on the right (search, options, Explain): 28 tall.
    static let toolWidth: CGFloat = 28
    static let toolHeight: CGFloat = 28
    static let toolRadius = Theme.Radius.control
    /// Between the icons on the right: the same between each pair, a little
    /// more between search and hand off, where the rule sits in the middle.
    static let toolGap: CGFloat = 8
    static let ruleGap: CGFloat = 7
    /// Hand off sits this much right of the even spacing.
    static let handoffNudge: CGFloat = 3
}

/// What the tag menu offers, in order: your tabs, Margin's suggested tabs, Margin's tags.
struct FilterOptions {
    var tabs: [String]
    var suggested: [(name: String, count: Int)]
    var tags: [(name: String, count: Int)]

    var allNames: [String] { tabs + suggested.map(\.name) + tags.map(\.name) }
}

/// A magnifier at the end of the header row. Clicked, it grows to the left
/// into a field; picked tags sit in it as tokens.
struct RepoSearch: View {
    @Binding var query: String
    @Binding var filters: [String]
    @Binding var open: Bool
    @Binding var menuOpen: Bool
    let submit: () -> Void
    @FocusState private var focused: Bool
    @State private var hovering = false
    /// Where the field is in its window, to tell a click outside it.
    @State private var frameInWindow: CGRect = .zero
    @State private var outsideClicks: Any?
    /// Folding back: the magnifier waits at the end the field shrinks into,
    /// rather than unwinding from the cursor while the field slides away.
    @State private var closing = false
    /// The magnifier's own open state, set apart from `open` so closing can
    /// switch it to the magnifier with no animation at all (the binding's
    /// change arrives inside the field's own animation, too late to opt out).
    @State private var iconOpen = false
    @State private var iconPop: CGFloat = 1

    /// The magnifier's slot, and how far in from a plain text field's edge
    /// AppKit draws the cursor, so the field's cursor lands on the icon's line.
    private static let iconSlot: CGFloat = RepoHeader.searchClosed - 14
    private static let caretInset: CGFloat = 2
    /// The system cursor, measured on screen: 2 pt wide, 12 pt tall, its
    /// centre 2.25 pt left of the magnifier's.
    private static let caretWidth: CGFloat = 2
    private static let caretShift: CGFloat = -2.25
    private var hasContent: Bool { !query.isEmpty || !filters.isEmpty }

    var body: some View {
        ZStack(alignment: .leading) {
            // The magnifier turns into the text cursor right where it is: it
            // tilts upright and the ring folds into the line. The field starts
            // under it, so its own cursor appears on that same line and takes
            // over. Closing plays it back.
            // Folded, it is drawn exactly as the system cursor beside it:
            // 2 pt wide, 12 pt tall, square ends, the same grey, on the
            // same line, so the handover can't be seen.
            MagnifierCaret(progress: iconOpen ? 1 : 0)
                .stroke(Color.primary.opacity(open || hovering ? 0.75 : 0.5),
                        style: StrokeStyle(lineWidth: iconOpen ? Self.caretWidth : 1.5, lineCap: iconOpen ? .butt : .round, lineJoin: .round))
                .frame(width: 12, height: 13)
                .offset(x: iconOpen && !closing ? Self.caretShift : 0)
                .rotationEffect(.degrees(hovering && !open ? -8 : 0))
                .animation(.easeOut(duration: 0.2), value: hovering)
                // The folded line stands in for the cursor until the field
                // has focus; then the field's own cursor, on the same line,
                // takes over. Newer macOS draws that cursor itself and won't
                // hide it, so the two must never show at once.
                .opacity(open && (hasContent || focused) ? 0 : 1)
                .animation(.easeOut(duration: closing ? 0.18 : 0.08), value: open && (hasContent || focused))
                .modifier(CaretBlink(on: open && iconOpen && !hasContent && !focused && !closing))
                .scaleEffect(iconPop)
                .frame(width: Self.iconSlot)
                // While closing it sits where it will rest, at the trailing
                // end, and the field shrinks into it.
                .frame(maxWidth: .infinity, alignment: closing ? .trailing : .leading)
                .allowsHitTesting(false)
            if open {
                HStack(spacing: 5) {
                    ForEach(filters, id: \.self) { filter in
                        FilterToken(text: filter) {
                            withAnimation(Brand.motion) { filters.removeAll { $0 == filter } }
                        }
                    }
                    TextField("", text: $query, prompt: Text(filters.isEmpty ? "Search" : "").foregroundColor(Color.primary.opacity(0.35)))
                        .textFieldStyle(.plain)
                        .font(Theme.Typography.ui(Theme.Typography.control))
                        .focused($focused)
                        // The cursor in the magnifier's grey, so the line it
                        // folds into simply becomes the cursor.
                        .tint(Color.primary.opacity(0.75))
                        .onSubmit(submit)
                        .onExitCommand(perform: escape)
                        // The placeholder waits for the cursor to finish forming;
                        // closing, the words go at once.
                        .transition(.asymmetric(
                            insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.35)),
                            removal: .opacity.animation(.easeOut(duration: 0.08))
                        ))
                if !query.isEmpty || !filters.isEmpty {
                    Button(action: clear) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.primary.opacity(0.35))
                    }
                    .buttonStyle(.plain)
                    .toolTip("Clear")
                    .transition(.opacity)
                }
                }
                // The field's text (and cursor) starts on the icon's center line.
                .padding(.leading, Self.iconSlot / 2 - Self.caretInset)
                .transition(.asymmetric(insertion: .identity, removal: .opacity.animation(.easeOut(duration: 0.08))))
            }
        }
        .padding(.leading, 7)
        .padding(.trailing, open ? 5 : 7)
        // Closed, the bare magnifier, a light pill on hover like the other
        // tools. Open, no box at all: you type straight onto the page, the
        // magnifier turned cursor at the start and one hairline under the
        // words, level with the bottom of the slider's track.
        .frame(width: open ? RepoHeader.searchOpen : RepoHeader.searchClosed, height: RepoHeader.toolHeight, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: RepoHeader.toolRadius, style: .continuous)
                .fill(!open && hovering ? Theme.Palette.fillHover : .clear)
        )
        .overlay(alignment: .bottom) {
            if open {
                Rectangle()
                    .fill(Theme.Palette.ink.opacity(focused ? 0.22 : 0.12))
                    .frame(height: 1)
                    .padding(.horizontal, 7)
                    .padding(.bottom, (RepoHeader.toolHeight - 20) / 2)
                    // Draws out from where the magnifier was.
                    .transition(.scale(scale: 0, anchor: .leading).combined(with: .opacity))
                    .animation(Theme.Motion.hover, value: focused)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: RepoHeader.toolRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: RepoHeader.toolRadius, style: .continuous))
        .onTapGesture { if !open { openField() } else { focused = true; showMenu() } }
        .onHover { hovering = $0 }
        .onChange(of: focused) { isFocused in
            if isFocused {
                showMenu()
                greyCursor()
            }
        }
        .onChange(of: open) { isOpen in
            if isOpen {
                watchOutside()
                closing = false
                // Opening: the magnifier turns into the cursor.
                withAnimation(.timingCurve(0.45, 0, 0.2, 1, duration: 0.42)) { iconOpen = true }
            } else {
                focused = false
                stopWatching()
                // Closing: a magnifier at once, at the end it will rest, a
                // little small; it settles as the field closes round it.
                var still = Transaction()
                still.disablesAnimations = true
                withTransaction(still) {
                    iconOpen = false
                    closing = true
                    iconPop = 0.72
                }
                withAnimation(.spring(response: 0.38, dampingFraction: 0.72)) { iconPop = 1 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { if !open { closing = false } }
            }
        }
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { frameInWindow = geo.frame(in: .global) }
                .onChange(of: geo.frame(in: .global)) { frameInWindow = $0 }
        })
        .onAppear { iconOpen = open }
        .onChange(of: hasContent) { _ in if focused { greyCursor() } }
        .onDisappear(perform: stopWatching)
        .toolTip("Search", "Words, tags or themes", enabled: !open)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Filter")
    }

    /// The text cursor in the same grey as the magnifier's line (AppKit's
    /// field editor draws it, in the accent blue unless told otherwise).
    private func greyCursor() {
        let apply = {
            guard let window = NSApp.keyWindow,
                  let editor = window.fieldEditor(false, for: nil) as? NSTextView else { return }
            editor.insertionPointColor = NSColor.labelColor.withAlphaComponent(0.75)
        }
        apply()
        DispatchQueue.main.async(execute: apply)
    }

    private func openField() {
        // Just the field: no tag menu under it.
        withAnimation(Brand.motion) { open = true }
        // Focus as the cursor finishes forming, so the field's own cursor
        // takes over from it on the same spot.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { focused = true }
    }

    /// A click anywhere outside the open field: with nothing typed it folds
    /// back into the magnifier (the opening played backward); with words in
    /// it, it just stops taking keys and keeps filtering.
    private func watchOutside() {
        stopWatching()
        outsideClicks = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            guard let view = event.window?.contentView else { return event }
            let point = event.locationInWindow
            let flipped = CGPoint(x: point.x, y: view.bounds.height - point.y)
            if !frameInWindow.contains(flipped) {
                DispatchQueue.main.async {
                    focused = false
                    if query.isEmpty && filters.isEmpty { withAnimation(Brand.motion) { open = false } }
                }
            }
            return event
        }
    }

    private func stopWatching() {
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        outsideClicks = nil
    }

    /// The tag menu under the field is gone; searching is the words you type.
    private func showMenu() {}

    /// Esc closes the menu first, then the field when nothing is filtered.
    private func escape() {
        withAnimation(Brand.motion) {
            if menuOpen {
                menuOpen = false
                if query.isEmpty && filters.isEmpty { open = false }
            } else if query.isEmpty && filters.isEmpty {
                open = false
            } else {
                query = ""
                filters = []
                open = false
            }
        }
    }

    private func clear() {
        withAnimation(Brand.motion) {
            query = ""
            filters = []
        }
        focused = true
    }
}

/// A picked tag inside the field. Click to remove it.
private struct FilterToken: View {
    let text: String
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: remove) {
            HStack(spacing: 3) {
                Text(text)
                    .font(Theme.Typography.ui(10.5, .medium))
                    .lineLimit(1)
                Image(systemName: "xmark")
                    .font(.system(size: 6.5, weight: .bold))
                    .opacity(hovering ? 0.9 : 0.45)
            }
            .padding(.horizontal, 6)
            .frame(height: 14)
            .background(Capsule().fill(Color.primary.opacity(hovering ? 0.18 : 0.13)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .fixedSize()
        .toolTip("Remove \(text)", align: .center)
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }
}

/// Drops right under the search field, as wide as it: one list of tags,
/// your tabs first, then what Margin tagged, most used first, narrowed by
/// what you type. A name and a quiet count, nothing else.
struct FilterMenu: View {
    let query: String
    let filters: [String]
    let options: FilterOptions
    let pick: (String) -> Void
    let accept: (String) -> Void
    let dismiss: (String) -> Void

    private var items: [(name: String, count: Int?)] {
        var seen = Set<String>()
        var all: [(name: String, count: Int?)] = []
        let tagged = options.suggested + options.tags
        let counts = Dictionary(tagged.map { ($0.name.lowercased(), $0.count) }, uniquingKeysWith: max)
        for tab in options.tabs where seen.insert(tab.lowercased()).inserted {
            all.append((tab, counts[tab.lowercased()]))
        }
        for tag in tagged.sorted(by: { $0.count > $1.count }) where seen.insert(tag.name.lowercased()).inserted {
            all.append((tag.name, tag.count))
        }
        let q = query.trimmed
        return all.filter { !filters.contains($0.name) && (q.isEmpty || $0.name.localizedCaseInsensitiveContains(q)) }
    }

    var body: some View {
        let list = items
        VStack(alignment: .leading, spacing: 0) {
            if list.isEmpty {
                Text(query.trimmed.isEmpty ? "No tags yet" : "Searching for “\(query.trimmed)”")
                    .font(Archive.sans(12))
                    .foregroundStyle(Archive.faint)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .frame(height: 26, alignment: .leading)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(list, id: \.name) { item in
                            FilterRow(name: item.name, count: item.count) { pick(item.name) }
                        }
                    }
                }
                .frame(height: min(CGFloat(list.count) * 26, 26 * 9))
            }
        }
        .padding(4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Brand.background)
                .shadow(color: .black.opacity(0.1), radius: 14, y: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }
}

/// One tag: its name, and how many moments carry it, faint at the far edge.
private struct FilterRow: View {
    let name: String
    let count: Int?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(name)
                    .font(Archive.sans(12))
                    .foregroundStyle(Archive.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                if let count {
                    Text("\(count)")
                        .font(Archive.sansLight(12))
                        .monospacedDigit()
                        .foregroundStyle(Archive.faint)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.06 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A tab (filled) or one of Margin's tags (outlined) in the menu.
private struct MenuChip: View {
    enum Style { case tab, tag }
    let text: String
    var count: Int? = nil
    let style: Style
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(text)
                    .font(Theme.Typography.ui(11.5, style == .tab ? .medium : .regular))
                if let count {
                    Text("\(count)")
                        .font(Theme.Typography.ui(10.5))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 3.5)
            .foregroundStyle(style == .tab ? Color.primary : Color.secondary)
            .background(Capsule().fill(style == .tab ? Color.primary.opacity(hovering ? 0.13 : 0.08) : Color.primary.opacity(hovering ? 0.07 : 0)))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(style == .tag ? 0.14 : 0), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A tab Margin suggests: dashed until you accept it (✓) or wave it off (✕).
struct SuggestedChip: View {
    let name: String
    let count: Int
    let isOn: Bool
    let select: () -> Void
    let accept: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: select) {
                HStack(spacing: 4) {
                    Text(name).font(Theme.Typography.ui(11.5, .medium))
                    Text("\(count)").font(Theme.Typography.ui(10.5)).monospacedDigit().foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            Button(action: accept) { Image(systemName: "checkmark").font(.system(size: 8.5, weight: .bold)) }
                .buttonStyle(.plain)
                .toolTip("Make this a tab", align: .center)
            Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(.secondary) }
                .buttonStyle(.plain)
                .toolTip("Not a tab", align: .center)
        }
        .padding(.leading, 9)
        .padding(.trailing, 7)
        .padding(.vertical, 3.5)
        .background(Capsule().fill(isOn ? Brand.fill : Color.clear))
        .overlay(Capsule().strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3])).foregroundStyle(Color.secondary.opacity(0.5)))
        .foregroundStyle(.secondary)
        .toolTip("Suggested", "Margin found this in your captures", align: .leading)
    }
}

/// A magnifier at 0, a text cursor at 1, and every shape between. Built as
/// the cursor (a ring on top of a vertical handle) and tilted 45° back into
/// a magnifier, so the morph is: straighten up, fold the ring flat into the
/// line.
struct MagnifierCaret: Shape {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let p = min(max(progress, 0), 1)
        let unfold = min(p, 1)
        let h = rect.height
        // The magnifier is longer, diagonally; folded, the cursor's 12 pt.
        let length = 12 + (h * 1.25 - 12) * (1 - unfold)
        let top = rect.midY - length / 2
        let ring = length * 0.56 * (1 - 0.15 * unfold)
        var path = Path()
        // Ring: it narrows to nothing, leaving its height as part of the line.
        let rx = ring / 2 * (1 - unfold)
        if rx > 0.05 {
            path.addEllipse(in: CGRect(x: rect.midX - rx, y: top, width: rx * 2, height: ring))
        } else {
            path.move(to: CGPoint(x: rect.midX, y: top))
            path.addLine(to: CGPoint(x: rect.midX, y: top + ring))
        }
        // Handle.
        path.move(to: CGPoint(x: rect.midX, y: top + ring))
        path.addLine(to: CGPoint(x: rect.midX, y: top + length))
        // Tilt: upright at 1, handle to the bottom right at 0.
        let angle = -.pi / 4 * (1 - p)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        return path.applying(
            CGAffineTransform(translationX: center.x, y: center.y)
                .rotated(by: angle)
                .translatedBy(x: -center.x, y: -center.y)
        )
    }
}

/// The drawn cursor's blink, once the magnifier has folded into it: on and
/// off like the system's, starting on.
private struct CaretBlink: ViewModifier {
    let on: Bool
    @State private var since = Date()

    func body(content: Content) -> some View {
        TimelineView(.periodic(from: .now, by: 0.53)) { timeline in
            // The fold takes about 0.45 s; blink after it.
            let t = timeline.date.timeIntervalSince(since) - 0.5
            let visible = !on || t < 0 || Int(t / 0.53) % 2 == 0
            content.opacity(visible ? 1 : 0)
        }
        .onChange(of: on) { if $0 { since = Date() } }
    }
}
