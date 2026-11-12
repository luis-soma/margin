import AppKit
import MarginKit

/// Finds what makes Margin stutter, on the machine where it happens.
///
/// A background thread asks the main thread to answer every 100 ms. When it
/// hasn't answered for half a second, the window is stuck: that goes in the
/// log, and Margin samples itself with macOS's own `sample` tool for two
/// seconds, saving where the time goes as stall-<time>.txt beside the log.
/// When the main thread answers again, the length of the stall is logged.
///
/// Team builds only, at most one sample every 30 seconds and six a launch.
final class StallWatch: @unchecked Sendable {
    static let shared = StallWatch()

    private let lock = NSLock()
    private var lastAnswer = Date()
    private var stalledSince: Date?
    private var samples = 0
    private var lastSample = Date.distantPast
    private var timer: DispatchSourceTimer?

    /// Stuck for this long counts as a stall.
    static let threshold: TimeInterval = 0.5

    func start() {
        lock.lock(); defer { lock.unlock() }
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "margin.stallwatch", qos: .utility))
        timer.schedule(deadline: .now() + 0.2, repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.check() }
        timer.resume()
        self.timer = timer
    }

    private func check() {
        DispatchQueue.main.async { [weak self] in self?.answer() }
        let now = Date()
        lock.lock()
        let silent = now.timeIntervalSince(lastAnswer)
        let began = silent > Self.threshold && stalledSince == nil
        if began { stalledSince = lastAnswer }
        let takeSample = began && samples < 6 && now.timeIntervalSince(lastSample) > 30
        if takeSample {
            samples += 1
            lastSample = now
        }
        lock.unlock()
        guard began else { return }
        MarginLog.info("Stall: the window stopped answering")
        if takeSample { sample() }
    }

    private func answer() {
        let now = Date()
        lock.lock()
        let since = stalledSince
        stalledSince = nil
        lastAnswer = now
        lock.unlock()
        if let since {
            MarginLog.info(String(format: "Stall over after %.1f s", now.timeIntervalSince(since)))
        }
    }

    private func sample() {
        let format = DateFormatter()
        format.dateFormat = "yyyyMMdd-HHmmss"
        let name = "stall-\(format.string(from: Date())).txt"
        let out = MarginLog.url.deletingLastPathComponent().appendingPathComponent(name)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        // Two seconds, a sample every 10 ms.
        process.arguments = [String(ProcessInfo.processInfo.processIdentifier), "2", "10", "-mayDie", "-file", out.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            MarginLog.info("Stall sample: \(name)")
        } catch {
            MarginLog.info("Stall sample failed: \(error.localizedDescription)")
        }
    }
}
