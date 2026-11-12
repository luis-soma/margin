import Foundation

/// A minimal Model Context Protocol client over Streamable HTTP, enough to
/// talk to Figma's desktop MCP server (http://127.0.0.1:3845/mcp):
/// initialize, list tools, call a tool. Responses may come back as plain
/// JSON or as a Server-Sent Events stream; both are handled.
public final class MCPClient {
    public struct Tool: Equatable, Sendable {
        public let name: String
        public let properties: Set<String>
        public let required: Set<String>
    }

    public struct ToolResult {
        public var texts: [String] = []
        /// Decoded image payloads with their MIME types.
        public var images: [(data: Data, mimeType: String)] = []
        /// URIs from resource links.
        public var links: [String] = []
        public var isError = false

        /// All text joined, for logs and parsing.
        public var text: String { texts.joined(separator: "\n") }
    }

    public enum MCPError: Error, CustomStringConvertible, Equatable {
        /// Nothing listening, e.g. Figma closed or its MCP server switched off.
        case unreachable(String)
        case http(Int, String)
        case rpc(Int, String)
        case badResponse(String)

        public var description: String {
            switch self {
            case .unreachable(let message): return "not reachable (\(message))"
            case .http(let code, let body): return "HTTP \(code) \(body.prefix(200))"
            case .rpc(let code, let message): return "error \(code): \(message)"
            case .badResponse(let message): return "unexpected response: \(message)"
            }
        }
    }

    public static let figmaDesktop = URL(string: "http://127.0.0.1:3845/mcp")!
    public static let protocolVersion = "2025-06-18"

    public let endpoint: URL
    private let session: URLSession
    private var sessionID: String?
    private var negotiatedVersion: String?
    private var nextID = 1
    public private(set) var serverName: String?
    public private(set) var tools: [Tool] = []

    public init(endpoint: URL = MCPClient.figmaDesktop, session: URLSession? = nil) {
        self.endpoint = endpoint
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.connectionProxyDictionary = [:] // never send localhost through a proxy
            config.timeoutIntervalForRequest = 20
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: Lifecycle

    /// Opens a session and loads the tool list.
    @discardableResult
    public func connect(timeout: TimeInterval = 3) async throws -> [Tool] {
        let result = try await request("initialize", params: [
            "protocolVersion": Self.protocolVersion,
            "capabilities": [String: Any](),
            "clientInfo": ["name": "Margin", "version": "0.4"],
        ], timeout: timeout)
        negotiatedVersion = result["protocolVersion"] as? String
        serverName = (result["serverInfo"] as? [String: Any])?["name"] as? String
        try await notify("notifications/initialized")
        let list = try await request("tools/list", params: [:], timeout: timeout)
        tools = (list["tools"] as? [[String: Any]] ?? []).compactMap(Self.tool)
        return tools
    }

    public func tool(named names: String...) -> Tool? {
        for name in names {
            if let tool = tools.first(where: { $0.name == name }) { return tool }
        }
        return nil
    }

    public func call(_ name: String, arguments: [String: Any], timeout: TimeInterval = 30) async throws -> ToolResult {
        let result = try await request("tools/call", params: ["name": name, "arguments": arguments], timeout: timeout)
        return Self.toolResult(result)
    }

    // MARK: Parsing (static so tests can use them directly)

    static func tool(_ json: [String: Any]) -> Tool? {
        guard let name = json["name"] as? String else { return nil }
        let schema = json["inputSchema"] as? [String: Any] ?? [:]
        let properties = Set((schema["properties"] as? [String: Any] ?? [:]).keys)
        let required = Set(schema["required"] as? [String] ?? [])
        return Tool(name: name, properties: properties, required: required)
    }

    static func toolResult(_ json: [String: Any]) -> ToolResult {
        var result = ToolResult()
        result.isError = json["isError"] as? Bool ?? false
        for item in json["content"] as? [[String: Any]] ?? [] {
            switch item["type"] as? String {
            case "text":
                if let text = item["text"] as? String { result.texts.append(text) }
            case "image":
                if let base64 = item["data"] as? String, let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) {
                    result.images.append((data, item["mimeType"] as? String ?? "image/png"))
                }
            case "resource":
                let resource = item["resource"] as? [String: Any] ?? [:]
                let mime = resource["mimeType"] as? String ?? ""
                if let blob = resource["blob"] as? String, mime.hasPrefix("image/"),
                   let data = Data(base64Encoded: blob, options: .ignoreUnknownCharacters) {
                    result.images.append((data, mime))
                } else if let text = resource["text"] as? String {
                    result.texts.append(text)
                } else if let uri = resource["uri"] as? String {
                    result.links.append(uri)
                }
            case "resource_link":
                if let uri = item["uri"] as? String { result.links.append(uri) }
            default:
                break
            }
        }
        return result
    }

    /// Finds the JSON-RPC response with this id in a body that is either JSON
    /// (object or batch array) or an SSE stream.
    static func response(id: Int, in body: Data, contentType: String) throws -> [String: Any]? {
        if contentType.lowercased().contains("text/event-stream") {
            let text = String(decoding: body, as: UTF8.self)
            for event in sseEvents(text) {
                if let message = try matching(id: id, json: Data(event.utf8)) { return message }
            }
            return nil
        }
        return try matching(id: id, json: body)
    }

    /// The data payloads of the events in an SSE stream.
    static func sseEvents(_ text: String) -> [String] {
        var events: [String] = []
        var data: [String] = []
        for rawLine in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if rawLine.isEmpty {
                if !data.isEmpty { events.append(data.joined(separator: "\n")) }
                data = []
            } else if rawLine.hasPrefix("data:") {
                var value = String(rawLine.dropFirst(5))
                if value.hasPrefix(" ") { value.removeFirst() }
                data.append(value)
            }
        }
        if !data.isEmpty { events.append(data.joined(separator: "\n")) }
        return events
    }

    private static func matching(id: Int, json: Data) throws -> [String: Any]? {
        guard let object = try? JSONSerialization.jsonObject(with: json) else { return nil }
        let messages: [[String: Any]]
        if let one = object as? [String: Any] {
            messages = [one]
        } else if let many = object as? [[String: Any]] {
            messages = many
        } else {
            return nil
        }
        for message in messages {
            guard let messageID = message["id"], idMatches(messageID, id) else { continue }
            if let error = message["error"] as? [String: Any] {
                throw MCPError.rpc(error["code"] as? Int ?? 0, error["message"] as? String ?? "unknown")
            }
            return message["result"] as? [String: Any] ?? [:]
        }
        return nil
    }

    private static func idMatches(_ value: Any, _ id: Int) -> Bool {
        if let number = value as? Int { return number == id }
        if let number = value as? NSNumber { return number.intValue == id }
        if let string = value as? String { return string == String(id) }
        return false
    }

    // MARK: Transport

    private func request(_ method: String, params: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        let id = nextID
        nextID += 1
        let body: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        let (data, response) = try await post(body, timeout: timeout)
        guard let http = response as? HTTPURLResponse else { throw MCPError.badResponse("no HTTP response") }
        if let session = http.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionID = session }
        guard (200..<300).contains(http.statusCode) else {
            throw MCPError.http(http.statusCode, String(decoding: data, as: UTF8.self))
        }
        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        guard let result = try Self.response(id: id, in: data, contentType: contentType) else {
            throw MCPError.badResponse("no reply to \(method): \(String(decoding: data.prefix(200), as: UTF8.self))")
        }
        return result
    }

    private func notify(_ method: String) async throws {
        let (_, response) = try await post(["jsonrpc": "2.0", "method": method], timeout: 3)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw MCPError.http(http.statusCode, "notification \(method) rejected")
        }
    }

    private func post(_ body: [String: Any], timeout: TimeInterval) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        if let negotiatedVersion { request.setValue(negotiatedVersion, forHTTPHeaderField: "MCP-Protocol-Version") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        do {
            return try await readResponse(request)
        } catch let error as URLError {
            throw MCPError.unreachable(error.localizedDescription)
        }
    }

    /// Reads the body as it streams in. An SSE stream may stay open after the
    /// reply, so stop as soon as an event carrying the reply has arrived.
    private func readResponse(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        let contentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
        var data = Data()
        guard contentType.lowercased().contains("text/event-stream") else {
            for try await byte in bytes { data.append(byte) }
            return (data, response)
        }
        let id = request.httpBody
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .flatMap { $0["id"] as? Int }
        var lineLength = 0
        var eventStart = 0
        for try await byte in bytes {
            data.append(byte)
            if byte == UInt8(ascii: "\n") {
                if lineLength == 0 || (lineLength == 1 && data[data.count - 2] == UInt8(ascii: "\r")) {
                    // A blank line ends an event.
                    if let id, Self.containsReply(id: id, event: data[eventStart...]) {
                        bytes.task.cancel()
                        break
                    }
                    eventStart = data.count
                }
                lineLength = 0
            } else {
                lineLength += 1
            }
        }
        return (data, response)
    }

    static func containsReply(id: Int, event: Data) -> Bool {
        for payload in sseEvents(String(decoding: event, as: UTF8.self)) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) else { continue }
            let messages = (object as? [[String: Any]]) ?? [(object as? [String: Any]) ?? [:]]
            if messages.contains(where: { $0["id"].map { idMatches($0, id) } ?? false }) { return true }
        }
        return false
    }
}
