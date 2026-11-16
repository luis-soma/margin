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
        automatic = false
        // Already built or downloaded in the background: put it in now.
        if let ready {
            installTimer?.invalidate()
            state = .installing
            installAndRelaunch(newApp: ready)
            return
        }
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
            if automatic {
                automatic = false
                state = .idle
                return
            }
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

        let built = repo.appendingPathComponent("build/Margin.app")
        if automatic {
            state = .idle
            installWhenQuiet(built)
        } else {
            state = .installing
            installAndRelaunch(newApp: built)
        }
    }

    /// Hands over to a helper that replaces this app once it has quit, then
    /// opens the new one. Margin quits right after.
    private func installAndRelaunch(newApp: URL, background: Bool = false) {
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
        if [ "$4" = "background" ]; then /usr/bin/open -g "$3" --args --background; else /usr/bin/open "$3"; fi
        """
        do {
            try script.write(to: helper, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            let quoted = [helper.path, String(pid), newApp.standardizedFileURL.path, destination.path, background ? "background" : "front"]
                .map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            process.arguments = ["-c", "nohup /bin/sh \(quoted.joined(separator: " ")) >> '\(logURL.path)' 2>&1 &"]
            try process.run()
            process.waitUntilExit()
        } catch {
            state = .failed("Couldn't install the update: \(error.localizedDescription)")
            return
        }
        MarginLog.info("Update \(background ? "installed quietly" : "built"); relaunching")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
    }

    private func fail(_ message: String, _ output: Shell.Output) {
        MarginLog.info("Update failed\(automatic ? " (automatic)" : ""): \(message)\n\(output.stderr.suffix(2000))")
        // An update you didn't ask for doesn't show its failure; the next
        // check tries again.
        if automatic {
            automatic = false
            state = .idle
        } else {
            state = .failed(message)
        }
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

    // MARK: Automatic updates

    /// Margin keeps itself current: on launch and every few hours it looks
    /// for a newer version. A copy built from the repo pulls and builds it;
    /// a downloaded copy fetches the newest release from GitHub. Either way
    /// it's put in place at a quiet moment (Margin not in front, nothing
    /// being captured or recorded) and Margin reopens in the menu bar.
    static let automaticKey = "updateAutomatically"
    static var isAutomatic: Bool {
        get { UserDefaults.standard.object(forKey: automaticKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: automaticKey) }
    }
    /// The public repository releases come from.
    static let releases = URL(string: "https://api.github.com/repos/luis-soma/margin/releases/latest")!

    /// Whether now is a good moment to swap the app; set by AppModel.
    var isQuiet: () -> Bool = { !NSApp.isActive }
    private var automatic = false
    private var ready: URL?
    private var checkTimer: Timer?
    private var installTimer: Timer?

    func startAutomatic() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.checkAutomatically() }
        checkTimer = Timer.scheduledTimer(withTimeInterval: 4 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkAutomatically() }
        }
    }

    func checkAutomatically() {
        guard Self.isAutomatic, !state.isBusy, ready == nil else { return }
        automatic = true
        if let repo {
            state = .checking
            Task { await run(repo) }
        } else {
            Task { await fetchRelease() }
        }
    }

    /// A downloaded copy: the newest release's disk image, if it's newer
    /// than this one, opened and its app copied out, ready to swap in.
    private func fetchRelease() async {
        defer { automatic = false }
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        var request = URLRequest(url: Self.releases, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else { return }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard Self.isNewer(version, than: current),
              let assets = json["assets"] as? [[String: Any]],
              let address = assets.first(where: { ($0["name"] as? String) == "Margin.dmg" })?["browser_download_url"] as? String,
              let url = URL(string: address) else { return }
        MarginLog.info("Update: Margin \(version) is out (this is \(current)); downloading")
        guard let (file, _) = try? await URLSession.shared.download(from: url) else {
            return MarginLog.info("Update: the download didn't finish")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("margin-update-\(version)", isDirectory: true)
        let app = await Task.detached { () -> URL? in
            let fm = FileManager.default
            try? fm.removeItem(at: folder)
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let dmg = folder.appendingPathComponent("Margin.dmg")
            let mount = folder.appendingPathComponent("mount")
            try? fm.moveItem(at: file, to: dmg)
            guard Shell.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-quiet", "-mountpoint", mount.path, dmg.path], timeout: 120).ok else { return nil }
            defer { Shell.run("/usr/bin/hdiutil", ["detach", "-quiet", mount.path], timeout: 60) }
            let copy = folder.appendingPathComponent("Margin.app")
            guard Shell.run("/usr/bin/ditto", [mount.appendingPathComponent("Margin.app").path, copy.path], timeout: 300).ok else { return nil }
            return copy
        }.value
        guard let app, let bundle = Bundle(url: app), bundle.bundleIdentifier == Bundle.main.bundleIdentifier else {
            return MarginLog.info("Update: the disk image didn't hold Margin")
        }
        installWhenQuiet(app)
    }

    /// Swaps the new version in at the first quiet moment, checking every
    /// half minute.
    private func installWhenQuiet(_ app: URL) {
        ready = app
        MarginLog.info("Update ready; it goes in when Margin isn't in use")
        installTimer?.invalidate()
        installTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, let ready = self.ready, self.isQuiet(), !self.state.isBusy else { return }
                timer.invalidate()
                self.state = .installing
                self.installAndRelaunch(newApp: ready, background: true)
            }
        }
    }

    /// "0.5.0" is newer than "0.4.10"? Compares number by number.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    func showLog() {
        NSWorkspace.shared.open(FileManager.default.fileExists(atPath: logURL.path) ? logURL : MarginLog.url)
    }
}
