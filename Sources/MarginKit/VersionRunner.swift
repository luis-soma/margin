import Foundation

/// Runs an old version of a project on localhost so you can click through
/// it: a web app's dev server, or a static site served as-is.
public final class VersionRunner {
    public enum Kind: Equatable {
        /// package.json with a dev/start script, run with the project's package manager.
        case node(manager: String, script: String)
        /// Plain HTML: served from `folder` (relative path, "" for the root).
        case staticSite(folder: String)
        /// Nothing Margin knows how to run.
        case unknown
    }

    public struct Running {
        public let directory: URL
        public let port: Int
        public let process: Process
        public let log: URL
        public var url: URL { URL(string: "http://localhost:\(port)/")! }
    }

    public enum RunError: Error, CustomStringConvertible {
        case notRunnable
        case failedToStart(String)
        public var description: String {
            switch self {
            case .notRunnable: return "Margin doesn't know how to run this project."
            case .failedToStart(let why): return why
            }
        }
    }

    private var running: [String: Running] = [:]
    private let lock = NSLock()

    public init() {}

    // MARK: What is it

    public static func detect(_ dir: URL) -> Kind {
        let fm = FileManager.default
        let packageURL = dir.appendingPathComponent("package.json")
        if let data = try? Data(contentsOf: packageURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let scripts = json["scripts"] as? [String: String] {
            if let script = ["dev", "start", "serve", "preview"].first(where: { scripts[$0] != nil }) {
                return .node(manager: packageManager(dir), script: script)
            }
        }
        if fm.fileExists(atPath: dir.appendingPathComponent("index.html").path) { return .staticSite(folder: "") }
        for folder in ["public", "site", "docs", "www", "src"] where fm.fileExists(atPath: dir.appendingPathComponent("\(folder)/index.html").path) {
            return .staticSite(folder: folder)
        }
        return .unknown
    }

    static func packageManager(_ dir: URL) -> String {
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.appendingPathComponent("pnpm-lock.yaml").path) { return "pnpm" }
        if fm.fileExists(atPath: dir.appendingPathComponent("yarn.lock").path) { return "yarn" }
        if fm.fileExists(atPath: dir.appendingPathComponent("bun.lockb").path) || fm.fileExists(atPath: dir.appendingPathComponent("bun.lock").path) { return "bun" }
        return "npm"
    }

    /// The shell command that starts the version on `port`.
    public static func command(for kind: Kind, port: Int) -> String? {
        switch kind {
        case .node(let manager, let script):
            let env = "PORT=\(port) BROWSER=none"
            switch manager {
            case "npm": return "\(env) exec npm run \(script) -- --port \(port)"
            case "bun": return "\(env) exec bun run \(script) --port \(port)"
            default: return "\(env) exec \(manager) run \(script) --port \(port)"
            }
        case .staticSite:
            return "exec /usr/bin/python3 -m http.server \(port) --bind 127.0.0.1"
        case .unknown:
            return nil
        }
    }

    // MARK: Running

    /// Starts the version in `directory`. Dependencies and .env files are
    /// borrowed from the live project (`original`), since versions don't
    /// keep them. Returns once the server answers.
    public func start(directory: URL, original: URL, timeout: TimeInterval = 90) async throws -> Running {
        if let existing = lock.withLock({ running[directory.path] }), existing.process.isRunning {
            return existing
        }
        let kind = Self.detect(directory)
        var workDir = directory
        if case .staticSite(let folder) = kind, !folder.isEmpty { workDir = directory.appendingPathComponent(folder) }
        let port = DevServer.freePort(from: 4100)
        guard let command = Self.command(for: kind, port: port) else { throw RunError.notRunnable }

        if case .node = kind { Self.borrowDependencies(into: directory, from: original) }

        let log = directory.appendingPathComponent(".margin-run.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // A login shell finds node, npm, pnpm… where the user installed them.
        process.arguments = ["-lc", "cd \(Self.quote(workDir.path)) && \(command)"]
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw RunError.failedToStart("Couldn't start: \(error.localizedDescription)")
        }

        // Ready when our port answers, or when the log names another local URL
        // (some tools ignore --port).
        let deadline = Date().addingTimeInterval(timeout)
        var readyPort: Int?
        while Date() < deadline {
            if DevServer.isListening(port: port) { readyPort = port; break }
            if let text = try? String(contentsOf: log, encoding: .utf8),
               let other = DevServer.urls(in: text).compactMap(\.port).first(where: { DevServer.isListening(port: $0) }) {
                readyPort = other
                break
            }
            if !process.isRunning {
                let tail = (try? String(contentsOf: log, encoding: .utf8)).map { String($0.suffix(600)) } ?? ""
                throw RunError.failedToStart("The version stopped while starting.\n\(tail)")
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        guard let readyPort else {
            process.terminate()
            throw RunError.failedToStart("It didn't start within \(Int(timeout)) seconds.")
        }
        let result = Running(directory: directory, port: readyPort, process: process, log: log)
        lock.withLock { running[directory.path] = result }
        return result
    }

    public func isRunning(_ directory: URL) -> Running? {
        lock.withLock {
            guard let run = running[directory.path], run.process.isRunning else { return nil }
            return run
        }
    }

    public func stop(_ directory: URL) {
        guard let run = lock.withLock({ running.removeValue(forKey: directory.path) }) else { return }
        Self.terminate(run)
    }

    public func stopAll() {
        let all = lock.withLock { () -> [Running] in
            let values = Array(running.values)
            running.removeAll()
            return values
        }
        all.forEach(Self.terminate)
    }

    private static func terminate(_ run: Running) {
        run.process.terminate()
        // Dev servers often fork; also stop whatever still listens on the port.
        let pids = Shell.run("/usr/sbin/lsof", ["-t", "-iTCP:\(run.port)", "-sTCP:LISTEN"], timeout: 5).text
        for line in pids.split(separator: "\n") {
            if let pid = Int32(line), pid != ProcessInfo.processInfo.processIdentifier { kill(pid, SIGTERM) }
        }
    }

    /// Links node_modules and copies .env files from the live project.
    static func borrowDependencies(into directory: URL, from original: URL) {
        let fm = FileManager.default
        let modules = directory.appendingPathComponent("node_modules")
        let liveModules = original.appendingPathComponent("node_modules")
        if !fm.fileExists(atPath: modules.path), fm.fileExists(atPath: liveModules.path) {
            try? fm.createSymbolicLink(at: modules, withDestinationURL: liveModules)
        }
        for name in (try? fm.contentsOfDirectory(atPath: original.path)) ?? [] where name == ".env" || name.hasPrefix(".env.") {
            let target = directory.appendingPathComponent(name)
            if !fm.fileExists(atPath: target.path) {
                try? fm.copyItem(at: original.appendingPathComponent(name), to: target)
            }
        }
    }

    static func quote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
