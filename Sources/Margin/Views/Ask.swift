import MarginKit
import SwiftUI

// MARK: - What Ask shows on the archive

/// What Ask is doing to the archive, for the timeline and the map to show.
/// Reading: a slow light passes over the archive (`ReadingSweep`). Found:
/// the answers light up one after another (on the map they gather into one
/// group under the question's name), the one you've stepped to is outlined,
/// and the rest stays quiet until you clear it.
struct AskLook: Equatable {
    enum Phase: Equatable { case reading, found }
    var phase: Phase
    /// The answers, best first.
    var ids: [UUID]
    /// Their name as a group, for the map.
    var title: String
    /// Changes with every step, so each one animates.
    var token: Int
    /// The answer you've stepped to (timeline).
    var current: UUID? = nil
    /// Answers come in one after another the first time; stepping is quick.
    var stagger = true

    /// Where each answer is in the order (for the stagger).
    var rank: [UUID: Int] {
        Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// How quiet a capture is: as it is while reading (the sweep does the
    /// quieting), nearly gone if it isn't an answer.
    func opacity(_ id: UUID) -> Double {
        switch phase {
        case .reading: return 1
        case .found: return ids.contains(id) ? 1 : 0.14
        }
    }

    /// Answers come in one after another, 45 ms apart; the rest quiets at once.
    func motion(_ id: UUID) -> Animation {
        if phase == .found, stagger, let index = rank[id] {
            return .easeOut(duration: 0.36).delay(0.08 + Double(min(index, 24)) * 0.045)
        }
        return .easeInOut(duration: 0.3)
    }
}

private struct AskLookKey: EnvironmentKey {
    static let defaultValue: AskLook? = nil
}

extension EnvironmentValues {
    var askLook: AskLook? {
        get { self[AskLookKey.self] }
        set { self[AskLookKey.self] = newValue }
    }
}

/// Ask's answer in the Themes view, for the map to take: the whole project
/// in new themes and patterns, best first. The map calls `done` once it has
/// started moving (false if it couldn't, say it isn't on screen).
final class AskSteer {
    struct Pattern { let name: String; let ids: [UUID] }
    struct Theme { let name: String; let patterns: [Pattern] }
    let themes: [Theme]
    let token: Int
    /// A sorting you haven't kept is on the map: this one replaces it, and
    /// Undo still goes back to the map from before either.
    let replacing: Bool
    let done: (Bool) -> Void

    init(themes: [Theme], token: Int, replacing: Bool, done: @escaping (Bool) -> Void) {
        self.themes = themes
        self.token = token
        self.replacing = replacing
        self.done = done
    }
}

// MARK: - The model

/// Ask: a panel on the right that understands what you mean. Not a chat:
/// the archive is the answer. You type a question or a lens, the panel shows
/// its plan ticking off while a light passes over your captures, then the
/// archive changes (answers light up in the timeline, the whole map regroups
/// in Themes) and the panel lists what changed, with Keep and Undo for a
/// new sorting or the way through the answers. With Intelligence off, or if
/// Gemini fails, it matches words instead and says why.
@MainActor
final class AskModel: ObservableObject {
    enum Stage: Equatable { case closed, open, working, answered }

    /// One step of the plan, in the words for doing it and for done.
    struct Step: Equatable {
        let doing: String
        let done: String
    }

    /// What stays after it's done: a few words, and the longer reply behind them.
    struct Result: Equatable {
        var caption: String
        var detail: String?
        /// The map was sorted again: Undo.
        var undoable = false
    }

    @Published var stage: Stage = .closed
    @Published var text = ""
    @Published private(set) var plan: [Step] = []
    @Published private(set) var stepIndex = 0
    /// Said in place of the current step while Gemini retries.
    @Published private(set) var stepNote: String?
    @Published private(set) var result: Result?
    @Published private(set) var look: AskLook?
    /// The answers in the timeline, and the one you're on.
    @Published private(set) var found: [UUID] = []
    @Published private(set) var current = 0
    /// Stepping through answers (the timeline, more than one answer).
    @Published private(set) var canStep = false
    /// The themes of a new sorting, in order, with how many captures each.
    @Published private(set) var sorted: [SortedTheme] = []
    /// A new sorting is on the map but not kept yet.
    @Published private(set) var previewPending = false
    /// This project's earlier questions, newest first.
    @Published private(set) var history: [String] = []
    /// How long the last answer took, for "Worked for 14 s".
    @Published private(set) var worked: TimeInterval?
    private var started = Date()
    private var project = ""

    struct SortedTheme: Identifiable, Equatable {
        let name: String
        let count: Int
        var id: String { name }
    }
    /// The question that was answered: Return on it again steps, like find.
    private var answered = ""

    /// Posted with an answer's id, for the timeline to bring it into view.
    static let reveal = Notification.Name("MarginAskReveal")
    /// Posted with an `AskSteer`, for the map to sort itself again.
    static let steer = Notification.Name("MarginAskSteer")
    /// Posted with a theme's name, for the map to bring it into view.
    static let focusTheme = Notification.Name("MarginAskFocusTheme")
    /// Undo for the last sorting, set by whoever submits.
    var undoSteer: (() -> Void)?

    private var task: Task<Void, Never>?
    private var token = 0
    static let morph = Animation.timingCurve(0.32, 0.72, 0, 1, duration: 0.42)
    static let tick = Animation.easeOut(duration: 0.25)

    func open() {
        guard stage == .closed else { return }
        withAnimation(Self.morph) { stage = .open }
    }

    /// Clears the answer and the archive, keeps the panel open with your
    /// words. A sorting you didn't keep goes back.
    func clear() {
        task?.cancel()
        if previewPending { undoSteer?() }
        previewPending = false
        sorted = []
        withAnimation(Theme.Motion.exit) {
            result = nil
            plan = []
            stepNote = nil
            canStep = false
        }
        withAnimation(.easeInOut(duration: 0.35)) { look = nil }
        found = []
        answered = ""
        withAnimation(Self.morph) { stage = .open }
    }

    /// Back to the button: everything as it was.
    func close() {
        clear()
        withAnimation(Self.morph) {
            stage = .closed
            text = ""
        }
    }

    /// Esc: first the answer goes, then the field.
    func escape() {
        if stage == .working || stage == .answered { clear() } else { close() }
    }

    /// Return: a new question asks; the same one again steps to the next answer.
    func returnPressed(submit: () -> Void) {
        if stage == .answered, canStep, text.trimmed == answered { next() } else { submit() }
    }

    func next() { step(by: 1) }
    func previous() { step(by: -1) }

    private func step(by delta: Int) {
        guard !found.isEmpty, look?.current != nil else { return }
        current = (current + delta + found.count) % found.count
        let id = found[current]
        if var l = look {
            l.current = id
            l.stagger = false
            withAnimation(.easeOut(duration: 0.2)) { look = l }
        }
        NotificationCenter.default.post(name: Self.reveal, object: id)
    }

    /// Puts the map back as it was before the sorting.
    func undo() {
        if previewPending { undoSteer?() }
        previewPending = false
        clear()
    }

    /// Keeps the new sorting as the map.
    func keep() {
        withAnimation(Theme.Motion.snappy) {
            previewPending = false
            if var r = result {
                r.undoable = false
                r.caption = "Kept: " + r.caption.prefix(1).lowercased() + r.caption.dropFirst()
                result = r
            }
        }
    }

    /// Jumps to one of the answers in the timeline.
    func go(to index: Int) {
        guard found.indices.contains(index) else { return }
        step(by: index - current)
    }

    // MARK: Earlier questions

    func load(project: String) {
        self.project = project
        history = UserDefaults.standard.stringArray(forKey: "askHistory." + project) ?? []
    }

    private func remember(_ question: String) {
        var list = history.filter { $0.caseInsensitiveCompare(question) != .orderedSame }
        list.insert(question, at: 0)
        history = Array(list.prefix(8))
        UserDefaults.standard.set(history, forKey: "askHistory." + project)
    }

    // MARK: Asking

    func submit(entries: [Entry], intelligence: Intelligence, clustering: Bool = false) {
        let question = text.trimmed
        guard !question.isEmpty, !entries.isEmpty else { return }
        task?.cancel()
        token += 1
        remember(question)
        started = Date()
        worked = nil
        withAnimation(Theme.Motion.exit) { sorted = [] }
        let useAI = intelligence.canRun
        let config = intelligence.config
        let n = entries.count
        let reading = Step(doing: "Reading \(n)", done: "Read \(n)")
        if clustering && useAI {
            setPlan([reading, Step(doing: "Grouping", done: "Grouped"), Step(doing: "Naming", done: "Named"),
                     Step(doing: "Arranging", done: "Arranged")])
        } else if useAI {
            setPlan([reading, Step(doing: "Finding", done: "Found"), Step(doing: "Showing", done: "Shown")])
        } else {
            setPlan([reading, Step(doing: "Matching words", done: "Matched"), Step(doing: "Showing", done: "Shown")])
        }
        withAnimation(Theme.Motion.exit) {
            result = nil
            canStep = false
        }
        found = []
        withAnimation(Self.morph) { stage = .working }
        withAnimation(.easeInOut(duration: 0.5)) {
            look = AskLook(phase: .reading, ids: [], title: "", token: token)
        }
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            // Reading is quick but real: long enough to see it happen.
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            self.advance()
            if clustering && useAI {
                await self.steer(question, entries: entries, config: config)
            } else {
                await self.find(question, entries: entries, config: config, useAI: useAI, clustering: clustering, failure: nil)
            }
        }
    }

    private func setPlan(_ steps: [Step]) {
        withAnimation(Self.tick) {
            plan = steps
            stepIndex = 0
            stepNote = nil
        }
    }

    private func advance() {
        withAnimation(Self.tick) {
            stepIndex = min(stepIndex + 1, plan.count)
            stepNote = nil
        }
    }

    /// Gemini retrying: say so, in place of the step.
    private nonisolated func retrying(_ note: String) {
        Task { @MainActor [weak self] in
            guard let self, self.stage == .working else { return }
            withAnimation(Self.tick) { self.stepNote = note }
        }
    }

    /// The timeline (or no Intelligence): the answers light up, or gather on the map.
    private func find(_ question: String, entries: [Entry], config: AIConfig, useAI: Bool, clustering: Bool,
                      failure: String?) async {
        let started = Date()
        var answer: (ids: [UUID], reply: String, label: String, keywords: Bool)
        var failed = failure
        if useAI && failure == nil {
            do {
                answer = try await Self.understand(question, entries: entries, config: config) { [weak self] in self?.retrying($0) }
            } catch {
                guard !Task.isCancelled else { return }
                failed = CaptureAsk.reason(error)
                setPlan([plan.first ?? Step(doing: "Reading", done: "Read"), Step(doing: "Matching words", done: "Matched"),
                         Step(doing: "Showing", done: "Shown")])
                advance()
                answer = Self.keywords(question, in: entries)
            }
        } else {
            answer = Self.keywords(question, in: entries)
        }
        let rest = 0.6 - Date().timeIntervalSince(started)
        if rest > 0 { try? await Task.sleep(nanoseconds: UInt64(rest * 1_000_000_000)) }
        guard !Task.isCancelled else { return }
        advance()

        token += 1
        let stepping = !clustering && answer.ids.count > 1
        if answer.ids.isEmpty {
            withAnimation(.easeInOut(duration: 0.35)) { look = nil }
        } else {
            found = answer.ids
            current = 0
            withAnimation(.easeOut(duration: 0.3)) {
                look = AskLook(phase: .found, ids: answer.ids, title: answer.label, token: token,
                               current: clustering ? nil : answer.ids.first)
            }
            NotificationCenter.default.post(name: Self.reveal, object: answer.ids.first)
        }
        let settle = answer.ids.isEmpty ? 0.2 : 0.35 + Double(min(answer.ids.count, 12)) * 0.045
        try? await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000))
        guard !Task.isCancelled else { return }
        advance()

        let caption: String
        var detail: String? = answer.reply
        if answer.ids.isEmpty {
            caption = "Nothing found"
        } else if let failed {
            caption = "Matched by words"
            detail = "\(failed.prefix(1).uppercased())\(failed.dropFirst()), so these are captures that use your words."
        } else if answer.keywords {
            caption = "Matched by words"
            detail = clustering ? "Sorting the map around a question needs Intelligence. These use your words." : answer.reply
        } else {
            caption = answer.label.isEmpty ? (answer.ids.count == 1 ? "1 capture" : "\(answer.ids.count) captures") : answer.label
        }
        answered = question
        withAnimation(Theme.Motion.snappy) {
            result = Result(caption: caption, detail: detail)
            canStep = stepping
            worked = Date().timeIntervalSince(started)
            stage = .answered
        }
    }

    /// Themes: the agent sorts the whole project around the question and the
    /// map rearranges itself, group by group.
    private func steer(_ question: String, entries: [Entry], config: AIConfig) async {
        let (items, byKey) = Self.items(entries)
        let steering: CaptureAsk.Steering
        do {
            let context = entries.first.map { ProjectNotes.shared.about($0.project) }
            steering = try await CaptureAsk(config: config).steer(question, items: items, context: context) { [weak self] in self?.retrying($0) }
        } catch {
            guard !Task.isCancelled else { return }
            setPlan([plan.first ?? Step(doing: "Reading", done: "Read"), Step(doing: "Matching words", done: "Matched"),
                     Step(doing: "Showing", done: "Shown")])
            advance()
            await find(question, entries: entries, config: config, useAI: false, clustering: true,
                       failure: CaptureAsk.reason(error))
            return
        }
        guard !Task.isCancelled else { return }
        // Naming is in the answer; a beat to see it.
        advance()
        try? await Task.sleep(nanoseconds: 400_000_000)
        guard !Task.isCancelled else { return }
        advance()
        let themes: [AskSteer.Theme] = steering.themes.map { theme in
            AskSteer.Theme(name: theme.name, patterns: theme.patterns.map { pattern in
                AskSteer.Pattern(name: pattern.name, ids: pattern.ids.compactMap { byKey[$0] })
            })
        }
        token += 1
        let moved: Bool = await withCheckedContinuation { continuation in
            var resumed = false
            let finish: (Bool) -> Void = { ok in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: ok)
            }
            NotificationCenter.default.post(name: Self.steer,
                                            object: AskSteer(themes: themes, token: token, replacing: previewPending, done: finish))
            // No map on screen to take it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { finish(false) }
        }
        guard !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: 0.5)) { look = nil }
        guard moved else {
            await find(question, entries: entries, config: config, useAI: false, clustering: true,
                       failure: "the map wasn't ready")
            return
        }
        // The line once the groups have landed.
        try? await Task.sleep(nanoseconds: UInt64((0.5 + Double(min(themes.count, 7)) * 0.09) * 1_000_000_000))
        guard !Task.isCancelled else { return }
        advance()
        let n = themes.count
        answered = question
        previewPending = true
        withAnimation(Theme.Motion.snappy) {
            result = Result(caption: n == 1 ? "Sorted into 1 theme" : "Sorted into \(n) themes",
                            detail: steering.reply.isEmpty ? nil : steering.reply, undoable: true)
            sorted = themes.map { SortedTheme(name: $0.name, count: $0.patterns.reduce(0) { $0 + $1.ids.count }) }
            worked = Date().timeIntervalSince(started)
            stage = .answered
        }
    }

    // MARK: Understanding

    /// One line per capture for the agent, newest first, at most 400.
    private static func items(_ entries: [Entry]) -> (items: [CaptureAsk.Item], byKey: [String: UUID]) {
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        var items: [CaptureAsk.Item] = []
        var byKey: [String: UUID] = [:]
        for (index, entry) in entries.reversed().prefix(400).enumerated() {
            let key = "c\(index + 1)"
            byKey[key] = entry.id
            var parts: [String] = [day.string(from: entry.createdAt), "\(entry.kind)"]
            func add(_ label: String, _ value: String?, limit: Int) {
                guard let value = value?.trimmed, !value.isEmpty else { return }
                let short = value.count > limit ? String(value.prefix(limit)) + "…" : value
                parts.append("\(label): \(short.replacingOccurrences(of: "\n", with: " "))")
            }
            add("TITLE", entry.displayTitle, limit: 90)
            add("WHY", entry.rationale, limit: 220)
            add("SEEN", entry.ai?.seen, limit: 160)
            add("TOPIC", entry.tab ?? entry.ai?.topic, limit: 40)
            let tags = (entry.tags + (entry.ai?.tags ?? [])).prefix(6).joined(separator: ", ")
            add("TAGS", tags, limit: 80)
            items.append(CaptureAsk.Item(id: key, line: parts.joined(separator: " | ")))
        }
        return (items, byKey)
    }

    private static func understand(_ question: String, entries: [Entry], config: AIConfig,
                                   onRetry: @escaping (String) -> Void)
        async throws -> (ids: [UUID], reply: String, label: String, keywords: Bool) {
        let (items, byKey) = items(entries)
        let context = entries.first.map { ProjectNotes.shared.about($0.project) }
        let answer = try await CaptureAsk(config: config).ask(question, items: items, context: context, onRetry: onRetry)
        let ids = answer.ids.compactMap { byKey[$0] }
        return (ids, answer.reply.isEmpty ? "Here's what fits." : answer.reply, answer.label, false)
    }

    // MARK: Words

    private static let stopWords: Set<String> = [
        "the", "and", "for", "with", "that", "this", "from", "what", "where", "when", "which", "who", "how", "why",
        "did", "does", "was", "were", "are", "is", "show", "find", "all", "any", "about", "into", "want", "making",
        "make", "made", "my", "me", "our", "your", "you", "can", "could", "would", "should", "case", "study",
    ]

    /// Captures that mention the question's words, most words first.
    static func keywords(_ question: String, in entries: [Entry]) -> (ids: [UUID], reply: String, label: String, keywords: Bool) {
        let words = question.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 3 && !stopWords.contains($0) }
        let label = question.trimmed.prefix(1).uppercased() + question.trimmed.dropFirst().prefix(40)
        guard !words.isEmpty else {
            return ([], "Try a few words that would be in your notes.", label, true)
        }
        var scored: [(UUID, Int, Date)] = []
        for entry in entries {
            let text = entry.searchText.lowercased()
            let hits = words.filter { text.contains($0) }.count
            if hits > 0 { scored.append((entry.id, hits, entry.createdAt)) }
        }
        let best = scored.map(\.1).max() ?? 0
        // Captures with most of the words; with one word, every mention.
        let floor = max(1, best - (words.count > 2 ? 1 : 0))
        let ids = scored.filter { $0.1 >= floor }
            .sorted { $0.1 == $1.1 ? $0.2 > $1.2 : $0.1 > $1.1 }
            .map(\.0)
        let quoted = words.prefix(3).map { "“\($0)”" }.joined(separator: ", ")
        let reply = ids.isEmpty
            ? "Nothing here mentions \(quoted). Turn on Intelligence to ask in your own words."
            : "\(ids.count == 1 ? "1 capture mentions" : "\(ids.count) captures mention") \(quoted). Turn on Intelligence to ask in your own words."
        return (ids, reply, label, true)
    }
}


// MARK: - The panel

/// Ask, as a panel on the right: the sidebar's frosted card, mirrored, no
/// outlines anywhere. Opening it narrows the sidebar to its rail (it comes
/// back when Ask closes). At the top, a soft white composer that says what
/// it acts on (the map or the timeline), with a round send that becomes a
/// round stop while it works. Under it, empty: suggestions (↳) and your
/// earlier questions; working: an ink pill with three circling dots saying
/// what it's doing, the plan quietly under it; done: "Worked for 12 s"
/// (the plan, folded), what changed, Keep and Undo as pills, and the themes
/// or answers as a list. The archive is the answer; the panel says what
/// happened.
struct AskPanel: View {
    @ObservedObject var ask: AskModel
    @EnvironmentObject private var store: EntryStore
    /// The captures in view, for the answers' thumbnails.
    let entries: [Entry]
    let clustering: Bool
    let submit: () -> Void
    let close: () -> Void
    @FocusState private var focused: Bool
    @State private var traceOpen = false

    static let width: CGFloat = 304
    static let inset = ProjectSidebar.inset
    /// What the archive gives up for it.
    static var room: CGFloat { width + inset }
    static let pad = Theme.Space.x3

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            // Above the composer, so the close button's tooltip isn't under it.
            top.zIndex(1)
            composer
                .padding(.horizontal, Self.pad - 4)
            ScrollView {
                content
                    .padding(.horizontal, Self.pad)
                    .padding(.top, Theme.Space.x4)
                    .padding(.bottom, Self.pad)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .clipShape(shape)
        .background(FloatingSurface(shape: shape, frosted: true))
        .padding(Self.inset)
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { focused = true } }
        .onChange(of: ask.stage) { _ in traceOpen = false }
        // Stepping through the answers: ↑ ↓, or ⌘G and ⇧⌘G like find.
        .background {
            if ask.canStep && ask.stage == .answered {
                ZStack {
                    Button("", action: ask.next).keyboardShortcut(.downArrow, modifiers: [])
                    Button("", action: ask.previous).keyboardShortcut(.upArrow, modifiers: [])
                    Button("", action: ask.next).keyboardShortcut("g", modifiers: .command)
                    Button("", action: ask.previous).keyboardShortcut("g", modifiers: [.command, .shift])
                }
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }

    // MARK: Top

    /// On the header's line: Margin's mark and the name, and close where the
    /// Ask button sits in the header.
    private var top: some View {
        HStack(spacing: Theme.Space.x2) {
            BracketMark().fill(Theme.Palette.ink).frame(width: 13, height: 13)
            Text("Ask")
                .font(Theme.Typography.ui(Theme.Typography.body, .medium))
                .foregroundStyle(Theme.Palette.ink)
            Spacer(minLength: 0)
            HeaderTool(help: "Close", detail: "Esc", plain: true, tipAlign: .trailing, action: close) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .medium))
            }
        }
        .padding(.leading, Self.pad + 2)
        .padding(.trailing, RepoHeader.inset - Self.inset)
        .frame(height: RepoHeader.toolHeight)
        .padding(.top, RepoHeader.inset - Self.inset)
        .padding(.bottom, Theme.Space.x2)
    }

    // MARK: Composer

    /// A white card on the frosted panel: what you write, and under it what
    /// it acts on and send (stop while it works).
    private var composer: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        return VStack(alignment: .leading, spacing: Theme.Space.x2) {
            ZStack(alignment: .topLeading) {
                if ask.stage == .working {
                    ShimmerText(text: ask.text, size: Theme.Typography.body)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                } else {
                    TextField("", text: $ask.text,
                              prompt: Text(clustering ? "Sort the map by…" : "Ask about this project").foregroundColor(Theme.Palette.ink3),
                              axis: .vertical)
                        .lineLimit(1...4)
                        .textFieldStyle(.plain)
                        .font(Theme.Typography.ui(Theme.Typography.body))
                        .foregroundStyle(Theme.Palette.ink)
                        .focused($focused)
                        .onSubmit { ask.returnPressed(submit: submit) }
                        .onExitCommand { if ask.stage == .open { close() } else { ask.escape() } }
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.2), value: ask.stage == .working)
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)

            HStack(spacing: Theme.Space.x1 + 2) {
                // What it will act on.
                Image(systemName: clustering ? "square.grid.2x2" : "list.bullet")
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.leading, 2)
                Text(clustering ? "Sorts the map" : "Finds in the timeline")
                Spacer(minLength: 0)
                action
            }
            .font(Theme.Typography.ui(Theme.Typography.caption))
            .foregroundStyle(Theme.Palette.ink3)
        }
        .padding(.leading, Theme.Space.x3 + 2)
        .padding(.trailing, Theme.Space.x2)
        .padding(.top, Theme.Space.x3 + 2)
        .padding(.bottom, Theme.Space.x2)
        .background(shape.fill(Theme.Palette.paper))
        // No outline: it lifts a little more while you write in it.
        .shadow(color: .black.opacity(focused ? 0.08 : 0.05), radius: 1, x: 0, y: 0.5)
        .shadow(color: .black.opacity(focused ? 0.08 : 0.05), radius: focused ? 14 : 10, x: 0, y: 4)
        .animation(Theme.Motion.hover, value: focused)
        .contentShape(Rectangle())
        .onTapGesture { if ask.stage != .working { focused = true } }
    }

    /// Send (ink) while there's something to send; stop while it works;
    /// clear once it's answered.
    @ViewBuilder private var action: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
        switch ask.stage {
        case .working:
            Button(action: ask.clear) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Theme.Palette.ink)
                    .frame(width: 9, height: 9)
                    .frame(width: 28, height: 28)
                    .background(Theme.Palette.fillSelected, in: shape)
            }
            .buttonStyle(PressStyle())
            .toolTip("Stop", edge: .below, align: .trailing)
            .transition(.scale(scale: 0.7).combined(with: .opacity))
        case .answered:
            AskIconButton(help: "Clear", action: ask.clear) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
            }
        default:
            let ready = !ask.text.trimmed.isEmpty
            Button(action: submit) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ready ? Theme.Palette.paper : Theme.Palette.ink3)
                    .frame(width: 28, height: 28)
                    .background(ready ? Theme.Palette.ink : Theme.Palette.fillSelected, in: shape)
            }
            .buttonStyle(PressStyle())
            .disabled(!ready)
            .animation(Theme.Motion.hover, value: ready)
            .accessibilityLabel("Ask")
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch ask.stage {
        case .working:
            VStack(alignment: .leading, spacing: Theme.Space.x4) {
                WorkingPill(text: ask.stepNote ?? currentStep)
                trace(done: false)
            }
            .transition(.opacity)
        case .answered:
            outcome.transition(.opacity)
        default:
            starts.transition(.opacity)
        }
    }

    /// Empty: suggestions as chips, then what you asked before.
    private var starts: some View {
        VStack(alignment: .leading, spacing: Theme.Space.x6) {
            VStack(alignment: .leading, spacing: Theme.Space.x2 + 2) {
                Text(clustering ? "Sort the map around a question, or try one of these." : "Ask in your own words, or try one of these.")
                    .font(Theme.Typography.ui(Theme.Typography.control))
                    .foregroundStyle(Theme.Palette.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(starters, id: \.self) { prompt in
                        PanelRow(title: prompt, icon: "arrow.turn.down.right", quiet: true) { run(prompt) }
                    }
                }
                .padding(.horizontal, -Theme.Space.x2)
            }
            if !ask.history.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    label("Earlier")
                    ForEach(ask.history, id: \.self) { question in
                        PanelRow(title: question, icon: "magnifyingglass", quiet: true) { run(question) }
                    }
                }
            }
        }
    }

    private var starters: [String] {
        clustering
            ? ["How I found the problem", "How the look evolved", "What I'd show in a case study"]
            : ["Where I decided the direction", "Feedback I got", "The final visuals"]
    }

    private func run(_ question: String) {
        ask.text = question
        submit()
    }

    /// The plan, quietly: done steps checked, the current one in ink, the
    /// rest faint. The pill above says the same step out loud.
    private func trace(done all: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(ask.plan.enumerated()), id: \.offset) { index, step in
                let done = all || index < ask.stepIndex
                let now = !all && index == ask.stepIndex
                HStack(spacing: Theme.Space.x2) {
                    ZStack {
                        if done {
                            Image(systemName: "checkmark").font(.system(size: 8, weight: .bold))
                                .transition(.scale(scale: 0.6).combined(with: .opacity))
                        } else {
                            Circle().fill(now ? Theme.Palette.ink : Theme.Palette.ink3.opacity(0.4)).frame(width: 4, height: 4)
                        }
                    }
                    .frame(width: 12)
                    Text(done ? step.done : step.doing)
                }
                .font(Theme.Typography.ui(Theme.Typography.control))
                .foregroundStyle(now ? Theme.Palette.ink : done ? Theme.Palette.ink3 : Theme.Palette.ink3.opacity(0.6))
                .frame(height: 22)
            }
        }
        .padding(.leading, 2)
        .animation(AskModel.tick, value: ask.stepIndex)
    }

    /// Done: how long it worked (the trace, folded), what changed, and the list.
    @ViewBuilder private var outcome: some View {
        if let result = ask.result {
            VStack(alignment: .leading, spacing: Theme.Space.x4) {
                VStack(alignment: .leading, spacing: Theme.Space.x2) {
                    Button {
                        withAnimation(Theme.Motion.snappy) { traceOpen.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Text(workedLine)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .semibold))
                                .rotationEffect(.degrees(traceOpen ? 90 : 0))
                        }
                        .font(Theme.Typography.ui(Theme.Typography.caption))
                        .foregroundStyle(Theme.Palette.ink3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if traceOpen {
                        trace(done: true).transition(.opacity)
                    }
                }
                VStack(alignment: .leading, spacing: Theme.Space.x1 + 2) {
                    Text(result.caption)
                        .font(Theme.Typography.ui(15, .medium))
                        .foregroundStyle(Theme.Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail = result.detail {
                        Text(detail)
                            .font(Theme.Typography.ui(Theme.Typography.body))
                            .foregroundStyle(Theme.Palette.ink2)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if ask.previewPending {
                    HStack(spacing: Theme.Space.x2) {
                        PanelButton(title: "Keep this sorting", icon: "checkmark", primary: true, action: ask.keep)
                        PanelButton(title: "Undo", icon: "arrow.uturn.backward", primary: false, action: ask.undo)
                    }
                    .transition(.opacity)
                }
                if !ask.sorted.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        label("Themes")
                        ForEach(ask.sorted) { theme in
                            PanelRow(title: theme.name, count: theme.count) {
                                NotificationCenter.default.post(name: AskModel.focusTheme, object: theme.name)
                            }
                        }
                    }
                } else if !ask.found.isEmpty {
                    answers
                }
            }
        }
    }

    private var currentStep: String {
        ask.plan.indices.contains(ask.stepIndex) ? ask.plan[ask.stepIndex].doing : "Working"
    }

    private var workedLine: String {
        guard let worked = ask.worked else { return "Done" }
        let seconds = max(1, Int(worked.rounded()))
        return seconds < 60 ? "Worked for \(seconds) s" : "Worked for \(seconds / 60) min \(seconds % 60) s"
    }

    /// The answers, best first: a thumbnail and its title, the one you're on filled.
    private var answers: some View {
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 0) {
                label(ask.found.count == 1 ? "1 capture" : "\(ask.found.count) captures")
                Spacer(minLength: 0)
                if ask.canStep {
                    Text("\(ask.current + 1) of \(ask.found.count)")
                        .font(Theme.Typography.ui(Theme.Typography.caption).monospacedDigit())
                        .foregroundStyle(Theme.Palette.ink3)
                        .padding(.trailing, 2)
                    AskIconButton(help: "Previous  ↑", action: ask.previous) {
                        Image(systemName: "chevron.up").font(.system(size: 9, weight: .semibold))
                    }
                    AskIconButton(help: "Next  ↓", action: ask.next) {
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    }
                }
            }
            ForEach(Array(ask.found.enumerated()), id: \.element) { index, id in
                if let entry = byID[id] {
                    AnswerRow(entry: entry, store: store, current: ask.canStep && index == ask.current) {
                        ask.go(to: index)
                    }
                }
            }
        }
    }

    private func label(_ title: String) -> some View {
        Text(title)
            .font(Theme.Typography.ui(Theme.Typography.caption))
            .foregroundStyle(Theme.Palette.ink3)
            .padding(.horizontal, Theme.Space.x2)
            .frame(height: 24, alignment: .leading)
    }
}

/// A row in the panel: an icon, words (and a count), a fill on hover.
private struct PanelRow: View {
    let title: String
    var icon: String? = nil
    var count: Int? = nil
    var quiet = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.x2) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(hovering ? Theme.Palette.ink2 : Theme.Palette.ink3)
                        .frame(width: 16)
                }
                Text(title)
                    .font(Theme.Typography.ui(Theme.Typography.body))
                    .foregroundStyle(quiet && !hovering ? Theme.Palette.ink2 : Theme.Palette.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let count {
                    Text("\(count)")
                        .font(Theme.Typography.mono(Theme.Typography.label))
                        .foregroundStyle(Theme.Palette.ink3)
                }
            }
            .padding(.horizontal, Theme.Space.x2)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .fill(hovering ? Theme.Palette.fillHover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(scale: 0.99))
        .onHover { inside in withAnimation(Theme.Motion.hover) { hovering = inside } }
    }
}

/// One answer: its thumbnail, title and day. Filled when it's the one you're on.
private struct AnswerRow: View {
    let entry: Entry
    let store: EntryStore
    let current: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.x2 + 2) {
                ZStack {
                    if let file = entry.imageFile {
                        AsyncThumbnail(store: store, file: file, interpolation: .high) { Theme.Palette.fill }
                            .scaledToFill()
                    } else {
                        WordsThumb(entry: entry, size: CGSize(width: 48, height: 34))
                    }
                }
                .frame(width: 48, height: 34)
                .clipped()
                .overlay(Rectangle().stroke(Archive.frame, lineWidth: 1).padding(-0.5))
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.displayTitle)
                        .font(Theme.Typography.ui(Theme.Typography.control))
                        .foregroundStyle(Theme.Palette.ink)
                        .lineLimit(1)
                    Text(entry.createdAt.formatted(.dateTime.month(.abbreviated).day()))
                        .font(Theme.Typography.ui(Theme.Typography.caption))
                        .foregroundStyle(Theme.Palette.ink3)
                }
                Spacer(minLength: 0)
            }
            .padding(Theme.Space.x1 + 2)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .fill(current ? Theme.Palette.fillSelected : hovering ? Theme.Palette.fillHover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(scale: 0.99))
        .onHover { inside in withAnimation(Theme.Motion.hover) { hovering = inside } }
    }
}

/// Keep (ink) and Undo (grey): the panel's two actions, each with an icon.
private struct PanelButton: View {
    let title: String
    var icon: String? = nil
    let primary: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon).font(.system(size: 10, weight: .semibold)) }
                Text(title).font(Theme.Typography.ui(Theme.Typography.control, .medium))
            }
            .foregroundStyle(primary ? Theme.Palette.paper : Theme.Palette.ink)
            .padding(.horizontal, Theme.Space.x3 + 2)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(primary ? Theme.Palette.ink.opacity(hovering ? 0.86 : 1) : (hovering ? Theme.Palette.fillSelected : Theme.Palette.fill)))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { inside in withAnimation(Theme.Motion.hover) { hovering = inside } }
    }
}

/// What the agent is doing, out loud: an ink strip, three dots circling,
/// the step in light words. The one dark thing in the panel.
private struct WorkingPill: View {
    let text: String

    var body: some View {
        HStack(spacing: Theme.Space.x2) {
            OrbitDots().frame(width: 14, height: 14)
            ShimmerText(text: text, size: Theme.Typography.control,
                        base: Theme.Palette.paper.opacity(0.55), light: Theme.Palette.paper)
                .id(text)
                .transition(.blurFade)
        }
        .animation(AskModel.tick, value: text)
        .padding(.leading, Theme.Space.x3)
        .padding(.trailing, Theme.Space.x3 + 2)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(Theme.Palette.ink))
        .fixedSize()
    }
}

/// Three dots of different sizes circling slowly, each breathing a little
/// out of step: the agent at work. In paper, on the ink pill.
private struct OrbitDots: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            let t: Double = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let cx: Double = Double(size.width) / 2, cy: Double = Double(size.height) / 2
                let u: Double = Double(size.width) / 14
                let sizes: [Double] = [3.2, 2.5, 1.8]
                for i in 0..<3 {
                    let phase: Double = Double(i) * 2 * .pi / 3
                    let angle: Double = t * 2 * .pi / 2.2 + phase
                    let breathe: Double = 0.5 + 0.5 * sin(t * 2 * .pi / 1.3 + phase)
                    let r: Double = (3.4 + 0.9 * breathe) * u
                    let d: Double = sizes[i] * (0.85 + 0.3 * breathe) * u
                    let rect = CGRect(x: cx + cos(angle) * r - d / 2, y: cy + sin(angle) * r - d / 2, width: d, height: d)
                    context.fill(Path(ellipseIn: rect), with: .color(Theme.Palette.paper.opacity(0.5 + 0.5 * breathe)))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// A small icon button inside the field, nested in its corners.
struct AskIconButton<Label: View>: View {
    let help: String
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label()
                .foregroundStyle(hovering ? Theme.Palette.ink : Theme.Palette.ink3)
                .frame(width: Theme.Floating.segment, height: Theme.Floating.segment)
                .background(hovering ? Theme.Palette.fillHover : .clear,
                            in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { inside in withAnimation(Theme.Motion.hover) { hovering = inside } }
        .accessibilityLabel(help)
    }
}

/// A 5 pt ink dot, breathing slowly: the step in progress.
private struct BreathingDot: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            let t: Double = timeline.date.timeIntervalSinceReferenceDate
            let wave: Double = 0.5 + 0.5 * sin(t * 2 * .pi / 1.4)
            Circle()
                .fill(Theme.Palette.ink)
                .frame(width: 5, height: 5)
                .opacity(0.35 + 0.65 * wave)
        }
        .frame(width: 5, height: 5)
    }
}

/// Text with a slow, faint light passing through it, once every 2.4 s:
/// grey words, a band a shade darker crossing them. Low key on purpose.
struct ShimmerText: View {
    let text: String
    var size: CGFloat = Theme.Typography.control
    var base: Color = Theme.Palette.ink3
    var light: Color = Theme.Palette.ink

    var body: some View {
        let label = Text(text).font(Theme.Typography.ui(size))
        label
            .foregroundStyle(base)
            .lineLimit(1)
            .overlay {
                TimelineView(.animation) { timeline in
                    let t: Double = timeline.date.timeIntervalSinceReferenceDate
                    let p: Double = (t / 2.4).truncatingRemainder(dividingBy: 1) * 1.6 - 0.3
                    label
                        .foregroundStyle(light)
                        .lineLimit(1)
                        .mask(
                            LinearGradient(stops: [
                                .init(color: .clear, location: unit(p - 0.18)),
                                .init(color: .black.opacity(0.55), location: unit(p)),
                                .init(color: .clear, location: unit(p + 0.18)),
                            ], startPoint: .leading, endPoint: .trailing)
                        )
                }
            }
    }
}

/// While Ask reads: the archive quiets a little and a soft band of clarity
/// passes slowly across it, left to right, as if it were being read. Drawn
/// over the timeline or the map, under the floating controls; never takes
/// a click.
struct ReadingSweep: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            let t: Double = timeline.date.timeIntervalSinceReferenceDate
            let p: Double = (t / 2.8).truncatingRemainder(dividingBy: 1) * 1.6 - 0.3
            Rectangle()
                .fill(Theme.Palette.paper.opacity(0.5))
                .mask(
                    LinearGradient(stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: unit(p - 0.22)),
                        .init(color: .clear, location: unit(p)),
                        .init(color: .black, location: unit(p + 0.22)),
                        .init(color: .black, location: 1),
                    ], startPoint: .leading, endPoint: .trailing)
                )
        }
        .allowsHitTesting(false)
    }
}

/// A gradient stop's place, kept inside 0...1 so the stops stay in order.
private func unit(_ x: Double) -> CGFloat { CGFloat(min(max(x, 0), 1)) }
