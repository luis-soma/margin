import Foundation
import Network

/// A tiny HTTP server on 127.0.0.1 that receives events from coding agents
/// (Claude Code hooks post their JSON here). Answers every request right
/// away with 200, so the agent is never slowed down.
public final class HookServer {
    public typealias Handler = (_ path: String, _ body: Data) -> Void

    public struct Request {
        public let method: String
        /// Path without the query, e.g. "/figma/poll".
        public let path: String
        public let query: [String: String]
        public let body: Data
    }

    public struct Response {
        public var status: Int
        public var body: Data
        public var contentType: String

        public init(status: Int = 200, body: Data = Data(), contentType: String = "application/json") {
            self.status = status
            self.body = body
            self.contentType = contentType
        }

        public static let ok = Response()

        public static func json(_ object: Any) -> Response {
            Response(body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8))
        }
    }

    /// Answers a request. Runs on the server's queue, so keep it quick.
    public typealias Router = (Request) -> Response

    /// Answers a request later: return true and call `reply` once, from any
    /// thread (a request held open until there's something to say). False
    /// passes the request on to the router.
    public typealias Deferred = (_ request: Request, _ reply: @escaping (Response) -> Void) -> Bool
    public var deferred: Deferred?

    public private(set) var port: UInt16 = 0
    private var listener: NWListener?
    private var listenerV6: NWListener?
    private let queue = DispatchQueue(label: "margin.hooks")
    private let router: Router

    /// Every request gets an empty 200; the handler sees path and body.
    public convenience init(handler: @escaping Handler) {
        self.init(router: { request in
            handler(request.path, request.body)
            return .ok
        })
    }

    public init(router: @escaping Router) {
        self.router = router
    }

    /// Starts on the first free port of `ports` (0 = any). Returns the port.
    @discardableResult
    public func start(ports: [UInt16]) throws -> UInt16 {
        var lastError: Error?
        for candidate in ports {
            do {
                let listener = try makeListener(host: .ipv4(.loopback), port: candidate)
                guard let actual = listener.port?.rawValue, actual != 0 else { throw NWError.posix(.EADDRINUSE) }
                self.listener = listener
                port = actual
                // "localhost" may resolve to ::1 first (the Figma plugin uses
                // localhost); listen there too when possible.
                listenerV6 = try? makeListener(host: .ipv6(.loopback), port: actual)
                return actual
            } catch {
                lastError = error
            }
        }
        throw lastError ?? NWError.posix(.EADDRINUSE)
    }

    /// Starts on every network interface (not just this Mac), on the first
    /// free port of `ports`, and announces itself with Bonjour as `service`
    /// so devices on the same Wi-Fi can find it. Returns the port.
    @discardableResult
    public func startOnNetwork(ports: [UInt16], service: NWListener.Service) throws -> UInt16 {
        var lastError: Error?
        for candidate in ports {
            do {
                let listener = try makeListener(host: nil, port: candidate, service: service)
                guard let actual = listener.port?.rawValue, actual != 0 else { throw NWError.posix(.EADDRINUSE) }
                self.listener = listener
                port = actual
                return actual
            } catch {
                lastError = error
            }
        }
        throw lastError ?? NWError.posix(.EADDRINUSE)
    }

    private func makeListener(host: NWEndpoint.Host?, port candidate: UInt16, service: NWListener.Service? = nil) throws -> NWListener {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let port = NWEndpoint.Port(rawValue: candidate) ?? .any
        if let host {
            parameters.requiredLocalEndpoint = .hostPort(host: host, port: port)
        }
        let listener = host == nil ? try NWListener(using: parameters, on: port) : try NWListener(using: parameters)
        listener.service = service
        let ready = DispatchSemaphore(value: 0)
        var failure: Error?
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed(let error): failure = error; ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return connection.cancel() }
            self.serve(connection)
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 3)
        if let failure {
            listener.cancel()
            throw failure
        }
        return listener
    }

    public func stop() {
        listener?.cancel()
        listenerV6?.cancel()
        listener = nil
        listenerV6 = nil
    }

    deinit {
        listener?.cancel()
        listenerV6?.cancel()
    }

    // MARK: HTTP

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Self.parse(buffer) {
                if request.method != "OPTIONS", let deferred = self.deferred {
                    let handled = deferred(request) { [weak self] response in
                        self?.queue.async { self?.respond(connection, response) }
                    }
                    if handled { return }
                }
                // Browsers (the Figma plugin) ask first whether they may post.
                let response = request.method == "OPTIONS" ? Response(status: 204) : self.router(request)
                self.respond(connection, response)
                return
            }
            if complete || error != nil || buffer.count > 400 << 20 {
                connection.cancel()
                return
            }
            self.receive(connection, buffer: buffer)
        }
    }

    private func respond(_ connection: NWConnection, _ response: Response) {
        let reason = [200: "OK", 204: "No Content", 404: "Not Found", 400: "Bad Request"][response.status] ?? "OK"
        let head = [
            "HTTP/1.1 \(response.status) \(reason)",
            "Content-Type: \(response.contentType)",
            "Content-Length: \(response.body.count)",
            // Local only, but the Figma plugin's page has no origin of its own.
            "Access-Control-Allow-Origin: *",
            "Access-Control-Allow-Methods: GET, POST, OPTIONS",
            "Access-Control-Allow-Headers: *",
            "Access-Control-Allow-Private-Network: true",
            "Connection: close",
        ].joined(separator: "\r\n") + "\r\n\r\n"
        connection.send(content: Data(head.utf8) + response.body, completion: .contentProcessed { _ in connection.cancel() })
    }

    /// A complete request (headers plus Content-Length bytes), or nil if more is needed.
    static func parse(_ data: Data) -> Request? {
        // Headers are small; only look for their end near the start.
        guard let headerEnd = data.prefix(65_536).range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[data.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        let method = requestLine.first.map(String.init) ?? "GET"
        let target = requestLine.count > 1 ? String(requestLine[1]) : "/"
        let components = URLComponents(string: target)
        let path = components?.path ?? target
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        var length = 0
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                length = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        let bodyStart = headerEnd.upperBound
        guard data.count - (bodyStart - data.startIndex) >= length else { return nil }
        return Request(method: method, path: path, query: query, body: Data(data[bodyStart..<(bodyStart + length)]))
    }
}
