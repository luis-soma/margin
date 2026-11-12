import Foundation

/// Reads Figma's motion tools: `get_motion_context` (is anything animated?)
/// and `export_video` (an MP4 of the timeline, possibly after a wait).
public enum FigmaMotion {
    public struct Info: Equatable {
        public var animated: Bool
        /// The top-level frame that owns the timeline, for export_video.
        public var timelineRoot: String?
    }

    /// Nil if the text isn't motion data at all.
    ///
    /// Real reply for a frame whose children animate (October 2026):
    /// `{"nodes":[{"nodeId":"139:223","nodeName":"margin","nodeType":"FRAME",
    ///   "codeSnippets":{"css":"animation: …","motionDev":"…"}}]}`
    /// and for a frame with no animation of its own:
    /// `{"nodes":[{"nodeId":"139:218",…,"timelineDurationMs":null,"motionSummary":null,"codeSnippets":{}}]}`
    public static func parse(_ text: String) -> Info? {
        guard let json = firstJSONObject(in: text) else { return nil }
        let nodes = json["nodes"] as? [[String: Any]] ?? []
        let cohorts = json["timelineCohorts"] as? [[String: Any]] ?? []
        guard json["nodes"] != nil || json["timelineCohorts"] != nil else { return nil }
        let animated = !cohorts.isEmpty || nodes.contains { node in
            if let snippets = node["codeSnippets"] as? [String: Any], !snippets.isEmpty { return true }
            if let duration = node["timelineDurationMs"] as? Double, duration > 0 { return true }
            if let summary = node["motionSummary"], !(summary is NSNull) { return true }
            if let tracks = node["tracks"] as? [Any], !tracks.isEmpty { return true }
            return false
        }
        let root = cohorts.compactMap { $0["rootNodeId"] as? String }.first
        return Info(animated: animated, timelineRoot: root)
    }

    /// export_video's answer: a download link when done, a job id while rendering.
    /// Real reply: `{"downloadUrl":"https://www.figma.com/blobs/…","availableUntil":"…","instructions":"…"}`
    public static func videoReply(_ text: String) -> (downloadURL: URL?, jobID: String?) {
        guard let json = firstJSONObject(in: text) else {
            return (ImageData.urls(in: text).first, nil)
        }
        let url = (json["downloadUrl"] as? String ?? json["url"] as? String).flatMap(URL.init(string:))
        let status = (json["status"] as? String)?.lowercased()
        let job = status == "processing" || status == "pending" || url == nil ? json["jobId"] as? String : nil
        return (url, job)
    }

    /// MP4 and QuickTime files have "ftyp" at byte 4.
    public static func isVideo(_ data: Data) -> Bool {
        guard data.count > 12 else { return false }
        return data[data.startIndex + 4..<data.startIndex + 8] == Data("ftyp".utf8)
    }

    static func firstJSONObject(in text: String) -> [String: Any]? {
        if let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] { return json }
        // Several content items joined by newlines: try each block.
        for block in text.components(separatedBy: "\n\n") + text.components(separatedBy: "\n") {
            let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("{"), let json = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any] else { continue }
            return json
        }
        return nil
    }
}
