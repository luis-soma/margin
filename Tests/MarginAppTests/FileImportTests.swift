import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Margin

@MainActor
final class FileImportTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("FileImportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A small JPEG that says it was taken at `stamp` (EXIF), with a camera.
    private func photo(_ name: String, stamp: String, offset: String?) throws -> URL {
        let url = folder.appendingPathComponent(name)
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0.5, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        var exif: [CFString: Any] = [kCGImagePropertyExifDateTimeOriginal: stamp]
        if let offset { exif[kCGImagePropertyExifOffsetTimeOriginal] = offset }
        let properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: exif,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone 17 Pro"],
        ]
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    func testDroppedFilesArePlacedByWhenTheyWereMadeAndKeepTheirMetadata() async throws {
        let store = EntryStore(baseURL: folder.appendingPathComponent("store"), projectKey: "test-\(UUID())")
        let shot = try photo("Moodboard.jpg", stamp: "2025:03:14 09:26:53", offset: "+02:00")
        let inner = folder.appendingPathComponent("Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        let note = inner.appendingPathComponent("Brief.md")
        try "Make the onboarding calmer.".write(to: note, atomically: true, encoding: .utf8)

        let added = await FileImport.importFiles([shot, inner], into: store, project: "Umbrella")
        XCTAssertEqual(added.count, 2)

        let image = try XCTUnwrap(added.first { $0.label == "Moodboard" })
        XCTAssertEqual(image.kind, .capture)
        XCTAssertEqual(image.project, "Umbrella")
        XCTAssertEqual(image.createdAt, ISO8601DateFormatter().date(from: "2025-03-14T07:26:53Z"))
        XCTAssertEqual(image.sourceApp, "Apple iPhone 17 Pro")
        let file = try XCTUnwrap(store.imageURL(for: image))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: shot.path), "the original stays where it was")

        let text = try XCTUnwrap(added.first { $0.label == "Brief" })
        XCTAssertEqual(text.kind, .note)
        XCTAssertEqual(text.body, "Make the onboarding calmer.")

        // Dropping the same files again adds nothing.
        let again = await FileImport.importFiles([shot, inner], into: store, project: "Umbrella")
        XCTAssertTrue(again.isEmpty)
        XCTAssertEqual(store.entries(in: "Umbrella").count, 2)
    }

    func testExifDatesUseTheirOffsetWhenTheyHaveOne() {
        let withOffset = FileImport.exifDate("2026:10:18 21:03:12", offset: "-07:00")
        XCTAssertEqual(withOffset, ISO8601DateFormatter().date(from: "2026-10-19T04:03:12Z"))
        XCTAssertNotNil(FileImport.exifDate("2026:10:18 21:03:12", offset: nil))
        XCTAssertNil(FileImport.exifDate("not a date", offset: nil))
    }
}
