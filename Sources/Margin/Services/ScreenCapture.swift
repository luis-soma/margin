import AppKit
import CoreGraphics
import MarginKit

/// The result of capturing an app's front window.
struct WindowShot {
    /// Window title, e.g. the Figma file name. Needs Screen Recording access.
    let title: String?
    /// Tiny grayscale fingerprint, used to tell whether anything changed.
    let fingerprint: [UInt8]
}

enum ScreenCapture {
    /// Screen Recording access is needed to capture other apps' windows.
    static var hasPermission: Bool {
        // The official check can report "no" on newer macOS even when access
        // is on, so also look for proof: other apps' window titles are only
        // visible to apps that are allowed to record the screen.
        CGPreflightScreenCaptureAccess() || canReadOtherWindowTitles()
    }

    private static func canReadOtherWindowTitles() -> Bool {
        let own = ProcessInfo.processInfo.processIdentifier
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return false }
        for info in list {
            guard let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != own,
                  let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue, layer == 0,
                  let owner = info[kCGWindowOwnerName as String] as? String,
                  owner != "Dock", owner != "Window Server", owner != "Finder",
                  let title = info[kCGWindowName as String] as? String, !title.isEmpty else { continue }
            return true
        }
        return false
    }

    /// Shows the system prompt the first time; afterwards the user has to
    /// switch it on in System Settings and restart Margin.
    static func requestPermission() {
        if !CGRequestScreenCaptureAccess(),
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
            // macOS only lists an app after it asked once; when Margin isn't
            // in the list (a reset, a new signature), show it in Finder too,
            // so it can be dragged in or added with +.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
            }
        }
    }

    /// Saves an area of the screen as a PNG at full resolution.
    /// - Parameter rect: Core Graphics global coordinates, in points.
    static func captureArea(_ rect: CGRect, to url: URL) async -> Bool {
        // -x no sound, -R this rectangle
        guard await run(["-x", "-R", RegionMath.screencaptureArgument(rect), url.path]) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Saves one window as a PNG, without its shadow.
    static func captureWindow(_ id: CGWindowID, to url: URL) async -> Bool {
        guard await run(["-x", "-o", "-l\(id)", url.path]) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Captures the front window of the app with this process id, scales it
    /// down and saves it as a HEIC at `url`, rounded corners and all.
    static func snapshot(pid: pid_t, to url: URL) async -> WindowShot? {
        guard let window = frontWindow(of: pid) else { return nil }
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("margin-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: temp) }

        // -x no sound, -o no window shadow, -l capture this window id
        guard await run(["-x", "-o", "-l\(window.id)", temp.path]),
              let image = ImageTools.load(temp) else { return nil }
        let fingerprint = ImageTools.fingerprint(image)
        guard ImageTools.writeHEIC(image, maxWidth: 1600, quality: 0.75, to: url) else { return nil }
        return WindowShot(title: window.title, fingerprint: fingerprint)
    }

    /// The frontmost normal window of an app, skipping tiny utility windows.
    static func frontWindow(of pid: pid_t) -> (id: CGWindowID, title: String?)? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return nil }
        // The list is ordered front to back.
        for info in list {
            guard let owner = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, owner == pid,
                  let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue, layer == 0,
                  let number = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { continue }
            if let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
               let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
               bounds.width < 200 || bounds.height < 150 {
                continue
            }
            let title = info[kCGWindowName as String] as? String
            return (CGWindowID(number), title)
        }
        return nil
    }

    private static func run(_ arguments: [String]) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = arguments
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus == 0)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: false)
            }
        }
    }
}
