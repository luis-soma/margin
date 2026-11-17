import AppKit
import CoreImage
import SwiftUI

/// Dressing a capture for documentation, the way CleanShot's background
/// tool does: a backdrop, room around it, rounded corners, a shadow and a
/// frame shape, then copy or save. Opens from the pencil under a capture's
/// details, in place of the focus panel, and goes back to it on Esc.
struct ExportStudio: View {
    let entry: Entry
    let source: URL
    let close: () -> Void

    @State private var style = ExportStyle.saved
    /// The capture (or a recording's first moment) at a size quick to restyle.
    @State private var small: CIImage?
    /// The capture's own size, for the size line under the controls.
    @State private var fullSize: CGSize?
    @State private var preview: CGImage?
    @State private var failed = false
    /// Saving a recording: how far along.
    @State private var progress: Double?
    @State private var busy = false
    @State private var flash: String?
    /// Only the newest preview lands.
    @State private var renderID = 0

    private var isVideo: Bool { ["mp4", "mov", "m4v"].contains(source.pathExtension.lowercased()) }
    private var F: Archive.Focus.Type { Archive.Focus.self }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: F.radius, style: .continuous)
        HStack(spacing: 0) {
            stage
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Rectangle()
                .fill(Archive.rule)
                .frame(width: 1)
                .frame(maxHeight: .infinity)
                .padding(.vertical, F.ruleInset)
            controls
                .frame(width: F.sidebarWidth)
                .padding(.leading, F.gap / 2)
                .padding(.trailing, F.trailing)
        }
        .overlay(alignment: .topTrailing) {
            NavIcon(symbol: "xmark", action: close)
                .pointingHand()
                .help("Back to the capture (esc)")
                .padding(.top, F.navTop)
                .padding(.trailing, F.navTrailing)
        }
        .background(Archive.paper, in: shape)
        .clipShape(shape)
        .background(
            shape.fill(Archive.paper)
                .shadow(color: .black.opacity(0.05), radius: 1.5, y: 1)
                .shadow(color: .black.opacity(0.10), radius: 28, y: 10)
        )
        .overlay(alignment: .bottom) {
            if let flash {
                FloatingNote(text: flash)
                    .padding(.bottom, 22)
                    .transition(.opacity.combined(with: .offset(y: 8)).combined(with: .scale(scale: 0.96, anchor: .bottom)))
            }
        }
        .animation(Brand.motion, value: flash)
        .task { await load() }
        .onChange(of: style) { new in
            ExportStyle.saved = new
            rerender()
        }
    }

    // MARK: The preview

    private var stage: some View {
        GeometryReader { geo in
            let room = CGSize(width: max(80, geo.size.width - 2 * F.leading), height: max(80, geo.size.height - 2 * F.verticalMargin * 0.75))
            ZStack {
                if let preview {
                    let size = fitted(CGSize(width: preview.width, height: preview.height), in: room)
                    ZStack {
                        if style.backdrop == .none { Checkerboard() }
                        Image(decorative: preview, scale: 1)
                            .resizable()
                            .interpolation(.high)
                    }
                    .frame(width: size.width, height: size.height)
                    // The edge of the exported picture, so a white one still
                    // shows where it ends.
                    .overlay(Rectangle().strokeBorder(Archive.rule, lineWidth: 1))
                    .animation(Theme.Motion.settle, value: size)
                } else if failed {
                    Text("This capture can't be opened here.")
                        .font(Archive.sans(F.valueSize))
                        .foregroundStyle(Archive.faint)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func fitted(_ size: CGSize, in room: CGSize) -> CGSize {
        let scale = min(room.width / max(size.width, 1), room.height / max(size.height, 1))
        return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }

    // MARK: The controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: F.blockGap) {
            VStack(alignment: .leading, spacing: F.titleGap) {
                Text("Export")
                    .font(Archive.headline(F.titleSize))
                    .foregroundStyle(Archive.ink)
                Text(isVideo ? "The recording on a backdrop, every frame, for docs and slides." : "The screenshot on a backdrop, for docs and slides.")
                    .font(Archive.sans(F.valueSize))
                    .foregroundStyle(Archive.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, Theme.Space.x2)

            group("Background") {
                Swatches(selection: $style.backdrop, options: ExportStyle.Backdrop.available(video: isVideo), capture: small)
            }
            group("Frame") {
                VStack(spacing: Theme.Space.x1 + 2) {
                    StyleSlider(title: "Padding", value: $style.padding)
                    StyleSlider(title: "Corners", value: $style.radius)
                    StyleSlider(title: "Shadow", value: $style.shadow)
                }
            }
            group("Shape") {
                RatioSwitch(selection: $style.ratio)
            }
            Spacer(minLength: Theme.Space.x4)
            footer
        }
        .padding(.top, F.verticalMargin * 0.75)
        .padding(.bottom, F.trailing)
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.x2) {
            Text(title)
                .font(Archive.font(F.labelSize))
                .foregroundStyle(Archive.faint)
            content()
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: Theme.Space.x3) {
            HStack(spacing: 0) {
                if let size = outputSize {
                    Text("\(Int(size.width)) × \(Int(size.height)) · \(isVideo ? "MP4" : "PNG")")
                        .monospacedDigit()
                }
                Spacer(minLength: Theme.Space.x2)
                Button("Reset") { withAnimation(Theme.Motion.settle) { style = ExportStyle() } }
                    .buttonStyle(.plain)
                    .foregroundStyle(Archive.muted)
                    .pointingHand()
                    .disabled(style == ExportStyle())
                    .opacity(style == ExportStyle() ? 0 : 1)
            }
            .font(Archive.sans(F.valueSize))
            .foregroundStyle(Archive.faint)

            HStack(spacing: Theme.Space.x2) {
                if !isVideo {
                    StudioButton(title: "Copy", primary: false, action: copy)
                        .disabled(busy || small == nil)
                }
                StudioButton(title: saveTitle, primary: true, progress: progress, action: save)
                    .disabled(busy || small == nil)
            }
        }
    }

    private var saveTitle: String {
        if let progress { return "Exporting \(Int(progress * 100))%" }
        return "Save to Downloads"
    }

    /// The exported picture's size in pixels.
    private var outputSize: CGSize? {
        guard let fullSize else { return nil }
        let canvas = ExportRenderer.layout(for: fullSize, style: style).canvas
        guard isVideo else { return canvas }
        let fit = min(1, 3840 / max(canvas.width, canvas.height))
        let scaled = ExportRenderer.layout(for: CGSize(width: fullSize.width * fit, height: fullSize.height * fit), style: style).canvas
        return CGSize(width: floor(scaled.width / 2) * 2, height: floor(scaled.height / 2) * 2)
    }

    // MARK: Work

    private func load() async {
        let url = source
        let video = isVideo
        let content: CIImage? = video ? await ExportRenderer.poster(of: url) : await Task.detached { ExportRenderer.picture(at: url) }.value
        guard let content else {
            failed = true
            return
        }
        fullSize = content.extent.size
        small = ExportRenderer.downsized(content, longest: 1600)
        rerender()
    }

    private func rerender() {
        guard let small else { return }
        renderID += 1
        let id = renderID
        let style = style
        Task.detached(priority: .userInitiated) {
            let image = ExportRenderer.cgImage(ExportRenderer.render(small, style: style))
            await MainActor.run {
                if id == renderID, let image { preview = image }
            }
        }
    }

    private func copy() {
        let url = source
        let style = style
        busy = true
        Task.detached(priority: .userInitiated) {
            let png = ExportRenderer.picture(at: url).flatMap { ExportRenderer.png($0, style: style) }
            await MainActor.run {
                busy = false
                guard let png else { return show("Couldn't copy the picture") }
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                let item = NSPasteboardItem()
                item.setData(png, forType: .png)
                if let tiff = NSBitmapImageRep(data: png)?.tiffRepresentation { item.setData(tiff, forType: .tiff) }
                pasteboard.writeObjects([item])
                show("Copied")
            }
        }
    }

    private func save() {
        guard let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return }
        let destination = Self.freeName(in: folder, base: FocusView.fileName(for: entry, extension: ""), ext: isVideo ? "mp4" : "png")
        let url = source
        let style = style
        busy = true
        if isVideo {
            progress = 0
            Task {
                do {
                    try await ExportRenderer.exportVideo(from: url, style: style, to: destination) { value in progress = value }
                    finishSave(destination, ok: true)
                } catch {
                    finishSave(destination, ok: false, error.localizedDescription)
                }
            }
        } else {
            Task.detached(priority: .userInitiated) {
                let png = ExportRenderer.picture(at: url).flatMap { ExportRenderer.png($0, style: style) }
                let ok = (try? png?.write(to: destination, options: .atomic)) != nil
                await MainActor.run { finishSave(destination, ok: ok) }
            }
        }
    }

    private func finishSave(_ destination: URL, ok: Bool, _ why: String? = nil) {
        busy = false
        progress = nil
        if ok {
            show("Saved to Downloads")
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } else {
            show(why ?? "Couldn't save the picture")
        }
    }

    private func show(_ message: String) {
        flash = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            if flash == message { flash = nil }
        }
    }

    /// `base.ext` in `folder`, or `base 2.ext` and on if that's taken.
    static func freeName(in folder: URL, base: String, ext: String) -> URL {
        var url = folder.appendingPathComponent("\(base).\(ext)")
        var copy = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(copy).\(ext)")
            copy += 1
        }
        return url
    }
}

// MARK: - Pieces

/// The backdrops, as small squares: the chosen one ringed in ink.
private struct Swatches: View {
    @Binding var selection: ExportStyle.Backdrop
    let options: [ExportStyle.Backdrop]
    /// For "From the capture": the capture itself, blurred.
    let capture: CIImage?
    @State private var thumbnail: NSImage?

    private let columns = Array(repeating: GridItem(.fixed(32), spacing: 8), count: 6)

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(options) { option in
                Swatch(option: option, selected: option == selection, thumbnail: thumbnail) {
                    withAnimation(Theme.Motion.snappy) { selection = option }
                }
            }
        }
        .onAppear(perform: makeThumbnail)
        .onChange(of: capture == nil) { _ in makeThumbnail() }
    }

    private func makeThumbnail() {
        guard thumbnail == nil, let capture else { return }
        let small = ExportRenderer.downsized(capture, longest: 96)
        if let image = ExportRenderer.cgImage(small) {
            thumbnail = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }
    }
}

private struct Swatch: View {
    let option: ExportStyle.Backdrop
    let selected: Bool
    let thumbnail: NSImage?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
        Button(action: action) {
            fill
                .frame(width: 32, height: 32)
                .clipShape(shape)
                .overlay(shape.strokeBorder(Theme.Palette.hairline, lineWidth: 1))
                .padding(2)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.chip + 2, style: .continuous)
                        .strokeBorder(Theme.Palette.ink, lineWidth: 1.5)
                        .opacity(selected ? 1 : 0)
                )
                .padding(-2)
                .scaleEffect(hovering && !selected ? 1.04 : 1)
                .contentShape(shape)
        }
        .buttonStyle(PressStyle(scale: 0.94))
        .onHover { inside in withAnimation(Theme.Motion.hover) { hovering = inside } }
        .toolTip(option.name, align: .center)
        .accessibilityLabel(option.name)
    }

    @ViewBuilder
    private var fill: some View {
        switch option {
        case .none:
            Checkerboard(square: 6)
        case .blur:
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: 4)
                    .scaleEffect(1.3)
            } else {
                Theme.Palette.fill
            }
        default:
            if let pair = option.colors {
                LinearGradient(colors: [Color(nsColor: ExportRenderer.color(pair.0)), Color(nsColor: ExportRenderer.color(pair.1))],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
    }
}

/// A row you drag across: the name on the left, the amount on the right,
/// the part up to the handle a shade deeper, the handle a thin ink line.
private struct StyleSlider: View {
    let title: String
    @Binding var value: Double
    @State private var hovering = false
    @State private var dragging = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
        GeometryReader { geo in
            let width = geo.size.width
            let x = CGFloat(value) * width
            ZStack(alignment: .leading) {
                shape.fill(Theme.Palette.fill)
                Rectangle()
                    .fill(Theme.Palette.ink.opacity(dragging ? 0.08 : hovering ? 0.065 : 0.05))
                    .frame(width: max(0, x))
                Rectangle()
                    .fill(Theme.Palette.ink)
                    .frame(width: 2, height: 14)
                    .offset(x: min(max(x - 1, 6), width - 8))
                    .opacity(value > 0.005 ? 1 : 0.35)
                HStack {
                    Text(title)
                        .foregroundStyle(Theme.Palette.ink)
                    Spacer()
                    Text("\(Int((value * 100).rounded()))")
                        .monospacedDigit()
                        .foregroundStyle(Theme.Palette.ink3)
                }
                .font(Theme.Typography.ui(Theme.Typography.control))
                .padding(.horizontal, Theme.Space.x3)
                .allowsHitTesting(false)
            }
            .clipShape(shape)
            .contentShape(shape)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        dragging = true
                        value = Double(min(max(drag.location.x / max(width, 1), 0), 1))
                    }
                    .onEnded { _ in dragging = false }
            )
            .onHover { inside in withAnimation(Theme.Motion.hover) { hovering = inside } }
        }
        .frame(height: 28)
        .accessibilityElement()
        .accessibilityLabel(title)
        .accessibilityValue("\(Int(value * 100)) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(1, value + 0.05)
            case .decrement: value = max(0, value - 0.05)
            @unknown default: break
            }
        }
    }
}

/// Auto, 16:9, 4:3, 1:1: Margin's switch, the chosen one in ink.
private struct RatioSwitch: View {
    @Binding var selection: ExportStyle.Ratio
    @Namespace private var thumb
    @State private var hovered: ExportStyle.Ratio?

    var body: some View {
        let S = Theme.Segmented.self
        HStack(spacing: 0) {
            ForEach(ExportStyle.Ratio.allCases) { ratio in
                Button {
                    withAnimation(Theme.Motion.snappy) { selection = ratio }
                } label: {
                    Text(ratio.name)
                        .font(Theme.Typography.ui(Theme.Typography.control, selection == ratio ? .medium : .regular))
                        .monospacedDigit()
                        .foregroundStyle(S.label(selection == ratio, hovered: hovered == ratio))
                        .frame(maxWidth: .infinity)
                        .frame(height: S.segment)
                        .background {
                            if selection == ratio {
                                SegmentThumb().matchedGeometryEffect(id: "thumb", in: thumb)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { inside in hovered = inside ? ratio : (hovered == ratio ? nil : hovered) }
            }
        }
        .padding(S.padding)
        .background(SegmentTrack())
    }
}

/// Save and Copy: 32 tall, corners of 8; Save in ink, Copy on the grey track.
private struct StudioButton: View {
    let title: String
    let primary: Bool
    var progress: Double? = nil
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
        Button(action: action) {
            Text(title)
                .font(Theme.Typography.ui(Theme.Typography.body, .medium))
                .monospacedDigit()
                .foregroundStyle(primary ? Theme.Palette.paper : Theme.Palette.ink)
                .frame(maxWidth: primary ? .infinity : nil)
                .padding(.horizontal, Theme.Space.x4)
                .frame(height: 32)
                .background {
                    if primary {
                        ZStack(alignment: .leading) {
                            shape.fill(Theme.Palette.ink.opacity(hovering && enabled ? 0.86 : 1))
                            if let progress {
                                GeometryReader { geo in
                                    Rectangle()
                                        .fill(Theme.Palette.paper.opacity(0.16))
                                        .frame(width: geo.size.width * progress)
                                }
                                .clipShape(shape)
                            }
                        }
                    } else {
                        shape.fill(hovering && enabled ? Theme.Palette.fillHover : Theme.Palette.fill)
                    }
                }
                .opacity(enabled || progress != nil ? 1 : 0.45)
                .contentShape(shape)
        }
        .buttonStyle(PressStyle())
        .onHover { inside in withAnimation(Theme.Motion.hover) { hovering = inside } }
    }
}

/// See-through, the way image editors show it: soft grey squares.
private struct Checkerboard: View {
    var square: CGFloat = 8

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.Palette.paper))
            let columns = Int(ceil(size.width / square)), rows = Int(ceil(size.height / square))
            var path = Path()
            for row in 0..<rows {
                for column in 0..<columns where (row + column) % 2 == 0 {
                    path.addRect(CGRect(x: CGFloat(column) * square, y: CGFloat(row) * square, width: square, height: square))
                }
            }
            context.fill(path, with: .color(Theme.Palette.ink.opacity(0.06)))
        }
    }
}
