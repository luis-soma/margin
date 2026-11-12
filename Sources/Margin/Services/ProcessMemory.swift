import Foundation
import MarginKit

/// What Margin learns from your Claude Code sessions, kept out of sight.
///
/// Claude Code keeps every session on this Mac (~/.claude/projects). In the
/// background Margin reads the ones that belong to a project, boils each down
/// to a few process notes (decisions, what was tried and dropped, changes of
/// direction, with your reasons only where you gave them) and keeps those as
/// context: they feed the summaries when you zoom out and the hand-off. They
/// never show up as captures.
///
/// A session belongs to a project when Margin already captured an iteration
/// from it, when it ran in a folder a project's iterations came from, or else
/// when what you asked reads clearly like that project. Anything else is left
/// alone. Off in Settings, it reads nothing.
@MainActor
final class ProcessMemory {
    nonisolated static let enabledKey = "processMemory"
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    /// The one in use, for the hand-off.
    private(set) static weak var shared: ProcessMemory?

    struct Digest: Codable {
        var file: String
        var size: Int
        var processed: Date
        var cwd: String?
        /// nil: read, but it doesn't belong to any project.
        var project: String?
        var notes: [ProcessNote]
    }

    private let store: EntryStore
    private let maps: ProjectMaps
    private let config: () -> AIConfig?
    private let canRun: () -> Bool
    private let url: URL
    private var digests: [String: Digest] = [:]
    private var timer: Timer?
    private var running = false

    /// Sessions summarized per pass, so a long history fills in over a few passes.
    static let perPass = 4
    nonisolated static let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true)

    init(store: EntryStore, maps: ProjectMaps, config: @escaping () -> AIConfig?, canRun: @escaping () -> Bool) {
        self.store = store
        self.maps = maps
        self.config = config
        self.canRun = canRun
        url = store.baseURL.appendingPathComponent("process-memory.json")
        load()
        Self.shared = self
    }

    func start() {
        // A while after launch, then every half hour.
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) { [weak self] in self?.pass() }
        timer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pass() }
        }
    }

    // MARK: Reading

    /// Notes for a project, oldest first, optionally within a stretch of time.
    func notes(for project: String, from start: Date? = nil, to end: Date? = nil) -> [ProcessNote] {
        guard Self.isEnabled else { return [] }
        let day: TimeInterval = 86_400
        return digests.values.filter { $0.project == project }.flatMap(\.notes).filter { note in
            if let start, note.date < start.addingTimeInterval(-day) { return false }
            if let end, note.date > end.addingTimeInterval(day) { return false }
            return true
        }.sorted { $0.date < $1.date }
    }

    /// The hand-off's section, or nil when there's nothing.
    static func handoffSection(for project: String) -> String? {
        guard let memory = shared else { return nil }
        let notes = memory.notes(for: project)
        guard !notes.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, yyyy"
        var out = "## Process, from the designer's Claude Code sessions\n\n"
        out += "_Condensed by Margin from the designer's conversations with Claude Code. Reasons appear only where the designer gave them; "
        out += "these are context, not captures._\n\n"
        var lastDay = ""
        for note in notes {
            let day = formatter.string(from: note.date)
            if day != lastDay { out += "\n**\(day)**\n\n"; lastDay = day }
            out += "- \(note.kind.capitalized): \(note.text)"
            if let why = note.why { out += " Why (designer): \(why)" }
            out += "\n"
        }
        return out
    }

    // MARK: The background pass

    func pass() {
        guard Self.isEnabled, canRun(), !running, let config = config() else { return }
        running = true
        let known = digests
        let projects = store.projects.filter { !store.entries(in: $0).isEmpty }
        // What ties a session to a project without guessing: sessions and
        // folders iterations came from.
        var bySession: [String: String] = [:]
        var byFolder: [String: [String: Int]] = [:]
        for entry in store.entries {
            if let session = entry.sessionID { bySession[session] = entry.project }
            if let root = entry.codeRoot { byFolder[root, default: [:]][entry.project, default: 0] += 1 }
        }
        Task {
            let candidates = await Task.detached(priority: .utility) { Self.changedSessions(known: known) }.value
            var done = 0
            for file in candidates where done < Self.perPass {
                guard Self.isEnabled else { break }
                guard let session = await Task.detached(priority: .utility, operation: { SessionReader.read(file.url) }).value else {
                    digests[file.url.path] = Digest(file: file.url.path, size: file.size, processed: Date(), cwd: nil, project: nil, notes: [])
                    continue
                }
                let project = match(session, bySession: bySession, byFolder: byFolder, projects: projects)
                guard let project else {
                    digests[file.url.path] = Digest(file: file.url.path, size: file.size, processed: Date(), cwd: session.cwd, project: nil, notes: [])
                    continue
                }
                // Short sessions rarely hold a decision.
                guard session.turns.filter(\.designer).count >= 3 else {
                    digests[file.url.path] = Digest(file: file.url.path, size: file.size, processed: Date(), cwd: session.cwd, project: project, notes: [])
                    continue
                }
                let condensed = SessionReader.condensed(session)
                do {
                    let notes = try await ProcessNoteWriter(config: config).notes(from: condensed)
                    digests[file.url.path] = Digest(file: file.url.path, size: file.size, processed: Date(), cwd: session.cwd, project: project, notes: notes)
                    MarginLog.info("Process memory: \(notes.count) notes from a session for \(project)")
                } catch {
                    MarginLog.info("Process memory failed: \(error)")
                    break
                }
                done += 1
            }
            save()
            running = false
        }
    }

    struct SessionFile: Sendable {
        let url: URL
        let size: Int
    }

    /// Sessions that are new, or have grown by a fifth since they were read
    /// (and weren't read in the last two hours). Not while still being written.
    nonisolated static func changedSessions(known: [String: Digest]) -> [SessionFile] {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        var out: [(SessionFile, Date)] = []
        for folder in folders {
            guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let size = values?.fileSize ?? 0
                let modified = values?.contentModificationDate ?? .distantPast
                guard Date().timeIntervalSince(modified) > 10 * 60 else { continue }
                if let digest = known[file.path] {
                    guard Double(size) > Double(digest.size) * 1.2,
                          Date().timeIntervalSince(digest.processed) > 2 * 3600 else { continue }
                }
                out.append((SessionFile(url: file, size: size), modified))
            }
        }
        // Newest first: what you're working on now matters most.
        return out.sorted { $0.1 > $1.1 }.map(\.0)
    }

    /// The project a session belongs to, or nil.
    private func match(_ session: SessionReader.Session, bySession: [String: String], byFolder: [String: [String: Int]], projects: [String]) -> String? {
        if let project = bySession[session.id], projects.contains(project) { return project }
        if let cwd = session.cwd {
            var counts: [String: Int] = [:]
            for (root, perProject) in byFolder where cwd == root || cwd.hasPrefix(root + "/") || root.hasPrefix(cwd + "/") {
                for (project, n) in perProject { counts[project, default: 0] += n }
            }
            if let best = counts.max(by: { $0.value < $1.value }), projects.contains(best.key) { return best.key }
        }
        // By meaning: what you asked against each project's captures.
        guard let v = Embedder.embedOne(SessionReader.designerWords(session)) else { return nil }
        var scores: [(String, Float)] = []
        for project in projects {
            let vectors = store.entries(in: project).prefix(200).compactMap { maps.vector(for: $0.id) }.filter { $0.count == v.count }
            guard vectors.count >= 5 else { continue }
            var sum = [Float](repeating: 0, count: v.count)
            for w in vectors { for d in 0..<v.count { sum[d] += w[d] } }
            scores.append((project, cosine(v, sum)))
        }
        scores.sort { $0.1 > $1.1 }
        guard let best = scores.first, best.1 >= 0.45 else { return nil }
        // Only when it clearly reads like one project more than the others.
        if scores.count > 1, best.1 - scores[1].1 < 0.05 { return nil }
        return best.0
    }

    private func cosine(_ a: [Float], _ b: [Float]) -> Float {
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<min(a.count, b.count) { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        return na > 0 && nb > 0 ? dot / (na.squareRoot() * nb.squareRoot()) : 0
    }

    // MARK: Storage

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: url), let saved = try? decoder.decode([String: Digest].self, from: data) {
            digests = saved
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try? encoder.encode(digests).write(to: url, options: .atomic)
    }
}
