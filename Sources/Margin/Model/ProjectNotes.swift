import AppKit
import MarginKit

/// What you tell Margin about a project: what it's for, who it's for, what
/// you're trying to find out. Kept with the archive (projects.json), and
/// read by Ask, the hand off and Claude when they work on the project.
@MainActor
final class ProjectNotes: ObservableObject {
    static let shared = ProjectNotes()
    @Published private(set) var about: [String: String] = [:]
    private var url: URL?

    /// Reads the notes of the archive `store` keeps.
    func load(_ store: EntryStore) {
        let file = store.baseURL.appendingPathComponent("projects.json")
        guard file != url else { return }
        url = file
        struct Stored: Codable { var about: String }
        if let data = try? Data(contentsOf: file),
           let stored = try? JSONDecoder().decode([String: Stored].self, from: data) {
            about = stored.mapValues(\.about)
        }
    }

    func about(_ project: String) -> String { about[project] ?? "" }

    func setAbout(_ text: String, for project: String) {
        about[project] = text.trimmed.isEmpty ? nil : text
        save()
    }

    func rename(_ old: String, to new: String) {
        guard let text = about.removeValue(forKey: old) else { return }
        about[new] = text
        save()
    }

    private func save() {
        guard let url else { return }
        struct Stored: Codable { var about: String }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(about.mapValues { Stored(about: $0) }) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

/// Renaming a project: its captures, and everything Margin keeps under its
/// name (pinned and order in the sidebar, cover, icon, notes, Ask's earlier
/// questions). Maps and themes are worked out again under the new name.
@MainActor
enum ProjectRename {
    /// Why `name` can't be used, or nil if it can.
    static func problem(with name: String, renaming old: String, in store: EntryStore) -> String? {
        let clean = name.trimmed
        if clean.isEmpty { return "A project needs a name." }
        if clean != old, store.projects.contains(where: { $0.caseInsensitiveCompare(clean) == .orderedSame }) {
            return "There's already a project called \(clean)."
        }
        return nil
    }

    static func rename(_ old: String, to new: String, in store: EntryStore) {
        let new = new.trimmed
        guard new != old, problem(with: new, renaming: old, in: store) == nil else { return }
        store.renameProject(old, to: new)

        let defaults = UserDefaults.standard
        for key in ["pinnedProjects", "projectOrder"] {
            let list = (defaults.string(forKey: key) ?? "").split(separator: "\n").map(String.init)
            defaults.set(list.map { $0 == old ? new : $0 }.joined(separator: "\n"), forKey: key)
        }
        if let history = defaults.stringArray(forKey: "askHistory." + old) {
            defaults.set(history, forKey: "askHistory." + new)
            defaults.removeObject(forKey: "askHistory." + old)
        }
        ProjectCovers.rename(old, to: new, in: store)
        ProjectIcons.shared.rename(old, to: new, store: store)
        ProjectNotes.shared.rename(old, to: new)
        MarginLog.info("Renamed project \(old) to \(new)")
    }
}
