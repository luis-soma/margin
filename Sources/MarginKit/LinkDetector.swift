import Foundation

/// Tells whether copied text is a single web address, the way an address
/// bar or a selected link looks: "https://arc.net/…", "github.com/x/y".
public enum LinkDetector {
    public static func url(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count < 4000,
              !trimmed.contains(where: { $0.isWhitespace }) else { return nil }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            guard let url = URL(string: trimmed), let host = url.host, !host.isEmpty else { return nil }
            return url
        }
        // No scheme: only clear domain names ("example.com", "docs.figma.com/x").
        guard !lower.contains("@"), !lower.hasPrefix("/"), !lower.hasPrefix("."),
              let url = URL(string: "https://" + trimmed), let host = url.host,
              host.contains("."), !host.hasSuffix("."),
              let tld = host.split(separator: ".").last, tld.count >= 2, tld.allSatisfy(\.isLetter),
              host.split(separator: ".").allSatisfy({ !$0.isEmpty }) else { return nil }
        // "file.js" or "index.html" look like domains but aren't.
        let fileEndings: Set<String> = ["js", "ts", "tsx", "jsx", "json", "md", "html", "css", "swift", "py", "txt", "png", "jpg", "pdf", "sh", "rb", "go", "rs", "yml", "yaml", "lock", "toml", "zip", "mov", "mp4"]
        if !trimmed.contains("/"), fileEndings.contains(String(tld).lowercased()) { return nil }
        return url
    }
}
