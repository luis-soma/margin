import AVFoundation
import AppKit
import ImageIO
import MarginKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Files dropped on the archive from Finder. Each becomes a capture in the
/// open project, placed in time by when it was made (the photo's EXIF date,
/// the video's recording date, else Finder's dates), with what the file
/// carries: its name, Finder tags, where it was downloaded from and the app
/// or camera that made it. The file is copied, never moved.
@MainActor
enum FileImport {
    /// What a file says about itself, read before it's copied.
    struct Facts: Equatable {
        var date: Date
        var name: String
        var link: String?
        var source: String?
        var tags: [String] = []
    }

    /// Imports the files (folders are opened) into `project`, oldest first.
    /// Returns the new entries; files already in the project are skipped.
    @discardableResult
    static func importFiles(_ urls: [URL], into store: EntryStore, project: String) async -> [Entry] {
        var added: [Entry] = []
        for url in expand(urls) {
            let facts = await facts(for: url)
            let already = store.entries.contains {
                $0.project == project && $0.label == facts.name && abs($0.createdAt.timeIntervalSince(facts.date)) < 1
            }
            guard !already, let entry = await makeEntry(url, facts: facts, store: store, project: project) else { continue }
            added.append(entry)
        }
        store.add(contentsOf: added)
        return added
    }

    /// The files themselves: folders are walked, hidden files left out.
    static func expand(_ urls: [URL]) -> [URL] {
        var files: [URL] = []
        for url in urls {
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])).map { ($0.isDirectory ?? false) && !($0.isPackage ?? false) } ?? false
            if isFolder {
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
            name: url.deletingPathExtension().lastPathComponent,
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

    private static func makeEntry(_ url: URL, facts: Facts, store: EntryStore, project: String) async -> Entry? {
        var entry = Entry(kind: .capture, project: project)
        entry.createdAt = facts.date
        entry.label = facts.name
        entry.sourceApp = facts.source
        entry.link = facts.link ?? ""
        entry.tags = facts.tags
        let ext = url.pathExtension.lowercased()

        if isType(url, .movie) {
            guard let copy = copy(url, store: store) else { return nil }
            entry.kind = .recording
            entry.mediaFile = copy.lastPathComponent
            entry.duration = await VideoTools.duration(of: copy)
            if let poster = await VideoTools.poster(for: copy) {
                entry.imageFile = writePreview(poster, store: store)
            }
        } else if isType(url, .image), let image = ImageTools.load(url) {
            if ["png", "jpg", "jpeg"].contains(ext) {
                guard let copy = copy(url, store: store) else { return nil }
                entry.imageFile = copy.lastPathComponent
            } else {
                // HEIC, GIF, TIFF, WebP…: keep the original, show a PNG of it.
                entry.mediaFile = copy(url, store: store)?.lastPathComponent
                entry.imageFile = writePreview(image, store: store)
            }
        } else if isType(url, .plainText), let text = try? String(contentsOf: url, encoding: .utf8) {
            entry.kind = .note
            entry.title = facts.name
            entry.body = String(text.prefix(20_000))
        } else {
            // Anything else (a PDF, a Figma or Sketch file, a zip): the file
            // itself, shown by its Quick Look picture.
            guard let copy = copy(url, store: store) else { return nil }
            entry.mediaFile = copy.lastPathComponent
            if let preview = await thumbnail(url) {
                entry.imageFile = writePreview(preview, store: store)
            }
        }
        return entry
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

    private static func thumbnail(_ url: URL) async -> CGImage? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 800, height: 800), scale: 2, representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
