import AVFoundation
import AppKit
import ImageIO
import MarginKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Files dropped on the archive from Finder (or handed over by Claude).
/// Each becomes a capture in the open project, in the form that suits it: a
/// picture, a recording, a live prototype for an HTML page or a site folder,
/// a note for text, a link for a web location, and the file itself, shown by
/// its Quick Look picture, for anything else. Each is placed in time by when
/// it was made (the photo's EXIF date, the video's recording date, else
/// Finder's dates), with its name, Finder tags, where it was downloaded from
/// and the app or camera that made it. Files are copied, never moved.
@MainActor
enum FileImport {
    /// What a file becomes in Margin.
    enum Kind: String, CaseIterable, Identifiable {
        case picture, recording, prototype, note, link, file

        var id: String { rawValue }
        var name: String {
            switch self {
            case .picture: return "Picture"
            case .recording: return "Recording"
            case .prototype: return "Prototype"
            case .note: return "Note"
            case .link: return "Link"
            case .file: return "File"
            }
        }
        /// A line on what it'll be, for the menu.
        var detail: String {
            switch self {
            case .picture: return "Shown as it is"
            case .recording: return "Plays in the archive"
            case .prototype: return "Runs, so you can click through it"
            case .note: return "Its text, to read and search"
            case .link: return "The website, live"
            case .file: return "The file, with its preview"
            }
        }
        var symbol: String {
            switch self {
            case .picture: return "photo"
            case .recording: return "play.rectangle"
            case .prototype: return "macwindow"
            case .note: return "text.alignleft"
            case .link: return "link"
            case .file: return "doc"
            }
        }
    }

    /// One file on its way in, with what can still be changed: its name,
    /// what it becomes and when it happened.
    struct Item: Identifiable {
        let id = UUID()
        let url: URL
        var name: String
        var kind: Kind
        /// What else it can be.
        let kinds: [Kind]
        var date: Date
        var facts: Facts
        var preview: NSImage?
    }

    /// What a file says about itself, read before it's copied.
    struct Facts: Equatable {
        var date: Date
        var name: String
        var link: String?
        var source: String?
        var tags: [String] = []
    }

    /// Imports the files (folders are opened) into `project`, as they are.
    /// Returns the new entries; files already in the project are skipped.
    @discardableResult
    static func importFiles(_ urls: [URL], into store: EntryStore, project: String) async -> [Entry] {
        await add(await prepare(urls), into: store, project: project)
    }

    /// The files read and sorted out, oldest first, ready to look over before
    /// they go in.
    static func prepare(_ urls: [URL]) async -> [Item] {
        var items: [Item] = []
        for url in expand(urls) {
            let facts = await facts(for: url)
            let kinds = options(for: url)
            items.append(Item(url: url, name: facts.name, kind: kinds[0], kinds: kinds, date: facts.date, facts: facts,
                              preview: await previewImage(url)))
        }
        return items.sorted { $0.date < $1.date }
    }

    /// Adds `items` to `project` as they were set. Returns the new entries;
    /// any already in the project are skipped.
    @discardableResult
    static func add(_ items: [Item], into store: EntryStore, project: String) async -> [Entry] {
        var added: [Entry] = []
        for item in items {
            let already = store.entries.contains {
                $0.project == project && $0.label == item.name && abs($0.createdAt.timeIntervalSince(item.date)) < 1
            }
            guard !already, let entry = await makeEntry(item, store: store, project: project) else { continue }
            added.append(entry)
        }
        store.add(contentsOf: added)
        return added
    }

    /// What a file can become, the best fit first.
    static func options(for url: URL) -> [Kind] {
        if isSite(url) { return [.prototype, .file] }
        let ext = url.pathExtension.lowercased()
        if ["html", "htm", "xhtml"].contains(ext) { return [.prototype, .note, .file] }
        if ["webloc", "url"].contains(ext), webLocation(url) != nil { return [.link, .file] }
        if isType(url, .movie) { return [.recording, .file] }
        if isType(url, .image) { return [.picture, .file] }
        if isType(url, .plainText) || ["md", "markdown"].contains(ext) { return [.note, .file] }
        return [.file]
    }

    /// A folder that is a website: an index.html at its top.
    static func isSite(_ url: URL) -> Bool {
        var folder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &folder), folder.boolValue else { return false }
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("index.html").path)
    }

    /// The address in a .webloc or .url file.
    static func webLocation(_ url: URL) -> URL? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let raw = plist["URL"] as? String {
            return URL(string: raw)
        }
        // Windows .url: "URL=https://…" in an INI file.
        let text = String(decoding: data, as: UTF8.self)
        guard let line = text.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("URL=") }) else { return nil }
        return URL(string: String(line.dropFirst(4)))
    }

    /// The files themselves: folders are walked (a website folder stays
    /// whole), hidden files left out.
    static func expand(_ urls: [URL]) -> [URL] {
        var files: [URL] = []
        for url in urls {
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])).map { ($0.isDirectory ?? false) && !($0.isPackage ?? false) } ?? false
            if isFolder, isSite(url) {
                files.append(url)
            } else if isFolder {
                let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants])
                while let file = walker?.nextObject() as? URL {
                    if (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { files.append(file) }
                }
            } else if !url.lastPathComponent.hasPrefix(".") {
                files.append(url)
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    // MARK: What the file says

    static func facts(for url: URL) async -> Facts {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey, .tagNamesKey])
        let spotlight = MDItemCreateWithURL(nil, url as CFURL)
        func attribute(_ key: CFString) -> Any? { spotlight.flatMap { MDItemCopyAttribute($0, key) } }

        let photo = imageFacts(url)
        let recorded = await videoDate(url)
        let date = photo.date
            ?? recorded
            ?? attribute(kMDItemContentCreationDate) as? Date
            ?? values?.creationDate
            ?? values?.contentModificationDate
            ?? Date()
        let link = (attribute(kMDItemWhereFroms) as? [String])?.first { $0.hasPrefix("http") }
        let source = photo.source ?? (attribute(kMDItemCreator) as? String)?.nonEmpty
        return Facts(
            date: date,
            name: isSite(url) ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent,
            link: link,
            source: source,
            tags: values?.tagNames ?? []
        )
    }

    /// The photo's own date (when it was taken, in the time zone it was taken
    /// in when the file says) and the app or camera that made it.
    static func imageFacts(_ url: URL) -> (date: Date?, source: String?) {
        guard let image = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any] else { return (nil, nil) }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let stamp = exif[kCGImagePropertyExifDateTimeOriginal] as? String
            ?? exif[kCGImagePropertyExifDateTimeDigitized] as? String
            ?? tiff[kCGImagePropertyTIFFDateTime] as? String
        let offset = exif[kCGImagePropertyExifOffsetTimeOriginal] as? String ?? exif[kCGImagePropertyExifOffsetTime] as? String
        let camera = [tiff[kCGImagePropertyTIFFMake] as? String, tiff[kCGImagePropertyTIFFModel] as? String]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces).nonEmpty }
        let model = camera.count == 2 && camera[1].hasPrefix(camera[0]) ? [camera[1]] : camera
        let source = (tiff[kCGImagePropertyTIFFSoftware] as? String)?.nonEmpty ?? model.joined(separator: " ").nonEmpty
        return (stamp.flatMap { exifDate($0, offset: offset) }, source)
    }

    /// "2026:10:18 21:03:12" (and "+02:00" when known) as a date.
    static func exifDate(_ text: String, offset: String?) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if let offset {
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ssxxx"
            if let date = formatter.date(from: text + offset) { return date }
        }
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = .current
        return formatter.date(from: text)
    }

    private static func videoDate(_ url: URL) async -> Date? {
        guard isType(url, .audiovisualContent) else { return nil }
        let asset = AVURLAsset(url: url)
        guard let item = try? await asset.load(.creationDate) else { return nil }
        return try? await item.load(.dateValue)
    }

    // MARK: Making the capture

    /// The capture for `item`, in the form chosen for it.
    static func makeEntry(_ item: Item, store: EntryStore, project: String) async -> Entry? {
        let url = item.url
        var entry = Entry(kind: .capture, project: project)
        entry.createdAt = item.date
        entry.label = item.name
        entry.sourceApp = item.facts.source
        entry.link = item.facts.link ?? ""
        entry.tags = item.facts.tags
        let ext = url.pathExtension.lowercased()

        switch item.kind {
        case .recording:
            guard let copy = copy(url, store: store) else { return nil }
            entry.kind = .recording
            entry.mediaFile = copy.lastPathComponent
            entry.duration = await VideoTools.duration(of: copy)
            if let poster = await VideoTools.poster(for: copy) {
                entry.imageFile = writePreview(poster, store: store)
            }
        case .picture:
            guard let image = ImageTools.load(url) else { return nil }
            if ["png", "jpg", "jpeg"].contains(ext) {
                guard let copy = copy(url, store: store) else { return nil }
                entry.imageFile = copy.lastPathComponent
            } else {
                // HEIC, GIF, TIFF, WebP…: keep the original, show a PNG of it.
                entry.mediaFile = copy(url, store: store)?.lastPathComponent
                entry.imageFile = writePreview(image, store: store)
            }
        case .prototype:
            guard await makePrototype(url, into: &entry, store: store) else { return nil }
        case .note:
            guard var text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            if ["html", "htm", "xhtml"].contains(ext) {
                text = (try? NSAttributedString(data: Data(text.utf8), options: [.documentType: NSAttributedString.DocumentType.html,
                                                                                 .characterEncoding: String.Encoding.utf8.rawValue],
                                                documentAttributes: nil).string) ?? text
            }
            entry.kind = .note
            entry.title = item.name
            entry.body = String(text.prefix(20_000))
        case .link:
            guard let address = webLocation(url) else { return nil }
            entry.kind = .link
            entry.link = address.absoluteString
            if let shot = await PagePreview.shot(address, timeout: 15) {
                entry.imageFile = store.saveFile(shot.png, ext: "png")
                if let title = shot.title, !title.isEmpty { entry.label = title }
            }
        case .file:
            // A PDF, a Figma or Sketch file, a zip, a site kept as files: the
            // file itself, shown by its Quick Look picture.
            if isSite(url) {
                guard await makePrototype(url, into: &entry, store: store) else { return nil }
                return entry
            }
            guard let copy = copy(url, store: store) else { return nil }
            entry.mediaFile = copy.lastPathComponent
            if let preview = await thumbnail(url) {
                entry.imageFile = writePreview(preview, store: store)
            }
        }
        return entry
    }

    /// An HTML page or a site folder, copied whole into Margin and served by
    /// it, so it runs in the archive the way a Claude Code capture does;
    /// pictured from that copy.
    static func makePrototype(_ url: URL, into entry: inout Entry, store: EntryStore) async -> Bool {
        let site = isSite(url)
        let page = site ? url.appendingPathComponent("index.html") : url
        let root = site ? url : url.deletingLastPathComponent()
        let relative = "sites/\(entry.id.uuidString)"
        let folder = store.baseURL.appendingPathComponent(relative, isDirectory: true)
        guard let copy = try? await Task.detached(operation: { try ClaudeSite.copy(page: page, project: root, to: folder) }).value else {
            MarginLog.info("Import: copying the site of \(url.lastPathComponent) failed")
            return false
        }
        entry.siteFolder = relative
        entry.sitePage = copy.page
        await picture(site: folder, page: copy.page, into: &entry, store: store)
        return true
    }

    /// A page given as HTML (a Claude artifact): saved as a site of its own.
    static func makePrototype(html: String, into entry: inout Entry, store: EntryStore) async -> Bool {
        let relative = "sites/\(entry.id.uuidString)"
        let folder = store.baseURL.appendingPathComponent(relative, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(html.utf8).write(to: folder.appendingPathComponent("index.html"))
        } catch {
            return false
        }
        entry.siteFolder = relative
        entry.sitePage = "index.html"
        await picture(site: folder, page: "index.html", into: &entry, store: store)
        return true
    }

    private static func picture(site folder: URL, page: String, into entry: inout Entry, store: EntryStore) async {
        let coding = AppModel.shared.coding
        let served = try? coding.sites.url(for: folder, page: page)
        if let shot = await PagePreview.shot(served ?? folder.appendingPathComponent(page)) {
            entry.imageFile = coding.saveJPEG(shot.png)
            if let title = shot.title, !title.isEmpty, entry.label == nil || entry.label == "index" { entry.label = title }
        }
    }

    /// A small picture for the list before adding: the file's own, or its
    /// Quick Look one.
    static func previewImage(_ url: URL) async -> NSImage? {
        let target = isSite(url) ? url.appendingPathComponent("index.html") : url
        if isType(target, .image), let image = ImageTools.load(target) {
            let small = ImageTools.resized(image, maxWidth: 160, keepingAlpha: true) ?? image
            return NSImage(cgImage: small, size: NSSize(width: small.width, height: small.height))
        }
        guard let image = await thumbnail(target, size: CGSize(width: 120, height: 120)) else {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    private static func isType(_ url: URL, _ type: UTType) -> Bool {
        (UTType(filenameExtension: url.pathExtension) ?? .data).conforms(to: type)
    }

    /// A copy in Margin's folder, keeping the extension.
    private static func copy(_ url: URL, store: EntryStore) -> URL? {
        let target = store.newImageURL(ext: url.pathExtension.lowercased().nonEmpty ?? "data")
        do {
            try FileManager.default.copyItem(at: url, to: target)
            return target
        } catch {
            MarginLog.info("Import failed for \(url.lastPathComponent): \(error)")
            return nil
        }
    }

    private static func writePreview(_ image: CGImage, store: EntryStore) -> String? {
        let url = store.newImageURL(ext: "png")
        let small = ImageTools.resized(image, maxWidth: 2000, keepingAlpha: true) ?? image
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, small, nil)
        return CGImageDestinationFinalize(destination) ? url.lastPathComponent : nil
    }

    private static func thumbnail(_ url: URL, size: CGSize = CGSize(width: 800, height: 800)) async -> CGImage? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: 2, representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
