import Foundation

/// Where the pointer went during a recording, and where it clicked: kept
/// beside the video (`name.cursor.json`) so the export studio can zoom in on
/// clicks and draw a smooth cursor. A second, cursorless copy of the video
/// (`name.studio.mp4`) lets it replace the recorded cursor with its own.
/// Nothing else in Margin reads these; recordings play as they always did.
public struct CursorTrack: Codable {
    public struct Point: Codable {
        /// Host clock seconds, the clock the video frames are stamped with.
        public var t: Double
        /// 0 to 1 across the recorded area, from its top left.
        public var x: Double
        public var y: Double

        public init(t: Double, x: Double, y: Double) {
            self.t = t
            self.x = x
            self.y = y
        }
    }

    public var version = 1
    /// The recorded area in points, to size the cursor against the frame.
    public var areaWidth: Double
    public var areaHeight: Double
    public var moves: [Point]
    public var clicks: [Point]
    /// Host seconds of each video's first frame: "main" and "studio".
    public var starts: [String: Double]

    public init(areaWidth: Double, areaHeight: Double, moves: [Point], clicks: [Point], starts: [String: Double]) {
        self.areaWidth = areaWidth
        self.areaHeight = areaHeight
        self.moves = moves
        self.clicks = clicks
        self.starts = starts
    }

    public static func sidecar(for video: URL) -> URL {
        video.deletingPathExtension().appendingPathExtension("cursor.json")
    }

    public static func studioVideo(for video: URL) -> URL {
        video.deletingPathExtension().appendingPathExtension("studio.mp4")
    }

    public static func load(for video: URL) -> CursorTrack? {
        guard let data = try? Data(contentsOf: sidecar(for: video)) else { return nil }
        return try? JSONDecoder().decode(CursorTrack.self, from: data)
    }

    public func save(for video: URL) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Self.sidecar(for: video), options: .atomic)
    }

    /// The files kept beside a recording, for removing it with them.
    public static func companions(of video: URL) -> [URL] {
        [sidecar(for: video), studioVideo(for: video)]
    }
}
