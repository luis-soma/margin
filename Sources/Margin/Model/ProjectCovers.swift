import AppKit
import MarginKit
import SwiftUI
import UniformTypeIdentifiers

/// A project's chosen cover, kept next to the captures in `covers/`. A
/// project without one shows its newest captures instead.
@MainActor
enum ProjectCovers {
    private static var cache: [String: (date: Date, image: NSImage)] = [:]

    static func folder(_ store: EntryStore) -> URL {
        store.baseURL.appendingPathComponent("covers", isDirectory: true)
    }

    static func url(for project: String, in store: EntryStore) -> URL {
        folder(store).appendingPathComponent(HandoverExporter.safe(project) + ".png")
    }

    /// The cover, if the project has one (cached until the file changes).
    /// A cover iCloud keeps only in the cloud is fetched in the background
    /// and shows when it's in: reading it here froze Margin at launch.
    static func image(for project: String, in store: EntryStore) -> NSImage? {
        let url = url(for: project, in: store)
        guard let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { return nil }
        if let hit = cache[url.path], hit.date == date { return hit.image }
        guard EntryStore.isOnThisMac(url) else {
            loadLater(url, date: date, store: store)
            return nil
        }
        guard let image = NSImage(contentsOf: url) else { return nil }
        cache[url.path] = (date, image)
        return image
    }

    private static var loading: Set<String> = []

    private static func loadLater(_ url: URL, date: Date, store: EntryStore) {
        guard !loading.contains(url.path) else { return }
        loading.insert(url.path)
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        EntryStore.fileQueue.async {
            let data = try? Data(contentsOf: url)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    loading.remove(url.path)
                    guard let data, let image = NSImage(data: data) else { return }
                    cache[url.path] = (date, image)
                    store.picturesArrived()
                }
            }
        }
    }

    static func has(_ project: String, in store: EntryStore) -> Bool {
        FileManager.default.fileExists(atPath: url(for: project, in: store).path)
    }

    /// Saves `image` as the project's cover (as PNG, at most 1600 px wide).
    static func set(_ image: NSImage, for project: String, in store: EntryStore) {
        guard let png = pngData(image, maxWidth: 1600) else { return }
        try? FileManager.default.createDirectory(at: folder(store), withIntermediateDirectories: true)
        try? png.write(to: url(for: project, in: store), options: .atomic)
        store.objectWillChange.send()
    }

    /// Picks a picture from disk for the cover.
    static func choose(for project: String, in store: EntryStore) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a cover for \(project)"
        guard panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url) else { return }
        set(image, for: project, in: store)
        UserDefaults.standard.set(true, forKey: chosenKey(project))
    }

    /// Back to the newest captures.
    static func clear(_ project: String, in store: EntryStore) {
        UserDefaults.standard.removeObject(forKey: chosenKey(project))
        try? FileManager.default.removeItem(at: url(for: project, in: store))
        store.objectWillChange.send()
    }

    // MARK: Shipped

    /// Covers that ship with the app (Resources/Covers), by project name: a
    /// looping film or a picture. They come before any cover set for the
    /// project, until you choose one yourself.
    enum Shipped {
        case film(URL)
        case picture(NSImage)
    }

    private static var shippedPictures: [String: NSImage] = [:]

    static func shipped(for project: String) -> Shipped? {
        guard !UserDefaults.standard.bool(forKey: chosenKey(project)),
              let folder = Bundle.main.url(forResource: "Covers", withExtension: nil) else { return nil }
        let base = folder.appendingPathComponent(HandoverExporter.safe(project))
        for ext in ["mp4", "mov"] where FileManager.default.fileExists(atPath: base.appendingPathExtension(ext).path) {
            return .film(base.appendingPathExtension(ext))
        }
        for ext in ["jpg", "png"] {
            let url = base.appendingPathExtension(ext)
            if let hit = shippedPictures[url.path] { return .picture(hit) }
            if let image = NSImage(contentsOf: url) {
                shippedPictures[url.path] = image
                return .picture(image)
            }
        }
        return nil
    }

    private static func chosenKey(_ project: String) -> String { "coverChosen." + project }

    static func pngData(_ image: NSImage, maxWidth: CGFloat) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = min(1, maxWidth / CGFloat(cg.width))
        let w = Int(CGFloat(cg.width) * scale), h = Int(CGFloat(cg.height) * scale)
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let scaled = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: scaled).representation(using: .png, properties: [:])
    }
}

// MARK: - Profile

/// Who's using Margin: a name and a picture, shown top right of the
/// projects page. Kept on this Mac.
@MainActor
final class Profile: ObservableObject {
    static let shared = Profile()

    @Published var name: String {
        didSet { UserDefaults.standard.set(name, forKey: "profileName") }
    }
    @Published private(set) var image: NSImage?

    private static var imageURL: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Margin", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("profile.png")
    }

    private init() {
        let first = NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
        name = UserDefaults.standard.string(forKey: "profileName") ?? first
        image = NSImage(contentsOf: Self.imageURL)
    }

    /// Initials for when there's no picture.
    var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap(\.first).map(String.init).joined()
        return letters.isEmpty ? "·" : letters.uppercased()
    }

    func choosePicture() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Choose your picture"
        guard panel.runModal() == .OK, let url = panel.url, let picked = NSImage(contentsOf: url),
              let png = ProjectCovers.pngData(picked, maxWidth: 400) else { return }
        try? png.write(to: Self.imageURL, options: .atomic)
        image = NSImage(data: png)
    }

    func removePicture() {
        try? FileManager.default.removeItem(at: Self.imageURL)
        image = nil
    }
}

/// The round picture (or initials) for the profile. With no picture, the
/// initials sit on a colour picked from the name, so it's never a grey blank.
struct ProfileAvatar: View {
    @ObservedObject var profile = Profile.shared
    var size: CGFloat = 22

    /// Calm, mid-tone colours that hold white initials.
    private static let colors: [Color] = [
        Color(red: 0.29, green: 0.48, blue: 0.81),  // blue
        Color(red: 0.24, green: 0.60, blue: 0.35),  // green
        Color(red: 0.87, green: 0.47, blue: 0.22),  // orange
        Color(red: 0.55, green: 0.42, blue: 0.80),  // violet
        Color(red: 0.80, green: 0.36, blue: 0.47),  // rose
        Color(red: 0.20, green: 0.56, blue: 0.62),  // teal
    ]

    private var color: Color {
        let seed = profile.name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return Self.colors[abs(seed) % Self.colors.count]
    }

    var body: some View {
        ZStack {
            Circle().fill(color)
            if let image = profile.image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Text(profile.initials)
                    .font(Theme.Typography.ui(size * 0.42, .medium)).textCase(.uppercase)
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }
}
