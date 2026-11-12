import Foundation

/// A node as Figma describes it: "12:34", "Home", "frame".
public struct FigmaNodeInfo: Equatable, Sendable {
    public var id: String
    public var name: String?
    public var type: String?

    public init(id: String, name: String? = nil, type: String? = nil) {
        self.id = id
        self.name = name
        self.type = type
    }

    /// Pages and the document itself aren't a selection.
    public var isPage: Bool {
        guard let type = type?.lowercased() else { return false }
        return type == "canvas" || type == "page" || type == "document"
    }
}

/// Reads what the Figma MCP server's `get_metadata` returns: an XML outline,
/// sometimes preceded by a "Currently selected nodes:" block. The exact text
/// varies between Figma versions, so this is deliberately forgiving.
public enum FigmaMetadata {
    /// The first element with an id, e.g. `<frame id="1:2" name="Home" …>`.
    public static func root(in text: String) -> FigmaNodeInfo? {
        elements(in: text).first
    }

    /// Nodes listed under "Currently selected nodes:", if the server sent that block.
    public static func selected(in text: String) -> [FigmaNodeInfo] {
        let lines = text.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: { $0.lowercased().contains("currently selected") }) else { return [] }

        // The header line may carry the list itself ("…: 1:2 Home").
        var block: [String] = []
        let header = lines[start]
        if let colon = header.firstIndex(of: ":") {
            let rest = header[header.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty { block.append(rest) }
        }
        for line in lines[(start + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if block.isEmpty { continue } else { break }
            }
            // The XML dump of the queried node starts after the block.
            if trimmed.hasPrefix("<"), !block.isEmpty, elements(in: block.joined(separator: "\n")).isEmpty { break }
            block.append(trimmed)
        }

        let joined = block.joined(separator: "\n")
        let xml = elements(in: joined)
        if !xml.isEmpty { return xml }

        var nodes: [FigmaNodeInfo] = []
        for line in block {
            guard let id = firstMatch(#"\b(?:guid|id)\s*[=:]\s*"?([IT]?\d+[:-]\d+(?:;\d+[:-]\d+)*)"#, in: line)
                    ?? firstMatch(#"\b([IT]?\d+:\d+(?:;\d+:\d+)*)\b"#, in: line),
                  let apiID = FigmaLink.apiNodeID(id) else { continue }
            var name = firstMatch(#"name\s*[=:]\s*"([^"]*)""#, in: line)
            if name == nil {
                // "- 1:2 Home (FRAME)" or "1:2: Home"
                var rest = line
                if let range = line.range(of: id) { rest = String(line[range.upperBound...]) }
                rest = rest.replacingOccurrences(of: typeSuffix, with: "", options: .regularExpression)
                rest = rest.trimmingCharacters(in: CharacterSet(charactersIn: " -:,|\"'"))
                name = rest.isEmpty ? nil : rest
            }
            let type = firstMatch(typeSuffix, in: line) ?? firstMatch(#"\btype\s*[=:]\s*"?(\w+)"#, in: line)
            nodes.append(FigmaNodeInfo(id: apiID, name: name.map(decodeEntities), type: type?.lowercased()))
        }
        return nodes
    }

    /// The node to export: the selection if there is one, else the queried node
    /// unless that is a page. Nil means nothing is selected.
    public static func target(in text: String, requested: String?) -> FigmaNodeInfo? {
        let root = root(in: text)
        if let requested, let root, !root.isPage, sameID(root.id, requested) { return root }
        if let selection = selected(in: text).first(where: { !$0.isPage }) { return selection }
        if let root, !root.isPage { return root }
        return nil
    }

    public static func sameID(_ a: String, _ b: String) -> Bool {
        a.replacingOccurrences(of: "-", with: ":") == b.replacingOccurrences(of: "-", with: ":")
    }

    /// "(FRAME)" at the end of a line: Figma's node types are uppercase.
    static let typeSuffix = #"\(([A-Z][A-Z_]+)\)\s*$"#

    // MARK: XML

    static func elements(in text: String) -> [FigmaNodeInfo] {
        guard let regex = try? NSRegularExpression(pattern: #"<([A-Za-z][\w-]*)\s+([^<>]*?)/?>"#) else { return [] }
        let ns = text as NSString
        var nodes: [FigmaNodeInfo] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: match.range(at: 1))
            let attributes = attributesIn(ns.substring(with: match.range(at: 2)))
            guard let rawID = attributes["id"] ?? attributes["guid"], let id = FigmaLink.apiNodeID(rawID) else { continue }
            let type = attributes["type"] ?? tag
            nodes.append(FigmaNodeInfo(id: id, name: attributes["name"].map(decodeEntities), type: type.lowercased()))
        }
        return nodes
    }

    static func attributesIn(_ text: String) -> [String: String] {
        guard let regex = try? NSRegularExpression(pattern: #"([\w-]+)="([^"]*)""#) else { return [:] }
        let ns = text as NSString
        var result: [String: String] = [:]
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result[ns.substring(with: match.range(at: 1))] = ns.substring(with: match.range(at: 2))
        }
        return result
    }

    static func decodeEntities(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
