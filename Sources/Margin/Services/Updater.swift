import AppKit
import MarginKit

/// Updates Margin from GitHub while it keeps running: fetch, build, then
/// swap the app and relaunch. Margin quits itself only once the new build
/// is ready, and a small helper waits for it to be gone before replacing
/// it, so an update never leaves the old version running.
@MainActor
final class Updater: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case building
        case installing
        case upToDate
        case failed(String)

        var isBusy: Bool { self == .checking || self == .building || self == .installing }
    }

    @Published private(set) var state: State = .idle {
        didSet { if state != oldValue { stageStarted = Date() } }
    }
    /// When the current state began, for the update pill's fill.
    private(set) var stageStarted = Date()
    /// How long the last build took on this Mac; the fill eases through that.
    private var expectedBuild: TimeInterval {
        let last = UserDefaults.standard.double(forKey: "lastBuildSeconds")
        return last > 5 ? last : 60
    }

    /// How far along the update is (0...1): checking, then the build measured
    /// against the last one, then restarting. Holds short of full until the
    /// build really finishes.
    func fraction(at date: Date = Date()) -> Double? {
        switch state {
        case .checking: return 0.06
        case .building:
            let elapsed = date.timeIntervalSince(stageStarted)
            return 0.1 + 0.8 * min(elapsed / expectedBuild, 1)
        case .installing: return 1
        default: return nil
        }
    }

    let logURL = MarginLog.url.deletingLastPathComponent().appendingPathComponent("update.log")

    /// The repository this app was built from (written by build-app.sh).
    private var repo: URL? {
        guard let url = Bundle.main.url(forResource: "repo-path", withExtension: nil),
              let path = try? String(contentsOf: url, encoding: .utf8).trimmed, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// The commit this app was built from.
    private var installedCommit: String? {
        Bundle.main.url(forResource: "commit", withExtension: nil)
            .flatMap { try? String(contentsOf: $0, encoding: .utf8).trimmed }
    }

    /// Where Update Margin pulls from: a branch on GitHub, "main" unless
    /// you set another in Settings (or with
    /// `defaults write com.svsd.margin updateBranch <branch>`).
    static let branchKey = "updateBranch"
    static let defaultBranch = "main"

    static var branch: String {
        get {
            let saved = UserDefaults.standard.string(forKey: branchKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return isValid(saved) ? saved : defaultBranch
        }
        set {
            let name = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty || name == defaultBranch {
                UserDefaults.standard.removeObject(forKey: branchKey)
            } else if isValid(name) {
                UserDefaults.standard.set(name, forKey: branchKey)
            }
        }
    }

    /// A plain branch name: letters, digits, "-", "_", "." and "/", not
    /// starting with "-". Anything else never reaches the shell.
    static func isValid(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("-"), !name.contains(".."), name.count <= 100 else { return false }
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./")
        return name.allSatisfy { allowed.contains($0) }
    }

    func update() {
        guard !state.isBusy else { return }
        guard let repo else {
            state = .failed("Margin doesn't know where its code is. Build it once with scripts/build-app.sh.")
            return
        }
        try? FileManager.default.removeItem(at: logURL)
        state = .checking
        Task { await run(repo) }
    }

    private func run(_ repo: URL) async {
        // The branch picked in Settings, or the team's main. With a branch
        // picked, the local copy moves onto it first, so the build and the
        // commit it records match what's on GitHub. Without one, as before:
        // main comes into whichever branch this copy is on.
        let branch = Self.branch
        let chosen = UserDefaults.standard.string(forKey: Self.branchKey) != nil && branch != Self.defaultBranch
        let fetch = await shell("git fetch --quiet origin && git rev-parse --verify --quiet origin/\(branch) >/dev/null", in: repo, timeout: 60)
        guard fetch.ok else {
            return fail("Couldn't find the branch \(branch) on GitHub. Check your connection, or the branch in Settings.", fetch)
        }
        let current = await shell("git rev-parse --abbrev-ref HEAD", in: repo, timeout: 30)
        if chosen, current.text.trimmingCharacters(in: .whitespacesAndNewlines) != branch {
            let move = await shell("git switch --quiet \(branch)", in: repo, timeout: 60)
            guard move.ok else {
                return fail("Couldn't switch your copy of the project to \(branch). In Terminal: cd \(repo.path) && git status", move)
            }
        }
        let heads = await shell("git rev-parse HEAD && git rev-parse origin/\(branch)", in: repo, timeout: 30)
        let lines = heads.text.split(separator: "\n").map(String.init)
        guard heads.ok, lines.count >= 2 else {
            return fail("Couldn't read the branch \(branch).", heads)
        }
        let local = lines[lines.count - 2]
        let upstream = lines[lines.count - 1]

        if local == upstream, upstream == installedCommit {
            state = .upToDate
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if state == .upToDate { state = .idle }
            return
        }
        if local != upstream {
            let merge = await shell("git merge --ff-only --quiet \(upstream)", in: repo, timeout: 60)
            guard merge.ok else {
                return fail("Your copy of the project has changes git can't update past. In Terminal: cd \(repo.path) && git status", merge)
            }
        }

        state = .building
        let build = await shell("MARGIN_BUILD_ONLY=1 scripts/build-app.sh", in: repo, timeout: 1200)
        if build.ok { UserDefaults.standard.set(Date().timeIntervalSince(stageStarted), forKey: "lastBuildSeconds") }
        guard build.ok else {
            let last = (build.stderr + "\n" + build.text).split(separator: "\n").last(where: { $0.contains("error") }).map(String.init)
            return fail("The build failed\(last.map { ": \($0)" } ?? ""). See the update log.", build)
        }

        state = .installing
        installAndRelaunch(newApp: repo.appendingPathComponent("build/Margin.app"))
    }

    /// Hands over to a helper that replaces this app once it has quit, then
    /// opens the new one. Margin quits right after.
    private func installAndRelaunch(newApp: URL) {
        let running = Bundle.main.bundleURL.standardizedFileURL
        let destination = running.pathExtension == "app" ? running : URL(fileURLWithPath: "/Applications/Margin.app")
        let pid = ProcessInfo.processInfo.processIdentifier
        let helper = FileManager.default.temporaryDirectory.appendingPathComponent("margin-install.sh")
        let script = """
        #!/bin/sh
        # Waits for Margin (pid $1) to quit, swaps in the new build, opens it.
        for i in $(seq 1 100); do kill -0 "$1" 2>/dev/null || break; sleep 0.1; done
        kill -9 "$1" 2>/dev/null
        if [ "$2" != "$3" ]; then
          rm -rf "$3" && /usr/bin/ditto "$2" "$3" || exit 1
          # One copy of Margin: the build goes once it's installed.
          rm -rf "$2"
        fi
        /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$3" >/dev/null 2>&1
        /usr/bin/open "$3"
        """
        do {
            try script.write(to: helper, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            let quoted = [helper.path, String(pid), newApp.standardizedFileURL.path, destination.path]
                .map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            process.arguments = ["-c", "nohup /bin/sh \(quoted.joined(separator: " ")) >> '\(logURL.path)' 2>&1 &"]
            try process.run()
            process.waitUntilExit()
        } catch {
            state = .failed("Couldn't install the update: \(error.localizedDescription)")
            return
        }
        MarginLog.info("Update built; relaunching")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
    }

    private func fail(_ message: String, _ output: Shell.Output) {
        MarginLog.info("Update failed: \(message)\n\(output.stderr.suffix(2000))")
        state = .failed(message)
    }

    /// Runs a command in a login shell (so git and swift are found), logging its output.
    private func shell(_ command: String, in directory: URL, timeout: TimeInterval) async -> Shell.Output {
        let log = logURL
        return await Task.detached {
            let output = Shell.run("/bin/zsh", ["-lc", "cd '\(directory.path)' && \(command)"], timeout: timeout)
            let entry = "$ \(command)\n\(output.text)\(output.stderr)\n(exit \(output.status))\n\n"
            if let handle = try? FileHandle(forWritingTo: log) {
                handle.seekToEndOfFile()
                handle.write(Data(entry.utf8))
                try? handle.close()
            } else {
                try? entry.write(to: log, atomically: true, encoding: .utf8)
            }
            return output
        }.value
    }

    func showLog() {
        NSWorkspace.shared.open(FileManager.default.fileExists(atPath: logURL.path) ? logURL : MarginLog.url)
    }
}
