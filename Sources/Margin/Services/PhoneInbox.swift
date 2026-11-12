import AppKit
import MarginKit
import Network
import SystemConfiguration

/// Photos shared from the iPhone (Photos → Share → Margin) arrive here, over
/// the Wi-Fi this Mac is on. Margin announces itself with Bonjour, the
/// phone's share sheet finds it, asks which projects there are, and sends the
/// photo with its annotation; it lands in the archive straight away.
///
/// - `GET /phone/hello`: this Mac's name, the projects, the open project.
/// - `POST /phone/photo`: `{project, note, image (base64 JPEG), name}`.
@MainActor
final class PhoneInbox {
    static let serviceType = "_margin._tcp"
    static let ports: [UInt16] = [47830, 47831, 47832, 47833]

    private let store: EntryStore
    private let onPhoto: (Entry) -> Void
    private var server: HookServer?

    init(store: EntryStore, onPhoto: @escaping (Entry) -> Void) {
        self.store = store
        self.onPhoto = onPhoto
    }

    func start() {
        let server = HookServer(router: { request in
            // The server's queue; the archive lives on the main thread.
            DispatchQueue.main.sync {
                MainActor.assumeIsolated { PhoneInbox.shared?.route(request) ?? Response(status: 404) }
            }
        })
        Self.shared = self
        let name = Host.current().localizedName ?? "Mac"
        // The phone talks to this Mac by its local name, e.g. Sarahs-MacBook-Pro.local.
        let host = (SCDynamicStoreCopyLocalHostName(nil) as String?).map { $0 + ".local" } ?? ProcessInfo.processInfo.hostName
        for port in Self.ports {
            let txt = NWTXTRecord(["host": host, "port": String(port)])
            let service = NWListener.Service(name: name, type: Self.serviceType, domain: nil, txtRecord: txt)
            if let actual = try? server.startOnNetwork(ports: [port], service: service) {
                MarginLog.info("Phone inbox on \(host):\(actual)")
                self.server = server
                return
            }
        }
        MarginLog.info("Phone inbox couldn't start")
    }

    private static weak var shared: PhoneInbox?
    private typealias Response = HookServer.Response

    private func route(_ request: HookServer.Request) -> Response {
        switch (request.method, request.path) {
        case ("GET", "/phone/hello"):
            let current = store.currentProject
            let others = store.projects.filter { $0 != current }
            return .json([
                "app": "Margin",
                "name": Host.current().localizedName ?? "Mac",
                "projects": [current] + others,
                "current": current,
                // Where to reach this Mac without Bonjour: networks like campus
                // Wi-Fi block devices from finding each other, but not from
                // connecting once the phone knows the address.
                "addresses": Self.addresses(),
                "port": Int(server?.port ?? 0),
            ])
        case ("POST", "/phone/photo"):
            return receivePhoto(request.body)
        case ("POST", "/phone/log"):
            MarginLog.info("Phone: " + String(decoding: request.body.prefix(2000), as: UTF8.self))
            return .ok
        default:
            return Response(status: 404)
        }
    }

    /// This Mac's IPv4 addresses on its networks (not loopback or the
    /// self-assigned ones a cable link gets).
    static func addresses() -> [String] {
        var result: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  entry.ifa_flags & UInt32(IFF_UP) != 0, entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            if !ip.hasPrefix("169.254.") { result.append(ip) }
        }
        return result
    }

    private func receivePhoto(_ body: Data) -> Response {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let encoded = json["image"] as? String,
              let image = Data(base64Encoded: encoded), NSImage(data: image) != nil else {
            return Response(status: 400)
        }
        let project = (json["project"] as? String)?.trimmed ?? ""
        var entry = Entry(kind: .capture, project: project.isEmpty ? store.currentProject : project)
        entry.imageFile = store.saveFile(image, ext: "jpg")
        guard entry.imageFile != nil else { return Response(status: 400) }
        entry.rationale = (json["note"] as? String)?.trimmed ?? ""
        entry.sourceApp = "iPhone"
        entry.label = (json["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        store.add(entry)
        onPhoto(entry)
        MarginLog.info("Photo from iPhone saved to \(entry.project)")
        return .json(["ok": true, "project": entry.project])
    }
}
