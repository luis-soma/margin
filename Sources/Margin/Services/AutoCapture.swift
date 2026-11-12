import AppKit
import CoreGraphics
import MarginKit

/// Automatic capture, kept quiet and few:
/// - Only in Figma, and at most every ten minutes while you're working there.
/// - A shot that looks like the last one is thrown away: first a cheap pixel
///   check, then OpenAI's Decisions API decides if the design actually moved
///   on (new screens, layout or content), not just the cursor, a selection
///   or a panel.
/// - What's kept is an automatic capture: it sits between your own captures,
///   hidden unless you show automatic captures.
/// Pictures of what Claude Code changed come from CodingSessions.
@MainActor
final class AutoCapture: ObservableObject {
    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Keys.enabled)
            reschedule()
        }
    }
    @Published private(set) var needsPermission = false
    @Published private(set) var lastCaptureDate: Date?

    /// Called after each kept capture with how much it changed (0...1).
    var onSnapshot: ((Entry, Double) -> Void)?
    /// The AI keys, for the Decisions check.
    var config: () -> AIConfig = { AIConfig() }

    /// Where automatic capture looks.
    static let apps: Set<String> = ["com.figma.Desktop"]
    /// At most one capture per this many seconds.
    static let interval: TimeInterval = 10 * 60
    /// How often Margin checks whether it's time.
    static let tick: TimeInterval = 30
    /// Below this pixel change, a shot is the same as the last one.
    static let minimumChange = 0.015
    /// Without Decisions, a shot needs this much pixel change to be kept.
    static let fallbackChange = 0.05
    /// Don't capture while you're away from the keyboard.
    static let idleLimit: TimeInterval = 120

    private let store: EntryStore
    private let context: AppContextTracker
    private var timer: Timer?
    private var lastFingerprints: [String: [UInt8]] = [:]
    /// The last kept picture per app, to compare the next one with.
    private var lastKept: [String: URL] = [:]
    private var lastAttempt = Date.distantPast
    private var isCapturing = false

    private enum Keys {
        static let enabled = "autoCaptureEnabled"
    }

    init(store: EntryStore, context: AppContextTracker) {
        self.store = store
        self.context = context
        isEnabled = UserDefaults.standard.object(forKey: Keys.enabled) as? Bool ?? true
    }

    func start() {
        needsPermission = !ScreenCapture.hasPermission
        reschedule()
    }

    /// Re-checks Screen Recording access, e.g. when the panel opens.
    func refreshPermission() {
        needsPermission = !ScreenCapture.hasPermission
    }

    /// Takes a snapshot right away, even if nothing changed.
    func captureNow() {
        Task { await capture(force: true) }
    }

    private func reschedule() {
        timer?.invalidate()
        timer = nil
        guard isEnabled else { return }
        let timer = Timer(timeInterval: Self.tick, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.capture(force: false) }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func capture(force: Bool) async {
        guard !isCapturing, let app = context.frontApp else { return }
        let key = app.bundleIdentifier ?? app.localizedName ?? "app"
        if !force {
            guard Self.apps.contains(key),
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
                  idleSeconds < Self.idleLimit,
                  Date().timeIntervalSince(lastAttempt) >= Self.interval else { return }
        }
        guard ScreenCapture.hasPermission else {
            needsPermission = true
            return
        }
        needsPermission = false
        isCapturing = true
        lastAttempt = Date()
        defer { isCapturing = false }

        let url = store.newImageURL(ext: "heic")
        guard let shot = await ScreenCapture.snapshot(pid: app.processIdentifier, to: url) else { return }

        let change = lastFingerprints[key].map { ImageTools.difference($0, shot.fingerprint) } ?? 1
        lastFingerprints[key] = shot.fingerprint
        if !force {
            var keep = change >= Self.minimumChange
            // After a relaunch, compare with the last automatic shot of this app.
            let previous = lastKept[key] ?? store.entries
                .last { $0.kind == .snapshot && $0.sourceApp == app.localizedName && $0.imageFile != nil }
                .flatMap { store.imageURL(for: $0) }
            if keep, let previous {
                keep = await movedOn(from: previous, to: url, change: change)
            }
            guard keep else {
                try? FileManager.default.removeItem(at: url)
                MarginLog.info("Auto capture skipped: looks like the last one (\(String(format: "%.3f", change)))")
                return
            }
        }
        lastKept[key] = url

        var entry = store.newEntry(.snapshot)
        entry.imageFile = url.lastPathComponent
        entry.sourceApp = app.localizedName
        entry.windowTitle = shot.title
        entry.changeScore = change
        store.add(entry)
        lastCaptureDate = Date()
        onSnapshot?(entry, change)
    }

    /// Did the design move on since the last kept shot? Asks Decisions when
    /// there's an OpenAI key; otherwise only a bigger pixel change counts.
    private func movedOn(from previous: URL, to current: URL, change: Double) async -> Bool {
        let config = config()
        guard let key = config.openai,
              let before = ImagePrep.jpeg(contentsOf: previous, maxPixel: 768, quality: 0.7),
              let after = ImagePrep.jpeg(contentsOf: current, maxPixel: 768, quality: 0.7) else {
            return change >= Self.fallbackChange
        }
        let client = DecisionsClient(apiKey: key, model: config.decisions)
        do {
            let answers = try await client.decide(
                text: "Two screenshots of a designer's Figma window, ten or more minutes apart. The first is the earlier one.",
                images: [before, after],
                questions: [.predicate(
                    name: "moved_on",
                    instructions: "True only if the second screenshot shows meaningfully new design work compared with the first: a new screen or frame, a changed layout, new or rearranged components, or new content. False if it's essentially the same design with only the cursor, selection, zoom, scroll position, open panels or tiny tweaks different."
                )]
            )
            let probability = answers["moved_on"]?.probability ?? 1
            return probability >= 0.5
        } catch {
            MarginLog.info("Auto capture: Decisions failed (\(error)); using the pixel check")
            return change >= Self.fallbackChange
        }
    }

    private var idleSeconds: TimeInterval {
        // ~0 is "any input event".
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }
}
