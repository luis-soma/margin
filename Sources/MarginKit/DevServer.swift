import Darwin
import Foundation

/// Finds the local web server a project runs on (npm run dev and friends),
/// so Margin can picture the app after every iteration.
public enum DevServer {
    /// Local URLs in text, e.g. "Local: http://localhost:5173/" from a dev
    /// server's output. 0.0.0.0 and [::1] become localhost.
    public static func urls(in text: String) -> [URL] {
        let pattern = #"https?://(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\]):(\d{2,5})(/[^\s"'`<>)\]]*)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        var seen = Set<String>()
        var urls: [URL] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let port = ns.substring(with: match.range(at: 1))
            var path = match.range(at: 2).location == NSNotFound ? "/" : ns.substring(with: match.range(at: 2))
            path = path.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))
            if path.isEmpty { path = "/" }
            let string = "http://localhost:\(port)\(path)"
            guard !seen.contains(string), let url = URL(string: string) else { continue }
            seen.insert(string)
            urls.append(url)
        }
        return urls
    }

    /// True if something accepts connections on this local port.
    public static func isListening(port: Int) -> Bool {
        for family in [AF_INET, AF_INET6] {
            let fd = socket(family, SOCK_STREAM, 0)
            guard fd >= 0 else { continue }
            defer { close(fd) }
            var result: Int32 = -1
            if family == AF_INET {
                var address = sockaddr_in()
                address.sin_family = sa_family_t(AF_INET)
                address.sin_port = in_port_t(UInt16(port).bigEndian)
                address.sin_addr.s_addr = inet_addr("127.0.0.1")
                result = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
            } else {
                var address = sockaddr_in6()
                address.sin6_family = sa_family_t(AF_INET6)
                address.sin6_port = in_port_t(UInt16(port).bigEndian)
                address.sin6_addr = in6addr_loopback
                result = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
                }
            }
            if result == 0 { return true }
        }
        return false
    }

    /// Local web servers started from inside `root` (their working folder is
    /// in the project), lowest port first. Works for servers Claude started
    /// and ones you started yourself.
    public static func listening(under root: URL, excludingPorts excluded: Set<Int> = []) -> [URL] {
        let lsof = "/usr/sbin/lsof"
        let listeners = Shell.run(lsof, ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpn"], timeout: 10)
        guard listeners.ok || !listeners.stdout.isEmpty else { return [] }
        var portsByPID: [Int32: Set<Int>] = [:]
        var pid: Int32 = 0
        for line in listeners.text.split(separator: "\n") {
            if line.hasPrefix("p") {
                pid = Int32(line.dropFirst()) ?? 0
            } else if line.hasPrefix("n"), let colon = line.lastIndex(of: ":"), let port = Int(line[line.index(after: colon)...]) {
                portsByPID[pid, default: []].insert(port)
            }
        }
        guard !portsByPID.isEmpty else { return [] }

        let pids = portsByPID.keys.map(String.init).joined(separator: ",")
        let cwds = Shell.run(lsof, ["-a", "-d", "cwd", "-p", pids, "-Fpn"], timeout: 10)
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        var ports = Set<Int>()
        pid = 0
        for line in cwds.text.split(separator: "\n") {
            if line.hasPrefix("p") {
                pid = Int32(line.dropFirst()) ?? 0
            } else if line.hasPrefix("n") {
                let cwd = URL(fileURLWithPath: String(line.dropFirst())).standardizedFileURL.resolvingSymlinksInPath().path
                if cwd == rootPath || cwd.hasPrefix(rootPath + "/") {
                    ports.formUnion(portsByPID[pid] ?? [])
                }
            }
        }
        return ports.subtracting(excluded).sorted().compactMap { URL(string: "http://localhost:\($0)/") }
    }

    /// The URL to picture: one Claude or the dev server printed, if it's up,
    /// else a server running from the project folder.
    public static func best(mentioned: [URL], root: URL, excludingPorts excluded: Set<Int> = []) -> URL? {
        for url in mentioned.reversed() {
            if let port = url.port, !excluded.contains(port), isListening(port: port) { return url }
        }
        return listening(under: root, excludingPorts: excluded).first
    }

    /// A free local port, starting at `preferred`.
    public static func freePort(from preferred: Int = 4100) -> Int {
        for port in preferred..<(preferred + 400) where !isListening(port: port) {
            return port
        }
        return preferred
    }
}
