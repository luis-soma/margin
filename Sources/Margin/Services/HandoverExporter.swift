import AppKit
import Foundation
import MarginKit

/// Packs a project into a folder an AI coding tool can build from:
///
///     ~/Documents/Margin Handoff/<Project>/
///       CLAUDE.md       how to read the bundle (Claude Code reads it first)
///       HANDOFF.md     the story: summary, decisions, every moment by day
///       TASTE.md       the design language (TasteWriter)
///       moments.json    every moment, raw
///       captures/       every picture, recording and text file, as captured
///
/// Margin doesn't write the case study. It hands over everything it knows,
/// raw and in order, and says which words are the designer's.
enum HandoverExporter {
    static let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Margin Handoff", isDirectory: true)

    static func folder(for project: String) -> URL {
        root.appendingPathComponent(safe(project), isDirectory: true)
    }

    /// Everything written by `prepare`, ready to copy off the main thread.
    struct Plan {
        var folder: URL
        var texts: [(name: String, contents: String)]
        var copies: [(from: URL, to: URL)]
    }

    /// Builds the files' contents and the list of captures to copy. Cheap; on the main actor.
    @MainActor
    static func plan(project: String, entries: [Entry], store: EntryStore, summary: ChapterSummary?) -> Plan {
        let folder = folder(for: project)
        let captures = folder.appendingPathComponent("captures", isDirectory: true)
        let chronological = entries.sorted { $0.createdAt < $1.createdAt }

        var files = Set<String>()
        for entry in chronological {
            if let file = entry.imageFile { files.insert(file) }
            if let file = entry.mediaFile { files.insert(file) }
            for frame in entry.frames ?? [] {
                if let file = frame.imageFile { files.insert(file) }
                if let file = frame.mediaFile { files.insert(file) }
            }
        }
        let copies = files.sorted().compactMap { file -> (URL, URL)? in
            let source = store.imageURL(forFile: file)
            guard FileManager.default.fileExists(atPath: source.path) else { return nil }
            return (source, captures.appendingPathComponent(file))
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let json = (try? encoder.encode(chronological)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        return Plan(
            folder: folder,
            texts: [
                ("CLAUDE.md", guide(project: project, entries: chronological, files: copies.count)),
                ("HANDOFF.md", story(project: project, entries: chronological, summary: summary,
                                      process: ProcessMemory.handoffSection(for: project))),
                ("moments.json", json + "\n"),
            ],
            copies: copies
        )
    }

    /// Writes the bundle, reporting each copied capture. Captures already in
    /// the folder (same name, so the same file) are skipped on a second handoff.
    static func write(_ plan: Plan, progress: @escaping @Sendable (Int) async -> Void) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: plan.folder.appendingPathComponent("captures", isDirectory: true), withIntermediateDirectories: true)
        for text in plan.texts {
            try text.contents.write(to: plan.folder.appendingPathComponent(text.name), atomically: true, encoding: .utf8)
        }
        for (index, copy) in plan.copies.enumerated() {
            if !fm.fileExists(atPath: copy.to.path) {
                try? fm.copyItem(at: copy.from, to: copy.to)
            }
            await progress(index + 1)
        }
    }

    // MARK: The first prompt and the link into Claude

    static func prompt(project: String, since: Date? = nil) -> String {
        if let since {
            return "Read CLAUDE.md, then HANDOFF.md and TASTE.md. You've seen this project, \(project), before: focus on what's new since \(day(since)), the moments after that date in HANDOFF.md and moments.json. Tell me in a few lines what changed and why, then wait for what I want to build with it."
        }
        return "Read CLAUDE.md, then HANDOFF.md and TASTE.md. Together with the captures folder they hold the full record of how I designed \(project): my decisions and my reasons, its design language, every capture and the raw data. Get to know the project, tell me in a few lines what you understood, then wait for what I want to build with it."
    }

    private static func day(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    /// For any other tool (an existing chat, Codex, Cursor): the same ask,
    /// with the folder's full path and the reading rules spelled out, so it
    /// works without opening a session in the folder.
    static func portablePrompt(folder: URL, project: String, since: Date? = nil) -> String {
        let ask = since.map { "Focus on what's new since \(day($0)): the moments after that date in HANDOFF.md and moments.json. Tell me in a few lines what changed and why, then wait for what I want to build with it." }
            ?? "Get to know the project, tell me in a few lines what you understood, then wait for what I want to build with it."
        return """
        I'm handing off the design record of my project "\(project)", captured with Margin. It's in this folder:
        \(folder.path)

        Read \(folder.appendingPathComponent("CLAUDE.md").path) first, then HANDOFF.md and TASTE.md (the project's design language) in the same folder. captures/ holds every picture, recording and text capture; moments.json has every moment raw.

        How to read it:
        - My own words (titles, notes, "Why:" lines, "Also considered", prompts) are the only source of reasons and intent.
        - "Margin saw" lines are machine descriptions of a capture: observations, never reasons.
        - A summary marked as a draft was written by Margin, not me.
        - Never invent why something was decided. If a reason isn't written down, say so or ask.

        \(ask)
        """
    }

    /// claude://code/new opens a new Claude Code session in the desktop app,
    /// in `folder`, with `q` typed in. The app asks before opening the folder.
    static func claudeLink(folder: URL, prompt: String) -> URL? {
        URL(string: "claude://code/new?q=\(encode(prompt))&folder=\(encode(folder.path))")
    }

    /// Opens the session; false when the Claude app isn't installed.
    @discardableResult
    static func openInClaude(folder: URL, project: String, since: Date? = nil) -> Bool {
        let text = prompt(project: project, since: since)
        guard let url = claudeLink(folder: folder, prompt: text),
              NSWorkspace.shared.urlForApplication(toOpen: url) != nil else {
            // No Claude app: show the folder and put the prompt on the clipboard.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            NSWorkspace.shared.activateFileViewerSelecting([folder])
            return false
        }
        NSWorkspace.shared.open(url)
        return true
    }

    // MARK: Agents

    /// Where the folder can go. Claude Code is the default and opens a new
    /// session in the folder with the prompt typed in. The others open the
    /// folder in their app with the prompt (with full paths) on the clipboard.
    struct Agent: Identifiable, Equatable {
        let id: String
        let name: String
        let bundleIDs: [String]

        var appURL: URL? {
            bundleIDs.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
        }
        var icon: NSImage? { appURL.map { NSWorkspace.shared.icon(forFile: $0.path) } }
        var isInstalled: Bool { appURL != nil }

        static let claude = Agent(id: "claude", name: "Claude Code", bundleIDs: ["com.anthropic.claudefordesktop"])
        static let all: [Agent] = [
            claude,
            Agent(id: "codex", name: "Codex", bundleIDs: ["com.openai.codex"]),
            Agent(id: "cursor", name: "Cursor", bundleIDs: ["com.todesktop.230313mzl4w4u92"]),
            Agent(id: "vscode", name: "VS Code", bundleIDs: ["com.microsoft.VSCode"]),
        ]
        /// Claude always (it falls back to Finder and the clipboard), the rest when installed.
        static var available: [Agent] { all.filter { $0 == claude || $0.isInstalled } }
    }

    /// Hands the folder to `agent`. Returns false when it couldn't open the
    /// app (the folder is shown and the prompt is on the clipboard instead).
    @discardableResult
    static func handOff(folder: URL, project: String, to agent: Agent, since: Date? = nil) -> Bool {
        if agent == .claude { return openInClaude(folder: folder, project: project, since: since) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(portablePrompt(folder: folder, project: project, since: since), forType: .string)
        guard let app = agent.appURL else {
            NSWorkspace.shared.activateFileViewerSelecting([folder])
            return false
        }
        NSWorkspace.shared.open([folder], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        return true
    }

    // MARK: Files

    private static func guide(project: String, entries: [Entry], files: Int) -> String {
        let span = entries.first.map { first in
            "\(first.createdAt.formatted(date: .abbreviated, time: .omitted)) to \((entries.last ?? first).createdAt.formatted(date: .abbreviated, time: .omitted))"
        } ?? "no dates yet"
        return """
        # \(project): design handoff from Margin

        This folder is the design record of **\(project)**, captured with Margin while it was designed (\(span), \(entries.count) moments, \(files) files). It is context, not a finished case study. Read it before building anything from it.

        ## What's here

        - `HANDOFF.md`: the story. A short overview, the decisions, then every moment in order, day by day, with links to its files.
        - `TASTE.md`: the project's design language: palette, type, layout, components, voice, and what the designer dropped. Build anything new in this style.
        - `captures/`: every picture, recording and text capture, exactly as captured. File names match the links in HANDOFF.md and the fields in moments.json.
        - `moments.json`: every moment, raw. Use it when you need fields the story leaves out.

        ## How to read it

        - **The designer's words come first.** Titles, notes, "**Why:**" lines, "Also considered" and iteration prompts were written by the designer. They are the only source of reasons and intent.
        - **"Margin saw" lines are machine notes.** An AI described what a capture shows and what changed. Treat them as observations, never as reasons.
        - **A draft summary, if there is one, is Margin's, not the designer's.** It's marked as a draft.
        - **Never invent why something was decided.** If a reason isn't written down, say it's missing or ask.
        - **Captured text is quoted** (lines starting with `>`): something on screen, not the designer speaking.
        - **Snapshots** are automatic screenshots. Many show small steps; the designer's moments matter more.
        - **Iterations** are prompts the designer gave a coding agent, with what they expected and their verdict (Keep, Not quite, Dead end).

        ## What happens next

        The designer will tell you what to build from this: a case study site, a presentation, a write-up, or something else. Wait for that. When you do build, use the captures as they are (no rounded corners or filters on the designer's work) and quote the designer's own words for reasons.
        """ + "\n"
    }

    private static func story(project: String, entries: [Entry], summary: ChapterSummary?, process: String? = nil) -> String {
        var out = ""
        if let summary, !summary.hidden {
            let mark = summary.accepted ? "accepted by the designer" : "draft written by Margin, not the designer's words"
            out += "> **\(summary.title)**\n>\n> \(summary.summary)\n>\n> _(\(mark))_\n\n"
        }
        var story = MarkdownExporter.render(project: project, entries: entries, media: "captures")
        // Put the overview under the title.
        if !out.isEmpty, let titleEnd = story.range(of: "\n\n") {
            story.insert(contentsOf: "\n\n" + out.trimmingCharacters(in: .newlines), at: titleEnd.lowerBound)
        }
        // What Margin read from the designer's Claude Code sessions, at the end.
        if let process {
            story = story.trimmingCharacters(in: .newlines) + "\n\n" + process
        }
        return story
    }

    private static func encode(_ text: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    static func safe(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Project" : cleaned
    }
}
