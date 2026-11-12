import AVFoundation
import CoreMedia
import CoreVideo

/// Writes screen frames to an H.264 .mp4. Frames arrive only when something
/// on screen changed, so the last frame is repeated at the end to keep the
/// video as long as the recording really was.
public final class VideoWriter {
    public enum WriterError: Error { case cannotAddInput }

    public let url: URL
    public let width: Int
    public let height: Int
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let lock = NSLock()
    private var started = false
    private var finished = false
    private var firstTime = CMTime.invalid
    private var lastTime = CMTime.invalid
    private var lastBuffer: CVPixelBuffer?
    public private(set) var frameCount = 0

    public init(url: URL, width: Int, height: Int, frameRate: Int = 30) throws {
        self.url = url
        self.width = width
        self.height = height
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let bitRate = max(2_000_000, min(width * height * 4, 24_000_000))
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoExpectedSourceFrameRateKey: frameRate,
                AVVideoMaxKeyFrameIntervalKey: frameRate * 2,
            ],
        ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(input) else { throw WriterError.cannotAddInput }
        writer.add(input)
    }

    /// Seconds between the first and the last frame written.
    public var writtenDuration: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        guard firstTime.isValid, lastTime.isValid else { return 0 }
        return (lastTime - firstTime).seconds
    }

    @discardableResult
    public func append(_ sample: CMSampleBuffer) -> Bool {
        guard let buffer = CMSampleBufferGetImageBuffer(sample) else { return false }
        return append(buffer, at: CMSampleBufferGetPresentationTimeStamp(sample))
    }

    @discardableResult
    public func append(_ buffer: CVPixelBuffer, at time: CMTime) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !finished, time.isValid else { return false }
        if !started {
            guard writer.startWriting() else { return false }
            writer.startSession(atSourceTime: time)
            firstTime = time
            started = true
        }
        guard writer.status == .writing else { return false }
        if lastTime.isValid, time <= lastTime { return false }
        // Real time: drop a frame rather than wait.
        guard input.isReadyForMoreMediaData, adaptor.append(buffer, withPresentationTime: time) else { return false }
        lastTime = time
        lastBuffer = buffer
        frameCount += 1
        return true
    }

    /// Finishes the file. `end` is when recording stopped, on the same clock
    /// as the frames. Returns false if nothing usable was written.
    public func finish(at end: CMTime? = nil) async -> Bool {
        guard let endTime = closeInput(at: end) else { return false }
        writer.endSession(atSourceTime: endTime)
        await writer.finishWriting()
        return writer.status == .completed
    }

    /// Holds the last frame until `end`, marks the input finished and returns
    /// the session's end time. Nil if nothing was written.
    private func closeInput(at end: CMTime?) -> CMTime? {
        lock.lock(); defer { lock.unlock() }
        guard started, !finished else {
            if !started, !finished { writer.cancelWriting() }
            finished = true
            return nil
        }
        finished = true
        if let end, end.isValid, let lastBuffer, lastTime.isValid, end > lastTime, (end - lastTime).seconds < 600 {
            // Wait briefly for the encoder, then repeat the last frame at the end.
            var waited = 0
            while !input.isReadyForMoreMediaData && waited < 50 {
                usleep(2_000)
                waited += 1
            }
            if input.isReadyForMoreMediaData, adaptor.append(lastBuffer, withPresentationTime: end) {
                lastTime = end
            }
        }
        input.markAsFinished()
        return lastTime
    }

    public func cancel() {
        lock.lock(); defer { lock.unlock() }
        finished = true
        if started { writer.cancelWriting() }
        try? FileManager.default.removeItem(at: url)
    }
}

public enum VideoTools {
    public static func duration(of url: URL) async -> TimeInterval? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration), duration.isNumeric else { return nil }
        return duration.seconds
    }

    /// A still from early in the video, for thumbnails.
    public static func poster(for url: URL, maxSize: CGSize = CGSize(width: 1600, height: 1600)) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maxSize
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 2)
        let seconds = (await duration(of: url)) ?? 0
        let time = CMTime(seconds: min(0.4, seconds / 2), preferredTimescale: 600)
        return try? await generator.image(at: time).image
    }
}
