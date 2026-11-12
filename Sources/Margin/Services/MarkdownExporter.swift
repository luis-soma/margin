import Foundation
import MarginKit

/// Turns a project's log into a Markdown "story" with a decisions summary.
enum MarkdownExporter {
    /// Writes "<project> design log.md" next to the images folder and returns its URL.
    static func export(project: String, entries: [Entry], to directory: URL) throws -> URL {
        let safeName = project
            .components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>"))
            .joined(separator: "-")
        let url = directory.appendingPathComponent("\(safeName) design log.md")
        try render(project: project, entries: entries).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// - Parameter media: the folder the pictures and recordings sit in, next to the file.
    static func render(project: String, entries: [Entry], media: String = "images") -> String {
        let chronological = entries.sorted { $0.createdAt < $1.createdAt }
        var out = "# \(project): design log\n\n"
        out += "_Exported \(Date().formatted(date: .long, time: .shortened)) · \(entries.count) entries_\n\n"

        let decisions = chronological.filter { $0.kind == .decision }
        if !decisions.isEmpty {
            out += "## Decisions at a glance\n\n"
            for decision in decisions {
                out += "- **\(decision.displayTitle)**"
                if !decision.rationale.isEmpty { out += ": \(oneLine(decision.rationale))" }
                out += " _(\(decision.createdAt.formatted(date: .abbreviated, time: .omitted)))_\n"
            }
            out += "\n"
        }

        out += "## Timeline\n\n"
        let days = Dictionary(grouping: chronological) { Calendar.current.startOfDay(for: $0.createdAt) }
        for day in days.keys.sorted() {
            out += "### \(day.formatted(date: .complete, time: .omitted))\n\n"
            for entry in days[day] ?? [] {
                out += block(for: entry, media: media)
            }
        }
        return out
    }

    private static func block(for entry: Entry, media: String) -> String {
        var out = "#### \(entry.createdAt.formatted(date: .omitted, time: .shortened)) · \(entry.kind.label): \(entry.displayTitle)\n\n"

        var meta: [String] = []
        if let app = entry.sourceApp { meta.append("in \(app)") }
        if let window = entry.windowTitle, window != entry.displayTitle { meta.append(window) }
        meta += entry.tags.map { "#\($0)" }
        if !meta.isEmpty { out += "_\(meta.joined(separator: " · "))_\n\n" }

        if entry.kind == .iteration {
            if let prompt = entry.prompt { out += "**You asked \(entry.agent ?? "the agent"):** \(oneLine(prompt))\n\n" }
            if let expectation = entry.expectation, !expectation.isEmpty { out += "**You expected:** \(expectation)\n\n" }
            var result: [String] = []
            if let verdict = entry.verdictLabel { result.append(verdict) }
            if let stat = entry.diffStat { result.append(stat) }
            if !result.isEmpty { out += "**Result:** \(result.joined(separator: " · "))\n\n" }
            if let summary = entry.summary, !summary.isEmpty { out += "_\(entry.agent ?? "Agent"): \(oneLine(summary))_\n\n" }
        }
        if entry.kind == .text {
            // Captured text: quoted, since they aren't the designer's words.
            let quoted = entry.body.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .newlines).map { "> \($0)" }.joined(separator: "\n")
            out += "\(quoted)\n\n"
        } else if !entry.body.isEmpty, entry.body.trimmingCharacters(in: .whitespacesAndNewlines) != entry.displayTitle {
            out += "\(entry.body)\n\n"
        }
        if !entry.rationale.isEmpty { out += "**Why:** \(entry.rationale)\n\n" }
        if let note = entry.ai {
            // Machine notes on the picture: what's there, never why.
            var saw = "_Margin saw: \(oneLine(note.seen))"
            if let changed = note.changed { saw += " Changed: \(oneLine(changed))" }
            out += saw + "_\n\n"
        }
        if !entry.alternatives.isEmpty { out += "**Also considered:** \(entry.alternatives)\n\n" }
        if !entry.link.isEmpty { out += "<\(entry.link)>\n\n" }
        if entry.kind == .recording, let mediaFile = entry.mediaFile {
            let length = entry.duration.map { " (\(Int($0.rounded())) s)" } ?? ""
            out += "[▶ Recording\(length)](\(media)/\(mediaFile))\n\n"
        }
        if let frames = entry.frames, frames.count > 1 {
            for frame in frames {
                if let file = frame.imageFile { out += "![\(frame.name ?? "Frame")](\(media)/\(file))\n" }
                if let link = frame.link { out += "<\(link)>\n" }
            }
            out += "\n"
        } else if entry.kind != .text, let file = entry.imageFile { out += "![\(entry.displayTitle)](\(media)/\(file))\n\n" }
        return out
    }

    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }
}
