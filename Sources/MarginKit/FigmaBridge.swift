import Foundation

/// Talks to Margin's Figma plugin, which runs hidden inside Figma and can do
/// what no server can: export the selected frame exactly as Figma renders it,
/// including its animation as MP4 (the plugin API's exportAsync).
///
/// The plugin polls `GET /figma/poll` on Margin's local server. When Margin
/// wants an export, the poll answers with a request; the plugin exports and
/// posts the result to `POST /figma/result`.
public final class FigmaBridge {
    public struct Frame {
        public var nodeID: String?
        public var nodeName: String?
        public var nodeType: String?
        public var png: Data?
        public var video: Data?
        public var videoError: String?
    }

    public struct Export {
        /// Every selected frame, each exported on its own (first = primary).
        public var frames: [Frame] = []
        /// How many layers were selected (frames is capped).
        public var selectionCount = 0
        public var nodeID: String?
        public var nodeName: String?
        public var nodeType: String?
        public var fileKey: String?
        public var fileName: String?
        public var png: Data?
        public var video: Data?
        public var videoError: String?
        public var nothingSelected = false

        /// A link to the node, when the plugin knew the file key.
        public var link: URL? { link(to: nodeID) }

        public func link(to nodeID: String?) -> URL? {
            guard let fileKey, let nodeID else { return nil }
            var components = URLComponents()
            components.scheme = "https"
            components.host = "www.figma.com"
            let slug = (fileName ?? "File").replacingOccurrences(of: " ", with: "-")
            components.path = "/design/\(fileKey)/\(slug)"
            components.queryItems = [URLQueryItem(name: "node-id", value: nodeID.replacingOccurrences(of: ":", with: "-"))]
            return components.url
        }
    }

    public enum BridgeError: Error, CustomStringConvertible {
        case notRunning
        case timedOut
        public var description: String {
            switch self {
            case .notRunning: return "The Margin plugin isn't running in Figma"
            case .timedOut: return "The Margin plugin didn't answer in time"
            }
        }
    }

    private struct Pending {
        let id: String
        let wantVideo: Bool
        /// The plugin looks for animation itself and exports video when it finds some.
        var detectMotion = false
        /// Every slide of a Figma Slides deck rather than the selection.
        var deck = false
        /// When a poll took the job; offered again if no result comes back.
        var handedOutAt: Date?
        let continuation: CheckedContinuation<Export, Error>
        /// Frames done so far and how many there are, as the plugin reports them.
        let progress: ((Int, Int) -> Void)?
    }

    private let lock = NSLock()
    private var pending: Pending?
    private var lastPoll: Date?
    /// How many layers the plugin last said were selected; -1 when it didn't say.
    private var selected = -1
    /// Which Figma editor the plugin runs in ("figma", "slides"); empty when it didn't say.
    private var editor = ""
    /// How long since the last poll still counts as running.
    public var aliveWindow: TimeInterval = 3
    /// How long a waiting plugin's request is held open before it's answered
    /// empty (it asks again straight away).
    public var holdSeconds: TimeInterval = 20
    /// Plugins waiting for work right now: their requests are held open, so
    /// a job reaches them the moment it exists, with no timers involved.
    /// Timers in Figma's hidden plugin window run late or not at all; open
    /// requests don't care.
    private var waiters: [(id: UUID, reply: (HookServer.Response) -> Void)] = []

    public init() {}

    /// A plugin is waiting, or asked recently. Call with the lock held.
    private var alive: Bool {
        if !waiters.isEmpty { return true }
        return lastPoll.map { Date().timeIntervalSince($0) < aliveWindow } ?? false
    }

    public var isConnected: Bool {
        lock.withLock { alive }
    }

    /// The file open in Figma is a Figma Slides deck (the plugin says so).
    public var isSlidesDeck: Bool {
        lock.withLock { alive && editor == "slides" }
    }

    /// How many layers are selected in Figma right now, when the plugin is
    /// running and says (older plugins don't); nil otherwise.
    public var selectionCount: Int? {
        lock.withLock {
            guard alive, selected >= 0 else { return nil }
            return selected
        }
    }

    /// Asks the plugin to export the current selection.
    /// - Parameter progress: called with (done, total) as each frame of a
    ///   multi-frame selection finishes, on a background thread. Older plugins never call it.
    /// - Parameter detectMotion: the plugin checks each frame for animation
    ///   and exports video for the ones that move. Older plugins ignore it.
    public func export(wantVideo: Bool, detectMotion: Bool = false, deck: Bool = false, timeout: TimeInterval = 120, progress: ((Int, Int) -> Void)? = nil) async throws -> Export {
        guard isConnected else { throw BridgeError.notRunning }
        let id = UUID().uuidString
        return try await withCheckedThrowingContinuation { continuation in
            let (woken, offer): (((HookServer.Response) -> Void)?, [String: Any]?) = lock.withLock {
                pending?.continuation.resume(throwing: BridgeError.timedOut)
                pending = Pending(id: id, wantVideo: wantVideo, detectMotion: detectMotion, deck: deck, continuation: continuation, progress: progress)
                // A plugin is already waiting: hand it the job now.
                guard !waiters.isEmpty, let offer = takeJob() else { return (nil, nil) }
                return (waiters.removeFirst().reply, offer)
            }
            if let woken, let offer { woken(.json(["app": "Margin", "request": offer])) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish(id: id, with: .failure(BridgeError.timedOut))
            }
            // Nobody picked it up: the plugin went away. Don't keep the designer waiting.
            DispatchQueue.global().asyncAfter(deadline: .now() + 8) { [weak self] in
                guard let self else { return }
                let untaken = self.lock.withLock { self.pending?.id == id && self.pending?.handedOutAt == nil }
                if untaken { self.finish(id: id, with: .failure(BridgeError.notRunning)) }
            }
        }
    }

    /// The job to hand out, marking it taken; nil when there's none (or it
    /// was handed out a moment ago). Call with the lock held.
    private func takeJob() -> [String: Any]? {
        guard var job = pending else { return nil }
        if let taken = job.handedOutAt, Date().timeIntervalSince(taken) < (job.wantVideo || job.detectMotion ? 90 : 15) {
            return nil
        }
        job.handedOutAt = Date()
        pending = job
        return ["id": job.id, "wantVideo": job.wantVideo, "detectMotion": job.detectMotion, "deck": job.deck]
    }

    /// What every plugin request says about Figma. Call with the lock held.
    private func note(_ request: HookServer.Request) {
        lastPoll = Date()
        if let count = request.query["selected"].flatMap({ Int($0) }) { selected = count }
        if let kind = request.query["editor"] { editor = kind }
    }

    /// `GET /figma/wait`: held open until there's a job or `holdSeconds`
    /// pass. Returns false for any other request. `reply` may be called on
    /// any thread, once.
    public func handleDeferred(_ request: HookServer.Request, reply: @escaping (HookServer.Response) -> Void) -> Bool {
        guard request.method == "GET", request.path == "/figma/wait" else { return false }
        let id = UUID()
        let offer: [String: Any]? = lock.withLock {
            note(request)
            if let offer = takeJob() { return offer }
            waiters.append((id, reply))
            return nil
        }
        if let offer {
            reply(.json(["app": "Margin", "request": offer]))
            return true
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + holdSeconds) { [weak self] in
            guard let self else { return }
            let expired: ((HookServer.Response) -> Void)? = self.lock.withLock {
                guard let index = self.waiters.firstIndex(where: { $0.id == id }) else { return nil }
                // It was waiting all along: still alive.
                self.lastPoll = Date()
                return self.waiters.remove(at: index).reply
            }
            expired?(.json(["app": "Margin"]))
        }
        return true
    }

    /// Routes plugin requests; nil for anything else.
    public func handle(_ request: HookServer.Request) -> HookServer.Response? {
        switch (request.method, request.path) {
        case ("GET", "/figma/poll"), ("GET", "/figma/wait"):
            // /figma/wait lands here only where requests can't be held open:
            // answered at once, like a poll.
            return lock.withLock {
                note(request)
                // "hello" polls only look for Margin; they don't take work.
                guard request.query["hello"] == nil, let offer = takeJob() else { return .json(["app": "Margin"]) }
                return .json(["app": "Margin", "request": offer])
            }
        case ("POST", "/figma/bye"), ("GET", "/figma/bye"):
            // The plugin closes itself after a job: stop counting it as running
            // right away, so the next capture starts it again.
            let open: [(HookServer.Response) -> Void] = lock.withLock {
                lastPoll = nil
                selected = -1
                let replies = waiters.map(\.reply)
                waiters.removeAll()
                return replies
            }
            open.forEach { $0(.json(["app": "Margin"])) }
            return .json(["ok": true])
        case ("POST", "/figma/selection"):
            lock.withLock { note(request) }
            return .json(["ok": true])
        case ("POST", "/figma/progress"):
            guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let id = json["id"] as? String, let done = json["done"] as? Int, let total = json["total"] as? Int, total > 0
            else { return HookServer.Response(status: 400) }
            let report = lock.withLock { pending?.id == id ? pending?.progress : nil }
            report?(min(done, total), total)
            return .json(["ok": true])
        case ("POST", "/figma/result"):
            guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let id = json["id"] as? String else { return HookServer.Response(status: 400) }
            finish(id: id, with: .success(Self.export(from: json)))
            return .json(["ok": true])
        default:
            return nil
        }
    }

    static func export(from json: [String: Any]) -> Export {
        var export = Export()
        export.nodeID = json["nodeId"] as? String
        export.nodeName = json["nodeName"] as? String
        export.nodeType = json["nodeType"] as? String
        export.fileKey = json["fileKey"] as? String
        export.fileName = json["fileName"] as? String
        export.png = (json["png"] as? String).flatMap { Data(base64Encoded: $0) }
        export.video = (json["video"] as? String).flatMap { Data(base64Encoded: $0) }
        export.videoError = json["videoError"] as? String
        export.nothingSelected = json["nothingSelected"] as? Bool ?? false
        export.selectionCount = json["selectionCount"] as? Int ?? 1
        export.frames = (json["frames"] as? [[String: Any]] ?? []).map { item in
            Frame(
                nodeID: item["nodeId"] as? String,
                nodeName: item["nodeName"] as? String,
                nodeType: item["nodeType"] as? String,
                png: (item["png"] as? String).flatMap { Data(base64Encoded: $0) },
                video: (item["video"] as? String).flatMap { Data(base64Encoded: $0) },
                videoError: item["videoError"] as? String
            )
        }
        // Older plugin versions send one frame at the top level.
        if export.frames.isEmpty, export.png != nil || export.video != nil {
            export.frames = [Frame(nodeID: export.nodeID, nodeName: export.nodeName, nodeType: export.nodeType, png: export.png, video: export.video, videoError: export.videoError)]
        }
        return export
    }

    private func finish(id: String, with result: Result<Export, Error>) {
        let job: Pending? = lock.withLock {
            guard let job = pending, job.id == id else { return nil }
            pending = nil
            return job
        }
        job?.continuation.resume(with: result)
    }
}
