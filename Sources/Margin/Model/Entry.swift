import Foundation
import MarginKit

/// The kinds of things that end up in a project's log.
enum EntryKind: String, Codable, CaseIterable, Identifiable {
    case capture
    case decision
    case inspiration
    case note
    /// Taken automatically by live capture while you work.
    case snapshot
    /// A frame exported from Figma, with a link back to it.
    case figma
    /// Selected text, kept in its original formatting.
    case text
    /// A short screen recording, e.g. of a prototype.
    case recording
    /// One instruction to a coding agent and the version it produced.
    case iteration
    /// A website: its link and a picture of the page.
    case link

    var id: String { rawValue }

    var label: String {
        switch self {
        case .capture: return "Capture"
        case .decision: return "Decision"
        case .inspiration: return "Inspiration"
        case .note: return "Note"
        case .snapshot: return "Snapshot"
        case .figma: return "Figma frame"
        case .text: return "Text"
        case .recording: return "Recording"
        case .iteration: return "Iteration"
        case .link: return "Website"
        }
    }

    var symbol: String {
        switch self {
        case .capture: return "camera.viewfinder"
        case .decision: return "checkmark.seal"
        case .inspiration: return "sparkles"
        case .note: return "note.text"
        case .snapshot: return "photo"
        case .figma: return "square.on.square"
        case .text: return "text.quote"
        case .recording: return "play.rectangle"
        case .iteration: return "chevron.left.forwardslash.chevron.right"
        case .link: return "globe"
        }
    }

    /// Made on purpose by the designer, as opposed to captured automatically.
    var isIntentional: Bool { self != .snapshot }
}

/// One moment in a project's log.
struct Entry: Identifiable, Codable, Hashable {
    var id = UUID()
    var kind: EntryKind
    var project: String
    var createdAt = Date()

    var title = ""
    var body = ""
    /// The designer's "why". Only ever written by the designer.
    var rationale = ""
    /// Decisions: what else was considered.
    var alternatives = ""
    var link = ""
    /// File name inside the store's images folder.
    var imageFile: String?
    /// The app that was in front when the entry was made, e.g. "Figma".
    var sourceApp: String?
    /// Window title at capture time, e.g. the Figma file name.
    var windowTitle: String?
    var tags: [String] = []
    /// Snapshots: how different this frame was from the previous one, 0...1.
    var changeScore: Double?
    /// A name that came with the capture, e.g. the Figma frame's name.
    /// Not the designer's words.
    var label: String?
    /// The capture itself when it isn't an image: the recording (.mp4) or
    /// the rich text (.rtf/.html). `imageFile` then holds its preview.
    var mediaFile: String?
    /// Recordings: length in seconds.
    var duration: Double?

    // Iterations (coding agents)
    /// What the designer asked the agent to do.
    var prompt: String?
    /// What the agent said it did. Not the designer's words.
    var summary: String?
    /// What the designer expected, typed while the agent worked.
    var expectation: String?
    /// "keep", "notQuite" or "deadEnd".
    var verdict: String?
    /// The project folder on disk.
    var codeRoot: String?
    /// This version in Margin's hidden history, and the one before it.
    var snapshot: String?
    var baseSnapshot: String?
    /// "3 files · +40 −12"
    var diffStat: String?
    /// "Claude Code", "Cursor"…
    var agent: String?
    var sessionID: String?
    /// Where the app ran when this version was pictured.
    var previewURL: String?
    /// "repo": `snapshot` is a commit in the project's own git (pushed by an
    /// agent elsewhere); otherwise it's in Margin's hidden history.
    var snapshotSource: String?
    /// A copy of a local HTML site, inside Margin's folder (e.g. "sites/<id>"),
    /// and the page to open in it ("index.html").
    var siteFolder: String?
    var sitePage: String?

    /// Several frames captured together (Figma multi-select). The first is
    /// the same as this entry's own image; the rest stack behind it.
    var frames: [FrameRef]?

    /// What Margin saw in this capture. Facts only, never the designer's words.
    var ai: CaptureNote?
    /// The tab the designer filed this under (accepted from a suggestion or chosen).
    var tab: String?

    var frameCount: Int { max(frames?.count ?? 1, 1) }

    init(kind: EntryKind, project: String) {
        self.kind = kind
        self.project = project
    }

    var displayTitle: String {
        if !title.trimmed.isEmpty { return title.trimmed }
        if let prompt, !prompt.trimmed.isEmpty {
            let line = prompt.trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? prompt.trimmed
            return line.count > 120 ? String(line.prefix(118)) + "…" : line
        }
        if let label, !label.trimmed.isEmpty { return label.trimmed }
        // Margin's title for what was captured: before captured text's first
        // line (someone else's words), after the designer's own note.
        let named = ai?.title?.trimmed ?? ""
        if kind == .text, !named.isEmpty { return named }
        let firstLine = body.split(separator: "\n").first.map(String.init) ?? ""
        if !firstLine.trimmed.isEmpty { return firstLine.trimmed }
        if !named.isEmpty { return named }
        if let windowTitle, !windowTitle.trimmed.isEmpty { return windowTitle.trimmed }
        return kind.label
    }

    /// The designer put words to this moment. Captured text doesn't count:
    /// those are someone else's words until the designer adds a why.
    var hasWords: Bool {
        !title.trimmed.isEmpty || !rationale.trimmed.isEmpty || (kind != .text && !body.trimmed.isEmpty)
            || !(prompt ?? "").trimmed.isEmpty || !(expectation ?? "").trimmed.isEmpty
    }

    /// Taken by Margin on its own: timed snapshots in Figma and pictures of
    /// what Claude Code changed. They live between your captures, shown
    /// only when you ask for them, until you give one a title or a why.
    var isAutomatic: Bool {
        (kind == .snapshot || kind == .iteration) && title.trimmed.isEmpty && rationale.trimmed.isEmpty
    }

    /// Captured on purpose with the shortcut, as opposed to live capture.
    var standsAlone: Bool {
        kind != .snapshot || hasWords || imageFile == nil
    }

    var searchText: String {
        var parts: [String] = [title, body, rationale, alternatives, link]
        parts += [sourceApp ?? "", windowTitle ?? "", label ?? "", prompt ?? ""]
        parts += [expectation ?? "", summary ?? "", tab ?? ""]
        if let ai {
            parts += [ai.seen, ai.changed ?? "", ai.visibleText ?? ""]
            parts += ai.tags
        }
        parts += tags
        return parts.joined(separator: " ")
    }

    // MARK: Codable (tolerant of files written by older versions)

    enum CodingKeys: String, CodingKey {
        case id, kind, project, createdAt, title, body, rationale, alternatives, link
        case imageFile, sourceApp, windowTitle, tags, changeScore
        case label, mediaFile, duration
        case prompt, summary, expectation, verdict, codeRoot, snapshot, baseSnapshot, diffStat, agent, sessionID, previewURL
        case frames, snapshotSource, ai, tab, siteFolder, sitePage
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = (try? c.decode(EntryKind.self, forKey: .kind)) ?? .note
        project = try c.decode(String.self, forKey: .project)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        rationale = try c.decodeIfPresent(String.self, forKey: .rationale) ?? ""
        alternatives = try c.decodeIfPresent(String.self, forKey: .alternatives) ?? ""
        link = try c.decodeIfPresent(String.self, forKey: .link) ?? ""
        imageFile = try c.decodeIfPresent(String.self, forKey: .imageFile)
        sourceApp = try c.decodeIfPresent(String.self, forKey: .sourceApp)
        windowTitle = try c.decodeIfPresent(String.self, forKey: .windowTitle)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        changeScore = try c.decodeIfPresent(Double.self, forKey: .changeScore)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        mediaFile = try c.decodeIfPresent(String.self, forKey: .mediaFile)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration)
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        expectation = try c.decodeIfPresent(String.self, forKey: .expectation)
        verdict = try c.decodeIfPresent(String.self, forKey: .verdict)
        codeRoot = try c.decodeIfPresent(String.self, forKey: .codeRoot)
        snapshot = try c.decodeIfPresent(String.self, forKey: .snapshot)
        baseSnapshot = try c.decodeIfPresent(String.self, forKey: .baseSnapshot)
        diffStat = try c.decodeIfPresent(String.self, forKey: .diffStat)
        agent = try c.decodeIfPresent(String.self, forKey: .agent)
        sessionID = try c.decodeIfPresent(String.self, forKey: .sessionID)
        previewURL = try c.decodeIfPresent(String.self, forKey: .previewURL)
        frames = try c.decodeIfPresent([FrameRef].self, forKey: .frames)
        snapshotSource = try c.decodeIfPresent(String.self, forKey: .snapshotSource)
        ai = try? c.decodeIfPresent(CaptureNote.self, forKey: .ai)
        tab = try c.decodeIfPresent(String.self, forKey: .tab)
        siteFolder = try c.decodeIfPresent(String.self, forKey: .siteFolder)
        sitePage = try c.decodeIfPresent(String.self, forKey: .sitePage)
    }

    /// The tab this moment shows under: the designer's, or a confirmed tab its
    /// suggested topic matches.
    func effectiveTab(confirmed: Set<String>) -> String? {
        if let tab { return tab }
        if let topic = ai?.topic, confirmed.contains(topic) { return topic }
        return nil
    }

    /// Iteration verdicts, as shown.
    static let verdicts: [(id: String, label: String)] = [("keep", "Keep"), ("notQuite", "Not quite"), ("deadEnd", "Dead end")]

    var verdictLabel: String? {
        verdict.flatMap { id in Self.verdicts.first { $0.id == id }?.label }
    }
}

/// One frame of a multi-frame capture.
struct FrameRef: Codable, Hashable {
    var imageFile: String?
    var mediaFile: String?
    var duration: Double?
    var name: String?
    var nodeID: String?
    var link: String?
}

extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
