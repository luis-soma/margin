import Foundation

/// Serves copied sites to the browser from Margin itself: one small server
/// per site, on 127.0.0.1, while Margin runs. Unlike file://, JS modules,
/// fetch() of local files and root paths like /style.css all work, and
/// nothing needs to be installed.
public final class SiteServer {
    private var servers: [String: (server: HookServer, port: UInt16)] = [:]
    private let lock = NSLock()

    public init() {}

    /// The address of `page` inside `folder`, starting a server for the folder if needed.
    public func url(for folder: URL, page: String) throws -> URL {
        let root = folder.standardizedFileURL.resolvingSymlinksInPath()
        let key = root.path
        if let existing = lock.withLock({ servers[key] }) { return Self.address(port: existing.port, page: page) }
        let server = HookServer(router: { request in Self.serve(request, root: root) })
        let port = try server.start(ports: Array<UInt16>(4300...4399))
        lock.withLock { servers[key] = (server, port) }
        return Self.address(port: port, page: page)
    }

    static func address(port: UInt16, page: String) -> URL {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(port)
        components.path = "/" + page
        return components.url ?? URL(string: "http://127.0.0.1:\(port)/")!
    }

    static func serve(_ request: HookServer.Request, root: URL) -> HookServer.Response {
        guard request.method == "GET" || request.method == "HEAD" else {
            return HookServer.Response(status: 404, body: Data("Not found".utf8), contentType: "text/plain")
        }
        var path = request.path
        if path.isEmpty || path.hasSuffix("/") { path += "index.html" }
        var file = root.appendingPathComponent(String(path.drop(while: { $0 == "/" }))).standardizedFileURL
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), isDirectory.boolValue {
            file = file.appendingPathComponent("index.html")
        }
        // Only files inside this site, never ../ or a link out of it.
        let resolved = file.resolvingSymlinksInPath().path
        guard resolved.hasPrefix(root.path + "/"), let data = try? Data(contentsOf: URL(fileURLWithPath: resolved)) else {
            return HookServer.Response(status: 404, body: Data("Not found".utf8), contentType: "text/plain")
        }
        return HookServer.Response(status: 200, body: request.method == "HEAD" ? Data() : data, contentType: contentType(for: file.pathExtension))
    }

    static func contentType(for ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "js", "mjs", "cjs": return "text/javascript; charset=utf-8"
        case "json", "map": return "application/json; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "avif": return "image/avif"
        case "ico": return "image/x-icon"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        case "mp4", "m4v": return "video/mp4"
        case "webm": return "video/webm"
        case "mov": return "video/quicktime"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "txt", "md": return "text/plain; charset=utf-8"
        case "xml": return "application/xml"
        case "pdf": return "application/pdf"
        case "wasm": return "application/wasm"
        default: return "application/octet-stream"
        }
    }
}
