import AppKit
import ApplicationServices

/// Fires when a Command key (left or right) is tapped twice on its own, like
/// Wispr Flow's Fn key but without taking Fn. Needs Accessibility permission
/// to see key events while other apps are in front.
final class DoubleTapShortcut {
    /// Virtual key codes of the Command keys, and each one's own bit in the
    /// modifier flags (so we know which side went up or down).
    private static let commandKeys: [UInt16: UInt] = [54: 0x10, 55: 0x08] // right, left
    /// A tap is a quick press and release with nothing else in between.
    private static let maxTapLength: TimeInterval = 0.3
    /// The second tap has to follow the first this quickly.
    private static let maxGap: TimeInterval = 0.4

    private let action: () -> Void
    private var monitors: [Any] = []
    private var pressedAt: Date?
    private var interrupted = false
    private var lastTap: Date?

    init(action: @escaping () -> Void) {
        self.action = action
        start()
    }

    deinit {
        monitors.forEach(NSEvent.removeMonitor)
    }

    /// True once Margin may watch the keyboard.
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that leads to Accessibility settings.
    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    private func start() {
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            self?.handleFlags(event)
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] _ in
            self?.interrupt()
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            self?.handleFlags(event)
            return event
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            self?.interrupt()
            return event
        }) { monitors.append(monitor) }
    }

    private func handleFlags(_ event: NSEvent) {
        guard let bit = Self.commandKeys[event.keyCode] else {
            // Another modifier joined in: this isn't a clean tap.
            interrupt()
            return
        }
        let now = Date()
        let raw = event.modifierFlags.rawValue
        let down = raw & bit != 0
        // Both Command keys held at once isn't a tap either.
        let otherHeld = Self.commandKeys.values.contains { $0 != bit && raw & $0 != 0 }
        if otherHeld {
            interrupt()
            pressedAt = nil
            return
        }
        if down {
            pressedAt = now
            interrupted = false
            return
        }
        // Released.
        guard let pressedAt, !interrupted, now.timeIntervalSince(pressedAt) <= Self.maxTapLength else {
            self.pressedAt = nil
            lastTap = nil
            return
        }
        self.pressedAt = nil
        if let lastTap, now.timeIntervalSince(lastTap) <= Self.maxGap {
            self.lastTap = nil
            DispatchQueue.main.async { self.action() }
        } else {
            lastTap = now
        }
    }

    private func interrupt() {
        interrupted = true
        lastTap = nil
    }
}
