import Foundation

/// A link to a Figma file, and optionally a node in it, as Figma's
/// "Copy link to selection" (⌘L) produces:
/// `https://www.figma.com/design/<fileKey>/<name>?node-id=12-34&t=…`
public struct FigmaLink: Equatable, Sendable {
    /// design, file, proto, board, slides, make…
    public let kind: String
    public let fileKey: String
    /// In API form, e.g. "12:34". Nil when the link points at the whole file.
    public let nodeID: String?
    /// The file name from the URL, e.g. "SVSD Competition".
    public let fileName: String?
    public let url: URL
    /// The link was copied while the frame was open in Figma's motion
    /// timeline ("timeline=keyframe" in the link).
    public let isMotion: Bool

    private static let kinds: Set<String> = ["file", "design", "proto", "board", "slides", "make", "deck", "site", "buzz"]

    public static func parse(_ string: String?) -> FigmaLink? {
        guard let raw = string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              // Only the first token: Figma never copies more, but be safe.
              let token = raw.split(whereSeparator: \.isWhitespace).first,
              let url = URL(string: String(token)),
              let host = url.host?.lowercased(),
              host == "figma.com" || host.hasSuffix(".figma.com"),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }

        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2 else { return nil }
        let kind = parts[0].lowercased()
        guard kinds.contains(kind) else { return nil }

        var fileKey = parts[1]
        var nameIndex = 2
        // Branches: /design/<key>/branch/<branchKey>/<name>
        if parts.count >= 4, parts[2].lowercased() == "branch" {
            fileKey = parts[3]
            nameIndex = 4
        }
        guard isFileKey(fileKey) else { return nil }

        let rawNode = components.queryItems?.first(where: { $0.name == "node-id" })?.value
        let fileName = parts.count > nameIndex ? prettyName(parts[nameIndex]) : nil
        let isMotion = components.queryItems?.contains { $0.name == "timeline" || $0.name.hasPrefix("timeline-") } ?? false
        return FigmaLink(kind: kind, fileKey: fileKey, nodeID: rawNode.flatMap(apiNodeID), fileName: fileName, url: url, isMotion: isMotion)
    }

    /// "12-34" or "12%3A34" → "12:34". Instance ids keep their ";" parts.
    public static func apiNodeID(_ raw: String) -> String? {
        let id = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "-", with: ":")
        guard !id.isEmpty, id.range(of: #"^[IT]?\d+:\d+(;\d+:\d+)*$"#, options: .regularExpression) != nil else { return nil }
        return id
    }

    static func isFileKey(_ key: String) -> Bool {
        key.count >= 10 && key.allSatisfy { $0.isLetter || $0.isNumber }
    }

    /// "SVSD-Competition" → "SVSD Competition"
    static func prettyName(_ slug: String) -> String? {
        let name = (slug.removingPercentEncoding ?? slug).replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
}
