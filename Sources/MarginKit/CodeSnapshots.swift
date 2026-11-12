import Foundation

/// Keeps every version of a code project in a hidden git history of Margin's
/// own (~/Documents/Margin/code/<project>.git). The project's files are only
/// read; its own git, if it has one, is never touched.
public final class CodeSnapshots {
    public struct Snapshot: Equatable, Sendable {
        /// Commit id of this version.
        public let commit: String
        /// The file tree; equal trees mean nothing changed.
        public let tree: String
        /// False when this version is identical to the previous one.
        public let changed: Bool
    }

    public struct DiffStat: Equatable, Sendable {
        public var files: [String] = []
        public var insertions = 0
        public var deletions = 0

        public init(files: [String] = [], insertions: Int = 0, deletions: Int = 0) {
            self.files = files
            self.insertions = insertions
            self.deletions = deletions
        }

        public var summary: String {
            let count = files.count
            return "\(count) \(count == 1 ? "file" : "files") · +\(insertions) −\(deletions)"
        }
    }

    public enum SnapshotError: Error, CustomStringConvertible {
        case git(String)
        public var description: String {
            switch self {
            case .git(let message): return "git: \(message)"
            }
        }
    }

    /// git's empty tree, to diff the first version against.
    static let emptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

    /// Never kept: dependencies, build output, caches and secrets.
    static let excludes = [
        "node_modules/", ".next/", ".nuxt/", ".svelte-kit/", ".turbo/", ".vercel/", ".cache/", ".parcel-cache/",
        "dist/", "build/", "out/", ".build/", "DerivedData/", "Pods/", "target/",
        ".venv/", "venv/", "__pycache__/", "*.pyc",
        ".DS_Store", "*.log", ".env", ".env.*", "*.pem", "*.key",
    ]

    public let base: URL
    private let git = "/usr/bin/git"

    public init(base: URL) {
        self.base = base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    // MARK: Which folder is the project

    /// The project a coding session works in: the enclosing git repository,
    /// or the folder itself if it looks like a project. Nil for places that
    /// aren't projects (your home folder, Desktop, Downloads…), so a research
    /// session started there is never copied.
    public static func projectRoot(for cwd: URL) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.resolvingSymlinksInPath()
        let notProjects: Set<String> = [
            "/", "/tmp", "/private/tmp", "/Users", "/Applications", "/System", "/Library",
            home.path,
            home.appendingPathComponent("Desktop").path,
            home.appendingPathComponent("Documents").path,
            home.appendingPathComponent("Downloads").path,
            home.appendingPathComponent("Library").path,
        ]
        let folder = cwd.standardizedFileURL.resolvingSymlinksInPath()
        var root = folder
        let top = Shell.run("/usr/bin/git", ["-C", folder.path, "rev-parse", "--show-toplevel"], timeout: 10)
        if top.ok {
            let path = top.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty { root = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath() }
        }
        guard !notProjects.contains(root.path), !notProjects.contains(folder.path) else { return nil }
        guard looksLikeProject(root) else { return nil }
        return root
    }

    static func looksLikeProject(_ folder: URL) -> Bool {
        let markers = [
            ".git", "package.json", "index.html", "Package.swift", "pyproject.toml", "requirements.txt",
            "Cargo.toml", "go.mod", "Gemfile", "composer.json", "deno.json", "vite.config.ts", "vite.config.js",
            "next.config.js", "next.config.mjs", "next.config.ts", "src", "app", "CLAUDE.md",
        ]
        let fm = FileManager.default
        if markers.contains(where: { fm.fileExists(atPath: folder.appendingPathComponent($0).path) }) { return true }
        let items = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        return items.contains { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".html") }
    }

    // MARK: Versions

    /// The hidden history for a project folder.
    public func gitDir(for root: URL) -> URL {
        let name = root.lastPathComponent.replacingOccurrences(of: " ", with: "-")
        return base.appendingPathComponent("\(name)-\(Self.shortHash(root.path)).git", isDirectory: true)
    }

    /// Records the project as it is now. Cheap when nothing changed.
    public func snapshot(root: URL, message: String) throws -> Snapshot {
        let dir = gitDir(for: root)
        try prepare(dir)
        let env = ["GIT_DIR": dir.path, "GIT_WORK_TREE": root.path]

        // --ignore-errors: an unreadable file shouldn't lose the whole version.
        let add = Shell.run(git, ["add", "-A", "--ignore-errors", "."], in: root, environment: env, timeout: 120)
        if !add.ok, add.stderr.contains("fatal:") {
            throw SnapshotError.git(add.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let treeOut = Shell.run(git, ["write-tree"], in: root, environment: env)
        let tree = treeOut.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard treeOut.ok, !tree.isEmpty else { throw SnapshotError.git(treeOut.stderr) }

        let head = Shell.run(git, ["rev-parse", "-q", "--verify", "HEAD"], in: root, environment: env)
        let headCommit = head.ok ? head.text.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        if let headCommit {
            let headTree = Shell.run(git, ["rev-parse", "\(headCommit)^{tree}"], in: root, environment: env)
                .text.trimmingCharacters(in: .whitespacesAndNewlines)
            if headTree == tree { return Snapshot(commit: headCommit, tree: tree, changed: false) }
        }

        var args = ["-c", "user.name=Margin", "-c", "user.email=margin@localhost", "commit-tree", tree, "-m", message]
        if let headCommit { args += ["-p", headCommit] }
        let commitOut = Shell.run(git, args, in: root, environment: env)
        let commit = commitOut.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard commitOut.ok, !commit.isEmpty else { throw SnapshotError.git(commitOut.stderr) }
        let update = Shell.run(git, ["update-ref", "HEAD", commit], in: root, environment: env)
        guard update.ok else { throw SnapshotError.git(update.stderr) }
        return Snapshot(commit: commit, tree: tree, changed: true)
    }

    /// Files and lines changed between two versions (from nil: everything).
    public func diffStat(root: URL, from: String?, to: String) -> DiffStat {
        let env = ["GIT_DIR": gitDir(for: root).path]
        let out = Shell.run(git, ["diff", "--numstat", "--no-renames", from ?? Self.emptyTree, to], environment: env)
        var stat = DiffStat()
        for line in out.text.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 2)
            guard parts.count == 3 else { continue }
            stat.insertions += Int(parts[0]) ?? 0
            stat.deletions += Int(parts[1]) ?? 0
            stat.files.append(String(parts[2]))
        }
        return stat
    }

    /// The full change as a unified diff, capped in size.
    public func diff(root: URL, from: String?, to: String, limit: Int = 400_000) -> String {
        let env = ["GIT_DIR": gitDir(for: root).path]
        let out = Shell.run(git, ["diff", "--no-color", "--no-renames", "-U3", from ?? Self.emptyTree, to], environment: env)
        let text = out.text
        return text.count > limit ? String(text.prefix(limit)) + "\n… (diff truncated)" : text
    }

    /// Writes the files of a version into `destination`.
    public func export(root: URL, commit: String, to destination: URL) throws {
        let env = ["GIT_DIR": gitDir(for: root).path]
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let tar = FileManager.default.temporaryDirectory.appendingPathComponent("margin-\(UUID().uuidString).tar")
        defer { try? FileManager.default.removeItem(at: tar) }
        let archive = Shell.run(git, ["archive", "--format=tar", "-o", tar.path, commit], environment: env)
        guard archive.ok else { throw SnapshotError.git(archive.stderr) }
        let untar = Shell.run("/usr/bin/tar", ["-xf", tar.path, "-C", destination.path])
        guard untar.ok else { throw SnapshotError.git("tar: \(untar.stderr)") }
    }

    // MARK: Helpers

    private func prepare(_ dir: URL) throws {
        guard !FileManager.default.fileExists(atPath: dir.appendingPathComponent("HEAD").path) else { return }
        let initOut = Shell.run(git, ["init", "-q", "--bare", dir.path])
        guard initOut.ok else { throw SnapshotError.git(initOut.stderr) }
        let info = dir.appendingPathComponent("info", isDirectory: true)
        try? FileManager.default.createDirectory(at: info, withIntermediateDirectories: true)
        try (Self.excludes.joined(separator: "\n") + "\n").write(to: info.appendingPathComponent("exclude"), atomically: true, encoding: .utf8)
        // Used with the project as work tree; no automatic gc pauses.
        Shell.run(git, ["--git-dir", dir.path, "config", "gc.auto", "0"])
        Shell.run(git, ["--git-dir", dir.path, "config", "core.autocrlf", "false"])
    }

    static func shortHash(_ text: String) -> String {
        // FNV-1a: stable across launches, unlike Swift's hashValue.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(hash, radix: 16).prefix(8).description
    }
}
