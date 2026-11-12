import AVFoundation
import CoreVideo
import XCTest
@testable import MarginKit

final class VideoWriterTests: XCTestCase {
    private func frame(width: Int, height: Int, shade: UInt8) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer)
        let pixel = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixel, [])
        let base = CVPixelBufferGetBaseAddress(pixel)!
        memset(base, Int32(shade), CVPixelBufferGetBytesPerRow(pixel) * height)
        CVPixelBufferUnlockBaseAddress(pixel, [])
        return pixel
    }

    func testWritesAVideoAsLongAsTheRecording() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("margin-test-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try VideoWriter(url: url, width: 320, height: 200)

        // Ten frames over a third of a second, then nothing changes on screen…
        let start = CMTime(seconds: 1000, preferredTimescale: 600)
        for i in 0..<10 {
            let time = start + CMTime(seconds: Double(i) / 30, preferredTimescale: 600)
            // Real time: the writer may drop a frame when the encoder is busy.
            writer.append(try frame(width: 320, height: 200, shade: UInt8(i * 20)), at: time)
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        // Out-of-order frames are ignored.
        XCTAssertFalse(writer.append(try frame(width: 320, height: 200, shade: 0), at: start))

        // …until the recording stops two seconds in.
        let ok = await writer.finish(at: start + CMTime(seconds: 2, preferredTimescale: 600))
        XCTAssertTrue(ok)
        XCTAssertGreaterThanOrEqual(writer.frameCount, 5)

        let measured = await VideoTools.duration(of: url)
        let duration = try XCTUnwrap(measured)
        XCTAssertEqual(duration, 2, accuracy: 0.15)
        let poster = await VideoTools.poster(for: url)
        XCTAssertEqual(poster?.width, 320)
    }

    func testFinishWithoutFramesFails() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("margin-test-\(UUID().uuidString).mp4")
        let writer = try VideoWriter(url: url, width: 64, height: 64)
        let ok = await writer.finish()
        XCTAssertFalse(ok)
    }
}
