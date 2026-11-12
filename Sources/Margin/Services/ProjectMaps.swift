import AppKit
import Combine
import MarginKit
import NaturalLanguage
import SwiftUI

/// What a capture means, as numbers: read on this Mac (Apple's sentence
/// embedding), stored with a hash of the words it was read from, so it's
/// only read again when those words change.
struct StoredVector: Codable {
    var hash: String
    var model: String
    var data: Data

    var floats: [Float] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    init(hash: String, model: String, floats: [Float]) {
        self.hash = hash
        self.model = model
        self.data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

/// A name Margin's model gave a group, kept so the same group (or nearly
/// the same) isn't named twice.
struct PatternName: Codable {
    var project: String
    var tier: Int
    var members: [String]
    var title: String
    var model: String?
}

/// Turns words into vectors on this Mac. Apple's sentence embedding when
/// it's there; otherwise a plain bag of words, which still puts captures
/// that share words together. Free and offline either way.
enum Embedder {
    static let model: String = NLEmbedding.sentenceEmbedding(for: .english) != nil ? "nl-sentence-en-1" : "bag-of-words-1"

    static func embed(_ todo: [(id: UUID, text: String, hash: String)]) -> [(UUID, StoredVector)] {
        let sentence = NLEmbedding.sentenceEmbedding(for: .english)
        var result: [(UUID, StoredVector)] = []
        for item in todo {
            guard let vector = vector(item.text, sentence) else { continue }
            result.append((item.id, StoredVector(hash: item.hash, model: model, floats: vector)))
        }
        return result
    }

    /// One piece of text, read now (a headline you just wrote).
    static func embedOne(_ text: String) -> [Float]? {
        vector(text, NLEmbedding.sentenceEmbedding(for: .english))
    }

    private static func vector(_ text: String, _ sentence: NLEmbedding?) -> [Float]? {
        if let sentence { return sentence.vector(for: text).map { $0.map(Float.init) } }
        return bagOfWords(text)
    }

    static func bagOfWords(_ text: String) -> [Float] {
        var v = [Float](repeating: 0, count: 256)
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }.filter { $0.count > 2 }
        for word in words {
            var h: UInt32 = 2_166_136_261
            for b in String(word).utf8 { h = (h ^ UInt32(b)) &* 16_777_619 }
            v[Int(h % 256)] += 1
        }
        return v
    }
}

/// The map of each project for the cluster view, kept ready in the
/// background, and the designer's hand on it. Every capture is read into a
/// vector as it comes in (on this Mac, no network) and the groups are
/// rebuilt from those whenever something changes. Your headlines, renames
/// and the captures you move are kept per project and lead: Margin sorts
/// the rest around them and only the names of its own groups go to the
/// model, once per change.
@MainActor
final class ProjectMaps: ObservableObject {
    /// The groups per project, for the captures they were last built from.
    @Published private(set) var maps: [String: ProjectMap] = [:]
    /// Each group's name per project, by group key.
    @Published private(set) var titles: [String: [String: String]] = [:]
    /// What you've changed on each project's map (the earlier, regrouping steering).
    @Published var edits: [String: MapEdits] = [:]
    /// Each project's map as it stands: Margin's first draft, then yours.
    @Published var arrangements: [String: Arrangement] = [:]
    /// The arrangement before your last change, for Undo, and when that was.
    var previousArrangement: [String: Arrangement] = [:]
    @Published var lastChange: [String: Date] = [:]
    /// The last capture you moved, per project, for Undo.
    @Published private(set) var lastMove: [String: Move] = [:]
    @Published private(set) var naming: Set<String> = []

    struct Move: Equatable {
        let entry: String
        /// Captures like it that followed it.
        let followers: [String]
        /// Where each of those was placed before, if anywhere.
        let before: [String: String]
        let at: Date
    }

    let store: EntryStore
    private let session: URLSession
    private let config: () -> AIConfig?
    private let canRun: () -> Bool
    private(set) var vectors: [UUID: StoredVector] = [:]
    private var names: [String: PatternName] = [:]
    private let vectorsURL: URL
    private let namesURL: URL
    private let editsURL: URL
    private let arrangementsURL: URL
    private var cancellables: Set<AnyCancellable> = []
    private var indexing = false
    private var indexAgain = false
    private var building: Set<String> = []
    private var namingFailed: [String: Date] = [:]
    /// The captures each project's map was last asked for.
    private var lastEntries: [String: [Entry]] = [:]
    /// Projects whose own group names should be redone once the map is rebuilt.
    private var renameAfterBuild: Set<String> = []

    /// The longest side of a capture on the map, in map points.
    static let side: CGFloat = 120

    init(store: EntryStore, session: URLSession, config: @escaping () -> AIConfig?, canRun: @escaping () -> Bool) {
        self.store = store
        self.session = session
        self.config = config
        self.canRun = canRun
        vectorsURL = store.baseURL.appendingPathComponent("embeddings.json")
        namesURL = store.baseURL.appendingPathComponent("pattern-names.json")
        editsURL = store.baseURL.appendingPathComponent("map-edits.json")
        arrangementsURL = store.baseURL.appendingPathComponent("map-arrangement.json")
        load()
    }

    func start() {
        store.$entries
            .debounce(for: .seconds(2), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.index() }
            .store(in: &cancellables)
        store.$currentProject
            .removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.prepare() } }
            .store(in: &cancellables)
        index()
    }

    // MARK: Reading captures

    /// The words a capture is read from: the designer's own first (what
    /// they decided, why, what they asked for), then what Margin saw.
    static func text(_ entry: Entry) -> String? {
        var parts: [String] = []
        if entry.kind == .decision { parts.append("Decision") }
        parts += [entry.title, entry.rationale, entry.alternatives, entry.prompt ?? "", entry.expectation ?? "", entry.verdict ?? ""]
        if entry.kind == .text || entry.kind == .note || entry.kind == .decision { parts.append(String(entry.body.prefix(400))) }
        if let ai = entry.ai {
            parts += [ai.title ?? "", ai.seen, ai.topic ?? "", ai.tags.joined(separator: ", ")]
        }
        parts += [entry.tab ?? "", entry.summary ?? "", entry.tags.joined(separator: ", ")]
        var text = parts.map(\.trimmed).filter { !$0.isEmpty }.joined(separator: ". ")
        if text.isEmpty { text = (entry.windowTitle ?? "").trimmed }
        return text.isEmpty ? nil : String(text.prefix(1200))
    }

    /// Reads every capture that hasn't been read (or whose words changed).
    func index() {
        guard !indexing else { indexAgain = true; return }
        let model = Embedder.model
        let todo: [(id: UUID, text: String, hash: String)] = store.entries.compactMap { entry in
            guard let text = Self.text(entry) else { return nil }
            let hash = ProjectMap.stableHash(text)
            if let stored = vectors[entry.id], stored.hash == hash, stored.model == model { return nil }
            return (entry.id, text, hash)
        }
        guard !todo.isEmpty else { prepare(); return }
        indexing = true
        Task {
            let read = await Task.detached(priority: .utility) { Embedder.embed(todo) }.value
            for (id, vector) in read { vectors[id] = vector }
            saveVectors()
            MarginLog.info("Map index: read \(read.count) captures (\(model))")
            indexing = false
            if indexAgain { indexAgain = false; index() } else { prepare() }
        }
    }

    /// The archive's captures for the open project, built ahead so the
    /// view opens on a finished map.
    private func prepare() {
        let project = store.currentProject
        let entries = lastEntries[project] ?? store.chronological(in: project).filter { !$0.isAutomatic }
        ensure(project: project, entries: entries)
    }

    // MARK: Maps

    /// The size a capture takes on the map: its own shape, the longest side `side`.
    func mapSize(for entry: Entry) -> CGSize {
        let s = Self.side
        guard let aspect = store.aspectRatio(for: entry), aspect > 0 else { return CGSize(width: s, height: (s * 0.7).rounded()) }
        if aspect >= 1 { return CGSize(width: s, height: max(44, (s / aspect).rounded())) }
        return CGSize(width: max(44, (s * aspect).rounded()), height: s)
    }

    private func items(for entries: [Entry]) -> [MapItem] {
        let model = Embedder.model
        return entries.map { entry in
            let stored = vectors[entry.id].flatMap { $0.model == model ? $0 : nil }
            return MapItem(id: entry.id.uuidString, vector: stored?.floats, date: entry.createdAt,
                           source: entry.windowTitle ?? entry.sourceApp, version: stored?.hash ?? "")
        }
    }

    /// Builds the groups for these captures in the background, if they
    /// aren't built already. The result arrives in `maps`.
    func ensure(project: String, entries: [Entry]) {
        guard !entries.isEmpty else { return }
        lastEntries[project] = entries
        let items = items(for: entries)
        let projectEdits = edits[project] ?? MapEdits()
        let signature = ProjectMap.signature(of: items, edits: projectEdits)
        guard maps[project]?.signature != signature, !building.contains(signature) else { return }
        building.insert(signature)
        Task {
            let started = Date()
            let map = await Task.detached(priority: .userInitiated) { ProjectMapBuilder.build(items, edits: projectEdits) }.value
            building.remove(signature)
            // A newer change may have been asked for meanwhile.
            let current = ProjectMap.signature(of: self.items(for: lastEntries[project] ?? entries), edits: edits[project] ?? MapEdits())
            guard current == signature else { return }
            MarginLog.info("Map built for \(project): \(items.count) captures, \(map.themes.count) themes, \(map.patterns.count) patterns, in \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
            maps[project] = map
            resolveTitles(project)
            if renameAfterBuild.remove(project) != nil { requestNames(project: project, force: true) }
        }
    }

    // MARK: Names

    private func nameKey(_ project: String, _ cluster: String) -> String { "\(project)|\(cluster)" }

    /// The designer's own name for a group, if they gave it one.
    func designerTitle(project: String, cluster: ProjectMap.Cluster) -> String? {
        guard let id = cluster.headline else { return nil }
        return edits[project]?.headline(id)?.title
    }

    /// The model's name for a group: its own, or that of a group with
    /// nearly the same captures at the same tier.
    private func modelName(project: String, tier: Int, cluster: ProjectMap.Cluster) -> String? {
        if let exact = names[nameKey(project, cluster.key)] { return exact.title }
        let mine = Set(cluster.members)
        guard !mine.isEmpty else { return nil }
        var best: (title: String, score: Double)?
        for record in names.values where record.project == project && record.tier == tier {
            let theirs = Set(record.members)
            let shared = Double(mine.intersection(theirs).count)
            guard shared > 0 else { continue }
            let score = shared / Double(mine.union(theirs).count)
            if score >= 0.6, score > (best?.score ?? 0) { best = (record.title, score) }
        }
        return best?.title
    }

    /// Every group's title: yours, then the model's, then Margin's own reading.
    private func resolveTitles(_ project: String) {
        guard let map = maps[project] else { return }
        let byID = Dictionary(store.entries.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { a, _ in a })
        var result: [String: String] = [:]
        for tier in [1, 0] {
            var used: Set<String> = Set(result.values)
            for cluster in map.tiers[tier] {
                let parentTitle = cluster.parent.flatMap { map.themes.indices.contains($0) ? result[map.themes[$0].key] : nil }
                var title = designerTitle(project: project, cluster: cluster)
                    ?? modelName(project: project, tier: tier, cluster: cluster)
                    ?? Self.localTitle(cluster.members.compactMap { byID[$0] }, tier: tier, avoid: used.union(parentTitle.map { [$0] } ?? []))
                if title.isEmpty { title = parentTitle ?? "Loose captures" }
                used.insert(title)
                result[cluster.key] = title
            }
        }
        titles[project] = result
    }

    /// Margin's own name for a group, without the model: the topic most of
    /// its captures share, or the title of its most telling capture.
    static func localTitle(_ entries: [Entry], tier: Int, avoid: Set<String>) -> String {
        var counts: [String: Int] = [:]
        for entry in entries {
            for topic in [entry.tab, entry.ai?.topic].compactMap({ $0?.trimmed }) where !topic.isEmpty {
                counts[topic, default: 0] += 1
            }
        }
        let ranked = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
        if let topic = ranked.first(where: { !avoid.contains($0) }) { return topic }
        for entry in entries {
            let title = entry.displayTitle.trimmed
            if !title.isEmpty, !avoid.contains(title) { return String(title.prefix(40)) }
        }
        return ranked.first ?? ""
    }

    func isNaming(_ project: String) -> Bool { naming.contains(project) }

    /// Asks the model to name Margin's groups, in one call: those without a
    /// name yet, or with `force` all of them (after you've changed the map,
    /// so they fit around your changes). Your own names are passed along
    /// and never changed.
    func requestNames(project: String, force: Bool = false) {
        guard let map = maps[project], canRun(), let settings = config() else { return }
        guard !naming.contains(project) else {
            if force { renameAfterBuild.insert(project) }
            return
        }
        if !force, let failed = namingFailed[project], Date().timeIntervalSince(failed) < 300 { return }
        let byID = Dictionary(store.entries.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { a, _ in a })

        var groups: [PatternNamer.Group] = []
        var clusterFor: [String: (tier: Int, cluster: ProjectMap.Cluster)] = [:]
        for (t, theme) in map.themes.enumerated() {
            let id = "\(t + 1)"
            let mine = designerTitle(project: project, cluster: theme)
            groups.append(PatternNamer.Group(id: id, tier: 1, name: mine ?? (force ? nil : modelName(project: project, tier: 1, cluster: theme)),
                                             designer: mine != nil, lines: []))
            clusterFor[id] = (1, theme)
            for (j, child) in theme.children.enumerated() where map.patterns.indices.contains(child) {
                let pattern = map.patterns[child]
                let pid = "\(id).\(j + 1)"
                let theirs = designerTitle(project: project, cluster: pattern)
                groups.append(PatternNamer.Group(id: pid, tier: 0,
                                                 name: theirs ?? (force ? nil : modelName(project: project, tier: 0, cluster: pattern)),
                                                 designer: theirs != nil,
                                                 lines: pattern.members.compactMap { byID[$0] }.map(Self.line)))
                clusterFor[pid] = (0, pattern)
            }
        }
        guard groups.contains(where: { $0.name == nil }) else { return }

        naming.insert(project)
        let namer = PatternNamer(config: settings, session: session)
        let wanted = groups.filter { $0.name == nil }.count
        Task {
            do {
                let started = Date()
                let found = try await namer.name(groups)
                MarginLog.info("Map names for \(project): \(found.count) of \(wanted) in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
                for (id, title) in found {
                    guard let entry = clusterFor[id] else { continue }
                    names[nameKey(project, entry.cluster.key)] = PatternName(project: project, tier: entry.tier, members: entry.cluster.members,
                                                                            title: title, model: namer.model)
                }
                saveNames()
                resolveTitles(project)
            } catch {
                MarginLog.info("Map names failed, keeping Margin's own: \(error)")
                namingFailed[project] = Date()
            }
            naming.remove(project)
            if renameAfterBuild.remove(project) != nil { requestNames(project: project, force: true) }
        }
    }

    /// One capture, as the model reads it when naming.
    static func line(_ entry: Entry) -> String {
        var parts = [entry.kind.label]
        let title = entry.displayTitle.trimmed
        if !title.isEmpty { parts.append("\"\(title.prefix(70))\"") }
        let words = [entry.rationale, entry.prompt ?? "", entry.expectation ?? ""].map(\.trimmed).filter { !$0.isEmpty }.joined(separator: " · ")
        if !words.isEmpty { parts.append("designer: \"\(words.prefix(200))\"") }
        if let seen = entry.ai?.seen.trimmed, !seen.isEmpty { parts.append("shows: \(seen.prefix(160))") }
        return parts.joined(separator: " · ")
    }

    // MARK: Your edits

    /// After a change: keep it, rebuild the groups round it, then rename
    /// Margin's own groups so they fit.
    private func commit(_ project: String, _ change: (inout MapEdits) -> Void) {
        var e = edits[project] ?? MapEdits()
        change(&e)
        edits[project] = e
        saveEdits()
        renameAfterBuild.insert(project)
        if let entries = lastEntries[project] { ensure(project: project, entries: entries) }
    }

    /// The headline behind a group, making one (keeping its captures and
    /// Margin's name) when the group is still Margin's.
    private func headline(for cluster: ProjectMap.Cluster, tier: Int, in map: ProjectMap, edits e: inout MapEdits) -> String {
        if let id = cluster.headline, e.headline(id) != nil { return id }
        let id = UUID().uuidString
        var parent: String?
        if tier == 0, let p = cluster.parent, map.themes.indices.contains(p) {
            parent = headline(for: map.themes[p], tier: 1, in: map, edits: &e)
        }
        e.headlines.append(MapHeadline(id: id, tier: tier, title: nil, parent: parent, anchors: cluster.members))
        return id
    }

    /// Renames a group. An empty name hands it back to Margin.
    func rename(project: String, tier: Int, key: String, to title: String) {
        guard let map = maps[project], let cluster = map.tiers[tier].first(where: { $0.key == key }) else { return }
        let clean = title.trimmed
        commit(project) { e in
            let id = headline(for: cluster, tier: tier, in: map, edits: &e)
            guard let i = e.headlines.firstIndex(where: { $0.id == id }) else { return }
            if clean.isEmpty {
                e.headlines[i].title = nil
                e.headlines[i].vector = nil
            } else {
                e.headlines[i].title = clean
                e.headlines[i].vector = Embedder.embedOne(clean)
            }
        }
    }

    /// A new headline: Margin sorts the captures that fit it into it. A
    /// pattern headline goes in the theme you wrote it in.
    func addHeadline(project: String, title: String, tier: Int, inTheme theme: Int?) {
        let clean = title.trimmed
        guard !clean.isEmpty, let map = maps[project] else { return }
        commit(project) { e in
            var parent: String?
            if tier == 0, let theme, map.themes.indices.contains(theme) {
                parent = headline(for: map.themes[theme], tier: 1, in: map, edits: &e)
            }
            e.headlines.append(MapHeadline(id: UUID().uuidString, tier: tier, title: clean, parent: parent, anchors: [],
                                           vector: Embedder.embedOne(clean)))
        }
    }

    /// Removes a headline you wrote; its captures go back to Margin.
    func removeHeadline(project: String, key: String) {
        guard let map = maps[project],
              let cluster = (map.themes + map.patterns).first(where: { $0.key == key }), let id = cluster.headline else { return }
        commit(project) { e in
            e.headlines.removeAll { $0.id == id || $0.parent == id }
            e.placed = e.placed.filter { _, value in value != id && e.headline(value) != nil }
        }
    }

    /// Puts a capture in a group by hand. The captures most like it that
    /// aren't already placed follow it; Undo puts them all back.
    @discardableResult
    func place(project: String, entry: UUID, tier: Int, key: String) -> Int {
        guard let map = maps[project], let cluster = map.tiers[tier].first(where: { $0.key == key }) else { return 0 }
        let id = entry.uuidString
        guard !cluster.members.contains(id) else { return 0 }
        let current = edits[project] ?? MapEdits()
        let neighbors = map.neighbors[id] ?? [], similarity = map.neighborSimilarity[id] ?? []
        let best = similarity.first ?? 0
        var followers: [String] = []
        for (n, other) in neighbors.enumerated() where followers.count < 2 {
            let s = n < similarity.count ? similarity[n] : 0
            // Only the close look-alikes, not already placed, not already there.
            guard s >= max(0.5, best * 0.9), current.placed[other] == nil, !cluster.members.contains(other) else { continue }
            followers.append(other)
        }
        var before: [String: String] = [:]
        for moved in [id] + followers { if let was = current.placed[moved] { before[moved] = was } }
        commit(project) { e in
            let target = headline(for: cluster, tier: tier, in: map, edits: &e)
            for moved in [id] + followers { e.placed[moved] = target }
        }
        lastMove[project] = Move(entry: id, followers: followers, before: before, at: Date())
        return followers.count
    }

    /// Takes back the last move.
    func undoMove(project: String) {
        guard let move = lastMove[project] else { return }
        lastMove[project] = nil
        commit(project) { e in
            for moved in [move.entry] + move.followers {
                if let was = move.before[moved] { e.placed[moved] = was } else { e.placed[moved] = nil }
            }
        }
    }

    func clearMove(project: String) { lastMove[project] = nil }

    // MARK: Files

    private func load() {
        if let data = try? Data(contentsOf: vectorsURL),
           let saved = try? JSONDecoder().decode([String: StoredVector].self, from: data) {
            for (key, value) in saved { if let id = UUID(uuidString: key) { vectors[id] = value } }
        }
        if let data = try? Data(contentsOf: namesURL),
           let saved = try? JSONDecoder().decode([String: PatternName].self, from: data) {
            names = saved
        }
        if let data = try? Data(contentsOf: editsURL),
           let saved = try? JSONDecoder().decode([String: MapEdits].self, from: data) {
            edits = saved
        }
        if let data = try? Data(contentsOf: arrangementsURL),
           let saved = try? JSONDecoder().decode([String: Arrangement].self, from: data) {
            arrangements = saved
        }
        // Once: the demo's Umbrella captures were retitled and put in
        // their place in time, so its map sorts again from them.
        let resort = "map.demoResort.v2"
        if DemoData.isOn, store.baseURL.standardizedFileURL == DemoData.baseURL.standardizedFileURL,
           !UserDefaults.standard.bool(forKey: resort) {
            UserDefaults.standard.set(true, forKey: resort)
            arrangements[DemoData.project] = nil
            edits[DemoData.project] = nil
            names = names.filter { $0.value.project != DemoData.project }
            saveNames()
            saveEdits()
            saveArrangements()
        }
    }

    private func saveVectors() {
        var out: [String: StoredVector] = [:]
        for (id, value) in vectors { out[id.uuidString] = value }
        let url = vectorsURL
        Task.detached(priority: .background) {
            try? JSONEncoder().encode(out).write(to: url, options: .atomic)
        }
    }

    private func saveNames() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(names).write(to: namesURL, options: .atomic)
    }

    func saveArrangements() {
        let saved = arrangements
        let url = arrangementsURL
        Task.detached(priority: .utility) {
            try? JSONEncoder().encode(saved).write(to: url, options: .atomic)
        }
    }

    /// A capture's vector, when it's been read.
    func vector(for id: UUID) -> [Float]? {
        vectors[id].flatMap { $0.model == Embedder.model ? $0.floats : nil }
    }

    private func saveEdits() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(edits).write(to: editsURL, options: .atomic)
    }
}
