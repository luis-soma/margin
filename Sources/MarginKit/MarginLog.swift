import Foundation

/// A small log file at ~/Library/Logs/Margin/margin.log, so capture problems
/// can be traced after the fact ("why did Figma fall back to a screenshot?").
public enum MarginLog {
    public static let url: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Margin", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("margin.log")
    }()

    private static let queue = DispatchQueue(label: "margin.log")
    private static let maxBytes = 1_000_000

    public static func info(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        NSLog("Margin: %@", message)
        queue.async {
            let fm = FileManager.default
            if let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue, size > maxBytes {
                // Keep the newer half.
                if let data = try? Data(contentsOf: url) {
                    try? data.suffix(maxBytes / 2).write(to: url)
                }
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
