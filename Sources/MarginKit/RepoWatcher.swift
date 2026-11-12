import Foundation

/// Notices new versions that arrive through git: commits an agent pushed
/// from somewhere else (a cloud session, a teammate) to a project you have
/// on this Mac. Reads only; never changes your branches or files.
public enum RepoWatcher {
    /// Remote branches and the commit each points at.
    public struct State: Equatable, Sendable {
        public var refs: [String: String]
        public init(refs: [String: String] = [:]) { self.refs = refs }
    }

    public struct Commit: Equatable, Sendable {
        public let sha: String
        public let subject: String
    }

    /// New commits on one remote branch.
    public struct Change: Equatable, Sendable {
        public let ref: String
        /// Where the branch was, nil for a new branch.
        public let from: String?
        public let to: String
        /// Newest first.
        public let commits: [Commit]
        /// The commit to diff against: the old tip, or the parent of the oldest new commit.
        public let base: String?

        /// "main", "margin-core-loop"
        public var branch: String { ref.components(separatedBy: "/").dropFirst(3).joined(separator: "/") }
    }

    private static let git = "/usr/bin/git"
    /// Never wait for a password prompt in the background.
    private static let env = ["GIT_TERMINAL_PROMPT": "0", "GIT_ASKPASS": "/usr/bin/true", "SSH_ASKPASS": "/usr/bin/true", "GIT_SSH_COMMAND": "ssh -o BatchMode=yes"]

    public static func isRepository(_ folder: URL) -> Bool {
        Shell.run(git, ["-C", folder.path, "rev-parse", "--git-dir"], environment: env, timeout: 10).ok
    }

    /// Fetches all remotes. False when offline or not allowed.
    @discardableResult
    public static func fetch(_ repo: URL, timeout: TimeInterval = 60) -> Bool {
        Shell.run(git, ["-C", repo.path, "fetch", "--all", "--quiet", "--prune"], environment: env, timeout: timeout).ok
    }

    public static func state(_ repo: URL) -> State {
        let out = Shell.run(git, ["-C", repo.path, "for-each-ref", "--format=%(refname) %(objectname)", "refs/remotes"], environment: env, timeout: 15)
        var refs: [String: String] = [:]
        for line in out.text.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count == 2, !parts[0].hasSuffix("/HEAD") else { continue }
            refs[String(parts[0])] = String(parts[1])
        }
        return State(refs: refs)
    }

    /// What arrived between two states.
    public static func changes(_ repo: URL, from old: State, to new: State, limit: Int = 50) -> [Change] {
        let known = Set(old.refs.values)
        var result: [Change] = []
        for (ref, sha) in new.refs.sorted(by: { $0.key < $1.key }) where old.refs[ref] != sha {
            var args = ["-C", repo.path, "log", "--format=%H%x09%s", "-n", String(limit), sha]
            if !known.isEmpty { args += ["--not"] + Array(known) }
            let log = Shell.run(git, args, environment: env, timeout: 20)
            let commits = log.text.split(separator: "\n").compactMap { line -> Commit? in
                let parts = line.split(separator: "\t", maxSplits: 1)
                guard let first = parts.first else { return nil }
                return Commit(sha: String(first), subject: parts.count > 1 ? String(parts[1]) : "")
            }
            guard !commits.isEmpty else { continue } // moved backwards or to a known commit
            var base = old.refs[ref]
            if base == nil, let oldest = commits.last {
                let parent = Shell.run(git, ["-C", repo.path, "rev-parse", "-q", "--verify", "\(oldest.sha)^"], environment: env)
                base = parent.ok ? parent.text.trimmingCharacters(in: .whitespacesAndNewlines) : nil
            }
            result.append(Change(ref: ref, from: old.refs[ref], to: sha, commits: commits, base: base))
        }
        return result
    }

    public static func diffStat(_ repo: URL, from: String?, to: String) -> CodeSnapshots.DiffStat {
        let out = Shell.run(git, ["-C", repo.path, "diff", "--numstat", "--no-renames", from ?? CodeSnapshots.emptyTree, to], environment: env, timeout: 30)
        var stat = CodeSnapshots.DiffStat()
        for line in out.text.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 2)
            guard parts.count == 3 else { continue }
            stat.insertions += Int(parts[0]) ?? 0
            stat.deletions += Int(parts[1]) ?? 0
            stat.files.append(String(parts[2]))
        }
        return stat
    }

    public static func diff(_ repo: URL, from: String?, to: String, limit: Int = 400_000) -> String {
        let text = Shell.run(git, ["-C", repo.path, "diff", "--no-color", "--no-renames", "-U3", from ?? CodeSnapshots.emptyTree, to], environment: env, timeout: 30).text
        return text.count > limit ? String(text.prefix(limit)) + "\n… (diff truncated)" : text
    }

    public static func export(_ repo: URL, commit: String, to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let tar = FileManager.default.temporaryDirectory.appendingPathComponent("margin-\(UUID().uuidString).tar")
        defer { try? FileManager.default.removeItem(at: tar) }
        let archive = Shell.run(git, ["-C", repo.path, "archive", "--format=tar", "-o", tar.path, commit], environment: env, timeout: 60)
        guard archive.ok else { throw CodeSnapshots.SnapshotError.git(archive.stderr) }
        let untar = Shell.run("/usr/bin/tar", ["-xf", tar.path, "-C", destination.path])
        guard untar.ok else { throw CodeSnapshots.SnapshotError.git("tar: \(untar.stderr)") }
    }
}
