import AppKit
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

    /// The page as a picture, with its title.
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
        guard let png = await preview.snapshot() else { return nil }
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
