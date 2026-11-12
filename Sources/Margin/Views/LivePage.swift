import AppKit
import MarginKit
import SwiftUI
import WebKit

/// What a capture can show live inside Margin.
enum LiveSource: Equatable {
    /// A copied HTML site, served by Margin.
    case site
    /// A kept version of an app's code, run on localhost on request.
    case version
    /// A website that was captured: the page itself, from the web.
    case website(URL)

    @MainActor
    static func of(_ entry: Entry, coding: CodingSessions) -> LiveSource? {
        if coding.siteFolder(entry) != nil { return .site }
        if entry.kind == .iteration, entry.codeRoot != nil, entry.snapshot != nil { return .version }
        if entry.kind == .link || entry.kind == .inspiration, let url = URL(string: entry.link),
           ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host?.lowercased(),
           !host.hasSuffix("figma.com"), !host.hasSuffix("claude.ai") {
            return .website(url)
        }
        return nil
    }

    /// Code you can show in Finder (a website has no files of its own).
    var hasFiles: Bool { !isWebsite }
    var isWebsite: Bool { if case .website = self { return true } else { return false } }
}

/// The live frame's sizes.
enum LiveLayout {
    /// The screen the page is laid out for: a laptop.
    static let viewport = CGSize(width: 1440, height: 900)
    /// Under the frame: the gap, then the switch.
    static var switchSpace: CGFloat { Archive.Space.x4 + RepoHeader.toolHeight + 4 }

    /// The room for the page (or its screenshot) inside the capture's area.
    static func room(in area: CGSize) -> CGSize {
        let inset = min(Archive.Focus.artMargin, area.width * 0.04)
        return CGSize(width: max(160, area.width - inset * 2), height: max(120, area.height - inset * 2 - switchSpace))
    }
}

/// A capture that runs: a Claude Code prototype or a captured website, live
/// where its picture would be, in a laptop-sized frame (laid out at 1440 × 900
/// and scaled to fit, so it looks like it did on the screen). A small switch
/// under it goes between the live page and the screenshot that was saved.
struct LiveCapture<Picture: View>: View {
    let entry: Entry
    let source: LiveSource
    /// The room the capture gets.
    let area: CGSize
    /// The screenshot's fitted size, so the switch stays put between the two.
    let pictureSize: CGSize
    @ViewBuilder let picture: () -> Picture

    @EnvironmentObject private var coding: CodingSessions
    @Environment(\.colorScheme) private var scheme
    @State private var live = true
    @State private var url: URL?
    @State private var starting = false
    @State private var problem: String?

    var body: some View {
        let room = LiveLayout.room(in: area)
        let frame = fitted(room)
        VStack(spacing: Archive.Space.x4) {
            ZStack {
                if live, let url {
                    LivePage(url: url, zoom: frame.width / LiveLayout.viewport.width, onFail: failed)
                        .frame(width: frame.width, height: frame.height)
                        .background(Color.white)
                        .overlay(Rectangle().stroke(Archive.frame, lineWidth: 1).padding(-0.5))
                        .background(
                            Rectangle().fill(Archive.paper)
                                .shadow(color: .black.opacity(scheme == .dark ? 0.4 : 0.06), radius: 6, y: 2)
                        )
                        .transition(.opacity)
                } else {
                    picture()
                        .opacity(live && starting ? 0.55 : 1)
                        .overlay {
                            if live && starting { ThinkingPill(text: "Starting this version", size: 12) }
                        }
                        .transition(.opacity)
                }
            }
            .frame(width: room.width, height: min(room.height, max(frame.height, pictureSize.height)))
            .overlay(alignment: .bottom) {
                if let problem {
                    FloatingNote(text: problem)
                        .padding(.bottom, 14)
                        .transition(.opacity)
                }
            }
            LiveSwitch(live: Binding(get: { live }, set: { choose($0) }))
        }
        .frame(width: area.width, height: area.height)
        .animation(Brand.motion, value: live)
        .animation(Brand.motion, value: url)
        .animation(Brand.quick, value: problem)
        .task(id: entry.id) {
            problem = nil
            switch source {
            case .site:
                url = coding.siteURL(entry)
            case .website(let page):
                url = page
            case .version:
                // A kept version needs its dev server first: the picture until
                // you switch to live (or it's already running).
                url = coding.runningVersions[entry.id]
                live = url != nil
            }
        }
    }

    /// The largest laptop-shaped frame that fits.
    private func fitted(_ room: CGSize) -> CGSize {
        let aspect = LiveLayout.viewport.width / LiveLayout.viewport.height
        var w = room.width, h = w / aspect
        if h > room.height { h = room.height; w = h * aspect }
        return CGSize(width: w.rounded(), height: h.rounded())
    }

    private func choose(_ wantsLive: Bool) {
        problem = nil
        live = wantsLive
        guard wantsLive, url == nil, source == .version, !starting else { return }
        starting = true
        Task {
            do {
                if let running = try await coding.runVersion(entry) {
                    url = running
                } else {
                    failed("Margin can't run this kind of project here")
                }
            } catch {
                failed((error as? LocalizedError)?.errorDescription ?? "\(error)")
            }
            starting = false
        }
    }

    private func failed(_ message: String) {
        problem = message
        live = false
        if source == .version { url = nil }
    }
}

/// Live page or screenshot: two small tools side by side in one paper pill,
/// like the switch between the timeline and themes. Rest the pointer on one
/// and its name shows above it.
private struct LiveSwitch: View {
    @Binding var live: Bool
    @Environment(\.colorScheme) private var scheme
    @Namespace private var chip
    @State private var hovered: Int?
    @State private var tip: Int?
    @State private var tipWork: DispatchWorkItem?

    var body: some View {
        let ink = MenuInk(scheme)
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        HStack(spacing: 1) {
            segment(0, label: "Live", symbol: "play")
            segment(1, label: "Screenshot", symbol: "photo")
        }
        .padding(2)
        .background(
            shape.fill(ink.surface)
                .shadow(color: .black.opacity(scheme == .dark ? 0.4 : 0.06), radius: 1, y: 0.5)
                .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0.07), radius: 8, y: 3)
        )
        .overlay(shape.strokeBorder(ink.hairline, lineWidth: 1))
        .animation(Brand.motion, value: live)
        .animation(Brand.quick, value: hovered)
        .animation(.easeOut(duration: 0.1), value: tip)
    }

    private func segment(_ index: Int, label: String, symbol: String) -> some View {
        let selected = (index == 0) == live
        let chipShape = RoundedRectangle(cornerRadius: Brand.smallRadius, style: .continuous)
        return Button {
            guard !selected else { return }
            live = index == 0
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .medium))
                .frame(width: 14, height: 14)
                .foregroundStyle(Color.primary.opacity(selected ? 0.85 : hovered == index ? 0.7 : 0.4))
                .frame(width: RepoHeader.toolWidth - 2, height: RepoHeader.toolHeight)
                .background {
                    if selected {
                        chipShape.fill(Color.primary.opacity(0.08)).matchedGeometryEffect(id: "chip", in: chip)
                    } else if hovered == index {
                        chipShape.fill(Color.primary.opacity(0.04))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .onHover { inside in hover(index, inside) }
        // The tool's name, above the pill.
        .overlay(alignment: .top) {
            if tip == index {
                Tooltip(text: label)
                    .fixedSize()
                    .frame(height: 0, alignment: .bottom)
                    .offset(y: -10)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
    }

    private func hover(_ index: Int, _ inside: Bool) {
        if inside {
            hovered = index
            tipWork?.cancel()
            if tip != nil { tip = index; return }
            let work = DispatchWorkItem { tip = index }
            tipWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        } else if hovered == index {
            hovered = nil
            tipWork?.cancel()
            let work = DispatchWorkItem { if hovered == nil { tip = nil } }
            tipWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        }
    }
}

/// A web view for a page Margin serves itself. Links that leave the page's
/// own address open in the browser instead.
struct LivePage: NSViewRepresentable {
    let url: URL
    /// The page's scale: the frame's width over the laptop width it's laid out for.
    var zoom: CGFloat = 1
    var onFail: (String) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.isElementFullscreenEnabled = true
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        view.pageZoom = zoom
        view.setAccessibilityLabel("Live page")
        load(url, in: view)
        context.coordinator.loaded = url
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
        if abs(view.pageZoom - zoom) > 0.001 { view.pageZoom = zoom }
        if context.coordinator.loaded != url {
            context.coordinator.loaded = url
            load(url, in: view)
        }
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading()
        view.navigationDelegate = nil
        view.uiDelegate = nil
    }

    private func load(_ url: URL, in view: WKWebView) {
        if url.isFileURL {
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            view.load(URLRequest(url: url))
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: LivePage
        var loaded: URL?

        init(_ parent: LivePage) { self.parent = parent }

        /// The page's own links stay here; anything that leaves for another
        /// site goes to the browser.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let target = action.request.url else { return decisionHandler(.allow) }
            let home = parent.url
            let sameSite = target.isFileURL ? home.isFileURL : (target.host == home.host && target.port == home.port)
            if action.navigationType == .linkActivated, !sameSite, ["http", "https", "mailto"].contains(target.scheme ?? "") {
                NSWorkspace.shared.open(target)
                return decisionHandler(.cancel)
            }
            decisionHandler(.allow)
        }

        /// target="_blank" and window.open: in the browser.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let target = action.request.url { NSWorkspace.shared.open(target) }
            return nil
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            fail(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            fail(error)
        }

        private func fail(_ error: Error) {
            let ns = error as NSError
            // A link the page cancelled itself, or one we sent to the browser.
            if ns.code == NSURLErrorCancelled || (ns.domain == "WebKitErrorDomain" && ns.code == 102) { return }
            MarginLog.info("Live page didn't load: \(error.localizedDescription)")
            parent.onFail("The page didn't load: \(error.localizedDescription)")
        }
    }
}

extension NSView {
    /// Inside a web view: the page has the keyboard and the clicks.
    var isInWebView: Bool {
        var view: NSView? = self
        while let current = view {
            if current is WKWebView { return true }
            view = current.superview
        }
        return false
    }
}
