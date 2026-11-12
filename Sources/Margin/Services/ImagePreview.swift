import AppKit
import SwiftUI

/// A large look at a capture, over a dimmed screen. Click outside the image
/// (or press Esc) to go back; ← → page through the frames of a stack.
/// From the capture card, it also takes the annotation: leaving the preview
/// (Return, Esc or a click outside) saves what you typed and closes the card.
@MainActor
final class ImagePreview: ObservableObject {
    static let shared = ImagePreview()

    @Published private(set) var images: [NSImage] = []
    @Published var index = 0
    @Published fileprivate var shown = false
    /// The annotation being typed, shared with the card.
    @Published var note = ""
    fileprivate var onNote: ((String) -> Void)?
    fileprivate var onSubmit: ((String) -> Void)?
    var takesNote: Bool { onNote != nil }

    private var panel: KeyablePanel?
    private var keyMonitor: Any?
    /// The window that had the keyboard before, so typing continues there.
    private weak var previousKey: NSWindow?

    var isOpen: Bool { panel != nil }

    /// - Parameters:
    ///   - note: annotation text to start from (the card's field).
    ///   - onNote: gets the text back when the preview closes.
    ///   - onSubmit: Return in the note field: save the capture with this text.
    func show(_ images: [NSImage], at start: Int = 0, on screen: NSScreen? = nil,
              note: String = "", onNote: ((String) -> Void)? = nil, onSubmit: ((String) -> Void)? = nil) {
        guard !images.isEmpty, let screen = screen ?? TopCenter.screen else { return }
        if panel != nil { dismissNow() }
        self.images = images
        self.note = note
        self.onNote = onNote
        self.onSubmit = onSubmit
        index = max(0, min(start, images.count - 1))
        shown = false
        previousKey = NSApp.keyWindow

        let panel = KeyablePanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = FirstClickHostingView(rootView: ImagePreviewView(preview: self, size: screen.frame.size))
        host.frame = CGRect(origin: .zero, size: screen.frame.size)
        panel.contentView = host
        panel.setFrame(screen.frame, display: true)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel != nil else { return event }
            switch event.keyCode {
            case 53: self.close(); return nil               // esc
            // ← → page while there's nothing typed (otherwise they move the caret).
            case 123 where self.note.isEmpty: self.step(-1); return nil
            case 124 where self.note.isEmpty: self.step(1); return nil
            case 49 where !self.takesNote: self.close(); return nil  // space, when there's no field
            default: return event
            }
        }
        withAnimation(.easeOut(duration: 0.18)) { shown = true }
    }

    func step(_ delta: Int) {
        guard images.count > 1 else { return }
        withAnimation(Brand.quick) { index = (index + delta + images.count) % images.count }
    }

    /// Closes and hands the annotation back to the card.
    func close() {
        guard panel != nil else { return }
        let handBack = onNote
        onNote = nil
        onSubmit = nil
        handBack?(note)
        withAnimation(.easeOut(duration: 0.14)) { shown = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.dismissNow() }
    }

    /// Return in the note field: save the capture, close everything.
    fileprivate func submit() {
        guard panel != nil else { return }
        let save = onSubmit
        onNote = nil
        onSubmit = nil
        save?(note)
        withAnimation(.easeOut(duration: 0.14)) { shown = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.dismissNow() }
    }

    private func dismissNow() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        panel?.orderOut(nil)
        panel = nil
        previousKey?.makeKey()
    }
}

private struct ImagePreviewView: View {
    @ObservedObject var preview: ImagePreview
    let size: CGSize

    var body: some View {
        ZStack {
            // Click anywhere outside the picture to go back.
            Color.black.opacity(preview.shown ? 0.72 : 0)
                .contentShape(Rectangle())
                .onTapGesture { preview.close() }

            if preview.images.indices.contains(preview.index) {
                VStack(spacing: 14) {
                    OutlinedImage(image: preview.images[preview.index])
                        .frame(maxWidth: size.width * 0.84, maxHeight: size.height * 0.78)
                        .onTapGesture {} // clicks on the picture don't close it
                        .id(preview.index)
                        .transition(.opacity)

                    if preview.takesNote {
                        NoteField(preview: preview)
                            .frame(width: min(560, size.width * 0.6))
                    }

                    HStack(spacing: 14) {
                        if preview.images.count > 1 {
                            pager("chevron.left") { preview.step(-1) }
                            Text("\(preview.index + 1) / \(preview.images.count)")
                                .font(Theme.Typography.ui(12, .medium))
                                .monospacedDigit()
                            pager("chevron.right") { preview.step(1) }
                        }
                        // The keys in little outlines, like the capture card's,
                        // centered on the words beside them.
                        HStack(alignment: .center, spacing: 6) {
                            if preview.takesNote {
                                PreviewKey("return")
                                Text("or")
                                PreviewKey("esc")
                                Text("to save   ·   click outside to close")
                            } else {
                                PreviewKey("esc")
                                Text("or click outside to close")
                            }
                        }
                        .font(Archive.sans(12))
                        .opacity(0.6)
                    }
                    .foregroundStyle(.white.opacity(0.85))
                    .onTapGesture {}
                }
                .scaleEffect(preview.shown ? 1 : 0.96)
                .opacity(preview.shown ? 1 : 0)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private func pager(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.white.opacity(0.12)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

/// The picture in its own shape, as it was captured, with a thin grey line
/// that traces its outline: square for an area or a window (its rounded
/// corners are filled in, see ImageTools.squareCorners), round for a round
/// frame. Drawn as the picture's silhouette nudged a point in
/// each direction underneath it.
private struct OutlinedImage: View {
    let image: NSImage
    private static let offsets: [CGSize] = [
        CGSize(width: -1, height: 0), CGSize(width: 1, height: 0), CGSize(width: 0, height: -1), CGSize(width: 0, height: 1),
        CGSize(width: -0.7, height: -0.7), CGSize(width: 0.7, height: -0.7), CGSize(width: -0.7, height: 0.7), CGSize(width: 0.7, height: 0.7),
    ]

    var body: some View {
        let picture = Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
        ZStack {
            ZStack {
                ForEach(Self.offsets.indices, id: \.self) { index in
                    picture.offset(Self.offsets[index])
                }
            }
            // A flat grey silhouette: every pixel white, then dimmed; transparency kept.
            .brightness(1)
            .compositingGroup()
            .opacity(0.35)
            picture
        }
    }
}

/// The annotation field under the picture, on the dark backdrop.
private struct NoteField: View {
    @ObservedObject var preview: ImagePreview
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $preview.note, prompt: Text("Add an annotation...").foregroundColor(.white.opacity(0.45)))
            .textFieldStyle(.plain)
            .font(Theme.Typography.ui(14))
            .foregroundStyle(.white)
            .focused($focused)
            .onSubmit { preview.submit() }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(focused ? 0.14 : 0.1)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(focused ? 0.28 : 0.14), lineWidth: 1))
            .onTapGesture {}
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { focused = true }
            }
    }
}

/// A key's name in a small outline, so it reads as a key on the keyboard.
private struct PreviewKey: View {
    let name: String
    init(_ name: String) { self.name = name }

    var body: some View {
        Text(name)
            .font(Theme.Typography.mono(9, .medium))
            .padding(.horizontal, 5)
            .frame(height: 17)
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
    }
}
