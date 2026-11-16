import AppKit
import MarginKit

/// Brings a project's history in from Claude: a Claude chat (in a Claude
/// project, with its files, artifacts and Figma links) documents what
/// happened, and each piece lands in the timeline at the time it happened.
///
/// Claude reaches Margin through `margin-mcp`, a small helper the Claude
/// desktop app starts (it's listed in Claude's config by Connect). The
/// helper passes Claude's calls on to these routes on Margin's local
/// server (127.0.0.1, the same one Claude Code's hooks use):
///
/// - `GET /margin/hello`: Margin is here.
/// - `GET /margin/projects`: every project, with how many captures and when.
/// - `GET /margin/project?name=`: what a project already has, so nothing
///   is brought in twice.
/// - `POST /margin/captures`: `{project, captures: [...]}`; each capture
///   has a kind, title, body, when, and a link, a Figma frame or a
///   picture's address. Margin fetches the pictures itself.
@MainActor
final class ClaudeImport {
    static let shared = ClaudeImport()

    /// The archive to write into and a way to have new captures noted.
    var store: EntryStore?
    var onAdded: ((Int) -> Void)?

    // MARK: Routes

    /// Answers `/margin/…` requests, on the main thread, later. False for
    /// anything else.
    nonisolated static func handle(_ request: HookServer.Request, reply: @escaping (HookServer.Response) -> Void) -> Bool {
        guard request.path.hasPrefix("/margin/") else { return false }
        Task { @MainActor in
            let response = await shared.route(request)
            reply(response)
        }
        return true
    }

    private func route(_ request: HookServer.Request) async -> HookServer.Response {
        guard let store else { return .json(["error": "Margin is still starting"]) }
        switch (request.method, request.path) {
        case ("GET", "/margin/hello"):
            return .json(["app": "Margin", "open": store.currentProject])
        case ("GET", "/margin/projects"):
            return .json(["projects": projects(in: store), "open": store.currentProject])
        case ("GET", "/margin/project"):
            let name = request.query["name"] ?? store.currentProject
            return .json(overview(of: name, in: store))
        case ("POST", "/margin/captures"):
            guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
                return HookServer.Response(status: 400, body: Data(#"{"error":"The body isn't JSON."}"#.utf8))
            }
            return .json(await add(json, to: store))
        case ("POST", "/margin/about"):
            guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let project = (json["project"] as? String)?.trimmed, !project.isEmpty,
                  let about = json["about"] as? String else {
                return HookServer.Response(status: 400, body: Data(#"{"error":"Send a project and its about text."}"#.utf8))
            }
            let before = ProjectNotes.shared.about(project)
            ProjectNotes.shared.setAbout(about.trimmed, for: project)
            MarginLog.info("Claude: updated the about text of \(project)")
            return .json(["saved": true, "before": before])
        default:
            return HookServer.Response(status: 404, body: Data(#"{"error":"No such route."}"#.utf8))
        }
    }

    private func projects(in store: EntryStore) -> [[String: Any]] {
        let iso = ISO8601DateFormatter()
        var byProject: [String: [Entry]] = [:]
        for entry in store.entries where !entry.isAutomatic { byProject[entry.project, default: []].append(entry) }
        return byProject.keys.sorted().map { name in
            let dates = byProject[name]!.map(\.createdAt)
            return ["name": name, "captures": dates.count,
                    "first": dates.min().map(iso.string(from:)) ?? "", "last": dates.max().map(iso.string(from:)) ?? ""]
        }
    }

    private func overview(of name: String, in store: EntryStore) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        let entries = store.entries(in: name).filter { !$0.isAutomatic }
        let listed = entries.prefix(400).map { entry -> [String: Any] in
            ["title": entry.displayTitle, "kind": entry.kind.rawValue, "when": iso.string(from: entry.createdAt),
             "link": entry.link, "body": String(entry.body.prefix(160))]
        }
        // What the designer wrote about the project, so Claude starts from it.
        return ["name": name, "captures": entries.count, "about": ProjectNotes.shared.about(name), "recent": listed]
    }

    // MARK: Adding

    private func add(_ json: [String: Any], to store: EntryStore) async -> [String: Any] {
        let project = (json["project"] as? String)?.trimmed ?? ""
        guard !project.isEmpty else { return ["error": "Say which Margin project these go in."] }
        let items = (json["captures"] as? [[String: Any]]) ?? [json]
        var added = 0, skipped = 0, pictured = 0
        var notes: [String] = []
        var batch: [Entry] = []
        let existing = store.entries(in: project)
        for item in items.prefix(40) {
            guard var entry = makeEntry(item, project: project) else {
                notes.append("Skipped one without a title or text.")
                continue
            }
            if isDuplicate(entry, of: existing + batch) {
                skipped += 1
                continue
            }
            let (file, label, note) = await picture(for: item, entry: entry, store: store)
            if let file {
                entry.imageFile = file
                pictured += 1
            }
            if let label, entry.label == nil { entry.label = label }
            if let note { notes.append(note) }
            batch.append(entry)
            added += 1
        }
        store.add(contentsOf: batch)
        if added > 0 {
            MarginLog.info("Claude: added \(added) captures to \(project) (\(pictured) with pictures, \(skipped) already there)")
            onAdded?(added)
        }
        return ["added": added, "already_there": skipped, "with_pictures": pictured, "notes": Array(Set(notes))]
    }

    private func makeEntry(_ item: [String: Any], project: String) -> Entry? {
        let title = (item["title"] as? String)?.trimmed ?? ""
        let body = (item["body"] as? String)?.trimmed ?? ""
        let link = (item["link"] as? String)?.trimmed ?? ""
        let figma = (item["figma_url"] as? String)?.trimmed ?? ""
        guard !title.isEmpty || !body.isEmpty || !link.isEmpty || !figma.isEmpty else { return nil }

        let kind: EntryKind = {
            switch (item["kind"] as? String)?.lowercased() {
            case "decision": return .decision
            case "link", "website": return .link
            case "figma": return .figma
            case "inspiration", "reference": return .inspiration
            case "text", "quote", "excerpt": return .text
            case "image", "picture", "capture": return .capture
            default: return figma.isEmpty ? (link.isEmpty ? .note : .link) : .figma
            }
        }()
        var entry = Entry(kind: kind, project: project)
        entry.createdAt = Self.date(item["when"] as? String) ?? Date()
        entry.title = title
        entry.body = body
        entry.link = figma.isEmpty ? link : figma
        // The designer's own words only, quoted from what they wrote.
        entry.rationale = (item["why"] as? String)?.trimmed ?? ""
        entry.alternatives = (item["alternatives"] as? String)?.trimmed ?? ""
        entry.sourceApp = (item["source"] as? String)?.trimmed.nilIfEmpty ?? "Claude"
        entry.tags = (item["tags"] as? [String]) ?? []
        return entry
    }

    /// Already in the project: the same link with the same title, or the
    /// same title and text.
    private func isDuplicate(_ entry: Entry, of others: [Entry]) -> Bool {
        others.contains { other in
            if !entry.link.isEmpty, entry.link == other.link, entry.title == other.title { return true }
            return !entry.title.isEmpty && entry.title == other.title && entry.body == other.body
        }
    }

    /// A Figma frame (through your Figma token), a picture's address, or a
    /// website pictured by loading it. Returns the saved file, a name that
    /// came with it and, when something didn't work, why.
    private func picture(for item: [String: Any], entry: Entry, store: EntryStore) async -> (String?, String?, String?) {
        if let raw = item["figma_url"] as? String, let link = FigmaLink.parse(raw), let node = link.nodeID {
            guard let token = Keychain.figmaToken else {
                return (nil, nil, "Figma frames come without pictures until a Figma token is added in Margin's Settings.")
            }
            if let export = try? await FigmaREST.export(fileKey: link.fileKey, nodeID: node, token: token) {
                return (store.saveFile(export.image, ext: ImageData.fileExtension(export.image)), export.node.name, nil)
            }
            return (nil, nil, "A Figma frame couldn't be fetched (check the link and that the token can open the file).")
        }
        if let raw = item["image_url"] as? String, let url = URL(string: raw), url.scheme?.hasPrefix("http") == true {
            if let data = try? await ImageData.download(url, session: nil), ImageData.isImage(data) {
                return (store.saveFile(data, ext: ImageData.fileExtension(data)), nil, nil)
            }
            return (nil, nil, "A picture's address didn't give a picture.")
        }
        // A public website: pictured by loading it. Claude's own pages
        // need you signed in, so they'd only show a sign-in page.
        if entry.kind == .link || entry.kind == .inspiration, let url = URL(string: entry.link),
           url.scheme?.hasPrefix("http") == true, !(url.host ?? "").hasSuffix("claude.ai"),
           let shot = await PagePreview.shot(url, timeout: 15) {
            return (store.saveFile(shot.png, ext: "png"), shot.title, nil)
        }
        return (nil, nil, nil)
    }

    private static func date(_ text: String?) -> Date? {
        guard let text = text?.trimmed, !text.isEmpty else { return nil }
        let full = ISO8601DateFormatter()
        if let date = full.date(from: text) { return date }
        full.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = full.date(from: text) { return date }
        // A day alone: midday, so it stays on that day anywhere.
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        day.timeZone = .current
        return day.date(from: String(text.prefix(10))).map { $0.addingTimeInterval(12 * 3600) }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Connecting the Claude app

/// Lists Margin's helper in the Claude desktop app's config, so chats there
/// (in any Claude project) can document into Margin. The helper is copied
/// to ~/.margin so its path stays the same across Margin's updates.
enum ClaudeDesktopLink {
    static let configURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
    static let helperURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".margin/margin-mcp")
    /// The helper as built into this copy of Margin.
    static var bundledHelper: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/margin-mcp")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: configURL.deletingLastPathComponent().path) }

    static var isConnected: Bool {
        guard let config = readConfig(), let servers = config["mcpServers"] as? [String: Any] else { return false }
        return servers["margin"] != nil
    }

    /// Puts the helper in place and lists it in Claude's config, keeping
    /// everything else there as it was (a copy of the old file is kept).
    static func connect() throws {
        try refreshHelper()
        let fm = FileManager.default
        try fm.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var config = readConfig() ?? [:]
        if fm.fileExists(atPath: configURL.path) {
            let backup = configURL.deletingLastPathComponent().appendingPathComponent("claude_desktop_config.before-margin.json")
            if !fm.fileExists(atPath: backup.path) { try? fm.copyItem(at: configURL, to: backup) }
        }
        var servers = config["mcpServers"] as? [String: Any] ?? [:]
        servers["margin"] = ["command": helperURL.path]
        config["mcpServers"] = servers
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: configURL, options: .atomic)
        MarginLog.info("Claude: listed Margin in \(configURL.path)")
    }

    /// Copies this build's helper over the one Claude starts, so an update
    /// to Margin updates it too. Quiet when there's nothing to copy.
    static func refreshHelper() throws {
        guard let source = bundledHelper else {
            throw NSError(domain: "Margin", code: 1, userInfo: [NSLocalizedDescriptionKey: "This copy of Margin doesn't include its Claude helper."])
        }
        let fm = FileManager.default
        try fm.createDirectory(at: helperURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: helperURL)
        try fm.copyItem(at: source, to: helperURL)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperURL.path)
    }

    private static func readConfig() -> [String: Any]? {
        guard let data = try? Data(contentsOf: configURL) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Takes Margin out of Claude's config again, leaving the rest.
    static func disconnect() throws {
        guard var config = readConfig() else { return }
        var servers = config["mcpServers"] as? [String: Any] ?? [:]
        servers["margin"] = nil
        config["mcpServers"] = servers
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: configURL, options: .atomic)
    }

    /// The skill as a zip in Downloads, ready to add to Claude
    /// (Settings › Capabilities › Skills). Returns where it went.
    static func saveSkill() throws -> URL {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("margin-skill-\(UUID().uuidString)", isDirectory: true)
        let folder = work.appendingPathComponent(MarginSkill.name, isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try MarginSkill.markdown.write(to: folder.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let zip = downloads.appendingPathComponent("\(MarginSkill.name).zip")
        try? fm.removeItem(at: zip)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", folder.path, zip.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0, fm.fileExists(atPath: zip.path) else {
            throw NSError(domain: "Margin", code: 2, userInfo: [NSLocalizedDescriptionKey: "Couldn't make the zip."])
        }
        return zip
    }
}
