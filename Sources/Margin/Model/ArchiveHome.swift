import Foundation
import MarginKit

/// Where the archive lives: Margin's own folder in Library
/// (~/Library/Application Support/Margin), which iCloud doesn't sync.
///
/// It used to live in Documents. With iCloud's Desktop & Documents on, macOS
/// keeps older files only in the cloud, so pictures came back slowly or not
/// at all, and reading them froze Margin. The first launch that finds an
/// archive in Documents moves it here:
/// - everything already on this Mac is copied at once (on the same disk
///   that's a clone: instant, no extra space);
/// - files iCloud still holds are fetched and copied in the background,
///   and until each arrives it's read from the old folder;
/// - the old folder is left exactly as it was, as a backup.
enum ArchiveHome {
    static let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Margin", isDirectory: true)

    /// Your captures.
    static let main: URL = resolve(new: support.appendingPathComponent("Archive", isDirectory: true),
                                   legacy: documents("Margin"))
    /// The example projects.
    static let demo: URL = resolve(new: support.appendingPathComponent("Demo", isDirectory: true),
                                   legacy: documents("Margin Demo"))

    /// Written while a move is still finishing; holds the old folder's path.
    static let markerName = "moved-from-documents"

    /// The old folder an archive is still being moved from, if any.
    static func movingFrom(_ base: URL) -> URL? {
        let marker = base.appendingPathComponent(markerName)
        guard let path = try? String(contentsOf: marker, encoding: .utf8) else { return nil }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : URL(fileURLWithPath: trimmed, isDirectory: true)
    }

    private static func documents(_ name: String) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name, isDirectory: true)
    }

    /// The files Margin reads at launch: copied even if iCloud has to fetch
    /// them first, so the archive is complete before it's opened.
    private static let essential: Set<String> = [
        "entries.json", "summaries.json", "embeddings.json", "map-arrangement.json",
        "map-edits.json", "pattern-names.json", "patterns.json", "process-memory.json",
    ]

    private static func resolve(new: URL, legacy: URL) -> URL {
        let fm = FileManager.default
        let entries = "entries.json"
        if fm.fileExists(atPath: new.appendingPathComponent(entries).path) {
            // Already here; a move that didn't finish carries on.
            if let from = movingFrom(new) { finishInBackground(from: from, to: new) }
            return new
        }
        try? fm.createDirectory(at: new, withIntermediateDirectories: true)
        guard fm.fileExists(atPath: legacy.appendingPathComponent(entries).path) else { return new }

        let started = Date()
        try? legacy.path.write(to: new.appendingPathComponent(markerName), atomically: true, encoding: .utf8)
        for name in essential {
            let from = legacy.appendingPathComponent(name)
            let to = new.appendingPathComponent(name)
            guard fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) else { continue }
            try? fm.copyItem(at: from, to: to)
        }
        let waiting = copyTree(from: legacy, to: new, fetching: false)
        MarginLog.info(String(format: "Archive: moved %@ out of iCloud to %@ in %.1f s; %d files still in iCloud follow in the background",
                              legacy.lastPathComponent, new.path, Date().timeIntervalSince(started), waiting))
        finishInBackground(from: legacy, to: new)
        return new
    }

    /// Copies what's missing in `to`. Without `fetching`, a file only in
    /// iCloud is skipped (and counted); with it, it's fetched and copied.
    @discardableResult
    private static func copyTree(from: URL, to: URL, fetching: Bool) -> Int {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: from.path) else { return 0 }
        try? fm.createDirectory(at: to, withIntermediateDirectories: true)
        var skipped = 0
        for name in names where name != ".DS_Store" && name != markerName {
            let source = from.appendingPathComponent(name)
            let target = to.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                skipped += copyTree(from: source, to: target, fetching: fetching)
                continue
            }
            guard !fm.fileExists(atPath: target.path) else { continue }
            if !fetching && !EntryStore.isOnThisMac(source) {
                skipped += 1
                continue
            }
            try? fm.copyItem(at: source, to: target)
        }
        return skipped
    }

    private static func finishInBackground(from legacy: URL, to new: URL) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
            let fm = FileManager.default
            // Ask iCloud for everything first, so the downloads run together.
            if let walker = fm.enumerator(at: legacy, includingPropertiesForKeys: nil) {
                for case let url as URL in walker where !EntryStore.isOnThisMac(url) {
                    try? fm.startDownloadingUbiquitousItem(at: url)
                }
            }
            let started = Date()
            copyTree(from: legacy, to: new, fetching: true)
            let left = copyTree(from: legacy, to: new, fetching: false)
            if left == 0 {
                try? fm.removeItem(at: new.appendingPathComponent(markerName))
            }
            MarginLog.info(String(format: "Archive: finished bringing %@ over in %.0f s%@", legacy.lastPathComponent,
                                  Date().timeIntervalSince(started), left == 0 ? "" : " (\(left) files couldn't be read)"))
        }
    }
}
