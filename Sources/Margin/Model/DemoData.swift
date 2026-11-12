import Foundation

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
}
