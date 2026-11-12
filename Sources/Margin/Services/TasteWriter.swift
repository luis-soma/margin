import AppKit
import Foundation
import MarginKit

/// TASTE.md: the project's design language, so whoever builds from the
/// handoff builds in the designer's style (what Naheel asked for).
///
/// Two kinds of content, kept apart:
/// - Measured by Margin: the palette, counted from the captures' pixels.
/// - Observed by Gemini from a dozen key captures: type, layout, components,
///   imagery, voice. Descriptions, never reasons.
/// - In the designer's words: preferences and things they dropped, only
///   from what they wrote (reasons, verdicts, notes).
enum TasteWriter {
    struct Taste: Decodable {
        var summary: String
        var color: String?
        var typography: String?
        var layout: String?
        var components: String?
        var imagery: String?
        var voice: String?
        var preferences: [Quote]?
        var rejected: [Quote]?
        var keep: [String]?
        var avoid: [String]?

        struct Quote: Decodable {
            var point: String
            var words: String?
        }
    }

    // MARK: Once, ahead of time

    /// Projects whose TASTE.md is being written right now.
    @MainActor private static var writing: Set<String> = []

    /// Writes TASTE.md only when it's missing or out of date: at most once a
    /// day, and only when the project has new captures since. Runs ahead of
    /// time (when you open a project), so the handoff never waits for it.
    /// Returns once it's there (or skipped).
    static func writeIfNeeded(project: String, entries: [Entry], store: EntryStore, config: AIConfig, folder: URL) async {
        let file = folder.appendingPathComponent("TASTE.md")
        let key = fingerprint(entries)
        let stamps = UserDefaults.standard.dictionary(forKey: "tasteWritten") as? [String: String] ?? [:]
        let exists = FileManager.default.fileExists(atPath: file.path)
        let written = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date ?? .distantPast
        if exists, stamps[project] == key || Date().timeIntervalSince(written) < 24 * 3600 { return }
        let started = await MainActor.run { () -> Bool in
            guard !writing.contains(project) else { return false }
            writing.insert(project)
            return true
        }
        guard started else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        await write(project: project, entries: entries, store: store, config: config, folder: folder)
        var updated = UserDefaults.standard.dictionary(forKey: "tasteWritten") as? [String: String] ?? [:]
        updated[project] = key
        UserDefaults.standard.set(updated, forKey: "tasteWritten")
        _ = await MainActor.run { writing.remove(project) }
    }

    /// Changes when the project's pictures or your words change enough to matter.
    private static func fingerprint(_ entries: [Entry]) -> String {
        let pictured = entries.filter { $0.imageFile != nil && $0.kind != .text }.count
        let worded = entries.filter(\.hasWords).count
        return "\(pictured / 10)-\(worded / 5)"
    }

    /// Writes TASTE.md into the handoff folder. Without a Gemini key it
    /// still writes the palette and the designer's own words.
    static func write(project: String, entries: [Entry], store: EntryStore, config: AIConfig, folder: URL) async {
        let picks = await MainActor.run { keyCaptures(entries, store: store) }
        let palette = Self.palette(picks.map(\.url))
        var taste: Taste?
        if let key = config.gemini {
            var parts: [GeminiClient.Part] = [.text(facts(project: project, entries: entries))]
            for pick in picks {
                guard let jpeg = ImagePrep.jpeg(contentsOf: pick.url, maxPixel: 768, quality: 0.7) else { continue }
                parts.append(.text("Capture from \(pick.date.formatted(date: .abbreviated, time: .omitted)):"))
                parts.append(.image(jpeg, mime: "image/jpeg"))
            }
            do {
                let data = try await GeminiClient(apiKey: key)
                    .generateJSON(model: config.summary, system: system, parts: parts, schema: schema, temperature: 0.3, timeout: 45)
                taste = try JSONDecoder().decode(Taste.self, from: data)
            } catch {
                MarginLog.info("Taste: Gemini failed (\(error)); writing palette and your words only")
            }
        }
        let text = render(project: project, entries: entries, taste: taste, palette: palette, pictures: picks.count)
        try? text.write(to: folder.appendingPathComponent("TASTE.md"), atomically: true, encoding: .utf8)
    }

    // MARK: Gemini

    private static let system = """
    You describe the design language of one project from screenshots of the designer's work and the words they wrote.
    Describe what is visible: type, color use, spacing, layout, components, imagery, motion cues and the voice of the interface copy. Be concrete: name sizes relative to each other, weights, corner treatment, density, alignment.
    Preferences and rejections may only come from lines marked "designer said" or verdicts; quote their words. Never invent intentions.
    Plain, specific language. No em dashes. No praise.
    """

    private static let schema: [String: Any] = [
        "type": "OBJECT",
        "properties": [
            "summary": ["type": "STRING", "description": "Two or three sentences: the overall visual language."],
            "color": ["type": "STRING", "description": "How color is used: background, ink, accents, contrast."],
            "typography": ["type": "STRING", "description": "Typefaces or their character, scale, weights, case, spacing."],
            "layout": ["type": "STRING", "description": "Grid, density, spacing rhythm, alignment, white space."],
            "components": ["type": "STRING", "description": "Recurring components and their treatment: corners, borders, shadows, states."],
            "imagery": ["type": "STRING", "description": "Images, icons, illustration, how media is framed. Empty if none."],
            "voice": ["type": "STRING", "description": "Tone of the interface copy, from visible text. Empty if too little text."],
            "preferences": ["type": "ARRAY", "items": ["type": "OBJECT", "properties": [
                "point": ["type": "STRING"], "words": ["type": "STRING", "description": "The designer's words it comes from."]],
                "required": ["point", "words"]], "description": "What the designer said they want or like. Only from their words."],
            "rejected": ["type": "ARRAY", "items": ["type": "OBJECT", "properties": [
                "point": ["type": "STRING"], "words": ["type": "STRING"]],
                "required": ["point"]], "description": "What they tried and dropped: dead ends, 'not quite' verdicts, things they said no to."],
            "keep": ["type": "ARRAY", "items": ["type": "STRING"], "description": "3 to 6 short rules for building something new in this style."],
            "avoid": ["type": "ARRAY", "items": ["type": "STRING"], "description": "2 to 5 short things that would break this style."],
        ],
        "required": ["summary", "color", "typography", "layout", "components", "keep", "avoid"],
    ]

    private static func facts(project: String, entries: [Entry]) -> String {
        var out = "Project: \(project)\n\nWhat the designer wrote, oldest first:\n"
        for entry in entries where entry.hasWords || entry.verdictLabel != nil {
            var line = "- \(entry.kind.label)"
            let words = [entry.title, entry.kind == .text ? "" : entry.body, entry.rationale, entry.alternatives, entry.prompt ?? "", entry.expectation ?? ""]
                .map(\.trimmed).filter { !$0.isEmpty }.joined(separator: " · ")
            if !words.isEmpty { line += " · designer said: \"\(words.prefix(300))\"" }
            if let verdict = entry.verdictLabel { line += " · verdict: \(verdict)" }
            out += line + "\n"
        }
        return out
    }

    // MARK: Pictures and palette

    struct Pick { var url: URL; var date: Date }

    /// A dozen captures: the ones with the designer's words first, then
    /// evenly through the project. Pictures only (no text or code cards).
    @MainActor
    private static func keyCaptures(_ entries: [Entry], store: EntryStore) -> [Pick] {
        let pictured = entries.filter { $0.imageFile != nil && ($0.kind == .capture || $0.kind == .figma || $0.kind == .snapshot || $0.kind == .decision || $0.kind == .inspiration) }
        let worded = Array(pictured.filter(\.hasWords).suffix(7))
        let rest = pictured.filter { !$0.hasWords }
        let step = max(1, rest.count / max(1, 12 - worded.count))
        let spread = stride(from: 0, to: rest.count, by: step).map { rest[$0] }.prefix(12 - worded.count)
        return (worded + spread).sorted { $0.createdAt < $1.createdAt }.compactMap { entry in
            store.imageURL(for: entry).map { Pick(url: $0, date: entry.createdAt) }
        }
    }

    /// The colors that cover the most of the captures, as hex with their share.
    static func palette(_ urls: [URL]) -> [(hex: String, share: Double)] {
        var counts: [UInt32: Int] = [:]
        var total = 0
        for url in urls {
            guard let image = NSImage(contentsOf: url),
                  let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            let side = 48
            var pixels = [UInt8](repeating: 0, count: side * side * 4)
            guard let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            context.interpolationQuality = .low
            context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
            for i in stride(from: 0, to: pixels.count, by: 4) {
                // Buckets of 16 levels per channel, so near colors count together.
                let r = UInt32(pixels[i] / 16), g = UInt32(pixels[i + 1] / 16), b = UInt32(pixels[i + 2] / 16)
                counts[(r << 8) | (g << 4) | b, default: 0] += 1
                total += 1
            }
        }
        guard total > 0 else { return [] }
        return counts.sorted { $0.value > $1.value }.prefix(8).map { key, count in
            let r = Int((key >> 8) & 15) * 16 + 8, g = Int((key >> 4) & 15) * 16 + 8, b = Int(key & 15) * 16 + 8
            return (String(format: "#%02X%02X%02X", r, g, b), Double(count) / Double(total))
        }
    }

    // MARK: The file

    private static func render(project: String, entries: [Entry], taste: Taste?, palette: [(hex: String, share: Double)], pictures: Int) -> String {
        var out = """
        # \(project): taste and design language

        How this project looks and feels, so anything built from this handoff (a case study, a deck, a site, the next screens) is built in the designer's style. Read it with CLAUDE.md: the same rule applies, reasons come only from the designer's words.

        """
        if let taste {
            out += "## At a glance\n\n\(taste.summary)\n\n_Observed by Margin from \(pictures) captures. A description, not the designer's words._\n\n"
        }
        if !palette.isEmpty {
            out += "## Palette\n\nThe colors covering the most of the captures, measured from their pixels (approximate):\n\n"
            for color in palette { out += "- `\(color.hex)` about \(Int((color.share * 100).rounded()))%\n" }
            if let color = taste?.color, !color.isEmpty { out += "\n\(color)\n" }
            out += "\n"
        }
        if let taste {
            let sections: [(String, String?)] = [
                ("Typography", taste.typography), ("Layout and spacing", taste.layout), ("Components", taste.components),
                ("Imagery", taste.imagery), ("Voice", taste.voice),
            ]
            for (title, text) in sections {
                guard let text = text?.trimmed, !text.isEmpty else { continue }
                out += "## \(title)\n\n\(text)\n\n"
            }
        }
        let preferences = taste?.preferences ?? []
        if !preferences.isEmpty {
            out += "## In the designer's words: what they want\n\n"
            for item in preferences {
                out += "- \(item.point)"
                if let words = item.words?.trimmed, !words.isEmpty { out += " (\"\(words)\")" }
                out += "\n"
            }
            out += "\n"
        }
        // Dropped directions: Margin's own list of dead ends, plus what Gemini found in their words.
        let deadEnds = entries.filter { $0.verdict == "deadEnd" || $0.verdict == "notQuite" }
        let rejected = taste?.rejected ?? []
        if !deadEnds.isEmpty || !rejected.isEmpty {
            out += "## What they tried and dropped\n\n"
            for item in rejected {
                out += "- \(item.point)"
                if let words = item.words?.trimmed, !words.isEmpty { out += " (\"\(words)\")" }
                out += "\n"
            }
            for entry in deadEnds.suffix(10) {
                out += "- \(entry.verdictLabel ?? "Dropped"): \(entry.displayTitle)"
                if !entry.rationale.trimmed.isEmpty { out += " (\"\(entry.rationale.trimmed)\")" }
                out += "\n"
            }
            out += "\n"
        }
        if let taste {
            if let keep = taste.keep, !keep.isEmpty {
                out += "## Building in this style\n\nKeep:\n" + keep.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
            }
            if let avoid = taste.avoid, !avoid.isEmpty {
                out += "Avoid:\n" + avoid.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
            }
        } else {
            out += "_Margin couldn't describe the look this time (no Gemini key, or it didn't answer). Look at the captures for type, layout and components._\n"
        }
        return out
    }
}
