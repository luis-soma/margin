import AppKit
import SwiftUI

/// A capture's thumbnail that never makes the window wait. A cached one
/// shows at once; otherwise a blank stands in while it's decoded off the
/// main thread, then the picture fades in. A card that only passes by while
/// you scroll fast is skipped before any work starts.
struct AsyncThumbnail<Placeholder: View>: View {
    /// Passed plainly, not observed: a thumbnail doesn't redraw when
    /// anything else in the archive changes.
    let store: EntryStore
    let file: String
    let interpolation: Image.Interpolation
    let placeholder: () -> Placeholder

    @State private var loaded: NSImage?
    @State private var loadedFile: String?

    init(store: EntryStore, file: String, interpolation: Image.Interpolation = .medium,
         @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.store = store
        self.file = file
        self.interpolation = interpolation
        self.placeholder = placeholder
    }

    var body: some View {
        let image = (loadedFile == file ? loaded : nil) ?? store.cachedThumbnail(forFile: file)
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(interpolation)
                    .scaledToFill()
                    .transition(.opacity)
            } else {
                placeholder()
            }
        }
        .task(id: file) {
            guard store.cachedThumbnail(forFile: file) == nil else { return }
            // Only passing by: let it go before reading anything.
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled else { return }
            let image = await store.loadThumbnail(forFile: file)
            guard !Task.isCancelled, let image else { return }
            withAnimation(.easeOut(duration: 0.15)) {
                loaded = image
                loadedFile = file
            }
        }
    }
}
