import AppKit
import Combine
import MarginKit

/// Margin's intelligence layer. It documents, it doesn't decide:
/// - notes on each capture (what's in it, what changed), kept apart from the
///   designer's words;
/// - suggested tabs, which only take effect once the designer accepts them;
/// - draft chapter summaries when zooming out, built from the designer's own
///   words, marked as drafts until accepted.
@MainActor
final class Intelligence: ObservableObject {
    enum Status: Equatable {
        case off(String)
        case ready
        case working(Int)
        case failed(String)

        var isWorking: Bool { if case .working = self { return true } else { return false } }
    }

    @Published private(set) var status: Status = .ready
    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Keys.enabled)
            refreshStatus()
            if isEnabled { scan() }
        }
    }
    @Published private(set) var summaries: [String: ChapterSummary] = [:]
    @Published private(set) var summarizing: Set<String> = []
    @Published private(set) var dismissedTabs: [String: Set<String>] = [:]
    /// The patterns Margin sees across each project (cluster view), by project.
    @Published private(set) var patterns: [String: ProjectPatterns] = [:]
    @Published private(set) var findingPatterns: Set<String> = []

    private(set) var config: AIConfig
    private let store: EntryStore
    private let session: URLSession
    /// Captures being noted right now; views show a thinking pill for them.
    @Published private(set) var inFlight: Set<UUID> = []
    private var failed: [UUID: Date] = [:]
    private var pausedUntil: Date?
    private var cancellables: Set<AnyCancellable> = []
    private let summariesURL: URL
    private let patternsURL: URL
    /// The cluster view's maps: captures read into vectors on this Mac as
    /// they come in, maps built ahead, groups named once by the model.
    private(set) lazy var maps: ProjectMaps = ProjectMaps(
        store: store, session: session,
        config: { [weak self] in self?.config },
        canRun: { [weak self] in self?.canRun ?? false }
    )
    /// Process notes from the designer's Claude Code sessions: context for
    /// summaries and the hand-off, never shown as captures.
    private(set) lazy var process: ProcessMemory = ProcessMemory(
        store: store, maps: maps,
        config: { [weak self] in self?.config },
        canRun: { [weak self] in self?.canRun ?? false }
    )
    /// How many captures are annotated at once.
    private let concurrency = 3

    private enum Keys {
        /// Off unless you turn it on (a new key: it was on by default before).
        static let enabled = "intelligenceOn"
        static let dismissed = "dismissedTabs"
    }

    init(store: EntryStore, config: AIConfig? = nil, session: URLSession = .shared) {
        self.store = store
        self.session = session
        self.config = config ?? Self.loadConfig()
        self.isEnabled = UserDefaults.standard.object(forKey: Keys.enabled) as? Bool ?? false
        self.summariesURL = store.baseURL.appendingPathComponent("summaries.json")
        self.patternsURL = store.baseURL.appendingPathComponent("patterns.json")
        if let data = UserDefaults.standard.dictionary(forKey: Keys.dismissed) as? [String: [String]] {
            dismissedTabs = data.mapValues(Set.init)
        }
        loadSummaries()
        loadPatterns()
        refreshStatus()
    }

    /// Keys from the environment, the app bundle (committed in the repo) or ~/.margin.
    static func loadConfig() -> AIConfig {
        var files: [URL] = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".margin/ai-keys.json")]
        if let bundled = Bundle.main.url(forResource: "ai-keys", withExtension: "json") { files.append(bundled) }
        return AIConfig.load(files: files)
    }

    /// Your own keys: ~/.margin/ai-keys.json, read before the bundled ones.
    static var keysURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".margin/ai-keys.json")
    }

    /// Saves your keys (nil leaves one as it is, empty removes it) and uses
    /// them from now on. Readable by you only.
    func saveKeys(gemini: String? = nil, openai: String? = nil) {
        let url = Self.keysURL
        var file = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(AIConfig.self, from: $0) } ?? AIConfig()
        if let gemini { file.gemini = gemini.trimmed.isEmpty ? nil : gemini.trimmed }
        if let openai { file.openai = openai.trimmed.isEmpty ? nil : openai.trimmed }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(file) {
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        config = Self.loadConfig()
        refreshStatus()
        if canRun { scan() }
    }

    func start() {
        store.$entries
            .debounce(for: .seconds(1.2), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.scan() }
            .store(in: &cancellables)
        // Views that read the maps through Intelligence redraw when they change.
        maps.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        maps.start()
        process.start()
        scan()
    }

    private func refreshStatus() {
        if !config.hasGemini { status = .off("No Gemini key. Add one to ~/.margin/ai-keys.json (see the Read Me).") }
        else if !isEnabled { status = .off("Turned off.") }
        else if inFlight.isEmpty { status = .ready }
        else { status = .working(inFlight.count) }
    }

    var canRun: Bool { isEnabled && config.hasGemini }

    // MARK: Notes on captures

    /// Captures worth a note: made on purpose, with a picture, not yet noted.
    private func needsNote(_ entry: Entry) -> Bool {
        guard !inFlight.contains(entry.id) else { return false }
        // A note, or (for notes from before titles) a title it doesn't have yet.
        guard entry.ai == nil || (entry.ai?.title == nil && entry.title.trimmed.isEmpty) else { return false }
        if entry.kind == .text {
            guard !entry.body.trimmed.isEmpty else { return false }
        } else {
            guard entry.imageFile != nil else { return false }
        }
        if entry.kind == .snapshot && !entry.hasWords { return false }
        if let when = failed[entry.id], Date().timeIntervalSince(when) < 600 { return false }
        return true
    }

    /// Annotates what's missing, newest first. `limit` caps a backfill.
    func scan(limit: Int = 40) {
        guard canRun else { refreshStatus(); return }
        if let pausedUntil, pausedUntil > Date() { return }
        let todo = store.entries.filter(needsNote).sorted { $0.createdAt > $1.createdAt }.prefix(limit)
        for entry in todo where inFlight.count < concurrency {
            annotate(entry)
        }
    }

    /// Notes on every older capture in the current project.
    func backfill() {
        failed.removeAll()
        scan(limit: 400)
    }

    private func annotate(_ entry: Entry) {
        if entry.kind == .text { return annotateText(entry) }
        guard let url = store.imageURL(for: entry) else { return }
        inFlight.insert(entry.id)
        refreshStatus()
        let previous = previousVersion(of: entry).flatMap { store.imageURL(for: $0) }
        let context = context(for: entry)
        let annotator = Annotator(config: config, session: session)
        let id = entry.id
        Task {
            let images: (Data?, Data?) = await Task.detached(priority: .utility) {
                (ImagePrep.jpeg(contentsOf: url), previous.flatMap { ImagePrep.jpeg(contentsOf: $0, maxPixel: 768) })
            }.value
            do {
                guard let image = images.0 else { throw AIError.badResponse("unreadable image") }
                let started = Date()
                let note = try await annotator.annotate(image: image, previous: images.1, context: context)
                MarginLog.info("AI note in \(String(format: "%.1f", Date().timeIntervalSince(started)))s: \(note.seen) | topic \(note.topic ?? "-") | change \(note.changeSize.map { String(format: "%.1f", $0) } ?? "-")")
                store.modify(id) { $0.ai = note }
            } catch {
                MarginLog.info("AI note failed: \(error)")
                failed[id] = Date()
                if let error = error as? AIError, error.isTransient {
                    pausedUntil = Date().addingTimeInterval(60)
                }
                status = .failed("\(error)")
            }
            inFlight.remove(id)
            if case .failed = status {} else { refreshStatus() }
            scan()
        }
    }

    /// Captured text: read the text itself for its title, tags and topic.
    private func annotateText(_ entry: Entry) {
        inFlight.insert(entry.id)
        refreshStatus()
        let context = context(for: entry)
        let annotator = Annotator(config: config, session: session)
        let id = entry.id, text = entry.body
        Task {
            do {
                let note = try await annotator.annotate(text: text, context: context)
                MarginLog.info("AI note on text: \(note.title ?? "-") | topic \(note.topic ?? "-")")
                store.modify(id) { $0.ai = note }
            } catch {
                MarginLog.info("AI note on text failed: \(error)")
                failed[id] = Date()
                if let error = error as? AIError, error.isTransient { pausedUntil = Date().addingTimeInterval(60) }
                status = .failed("\(error)")
            }
            inFlight.remove(id)
            if case .failed = status {} else { refreshStatus() }
            scan()
        }
    }

    /// The designer's last capture of the same thing: same Figma frame, same
    /// frame name or same window, otherwise the previous capture in the same
    /// app within two hours (Decisions then judges whether it's the same thing).
    func previousVersion(of entry: Entry) -> Entry? {
        let earlier = store.chronological(in: entry.project)
            .filter { $0.createdAt < entry.createdAt && $0.imageFile != nil && $0.id != entry.id && $0.kind != .snapshot }
            .reversed()
        let node = Self.figmaNode(entry.link)
        if let node, let match = earlier.first(where: { Self.figmaNode($0.link) == node }) { return match }
        if let label = entry.label?.trimmed, !label.isEmpty, let match = earlier.first(where: { $0.label?.trimmed == label }) { return match }
        if let window = entry.windowTitle?.trimmed, !window.isEmpty,
           let match = earlier.first(where: { $0.windowTitle?.trimmed == window && entry.createdAt.timeIntervalSince($0.createdAt) < 3 * 86400 }) {
            return match
        }
        return earlier.first { $0.sourceApp == entry.sourceApp && entry.createdAt.timeIntervalSince($0.createdAt) < 2 * 3600 }
    }

    static func figmaNode(_ link: String) -> String? {
        guard link.contains("figma.com"), let components = URLComponents(string: link) else { return nil }
        return components.queryItems?.first { $0.name == "node-id" }?.value
    }

    private func context(for entry: Entry) -> CaptureContext {
        let words = [entry.title, entry.rationale, entry.kind == .text ? "" : entry.body, entry.prompt ?? ""]
            .map(\.trimmed).filter { !$0.isEmpty }.joined(separator: " · ")
        return CaptureContext(
            kind: entry.kind.label,
            app: entry.sourceApp,
            window: entry.windowTitle,
            label: entry.label,
            designerWords: words.isEmpty ? nil : String(words.prefix(400)),
            topics: topicExamples(in: entry.project)
        )
    }

    /// Tabs and suggested tabs, each with one line about what's in it.
    private func topicExamples(in project: String) -> [(name: String, example: String)] {
        var examples: [String: String] = [:]
        for entry in store.entries(in: project) {
            guard let name = entry.tab ?? entry.ai?.topic, examples[name] == nil else { continue }
            examples[name] = entry.ai?.seen ?? entry.displayTitle
        }
        return examples.map { (name: $0.key, example: $0.value) }.sorted { $0.name < $1.name }
    }

    // MARK: Tabs

    /// Tabs the designer has.
    func tabs(in project: String) -> [String] {
        Array(Set(store.entries(in: project).compactMap(\.tab))).sorted()
    }

    /// Topics Margin noticed that aren't tabs yet: two or more captures, not dismissed.
    func suggestedTabs(in project: String) -> [(name: String, count: Int)] {
        let confirmed = Set(tabs(in: project))
        let dismissed = dismissedTabs[project] ?? []
        let topics = store.entries(in: project).filter { $0.tab == nil }.compactMap(\.ai?.topic)
        let counts = Dictionary(grouping: topics, by: { $0 }).mapValues(\.count)
        return counts.filter { $0.value >= 2 && !confirmed.contains($0.key) && !dismissed.contains($0.key) }
            .map { (name: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
    }

    /// Makes a suggestion a tab: every untabbed capture with that topic joins it.
    func acceptTab(_ name: String, in project: String, renamedTo newName: String? = nil) {
        let final = (newName?.trimmed).flatMap { $0.isEmpty ? nil : $0 } ?? name
        for entry in store.entries(in: project) where entry.tab == nil && entry.ai?.topic == name {
            store.modify(entry.id) { $0.tab = final }
        }
    }

    func dismissTab(_ name: String, in project: String) {
        dismissedTabs[project, default: []].insert(name)
        UserDefaults.standard.set(dismissedTabs.mapValues(Array.init), forKey: Keys.dismissed)
    }

    func renameTab(_ name: String, to newName: String, in project: String) {
        let final = newName.trimmed
        guard !final.isEmpty else { return }
        for entry in store.entries(in: project) where entry.tab == name {
            store.modify(entry.id) { $0.tab = final }
        }
    }

    func setTab(_ name: String?, for id: UUID) {
        store.modify(id) { $0.tab = name }
    }

    // MARK: Chapter summaries

    static func facts(for entries: [Entry]) -> [MomentFact] {
        entries.map { entry in
            let words = [entry.title, entry.rationale, entry.kind == .text ? "" : entry.body, entry.prompt ?? "", entry.expectation ?? ""]
                .map(\.trimmed).filter { !$0.isEmpty }.joined(separator: " · ")
            return MomentFact(
                id: String(entry.id.uuidString.prefix(8)),
                date: entry.createdAt,
                kind: entry.kind.label,
                label: entry.label,
                words: words.isEmpty ? nil : String(words.prefix(500)),
                verdict: entry.verdictLabel,
                seen: entry.ai.map { note in note.title.map { "\($0): \(note.seen)" } ?? note.seen },
                changed: entry.ai?.changed
            )
        }
    }

    /// The key a stretch of moments is summarized under; nil when it's too
    /// small to need a summary.
    static func summaryKey(for entries: [Entry], level: String? = nil) -> String? {
        let worth = entries.filter { $0.kind != .snapshot || $0.hasWords }
        guard worth.count >= 2 else { return nil }
        return ChapterSummary.key(for: facts(for: Array(worth.suffix(40))), level: level)
    }

    /// The draft summary for these moments, if it exists.
    func summary(for entries: [Entry], level: String? = nil) -> ChapterSummary? {
        Self.summaryKey(for: entries, level: level).flatMap { summaries[$0] }
    }

    /// Asks for a summary in the background. Call from `.task`, not from a body.
    func requestSummary(for entries: [Entry], level: String? = nil) {
        let worth = entries.filter { $0.kind != .snapshot || $0.hasWords }
        guard worth.count >= 2, canRun else { return }
        let facts = Self.facts(for: Array(worth.suffix(40)))
        let key = ChapterSummary.key(for: facts, level: level)
        guard summaries[key] == nil, !summarizing.contains(key) else { return }
        summarizing.insert(key)
        let summarizer = Summarizer(config: config, session: session)
        // What the designer's Claude Code sessions say about the same stretch.
        let dates = worth.map(\.createdAt)
        let context = (worth.first?.project).map { project in
            process.notes(for: project, from: dates.min(), to: dates.max()).map { note in
                note.text + (note.why.map { " (designer's reason: \($0))" } ?? "")
            }
        } ?? []
        Task {
            do {
                let started = Date()
                let summary = try await summarizer.summarize(facts, level: level, context: context)
                MarginLog.info("AI summary in \(String(format: "%.1f", Date().timeIntervalSince(started)))s: \(summary.title)")
                summaries[key] = summary
                saveSummaries()
            } catch {
                MarginLog.info("AI summary failed: \(error)")
            }
            summarizing.remove(key)
        }
    }

    /// Margin is writing the note for this capture.
    func isNoting(_ id: UUID) -> Bool { inFlight.contains(id) }

    func isSummarizing(_ entries: [Entry]) -> Bool {
        Self.summaryKey(for: entries).map { summarizing.contains($0) } ?? false
    }

    func updateSummary(for entries: [Entry], _ change: (inout ChapterSummary) -> Void) {
        guard let key = Self.summaryKey(for: entries), var summary = summaries[key] else { return }
        change(&summary)
        summaries[key] = summary
        saveSummaries()
    }

    private func loadSummaries() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: summariesURL), let saved = try? decoder.decode([String: ChapterSummary].self, from: data) {
            summaries = saved
        }
    }

    private func saveSummaries() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(summaries).write(to: summariesURL, options: .atomic)
    }
}

// MARK: - Patterns

extension Intelligence {
    /// Which captures a project's patterns were found for.
    static func patternsKey(project: String, entries: [Entry]) -> String {
        "\(project)|\(entries.count)|\(entries.last?.id.uuidString.prefix(8) ?? "")"
    }

    /// The patterns for this project and these captures, when they're ready.
    func patterns(for project: String, entries: [Entry]) -> ProjectPatterns? {
        guard let found = patterns[project], found.key == Self.patternsKey(project: project, entries: entries) else { return nil }
        return found
    }

    func isFindingPatterns(_ project: String) -> Bool { findingPatterns.contains(project) }

    /// Finds the project's patterns in the background, once per set of
    /// captures. Without a model (or if it fails), Margin groups them itself
    /// from its topics and the files and conversations they came from.
    func requestPatterns(project: String, entries: [Entry]) {
        let key = Self.patternsKey(project: project, entries: entries)
        guard patterns[project]?.key != key, !findingPatterns.contains(project), !entries.isEmpty else { return }
        let fallback = { [weak self] in
            guard let self else { return }
            self.patterns[project] = ProjectPatterns(groups: Self.localPatterns(for: entries), key: key, model: nil)
            self.savePatterns()
        }
        guard canRun else { fallback(); return }
        findingPatterns.insert(project)
        let finder = PatternFinder(config: config, session: session)
        let items = entries.map(Self.patternItem)
        Task {
            do {
                let started = Date()
                let groups = try await finder.find(items)
                guard !groups.isEmpty else { throw AIError.missingKey("patterns") }
                MarginLog.info("AI patterns in \(String(format: "%.1f", Date().timeIntervalSince(started)))s: \(groups.map(\.title))")
                patterns[project] = ProjectPatterns(groups: groups, key: key, model: finder.model)
                savePatterns()
            } catch {
                MarginLog.info("AI patterns failed, grouping locally: \(error)")
                fallback()
            }
            findingPatterns.remove(project)
        }
    }

    static func patternItem(_ entry: Entry) -> PatternItem {
        let words = [entry.rationale, entry.prompt ?? "", entry.expectation ?? ""]
            .map(\.trimmed).filter { !$0.isEmpty }.joined(separator: " · ")
        return PatternItem(
            id: entry.id.uuidString,
            date: entry.createdAt,
            app: entry.sourceApp,
            window: entry.windowTitle,
            title: entry.displayTitle,
            words: words.isEmpty ? nil : words,
            seen: entry.ai?.seen,
            topic: entry.tab ?? entry.ai?.topic,
            tags: entry.ai?.tags ?? []
        )
    }

    /// Margin's own grouping: a capture's tab or topic; one without takes the
    /// topic of the nearest capture from the same window, or else is grouped
    /// with the rest of that window. At most six, the smallest folded together.
    static func localPatterns(for entries: [Entry]) -> [ProjectPatterns.Group] {
        let sorted = entries.sorted { $0.createdAt < $1.createdAt }
        func topic(_ entry: Entry) -> String? { (entry.tab ?? entry.ai?.topic)?.trimmed.nilIfEmpty }
        func place(_ entry: Entry) -> String { (entry.windowTitle?.trimmed).flatMap(\.nilIfEmpty) ?? entry.sourceApp ?? "Loose captures" }
        var byGroup: [String: [String]] = [:]
        var order: [String] = []
        for (index, entry) in sorted.enumerated() {
            var name = topic(entry)
            if name == nil {
                // The nearest capture in time from the same window that has a topic.
                var step = 1
                while step < 40, name == nil {
                    for j in [index - step, index + step] where sorted.indices.contains(j) {
                        if place(sorted[j]) == place(entry), let t = topic(sorted[j]) { name = t; break }
                    }
                    step += 1
                }
            }
            let group = name ?? place(entry)
            if byGroup[group] == nil { order.append(group) }
            byGroup[group, default: []].append(entry.id.uuidString)
        }
        let ranked = order.sorted { byGroup[$0]!.count > byGroup[$1]!.count }
        var groups = ranked.prefix(5).map { ProjectPatterns.Group(title: $0, ids: byGroup[$0]!) }
        let rest = ranked.dropFirst(5).flatMap { byGroup[$0]! }
        if !rest.isEmpty { groups.append(ProjectPatterns.Group(title: "Everything else", ids: rest)) }
        return groups
    }

    func loadPatterns() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: patternsURL), let saved = try? decoder.decode([String: ProjectPatterns].self, from: data) {
            patterns = saved
        }
    }

    func savePatterns() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(patterns).write(to: patternsURL, options: .atomic)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
