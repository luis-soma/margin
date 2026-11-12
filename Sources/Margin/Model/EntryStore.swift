import AppKit
import Foundation
import ImageIO
import MarginKit

/// Persists entries as JSON and images as files in Margin's own folder,
/// ~/Library/Application Support/Margin/Archive (out of iCloud; see ArchiveHome).
@MainActor
final class EntryStore: ObservableObject {
    @Published private(set) var entries: [Entry] = []
    @Published var currentProject: String {
        didSet { UserDefaults.standard.set(currentProject, forKey: projectKey) }
    }

    let baseURL: URL
    let imagesURL: URL
    /// While the archive is still coming over from Documents: where a
    /// picture that hasn't arrived yet is read from.
    private let oldImagesURL: URL?
    private let entriesURL: URL
    private let thumbnails = NSCache<NSString, NSImage>()
    private var aspects: [String: CGFloat] = [:]
    /// Sizes being read in the background (or that couldn't be read).
    private var pendingAspects: Set<String> = []
    private var aspectsSaveScheduled = false
    private var pendingThumbnails: Set<String> = []
    private var aspectsBumpScheduled = false
    /// Bumped when picture sizes arrive in the background, so a layout that
    /// had to guess can take the real ones.
    @Published private(set) var aspectsVersion = 0
    private let projectKey: String
    /// entries.json as this copy last read or wrote it. Another copy of
    /// Margin open on the same archive changes it; then it's read again
    /// before any change here, so neither copy undoes the other's.
    private var diskStamp: DiskStamp?

    /// `projectKey` remembers the open project; the demo keeps its own.
    init(baseURL: URL? = nil, projectKey: String = "currentProject") {
        self.projectKey = projectKey
        let root = baseURL ?? ArchiveHome.main
        self.baseURL = root
        self.imagesURL = root.appendingPathComponent("images", isDirectory: true)
        self.oldImagesURL = ArchiveHome.movingFrom(root)?.appendingPathComponent("images", isDirectory: true)
        self.entriesURL = root.appendingPathComponent("entries.json")
        self.currentProject = UserDefaults.standard.string(forKey: projectKey) ?? "Untitled project"
        try? FileManager.default.createDirectory(at: imagesURL, withIntermediateDirectories: true)
        load()
        loadAspects()
        bringPicturesBack()
    }

    // MARK: Projects

    var projects: [String] {
        Set(entries.map(\.project)).union([currentProject]).sorted()
    }

    // MARK: Queries

    var lastEntryDate: Date? {
        entries.map(\.createdAt).max()
    }

    /// The last time the designer put words to something.
    var lastIntentionalEntryDate: Date? {
        entries.filter { $0.kind.isIntentional || !$0.rationale.trimmed.isEmpty }.map(\.createdAt).max()
    }

    /// Newest first.
    func entries(in project: String) -> [Entry] {
        entries.filter { $0.project == project }.sorted { $0.createdAt > $1.createdAt }
    }

    /// Oldest first.
    func chronological(in project: String) -> [Entry] {
        entries.filter { $0.project == project }.sorted { $0.createdAt < $1.createdAt }
    }

    /// Newest first.
    func todaysEntries(in project: String) -> [Entry] {
        entries(in: project).filter { Calendar.current.isDateInToday($0.createdAt) }
    }

    func entry(id: UUID) -> Entry? {
        entries.first { $0.id == id }
    }

    // MARK: Changes

    func newEntry(_ kind: EntryKind) -> Entry {
        Entry(kind: kind, project: currentProject)
    }

    func add(_ entry: Entry) {
        reloadIfChanged()
        entries.append(entry)
        save()
    }

    func add(contentsOf newEntries: [Entry]) {
        guard !newEntries.isEmpty else { return }
        reloadIfChanged()
        entries.append(contentsOf: newEntries)
        save()
    }

    func update(_ entry: Entry) {
        reloadIfChanged()
        // Gone: deleted in another copy of Margin; it stays deleted.
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index] = entry
        save()
    }

    func modify(_ id: UUID, _ change: (inout Entry) -> Void) {
        reloadIfChanged()
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        change(&entries[index])
        save()
    }

    func delete(_ entry: Entry) {
        reloadIfChanged()
        entries.removeAll { $0.id == entry.id }
        save()
        // Its files go after it's saved without them, and only those no
        // other capture still shows.
        var files = [entry.imageFile, entry.mediaFile]
        for frame in entry.frames ?? [] { files += [frame.imageFile, frame.mediaFile] }
        for file in Set(files.compactMap { $0 }) { removeUnusedFile(file) }
    }

    // MARK: Images

    func imageURL(for entry: Entry) -> URL? {
        entry.imageFile.map { located($0) }
    }

    func imageURL(forFile file: String) -> URL {
        located(file)
    }

    /// The recording or rich text file of an entry.
    func mediaURL(for entry: Entry) -> URL? {
        entry.mediaFile.map { located($0) }
    }

    /// A file in the archive's images; while the archive is still coming
    /// over from Documents, the old copy until this one has arrived.
    private func located(_ file: String) -> URL {
        let here = imagesURL.appendingPathComponent(file)
        guard let oldImagesURL, !FileManager.default.fileExists(atPath: here.path) else { return here }
        let there = oldImagesURL.appendingPathComponent(file)
        return FileManager.default.fileExists(atPath: there.path) ? there : here
    }

    /// Writes bytes into the images folder and returns the file name.
    func saveFile(_ data: Data, ext: String) -> String? {
        let url = newImageURL(ext: ext)
        do {
            try data.write(to: url, options: .atomic)
            return url.lastPathComponent
        } catch {
            NSLog("Margin: failed to save \(url.lastPathComponent): \(error)")
            return nil
        }
    }

    func newImageURL(ext: String = "png") -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let suffix = UUID().uuidString.prefix(4).lowercased()
        return imagesURL.appendingPathComponent("\(formatter.string(from: Date()))-\(suffix).\(ext)")
    }

    /// Saves an image as PNG and returns its file name.
    func saveImage(_ image: NSImage) -> String? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let url = newImageURL()
        do {
            try png.write(to: url)
            return url.lastPathComponent
        } catch {
            return nil
        }
    }

    /// A draft's picture, when the draft is thrown away (never saved).
    func discardImage(of entry: Entry) {
        if let file = entry.imageFile { removeUnusedFile(file) }
    }

    /// Removes a file from the images folder unless a capture still uses it,
    /// here or (read again from disk) in another copy of Margin.
    private func removeUnusedFile(_ file: String) {
        reloadIfChanged()
        let inUse = entries.contains { entry in
            entry.imageFile == file || entry.mediaFile == file
                || (entry.frames ?? []).contains { $0.imageFile == file || $0.mediaFile == file }
        }
        guard !inUse else {
            MarginLog.info("Kept \(file): another capture still uses it")
            return
        }
        removeImageFile(file)
    }

    private func removeImageFile(_ file: String) {
        thumbnails.removeObject(forKey: file as NSString)
        // Only ever here: the old folder in Documents stays as it was.
        try? FileManager.default.removeItem(at: imagesURL.appendingPathComponent(file))
    }

    /// A small, cached version of the entry's image for grids and lists.
    /// Redraws the pictures of text captures once (they used to fill only a
    /// corner of their frame). Safe to call at launch.
    func redrawTextPreviews(dark: Bool) {
        let key = "textPreviewsRedrawn2"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let jobs: [(rich: URL, image: URL)] = entries.compactMap { entry in
            guard entry.kind == .text, let image = entry.imageFile, let rich = mediaURL(for: entry) else { return nil }
            return (rich, imagesURL.appendingPathComponent(image))
        }
        // Text loading runs on the main thread; there are few of these, and
        // a pause between them keeps the app responsive.
        Task { @MainActor [weak self] in
            for job in jobs {
                if let text = RichText.load(contentsOf: job.rich), let png = RichText.preview(text, dark: dark) {
                    try? png.write(to: job.image, options: .atomic)
                }
                await Task.yield()
            }
            self?.thumbnails.removeAllObjects()
            self?.objectWillChange.send()
            UserDefaults.standard.set(true, forKey: key)
        }
    }

    /// Width over height of the entry's picture, read once from the file's
    /// header (the image itself isn't decoded) and remembered between launches.
    ///
    /// The archive lives in Documents, which iCloud may keep only in the
    /// cloud. Reading such a file means waiting for its download: on the
    /// main thread that froze Margin for minutes at launch. So a picture
    /// that isn't on this Mac is read in the background, and the layout
    /// takes its real size when it arrives (`aspectsVersion`).
    func aspectRatio(for entry: Entry) -> CGFloat? {
        guard let file = entry.imageFile else { return nil }
        if let known = aspects[file] { return known }
        let url = imageURL(forFile: file)
        guard Self.isOnThisMac(url) else {
            readAspectLater(file, url: url)
            return nil
        }
        guard let ratio = Self.readAspect(url) else { return nil }
        aspects[file] = ratio
        scheduleAspectsSave()
        return ratio
    }

    /// Whether the file's contents are on this Mac (not only in iCloud).
    /// Never triggers a download.
    nonisolated static func isOnThisMac(_ url: URL) -> Bool {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return false }
        // SF_DATALESS: iCloud keeps the contents; reading it downloads first.
        return info.st_flags & 0x4000_0000 == 0
    }

    /// One file at a time, off the main thread: reads that wait on iCloud
    /// queue here instead of tying up Swift's shared threads.
    nonisolated static let fileQueue = DispatchQueue(label: "margin.picture-files", qos: .utility)

    nonisolated static func readAspect(_ url: URL) -> CGFloat? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0 else { return nil }
        // Orientations 5 to 8 are rotated a quarter turn.
        let rotated = ((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1) >= 5
        return CGFloat(rotated ? height / width : width / height)
    }

    private func readAspectLater(_ file: String, url: URL) {
        guard !pendingAspects.contains(file) else { return }
        pendingAspects.insert(file)
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        Task {
            let ratio: CGFloat? = await withCheckedContinuation { done in
                Self.fileQueue.async { done.resume(returning: Self.readAspect(url)) }
            }
            // Unreadable stays pending: not tried again this launch.
            guard let ratio else { return }
            pendingAspects.remove(file)
            aspects[file] = ratio
            scheduleAspectsSave()
            picturesArrived()
        }
    }

    /// Sizes or pictures came in from iCloud: one redraw for the lot.
    func picturesArrived() {
        guard !aspectsBumpScheduled else { return }
        aspectsBumpScheduled = true
        Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            aspectsBumpScheduled = false
            aspectsVersion += 1
        }
    }

    /// Kept outside the archive (and outside iCloud), one file per archive.
    private var aspectsURL: URL {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Margin", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("aspects" + baseURL.path.replacingOccurrences(of: "/", with: "_") + ".json")
    }

    private func loadAspects() {
        guard let data = try? Data(contentsOf: aspectsURL),
              let saved = try? JSONDecoder().decode([String: Double].self, from: data) else { return }
        for (file, ratio) in saved where aspects[file] == nil { aspects[file] = CGFloat(ratio) }
    }

    private func scheduleAspectsSave() {
        guard !aspectsSaveScheduled else { return }
        aspectsSaveScheduled = true
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            aspectsSaveScheduled = false
            let saved = aspects.mapValues { Double($0) }
            if let data = try? JSONEncoder().encode(saved) { try? data.write(to: aspectsURL, options: .atomic) }
        }
    }

    /// Asks iCloud to bring back any of the archive's pictures it has taken
    /// off this Mac, in the background, so they're local next time.
    private func bringPicturesBack() {
        let folder = imagesURL
        // After launch has settled: hundreds of downloads at once slowed every
        // other file read, the ones launch needs included.
        Self.fileQueue.asyncAfter(deadline: .now() + 15) {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
            var asked = 0
            for name in names {
                let url = folder.appendingPathComponent(name)
                guard !EntryStore.isOnThisMac(url) else { continue }
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                asked += 1
            }
            if asked > 0 { MarginLog.info("iCloud: asked to bring back \(asked) pictures that were only in the cloud") }
        }
    }

    func thumbnail(for entry: Entry) -> NSImage? {
        guard let file = entry.imageFile else { return nil }
        return thumbnail(forFile: file)
    }

    /// Reads and decodes on the spot when it isn't cached yet. Fine for one
    /// picture; anything that scrolls uses `cachedThumbnail` and
    /// `loadThumbnail`, so the window never waits on the disk.
    func thumbnail(forFile file: String) -> NSImage? {
        if let cached = thumbnails.object(forKey: file as NSString) { return cached }
        let url = imageURL(forFile: file)
        // Only in iCloud: never wait for it here. It's fetched in the
        // background and the views that asked draw again when it's in.
        guard Self.isOnThisMac(url) else {
            if !pendingThumbnails.contains(file) {
                pendingThumbnails.insert(file)
                Task {
                    if await loadThumbnail(forFile: file) != nil { picturesArrived() }
                    pendingThumbnails.remove(file)
                }
            }
            return nil
        }
        guard let image = Self.decodeThumbnail(url) else { return nil }
        thumbnails.setObject(image, forKey: file as NSString)
        return image
    }

    /// The thumbnail if it's ready, without touching the disk.
    func cachedThumbnail(forFile file: String) -> NSImage? {
        thumbnails.object(forKey: file as NSString)
    }

    /// The thumbnail, decoded off the main thread and then kept.
    func loadThumbnail(forFile file: String) async -> NSImage? {
        if let cached = thumbnails.object(forKey: file as NSString) { return cached }
        let url = imageURL(forFile: file)
        let image: NSImage?
        if Self.isOnThisMac(url) {
            image = await Task.detached(priority: .userInitiated) { EntryStore.decodeThumbnail(url) }.value
        } else {
            // In iCloud only: wait for it in the file queue, not the shared threads.
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            image = await withCheckedContinuation { done in
                Self.fileQueue.async { done.resume(returning: EntryStore.decodeThumbnail(url)) }
            }
        }
        if let image { thumbnails.setObject(image, forKey: file as NSString) }
        return image
    }

    /// 640 px on the long side, corners squared. Safe on any thread.
    nonisolated static func decodeThumbnail(_ url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 640,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let cg = ImageTools.squareCorners(thumbnail)
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    // MARK: Persistence

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let data = try? Data(contentsOf: entriesURL) {
            do {
                entries = try decoder.decode([Entry].self, from: data)
                diskStamp = DiskStamp(entriesURL)
            } catch {
                // Keep the unreadable file instead of overwriting it on the next save.
                let backup = baseURL.appendingPathComponent("entries-unreadable-\(Int(Date().timeIntervalSince1970)).json")
                try? FileManager.default.moveItem(at: entriesURL, to: backup)
                NSLog("Margin: could not read entries.json, moved it to \(backup.path): \(error)")
            }
        }
    }

    private func save() {
        write(entries, to: entriesURL)
        diskStamp = DiskStamp(entriesURL)
    }

    /// Reads entries.json again if another copy of Margin wrote it since
    /// this one did. An unreadable file (an older build mid-write) is left
    /// alone and what's in memory is kept.
    func reloadIfChanged() {
        guard let now = DiskStamp(entriesURL), now != diskStamp,
              let data = try? Data(contentsOf: entriesURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let fresh = try? decoder.decode([Entry].self, from: data) else { return }
        entries = fresh
        diskStamp = now
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(value).write(to: url, options: .atomic)
        } catch {
            NSLog("Margin: failed to save \(url.lastPathComponent): \(error)")
        }
    }
}

/// Identifies one version of a file: an atomic write replaces the file, so
/// its file number changes even within the same instant.
private struct DiskStamp: Equatable {
    let modified: Date
    let size: Int
    let fileNumber: Int

    init?(_ url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date else { return nil }
        self.modified = modified
        size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.intValue ?? 0
    }
}
