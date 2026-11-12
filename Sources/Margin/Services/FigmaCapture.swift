import AppKit
import MarginKit

/// Captures the selected Figma frame: a clean export and a link to it, from
/// Margin's Figma plugin or Figma's desktop MCP server. It never presses
/// keys in Figma and never touches the clipboard.
@MainActor
final class FigmaCapture {
    static let bundleID = "com.figma.Desktop"

    enum Outcome {
        /// The frame, rendered by Figma.
        case exported(FigmaExport, link: FigmaLink?)
        /// Figma is in front but nothing is selected.
        case noSelection(link: FigmaLink?)
        /// Couldn't export automatically; `reason` says why. Margin falls back
        /// to letting the designer drag over the frame, keeping the link.
        case manual(link: FigmaLink?, reason: String)
    }

    /// Margin's plugin in Figma, when it's running.
    var bridge: FigmaBridge?
    /// What Margin is doing, for the loading pill, and how far along when
    /// that can be known (frames exported out of the selection).
    var onProgress: ((String, Double?) -> Void)?
    /// The export whose progress may still move the pill. The plugin posts
    /// progress and its result separately, so the last "2 of 2" can land
    /// after the result; by then the card is up, and a late report would
    /// replace it with a pill again.
    private var liveExport: UUID?

    /// Reports (done, total) from a background thread, until `liveExport` moves on.
    private func frameProgress(_ word: String) -> (Int, Int) -> Void {
        let token = UUID()
        liveExport = token
        return { [weak self] done, total in
            Task { @MainActor in
                guard let self, self.liveExport == token else { return }
                // Exporting is most of the wait; saving takes the last stretch.
                self.onProgress?("Exporting \(total) \(word)", 0.9 * Double(done) / Double(total))
            }
        }
    }

    /// True when Margin's plugin says nothing is selected in Figma: the
    /// shortcut then opens the capture menu straight away, with no export,
    /// no ⌘L and no loading pill.
    var knowsNothingSelected: Bool { bridge?.selectionCount == 0 }

    /// The file open in Figma is a Figma Slides deck, and the plugin can export it.
    var canExportDeck: Bool { bridge?.isSlidesDeck ?? false }

    /// Every slide of the open Figma Slides deck, in order, as one export
    /// (the first slide, with the rest as `others`); nil if the plugin couldn't.
    func captureDeck() async -> (export: FigmaExport, title: String?)? {
        guard let bridge, bridge.isConnected else { return nil }
        onProgress?("Exporting the deck…", nil)
        do {
            let result = try await bridge.export(wantVideo: false, deck: true, progress: frameProgress("slides"))
            liveExport = nil
            let slides: [FigmaExport] = result.frames.compactMap { frame in
                guard let png = frame.png else { return nil }
                let node = FigmaNodeInfo(id: frame.nodeID ?? "slide", name: frame.nodeName, type: frame.nodeType?.lowercased())
                return FigmaExport(image: png, node: node, via: "Figma plugin (deck)")
            }
            guard var first = slides.first else { return nil }
            first.others = Array(slides.dropFirst())
            MarginLog.info("Figma deck via plugin: \(slides.count) slides")
            return (first, result.fileName)
        } catch {
            liveExport = nil
            MarginLog.info("Figma deck export failed: \(error)")
            return nil
        }
    }

    func capture(canSendKeys: Bool) async -> Outcome {
        if knowsNothingSelected { return .noSelection(link: nil) }
        // The link comes from the plugin's answer (file and frame), never ⌘L.
        let link: FigmaLink? = nil

        // 0. The plugin only runs while it exports; start it for this capture.
        if let bridge, !bridge.isConnected, canSendKeys,
           let figma = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first {
            onProgress?("Exporting from Figma…", nil)
            let started = Date()
            if FigmaLauncher.startPlugin(in: figma) {
                let deadline = Date().addingTimeInterval(6)
                while !bridge.isConnected, Date() < deadline {
                    try? await Task.sleep(nanoseconds: 80_000_000)
                }
                MarginLog.info("Figma plugin \(bridge.isConnected ? "connected" : "didn't connect") after \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
            }
        }

        // 1. Margin's Figma plugin: Figma's own export, including animation as MP4.
        var reasons: [String] = []
        if let bridge, bridge.isConnected {
            // Without a link Margin can't tell motion apart, so the plugin
            // looks for animation in each frame and exports video for those.
            onProgress?("Exporting from Figma…", nil)
            do {
                let result = try await bridge.export(wantVideo: false, detectMotion: true, progress: frameProgress("frames from Figma"))
                liveExport = nil
                if result.nothingSelected { return .noSelection(link: link) }
                let exports: [FigmaExport] = result.frames.compactMap { frame in
                    guard frame.png != nil || frame.video != nil else { return nil }
                    let node = FigmaNodeInfo(id: frame.nodeID ?? "selection", name: frame.nodeName, type: frame.nodeType?.lowercased())
                    var export = FigmaExport(image: frame.png ?? Data(), node: node, via: "Figma plugin", hasMotion: frame.video != nil, video: frame.video)
                    if frame.video == nil, frame.videoError != nil {
                        export.note = "Figma couldn't export this as video (\(frame.videoError ?? "")). Video works on top-level frames with animation."
                    }
                    return export
                }
                if var primary = exports.first {
                    primary.others = Array(exports.dropFirst())
                    MarginLog.info("Figma export via plugin: \(exports.count) frame(s), first \(primary.node.id) \(primary.node.name ?? ""), video \(primary.video?.count ?? 0) bytes")
                    return .exported(primary, link: link ?? result.link.flatMap { FigmaLink.parse($0.absoluteString) })
                }
            } catch {
                liveExport = nil
                MarginLog.info("Figma plugin export failed: \(error)")
                reasons.append("the Margin plugin didn't answer (\(error))")
            }
        } else {
            reasons.append("Margin couldn't start its Figma plugin")
        }

        // Without the plugin Margin can't tell whether anything is selected
        // until it asks; the pill only shows if that takes a moment.
        let report = onProgress
        let pill = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            if !Task.isCancelled { report?("Exporting from Figma…", nil) }
        }
        defer { pill.cancel() }

        // 2. Figma's desktop MCP server: knows the selection, renders it crisply.
        do {
            let export = try await FigmaDesktopExporter().export(nodeID: link?.nodeID, fileKey: link?.fileKey, motionHint: link?.isMotion ?? false)
            MarginLog.info("Figma export via MCP: \(1 + export.others.count) frame(s), first \(export.node.id) \(export.node.name ?? ""), motion \(export.hasMotion), video \(export.video?.count ?? 0) bytes")
            return .exported(export, link: link)
        } catch FigmaExportError.noSelection {
            return .noSelection(link: link)
        } catch {
            // Most setups don't have this server; don't list it as a reason.
            MarginLog.info("Figma MCP export failed: \(error)")
        }

        // 2. REST API with a token, if the link points at a node.
        if let token = Keychain.figmaToken, let link, let nodeID = link.nodeID {
            do {
                var export = try await FigmaREST.export(fileKey: link.fileKey, nodeID: nodeID, token: token)
                // The API renders stills only; say so if this frame animates.
                export.hasMotion = link.isMotion
                MarginLog.info("Figma export via REST: \(export.node.id) \(export.node.name ?? "")")
                return .exported(export, link: link)
            } catch FigmaExportError.noSelection {
                return .noSelection(link: link)
            } catch {
                MarginLog.info("Figma REST export failed: \(error)")
                reasons.append("the access token export failed: \(error)")
            }
        }

        let reason = reasons.joined(separator: "; ").prefix(1).uppercased() + reasons.joined(separator: "; ").dropFirst()
            + ". If it was never added to Figma: Plugins → Development → Import plugin from manifest, then pick ~/.margin/figma-plugin/manifest.json once."
        MarginLog.info("Figma export failed: \(reason)")
        return .manual(link: link, reason: reason)
    }
}
