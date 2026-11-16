import AppKit
import ImageIO
import WebKit

/// Takes a picture of a web page without showing it: loads it in a hidden
/// web view, waits for it to settle and snapshots it.
@MainActor
public final class PagePreview: NSObject, WKNavigationDelegate {
    private let window: NSWindow
    private let webView: WKWebView
    private var continuation: CheckedContinuation<Bool, Never>?

    private init(size: CGSize) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: CGRect(origin: .zero, size: size), configuration: config)
        // As Safari: some sites send a bare page to anything else.
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Safari/605.1.15"
        // Off screen but "visible", so WebKit renders it.
        window = NSWindow(contentRect: CGRect(x: -30_000, y: -30_000, width: size.width, height: size.height),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.contentView = webView
        webView.navigationDelegate = self
    }

    /// A picture of the page and its title.
    public struct Shot {
        public let png: Data
        public let title: String?
    }

    /// PNG data of the page, or nil if it didn't load in time.
    /// - Parameters:
    ///   - settle: extra time after loading for scripts and fonts.
    public static func capture(_ url: URL, size: CGSize = CGSize(width: 1440, height: 900), settle: TimeInterval = 1.2, timeout: TimeInterval = 15) async -> Data? {
        await shot(url, size: size, settle: settle, timeout: timeout)?.png
    }

    /// The page as a picture, with its title. Pages that draw themselves
    /// with scripts are often still blank when they say they've loaded:
    /// it waits a few seconds more for something to show, and gives up
    /// rather than keep a blank picture.
    public static func shot(_ url: URL, size: CGSize = CGSize(width: 1440, height: 900), settle: TimeInterval = 1.2, timeout: TimeInterval = 15) async -> Shot? {
        // A local server that isn't running: don't picture the error page.
        if !url.isFileURL, ["localhost", "127.0.0.1"].contains(url.host ?? ""), let port = url.port, !DevServer.isListening(port: port) {
            return nil
        }
        let preview = PagePreview(size: size)
        defer { preview.close() }
        preview.window.orderFrontRegardless()
        let loaded = await preview.load(url, timeout: timeout)
        guard loaded else { return nil }
        try? await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000))
        // Nudge pictures that load as they scroll into view.
        _ = try? await preview.webView.evaluateJavaScript("window.scrollTo(0, 1); window.scrollTo(0, 0); true")
        var png = await preview.snapshot()
        var waited: TimeInterval = 0
        while let current = png, PictureCheck.isBlank(current), waited < 6 {
            try? await Task.sleep(nanoseconds: 800_000_000)
            waited += 0.8
            png = await preview.snapshot()
        }
        guard let png, !PictureCheck.isBlank(png) else { return nil }
        let title = preview.webView.title.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        return Shot(png: png, title: title)
    }

    private func load(_ url: URL, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            if url.isFileURL {
                webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            } else {
                webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish(false)
            }
        }
    }

    private func snapshot() async -> Data? {
        let config = WKSnapshotConfiguration()
        config.rect = webView.bounds
        return await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: config) { image, _ in
                guard let image,
                      let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: png)
            }
        }
    }

    private func finish(_ ok: Bool) {
        continuation?.resume(returning: ok)
        continuation = nil
    }

    private func close() {
        webView.stopLoading()
        window.orderOut(nil)
    }

    // MARK: WKNavigationDelegate

    public nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in self.finish(true) }
    }

    public nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.finish(false) }
    }

    public nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.finish(false) }
    }
}

/// Tells a picture with something in it from an empty one (a page that
/// hadn't drawn yet, a white flash).
public enum PictureCheck {
    /// Nearly every part of the picture is the same shade.
    public static func isBlank(_ image: CGImage) -> Bool {
        let size = 64
        var pixels = [UInt8](repeating: 0, count: size * size)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: size, height: size, bitsPerComponent: 8,
                                          bytesPerRow: size, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
            return true
        }
        guard drawn else { return false }
        let median = Int(pixels.sorted()[pixels.count / 2])
        let differing = pixels.reduce(0) { $0 + (abs(Int($1) - median) > 8 ? 1 : 0) }
        // Even a white page with one line of text has more than this.
        return differing < 10
    }

    public static func isBlank(_ png: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return true }
        return isBlank(image)
    }
}
