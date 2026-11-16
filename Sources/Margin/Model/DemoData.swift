import Foundation
import MarginKit

/// The Umbrella demo: a finished project, already annotated, kept apart from
/// the designer's own captures (in Margin's own folder). Turned on in
/// Settings; Margin relaunches to switch.
enum DemoData {
    static let project = "Umbrella"
    private static let key = "useDemoData"

    /// A downloaded Margin, not a development build from the repo (those
    /// know where their repo is).
    static var isDownloadedBuild: Bool {
        Bundle.main.url(forResource: "repo-path", withExtension: nil) == nil
    }

    /// A download starts with the shipped projects to explore, until the
    /// person turns them off in Settings.
    static func startOnInDownloads() {
        guard isDownloadedBuild, UserDefaults.standard.object(forKey: key) == nil, bundledURL != nil else { return }
        isOn = true
    }

    static var isOn: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// In Margin's own folder, out of iCloud (moved from ~/Documents/Margin
    /// Demo on first launch; see ArchiveHome).
    static var baseURL: URL { ArchiveHome.demo }

    /// The demo as shipped: Resources/Demo in the app (or the repo, in tests).
    static var bundledURL: URL? {
        Bundle.main.url(forResource: "Demo", withExtension: nil)
    }

    /// Copies the shipped demo into `base` unless it's already there.
    /// `force` starts it over (new captures made in demo mode are lost).
    @discardableResult
    static func seed(into base: URL = baseURL, from source: URL? = bundledURL, force: Bool = false) -> Bool {
        let fm = FileManager.default
        let entries = base.appendingPathComponent("entries.json")
        guard force || !fm.fileExists(atPath: entries.path) else { return true }
        guard let source, fm.fileExists(atPath: source.appendingPathComponent("entries.json").path) else { return false }
        if force { try? fm.removeItem(at: base) }
        let images = base.appendingPathComponent("images", isDirectory: true)
        try? fm.createDirectory(at: images, withIntermediateDirectories: true)
        // The captures, and what Margin already worked out about them (headlines,
        // the cluster map's layout and names) so the demo works without API keys.
        for name in ["entries.json", "summaries.json", "map-arrangement.json", "map-edits.json", "pattern-names.json", "patterns.json", "embeddings.json"] {
            let from = source.appendingPathComponent(name)
            guard fm.fileExists(atPath: from.path) else { continue }
            let to = base.appendingPathComponent(name)
            try? fm.removeItem(at: to)
            try? fm.copyItem(at: from, to: to)
        }
        // Copied HTML sites, opened in the browser from Margin.
        let sites = source.appendingPathComponent("sites", isDirectory: true)
        for folder in (try? fm.contentsOfDirectory(atPath: sites.path)) ?? [] {
            let to = base.appendingPathComponent("sites", isDirectory: true).appendingPathComponent(folder, isDirectory: true)
            guard !fm.fileExists(atPath: to.path) else { continue }
            try? fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.copyItem(at: sites.appendingPathComponent(folder, isDirectory: true), to: to)
        }
        let shipped = source.appendingPathComponent("images", isDirectory: true)
        for file in (try? fm.contentsOfDirectory(atPath: shipped.path)) ?? [] {
            let to = images.appendingPathComponent("demo-" + file)
            try? fm.removeItem(at: to)
            try? fm.copyItem(at: shipped.appendingPathComponent(file), to: to)
        }
        return fm.fileExists(atPath: entries.path)
    }

    // MARK: Making it yours

    /// Makes what you see with demo data on your own archive. Your archive
    /// as it was moves aside, untouched, as a backup next to it; any capture
    /// in it the demo doesn't have comes along, with its files. The demo's
    /// own folder stays as it is. Returns the backup's location, or nil if
    /// nothing could be done.
    @discardableResult
    static func adopt() -> URL? {
        let fm = FileManager.default
        let demo = baseURL
        // Margin's own Archive folder, named directly: asking ArchiveHome
        // for it would start a move from Documents first.
        let archive = ArchiveHome.support.appendingPathComponent("Archive", isDirectory: true)
        guard fm.fileExists(atPath: demo.appendingPathComponent("entries.json").path) else { return nil }

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let backup = ArchiveHome.support.appendingPathComponent("Archive before demo \(stamp.string(from: Date()))", isDirectory: true)
        let hadArchive = fm.fileExists(atPath: archive.path)
        do {
            if hadArchive { try fm.moveItem(at: archive, to: backup) }
            try fm.copyItem(at: demo, to: archive)
        } catch {
            MarginLog.info("Demo: couldn't make it yours: \(error.localizedDescription)")
            // Put your archive back where it was.
            if hadArchive, !fm.fileExists(atPath: archive.path) { try? fm.moveItem(at: backup, to: archive) }
            return nil
        }
        guard hadArchive else { return backup }

        // Captures only in your old archive come along.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let read: (URL) -> [Entry] = { url in
            (try? Data(contentsOf: url.appendingPathComponent("entries.json")))
                .flatMap { try? decoder.decode([Entry].self, from: $0) } ?? []
        }
        let kept = read(archive)
        let ids = Set(kept.map(\.id))
        let extra = read(backup).filter { !ids.contains($0.id) }
        if !extra.isEmpty {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(kept + extra) {
                try? data.write(to: archive.appendingPathComponent("entries.json"), options: .atomic)
            }
            // Their pictures, films and sites: whatever isn't there yet.
            copyMissing(from: backup, to: archive, top: true)
        }
        MarginLog.info("Demo: made it your archive (\(kept.count) captures, \(extra.count) from before); the old one is at \(backup.path)")
        return backup
    }

    /// Copies files `to` doesn't have. At the top level only folders: the
    /// archive's own files (entries, summaries, maps) are the demo's.
    private static func copyMissing(from: URL, to: URL, top: Bool) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: from.path) else { return }
        try? fm.createDirectory(at: to, withIntermediateDirectories: true)
        for name in names where name != ".DS_Store" && name != ArchiveHome.markerName {
            let source = from.appendingPathComponent(name)
            let target = to.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                copyMissing(from: source, to: target, top: false)
            } else if !top, !fm.fileExists(atPath: target.path) {
                try? fm.copyItem(at: source, to: target)
            }
        }
    }
}
