import Foundation

/// A local HTML project you're building with Claude, copied into Margin so it
/// can be opened again later, exactly as it was at that moment.
///
/// Finds the page from Claude Code's own session files (~/.claude/projects):
/// the project folder and the HTML files Claude wrote or edited.
public enum ClaudeSite {
    public struct Session {
        public let id: String
        public let transcript: URL
        public let modified: Date
        /// The project folder Claude worked in.
        public let cwd: URL
        /// HTML files Claude wrote or edited, oldest first.
        public let htmlFiles: [URL]
    }

    public struct Copy {
        /// The copied site's root folder.
        public let folder: URL
        /// The page inside `folder`, e.g. "index.html" or "site/about.html".
        public let page: String
        public let files: Int
        public let bytes: Int64
        public let skipped: [String]
    }

    public static var projectsFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true)
    }

    // MARK: Which session and page

    /// Claude Code sessions with activity in the last `maxAge`, newest first.
    public static func recentSessions(maxAge: TimeInterval = 3 * 3600, limit: Int = 8, now: Date = Date(), in folder: URL = projectsFolder) -> [Session] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        var files: [(URL, Date)] = []
        for dir in dirs {
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for item in items where item.pathExtension == "jsonl" {
                let date = (try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if now.timeIntervalSince(date) <= maxAge { files.append((item, date)) }
            }
        }
        return files.sorted { $0.1 > $1.1 }.prefix(limit).compactMap { parse($0.0, modified: $0.1) }
    }

    /// Reads a session file: where Claude worked and which HTML it touched.
    public static func parse(_ transcript: URL, modified: Date = Date()) -> Session? {
        guard let data = try? Data(contentsOf: transcript) else { return nil }
        var cwd: String?
        var html: [String] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if let dir = object["cwd"] as? String, !dir.isEmpty { cwd = dir }
            guard let message = object["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }
            for block in content where block["type"] as? String == "tool_use" {
                guard let input = block["input"] as? [String: Any] else { continue }
                let path = (input["file_path"] as? String) ?? (input["path"] as? String) ?? ""
                let ext = (path as NSString).pathExtension.lowercased()
                guard ext == "html" || ext == "htm" else { continue }
                var full = path
                if !full.hasPrefix("/"), let cwd { full = (cwd as NSString).appendingPathComponent(path) }
                html.removeAll { $0 == full }
                html.append(full)
            }
        }
        guard let cwd else { return nil }
        return Session(
            id: transcript.deletingPathExtension().lastPathComponent,
            transcript: transcript,
            modified: modified,
            cwd: URL(fileURLWithPath: cwd, isDirectory: true),
            htmlFiles: html.map { URL(fileURLWithPath: $0) }
        )
    }

    /// The page to capture: the HTML Claude touched last, else the project's
    /// index.html, else its newest HTML file.
    public static func page(in session: Session) -> URL? {
        let fm = FileManager.default
        if let last = session.htmlFiles.reversed().first(where: { fm.fileExists(atPath: $0.path) }) { return last }
        let index = session.cwd.appendingPathComponent("index.html")
        if fm.fileExists(atPath: index.path) { return index }
        return newestHTML(in: session.cwd)
    }

    static func newestHTML(in folder: URL, maxDepth: Int = 3) -> URL? {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey], options: [.skipsHiddenFiles]) else { return nil }
        var best: (URL, Date)?
        for case let url as URL in walker {
            if walker.level > maxDepth || skippedFolders.contains(url.lastPathComponent) { walker.skipDescendants(); continue }
            let ext = url.pathExtension.lowercased()
            guard ext == "html" || ext == "htm" else { continue }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if date > (best?.1 ?? .distantPast) { best = (url, date) }
        }
        return best?.0
    }

    // MARK: Copying the site

    static let skippedFolders: Set<String> = [".git", "node_modules", ".next", ".cache", ".venv", "venv", "__pycache__", ".DS_Store", ".svelte-kit", ".turbo"]
    public static let maxFileBytes: Int64 = 50 << 20
    public static let maxTotalBytes: Int64 = 300 << 20
    public static let maxFiles = 2_000

    /// Copies the page's site into `destination`: the page's folder, widened to
    /// include local files the page uses from further up the project. On APFS
    /// unchanged files are clones and cost almost no space.
    public static func copy(page: URL, project: URL, to destination: URL) throws -> Copy {
        let fm = FileManager.default
        let page = page.standardizedFileURL.resolvingSymlinksInPath()
        let project = project.standardizedFileURL.resolvingSymlinksInPath()
        var root = page.deletingLastPathComponent()
        let insideProject = page.path.hasPrefix(project.path + "/")
        if insideProject {
            for ref in localReferences(of: page) where ref.path.hasPrefix(project.path + "/") {
                root = commonAncestor(root, ref.deletingLastPathComponent())
            }
        }

        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        // A page saved straight into a big folder (home, Desktop…): copy only
        // the page and the files it uses, never the whole folder.
        let home = fm.homeDirectoryForCurrentUser.standardizedFileURL.resolvingSymlinksInPath()
        let broad = ["", "Desktop", "Documents", "Downloads"].map { $0.isEmpty ? home.path : home.appendingPathComponent($0).path } + ["/", "/Users"]
        if broad.contains(root.path) {
            var files = 0
            var bytes: Int64 = 0
            var skipped: [String] = []
            for source in [page] + localReferences(of: page) where source.path.hasPrefix(root.path + "/") {
                let rel = relative(source, to: root)
                let size = Int64((try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                guard size <= maxFileBytes else { skipped.append(rel); continue }
                let target = destination.appendingPathComponent(rel)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: target.path) { continue }
                try fm.copyItem(at: source, to: target)
                files += 1
                bytes += size
            }
            return Copy(folder: destination, page: relative(page, to: root), files: files, bytes: bytes, skipped: skipped)
        }
        var files = 0
        var bytes: Int64 = 0
        var skipped: [String] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: []) else {
            throw CocoaError(.fileReadUnknown)
        }
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let name = url.lastPathComponent
            if skippedFolders.contains(name) || name == ".DS_Store" {
                if values?.isDirectory == true { walker.skipDescendants() }
                continue
            }
            if values?.isSymbolicLink == true { skipped.append(relative(url, to: root)); continue }
            if values?.isDirectory == true { continue }
            let size = Int64(values?.fileSize ?? 0)
            let rel = relative(url, to: root)
            if size > maxFileBytes || files >= maxFiles || bytes + size > maxTotalBytes {
                skipped.append(rel)
                continue
            }
            let target = destination.appendingPathComponent(rel)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: target.path) { try? fm.removeItem(at: target) }
            try fm.copyItem(at: url, to: target)
            files += 1
            bytes += size
        }

        let pagePath = relative(page, to: root)
        let manifest: [String: Any] = [
            "page": pagePath,
            "source": root.path,
            "project": project.path,
            "capturedAt": ISO8601DateFormatter().string(from: Date()),
            "files": files,
            "bytes": bytes,
            "skipped": skipped,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: destination.appendingPathComponent(".margin-site.json"))
        }
        return Copy(folder: destination, page: pagePath, files: files, bytes: bytes, skipped: skipped)
    }

    static func relative(_ url: URL, to root: URL) -> String {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let base = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : url.lastPathComponent
    }

    static func commonAncestor(_ a: URL, _ b: URL) -> URL {
        let left = a.standardizedFileURL.pathComponents
        let right = b.standardizedFileURL.pathComponents
        var common: [String] = []
        for (x, y) in zip(left, right) { if x == y { common.append(x) } else { break } }
        return URL(fileURLWithPath: NSString.path(withComponents: common.isEmpty ? ["/"] : common), isDirectory: true)
    }

    /// Local files the page (and the CSS it links) refer to by relative path.
    public static func localReferences(of page: URL) -> [URL] {
        guard let html = try? String(contentsOf: page, encoding: .utf8) else { return [] }
        let base = page.deletingLastPathComponent()
        var found = references(in: html).compactMap { resolve($0, base: base) }
        for css in found where css.pathExtension.lowercased() == "css" {
            if let text = try? String(contentsOf: css, encoding: .utf8) {
                found += references(in: text).compactMap { resolve($0, base: css.deletingLastPathComponent()) }
            }
        }
        return found.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func references(in text: String) -> [String] {
        let patterns = [
            #"(?:src|href|poster|data)\s*=\s*["']([^"']+)["']"#,
            #"srcset\s*=\s*["']([^"']+)["']"#,
            #"url\(\s*["']?([^"')]+)["']?\s*\)"#,
            #"(?:import|from)\s*\(?\s*["']([^"']+)["']"#,
        ]
        var out: [String] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) {
                guard let r = Range(match.range(at: 1), in: text) else { continue }
                let value = String(text[r])
                if pattern.hasPrefix("srcset") {
                    out += value.split(separator: ",").compactMap { $0.split(separator: " ").first.map(String.init) }
                } else {
                    out.append(value)
                }
            }
        }
        return out
    }

    static func resolve(_ ref: String, base: URL) -> URL? {
        let clean = ref.trimmingCharacters(in: .whitespaces).components(separatedBy: CharacterSet(charactersIn: "?#")).first ?? ""
        let lower = clean.lowercased()
        guard !clean.isEmpty, !clean.hasPrefix("/"), !lower.contains("://"), !lower.hasPrefix("//"),
              !lower.hasPrefix("data:"), !lower.hasPrefix("mailto:"), !lower.hasPrefix("javascript:"), !lower.hasPrefix("tel:") else { return nil }
        let decoded = clean.removingPercentEncoding ?? clean
        return base.appendingPathComponent(decoded).standardizedFileURL
    }
}
