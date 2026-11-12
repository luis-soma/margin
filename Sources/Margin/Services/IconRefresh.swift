import AppKit
import MarginKit

/// On the first launch of each new build, Margin re-registers itself with
/// Launch Services and drops the build copy from the registry, so the Dock and
/// Finder show the installed app's icon. (It used to restart Notification
/// Center too, for notification icons; Margin sends no notifications now, and
/// the restart made the screen flash.)
enum IconRefresh {
    private static let key = "iconRefreshedForCommit"
    private static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    static func runIfNeeded() {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else { return }
        let commit = Bundle.main.url(forResource: "commit", withExtension: nil)
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
        let version = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let stamp = "\(commit)-\(version)"
        guard UserDefaults.standard.string(forKey: key) != stamp else { return }
        UserDefaults.standard.set(stamp, forKey: key)

        let hasCatalog = Bundle.main.url(forResource: "Assets", withExtension: "car") != nil
        MarginLog.info("Icon refresh for build \(version): asset catalog \(hasCatalog ? "yes" : "no"), \(bundle.path)")

        // The copy in the repo's build folder has the same bundle ID; keep
        // macOS looking at the one that's running.
        var stale: [String] = []
        if let repoPath = Bundle.main.url(forResource: "repo-path", withExtension: nil)
            .flatMap({ try? String(contentsOf: $0, encoding: .utf8) })?
            .trimmingCharacters(in: .whitespacesAndNewlines), !repoPath.isEmpty {
            let buildCopy = URL(fileURLWithPath: repoPath).appendingPathComponent("build/Margin.app").standardizedFileURL
            if buildCopy.path != bundle.standardizedFileURL.path { stale.append(buildCopy.path) }
        }

        DispatchQueue.global(qos: .utility).async {
            for path in stale { run(lsregister, ["-u", path]) }
            run(lsregister, ["-f", bundle.path])
        }
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) -> Int32 {
        let output = Shell.run(tool, arguments, timeout: 20)
        if output.status != 0 {
            MarginLog.info("Icon refresh: \((tool as NSString).lastPathComponent) \(arguments.joined(separator: " ")) exited \(output.status) \(output.stderr.prefix(200))")
        }
        return output.status
    }
}
