import Foundation

/// A frame exported from Figma.
public struct FigmaExport {
    public var image: Data
    public var node: FigmaNodeInfo
    /// "desktop MCP" or "REST API", for logs and the card.
    public var via: String
    /// The frame has animation (Figma's motion timeline).
    public var hasMotion = false
    /// The animation rendered by Figma as an MP4, when the server can.
    public var video: Data?
    /// Something worth telling the designer, e.g. why there's no video.
    public var note: String?
    /// More frames selected at the same time, each exported on its own.
    /// Saved together as one capture.
    public var others: [FigmaExport] = []

    public init(image: Data, node: FigmaNodeInfo, via: String, hasMotion: Bool = false, video: Data? = nil) {
        self.image = image
        self.node = node
        self.via = via
        self.hasMotion = hasMotion
        self.video = video
    }
}

public enum FigmaExportError: Error, CustomStringConvertible, Equatable {
    /// Nothing is selected in Figma (or only a page).
    case noSelection
    /// The export path isn't available, e.g. MCP server off or no token.
    case unavailable(String)
    case failed(String)

    public var description: String {
        switch self {
        case .noSelection: return "nothing selected"
        case .unavailable(let reason): return reason
        case .failed(let reason): return reason
        }
    }
}

/// Exports the selected frame through Figma's desktop MCP server. Needs the
/// Figma desktop app with "Enable desktop MCP server" switched on (Dev Mode,
/// right sidebar). Works without a link: the server knows the selection.
public struct FigmaDesktopExporter {
    public var endpoint: URL
    /// Longest edge of the exported PNG.
    public var maxDimension: Int
    public var session: URLSession?

    public init(endpoint: URL = MCPClient.figmaDesktop, maxDimension: Int = 2400, session: URLSession? = nil) {
        self.endpoint = endpoint
        self.maxDimension = maxDimension
        self.session = session
    }

    /// Whether the server answers, and which tools it offers.
    public func status() async -> Result<[String], MCPClient.MCPError> {
        let client = MCPClient(endpoint: endpoint, session: session)
        do {
            return .success(try await client.connect().map(\.name))
        } catch let error as MCPClient.MCPError {
            return .failure(error)
        } catch {
            return .failure(.badResponse("\(error)"))
        }
    }

    /// - Parameters:
    ///   - nodeID: from the ⌘L link, if there is one. Otherwise the selection.
    ///   - fileKey: from the link; some server versions want it.
    ///   - motionHint: the link says the frame is open in Figma's motion timeline.
    public func export(nodeID: String?, fileKey: String?, motionHint: Bool = false) async throws -> FigmaExport {
        let client = MCPClient(endpoint: endpoint, session: session)
        do {
            try await client.connect()
        } catch let error as MCPClient.MCPError {
            throw FigmaExportError.unavailable("Figma desktop MCP server \(error)")
        }
        MarginLog.info("Figma MCP tools: \(client.tools.map(\.name).joined(separator: ", "))")
        var export = try await exportStill(client: client, nodeID: nodeID, fileKey: fileKey)

        // 3. Motion: render the animation if the frame has any.
        var motion = motionHint
        var timelineRoot: String?
        if let tool = client.tool(named: "get_motion_context") {
            var args: [String: Any] = ["nodeId": export.node.id]
            if tool.properties.contains("recursive") { args["recursive"] = true }
            Self.addCommon(to: &args, tool: tool, fileKey: fileKey)
            if let result = try? await client.call(tool.name, arguments: args, timeout: 20), !result.isError,
               let info = FigmaMotion.parse(result.text) {
                motion = info.animated
                timelineRoot = info.timelineRoot
            }
        }
        export.hasMotion = motion
        guard motion else { return export }
        MarginLog.info("Figma frame \(export.node.id) has motion")
        guard let videoTool = client.tool(named: "export_video") else { return export }
        for candidate in [export.node.id, timelineRoot].compactMap({ $0 }) {
            do {
                export.video = try await exportVideo(client: client, tool: videoTool, nodeID: candidate, fileKey: fileKey)
                return export
            } catch {
                MarginLog.info("Figma video export of \(candidate) failed: \(error)")
            }
        }
        return export
    }

    /// Renders the animation to MP4, waiting while Figma renders it.
    func exportVideo(client: MCPClient, tool: MCPClient.Tool, nodeID: String, fileKey: String?, pollInterval: TimeInterval = 3, maxWait: TimeInterval = 180) async throws -> Data {
        var args: [String: Any] = ["nodeId": nodeID]
        if tool.properties.contains("quality") { args["quality"] = "high" }
        if tool.properties.contains("ttlSeconds") { args["ttlSeconds"] = 600 }
        Self.addCommon(to: &args, tool: tool, fileKey: fileKey)
        let deadline = Date().addingTimeInterval(maxWait)
        while true {
            let result = try await client.call(tool.name, arguments: args, timeout: 90)
            if result.isError { throw FigmaExportError.failed("export_video: \(result.text.prefix(200))") }
            let reply = FigmaMotion.videoReply(result.text)
            if let url = reply.downloadURL ?? result.links.compactMap(URL.init(string:)).first {
                let data = try await ImageData.download(url, session: session)
                guard FigmaMotion.isVideo(data) else { throw FigmaExportError.failed("export_video returned something that isn't a video") }
                return data
            }
            guard let job = reply.jobID, Date() < deadline else {
                throw FigmaExportError.failed("export_video gave no video: \(result.text.prefix(200))")
            }
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            args = ["jobId": job]
            Self.addCommon(to: &args, tool: tool, fileKey: fileKey)
        }
    }

    private func exportStill(client: MCPClient, nodeID: String?, fileKey: String?) async throws -> FigmaExport {

        // 1. Which node? Metadata without a node id is small (the pages, plus
        // the current selection on servers that report it). Only if that
        // doesn't settle it, ask about the linked node, which can be a whole
        // page's outline when nothing is selected.
        var node: FigmaNodeInfo?
        // The server answered and saw no selection. Some versions don't report
        // the selection here, so this alone isn't proof.
        var metadataSawNothing = false
        /// Everything selected, when the server lists it: several frames make a stack.
        var selection: [FigmaNodeInfo] = []
        if let metadataTool = client.tool(named: "get_metadata") {
            var args: [String: Any] = [:]
            Self.addCommon(to: &args, tool: metadataTool, fileKey: fileKey)
            if let result = try? await client.call(metadataTool.name, arguments: args, timeout: 10) {
                MarginLog.info("Figma MCP get_metadata: \(result.text.prefix(300).replacingOccurrences(of: "\n", with: " "))")
                if !result.isError {
                    node = FigmaMetadata.target(in: result.text, requested: nil)
                    metadataSawNothing = node == nil
                    selection = FigmaMetadata.selected(in: result.text).filter { !$0.isPage }
                } else if nodeID == nil, result.text.lowercased().contains("select") {
                    throw FigmaExportError.noSelection
                }
            }
            if node == nil, let nodeID {
                args["nodeId"] = nodeID
                if let result = try? await client.call(metadataTool.name, arguments: args, timeout: 20), !result.isError {
                    node = FigmaMetadata.target(in: result.text, requested: nodeID)
                    if node == nil { throw FigmaExportError.noSelection }
                }
            }
        }
        if node == nil, let nodeID { node = FigmaNodeInfo(id: nodeID) }

        // 2. Render it.
        guard let screenshotTool = client.tool(named: "get_screenshot", "get_image") else {
            throw FigmaExportError.unavailable("Figma's MCP server has no screenshot tool (tools: \(client.tools.map(\.name).joined(separator: ", ")))")
        }
        var args: [String: Any] = [:]
        if let id = node?.id { args["nodeId"] = id }
        if screenshotTool.properties.contains("enableBase64Response") { args["enableBase64Response"] = true }
        if screenshotTool.properties.contains("maxDimension") { args["maxDimension"] = maxDimension }
        Self.addCommon(to: &args, tool: screenshotTool, fileKey: fileKey)
        let missing = screenshotTool.required.subtracting(args.keys)
        if !missing.isEmpty {
            if node == nil && metadataSawNothing { throw FigmaExportError.noSelection }
            throw FigmaExportError.failed("\(screenshotTool.name) needs \(missing.sorted().joined(separator: ", "))")
        }

        let result: MCPClient.ToolResult
        do {
            result = try await client.call(screenshotTool.name, arguments: args, timeout: 40)
        } catch {
            if node == nil && metadataSawNothing { throw FigmaExportError.noSelection }
            throw FigmaExportError.failed("\(screenshotTool.name) \(error)")
        }
        if result.isError {
            let message = result.text
            if message.lowercased().contains("select") || (node == nil && metadataSawNothing) { throw FigmaExportError.noSelection }
            throw FigmaExportError.failed("\(screenshotTool.name): \(message.prefix(200))")
        }

        guard let image = await picture(in: result) else {
            if node == nil && metadataSawNothing { throw FigmaExportError.noSelection }
            throw FigmaExportError.failed("\(screenshotTool.name) returned no image: \(result.text.prefix(200))")
        }
        var export = FigmaExport(image: image, node: node ?? FigmaNodeInfo(id: "selection"), via: "desktop MCP")

        // Several frames selected: each of the others on its own, as the plugin does.
        if let first = node, nodeID == nil || FigmaMetadata.sameID(first.id, nodeID ?? "") {
            for other in selection.prefix(Self.maxFrames) where !FigmaMetadata.sameID(other.id, first.id) {
                args["nodeId"] = other.id
                guard let result = try? await client.call(screenshotTool.name, arguments: args, timeout: 40), !result.isError,
                      let image = await picture(in: result) else {
                    MarginLog.info("Figma MCP export of \(other.id) failed")
                    continue
                }
                export.others.append(FigmaExport(image: image, node: other, via: "desktop MCP"))
            }
        }
        return export
    }

    /// The most frames exported from one selection, as in the plugin.
    static let maxFrames = 12

    /// The picture in a screenshot tool's answer: inline, or (newer servers)
    /// at a short-lived URL.
    private func picture(in result: MCPClient.ToolResult) async -> Data? {
        if let image = result.images.first(where: { ImageData.isImage($0.data) }) { return image.data }
        for url in ImageData.urls(in: result.text) + result.links.compactMap(URL.init(string:)) {
            if let data = try? await ImageData.download(url, session: session), ImageData.isImage(data) { return data }
        }
        return nil
    }

    /// Fills arguments some server versions require.
    static func addCommon(to args: inout [String: Any], tool: MCPClient.Tool, fileKey: String?) {
        if let fileKey, tool.properties.contains("fileKey") { args["fileKey"] = fileKey }
        if tool.properties.contains("clientLanguages") { args["clientLanguages"] = "unknown" }
        if tool.properties.contains("clientFrameworks") { args["clientFrameworks"] = "unknown" }
    }
}

/// Exports through Figma's REST API with a personal access token. Needs the
/// file key and node id from the ⌘L link. Renders the last saved version,
/// which in Figma is a second or two behind what's on screen.
public enum FigmaREST {
    public static let base = URL(string: "https://api.figma.com/v1/")!

    public static func nodesRequest(fileKey: String, nodeID: String, token: String) -> URLRequest {
        var components = URLComponents(url: base.appendingPathComponent("files/\(fileKey)/nodes"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "ids", value: nodeID), URLQueryItem(name: "depth", value: "1")]
        return request(components.url!, token: token)
    }

    public static func imageRequest(fileKey: String, nodeID: String, token: String, scale: Double = 2) -> URLRequest {
        var components = URLComponents(url: base.appendingPathComponent("images/\(fileKey)"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "ids", value: nodeID),
            URLQueryItem(name: "format", value: "png"),
            URLQueryItem(name: "scale", value: String(format: "%g", scale)),
        ]
        return request(components.url!, token: token)
    }

    public static func meRequest(token: String) -> URLRequest {
        request(base.appendingPathComponent("me"), token: token)
    }

    static func request(_ url: URL, token: String) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue(token, forHTTPHeaderField: "X-Figma-Token")
        return request
    }

    public static func parseNode(_ data: Data, nodeID: String) -> FigmaNodeInfo? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let nodes = json["nodes"] as? [String: Any] else { return nil }
        let entry = nodes[nodeID] ?? nodes[nodeID.replacingOccurrences(of: ":", with: "-")]
        guard let document = (entry as? [String: Any])?["document"] as? [String: Any] else { return nil }
        return FigmaNodeInfo(id: nodeID, name: document["name"] as? String, type: (document["type"] as? String)?.lowercased())
    }

    public static func parseImageURL(_ data: Data, nodeID: String) throws -> URL {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FigmaExportError.failed("Figma API: unreadable response")
        }
        if let err = json["err"] as? String, !err.isEmpty { throw FigmaExportError.failed("Figma API: \(err)") }
        let images = json["images"] as? [String: Any] ?? [:]
        let value = images[nodeID] ?? images[nodeID.replacingOccurrences(of: ":", with: "-")]
        guard let string = value as? String, let url = URL(string: string) else {
            throw FigmaExportError.failed("Figma API rendered nothing for \(nodeID)")
        }
        return url
    }

    /// The account name for a token, to confirm it works.
    public static func whoAmI(token: String, session: URLSession = .shared) async throws -> String {
        let (data, response) = try await session.data(for: meRequest(token: token))
        try check(response, data)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["handle"] as? String) ?? (json?["email"] as? String) ?? "Figma user"
    }

    public static func export(fileKey: String, nodeID: String, token: String, session: URLSession = .shared) async throws -> FigmaExport {
        let (nodeData, nodeResponse) = try await session.data(for: nodesRequest(fileKey: fileKey, nodeID: nodeID, token: token))
        try check(nodeResponse, nodeData)
        let node = parseNode(nodeData, nodeID: nodeID) ?? FigmaNodeInfo(id: nodeID)
        if node.isPage { throw FigmaExportError.noSelection }

        let (imageData, imageResponse) = try await session.data(for: imageRequest(fileKey: fileKey, nodeID: nodeID, token: token))
        try check(imageResponse, imageData)
        let url = try parseImageURL(imageData, nodeID: nodeID)
        let png = try await ImageData.download(url, session: session)
        guard ImageData.isImage(png) else { throw FigmaExportError.failed("Figma API returned something that isn't an image") }
        return FigmaExport(image: png, node: node, via: "REST API")
    }

    static func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200..<300: return
        case 403: throw FigmaExportError.unavailable("Figma token was rejected (403)")
        case 404: throw FigmaExportError.failed("Figma API: file or node not found (404)")
        case 429: throw FigmaExportError.failed("Figma API rate limit, try again in a minute")
        default: throw FigmaExportError.failed("Figma API HTTP \(http.statusCode): \(String(decoding: data.prefix(160), as: UTF8.self))")
        }
    }
}

public enum ImageData {
    /// PNG, JPEG, GIF or WebP by magic bytes.
    public static func isImage(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(12))
        guard bytes.count >= 4 else { return false }
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return true }       // PNG
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return true }             // JPEG
        if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) { return true }       // GIF
        if bytes.count >= 12, bytes.starts(with: [0x52, 0x49, 0x46, 0x46]),
           bytes[8...11] == [0x57, 0x45, 0x42, 0x50] { return true }         // WebP
        return false
    }

    /// "png" or "jpg" for a file name.
    public static func fileExtension(_ data: Data) -> String {
        data.starts(with: [0xFF, 0xD8, 0xFF]) ? "jpg" : "png"
    }

    public static func urls(in text: String) -> [URL] {
        guard let regex = try? NSRegularExpression(pattern: #"https?://[^\s"'<>)\]]+"#) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap {
            URL(string: ns.substring(with: $0.range).trimmingCharacters(in: CharacterSet(charactersIn: ".,;")))
        }
    }

    public static func download(_ url: URL, session: URLSession?) async throws -> Data {
        let (data, response) = try await (session ?? .shared).data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FigmaExportError.failed("download HTTP \(http.statusCode)")
        }
        return data
    }
}
