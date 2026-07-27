import AppKit
import AVFoundation
import CoreVideo
import Foundation

enum PreviewMediaError: LocalizedError {
    case imageEncoding
    case videoEncoding(String)

    var errorDescription: String? {
        switch self {
        case .imageEncoding:
            return "ViewDeck could not encode the screenshot as PNG."
        case .videoEncoding(let message):
            return "ViewDeck could not encode the MP4: \(message)"
        }
    }
}

enum PreviewImageEncoding {
    static func bestBitmap(in image: NSImage) -> NSBitmapImageRep? {
        image.representations
            .compactMap { $0 as? NSBitmapImageRep }
            .max { lhs, rhs in
                lhs.pixelsWide * lhs.pixelsHigh < rhs.pixelsWide * rhs.pixelsHigh
            }
    }

    static func pngData(_ image: NSImage) throws -> Data {
        guard let data = bestBitmap(in: image)?.representation(using: .png, properties: [:]) else {
            throw PreviewMediaError.imageEncoding
        }
        return data
    }

    static func pixelSize(of image: NSImage) -> CGSize {
        guard let representation = bestBitmap(in: image) else { return image.size }
        return CGSize(width: representation.pixelsWide, height: representation.pixelsHigh)
    }

    static func image(from source: CGImage, pixelsWide: Int, pixelsHigh: Int) -> NSImage? {
        let width = max(1, pixelsWide)
        let height = max(1, pixelsHigh)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            return nil
        }
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let rendered = context.makeImage() else { return nil }
        let representation = NSBitmapImageRep(cgImage: rendered)
        representation.size = CGSize(width: width, height: height)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }

    static func draw(_ image: NSImage, into buffer: CVPixelBuffer) throws {
        guard let representation = bestBitmap(in: image),
              let source = representation.cgImage else {
            throw PreviewMediaError.imageEncoding
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else {
            throw PreviewMediaError.videoEncoding("The video frame has no writable memory.")
        }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            throw PreviewMediaError.videoEncoding("Could not create the video drawing context.")
        }
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
}

final class LivePreviewVideoRecorder {
    private let outputURL: URL
    private let duration: TimeInterval?
    private let framesPerSecond: Int
    private let captureScale: CGFloat
    private let overwrite: Bool
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var frameIndex = 0
    private var recordStartedAt: Date?
    private weak var preview: DevicePreviewView?
    private var completion: ((Result<Void, Error>) -> Void)?
    private var stopRequested = false
    private var isFinishing = false

    private var frameCount: Int? {
        duration.map { max(1, Int(($0 * Double(framesPerSecond)).rounded())) }
    }

    init(
        outputURL: URL,
        duration: TimeInterval?,
        framesPerSecond: Int,
        captureScale: CGFloat,
        overwrite: Bool
    ) {
        self.outputURL = outputURL
        self.duration = duration
        self.framesPerSecond = framesPerSecond
        self.captureScale = captureScale
        self.overwrite = overwrite
    }

    func record(
        preview: DevicePreviewView,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        if overwrite, FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }
        self.preview = preview
        self.completion = completion
        recordStartedAt = Date()
        scheduleNextFrame()
    }

    func stop() {
        stopRequested = true
        if frameIndex > 0, !isFinishing {
            finish()
        }
    }

    private func scheduleNextFrame() {
        guard !isFinishing, let preview else { return }
        let start = recordStartedAt ?? Date()
        let target = start.addingTimeInterval(Double(frameIndex) / Double(framesPerSecond))
        let delay = max(0, target.timeIntervalSinceNow)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak preview] in
            guard let self, let preview, !self.isFinishing else { return }
            self.captureNextFrame(preview: preview)
        }
    }

    private func captureNextFrame(preview: DevicePreviewView) {
        preview.captureVideoFrame(scale: captureScale) { [weak self] result in
            guard let self, !self.isFinishing else { return }
            do {
                let image = try result.get()
                if self.writer == nil {
                    try self.prepareWriter(for: image)
                }
                try self.append(image: image, at: self.frameIndex)
                self.frameIndex += 1
                if self.stopRequested || self.frameCount.map({ self.frameIndex >= $0 }) == true {
                    self.finish()
                } else {
                    self.scheduleNextFrame()
                }
            } catch {
                self.writer?.cancelWriting()
                self.complete(.failure(error))
            }
        }
    }

    private func prepareWriter(for image: NSImage) throws {
        guard let representation = PreviewImageEncoding.bestBitmap(in: image) else {
            throw PreviewMediaError.imageEncoding
        }
        let width = Self.even(representation.pixelsWide)
        let height = Self.even(representation.pixelsHigh)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let bitrate = min(24_000_000, max(2_000_000, width * height * 5))
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoMaxKeyFrameIntervalKey: framesPerSecond * 2
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = duration == nil
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
            ]
        )
        guard writer.canAdd(input) else {
            throw PreviewMediaError.videoEncoding("Cannot add the H.264 video input.")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? PreviewMediaError.videoEncoding("The MP4 writer could not start.")
        }
        writer.startSession(atSourceTime: .zero)
        self.writer = writer
        self.input = input
        self.adaptor = adaptor
    }

    private func append(image: NSImage, at index: Int) throws {
        guard let input, let adaptor, let pool = adaptor.pixelBufferPool else {
            throw PreviewMediaError.videoEncoding("The video pixel-buffer pool is unavailable.")
        }
        guard input.isReadyForMoreMediaData else {
            throw PreviewMediaError.videoEncoding("The H.264 encoder did not accept the next frame.")
        }
        var optionalBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &optionalBuffer)
        guard status == kCVReturnSuccess, let buffer = optionalBuffer else {
            throw PreviewMediaError.videoEncoding("Could not allocate a video frame.")
        }
        try PreviewImageEncoding.draw(image, into: buffer)
        let timestamp: CMTime
        if duration == nil {
            let elapsed = max(0, Date().timeIntervalSince(recordStartedAt ?? Date()))
            timestamp = CMTime(seconds: elapsed, preferredTimescale: 600)
        } else {
            timestamp = CMTime(value: CMTimeValue(index), timescale: CMTimeScale(framesPerSecond))
        }
        guard adaptor.append(buffer, withPresentationTime: timestamp) else {
            throw writer?.error ?? PreviewMediaError.videoEncoding("Could not append a video frame.")
        }
    }

    private func finish() {
        guard !isFinishing else { return }
        isFinishing = true
        guard let writer, let input else {
            complete(.failure(PreviewMediaError.videoEncoding("No video frames were captured.")))
            return
        }
        input.markAsFinished()
        writer.finishWriting { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                if writer.status == .completed {
                    self.complete(.success(()))
                } else {
                    self.complete(.failure(
                        writer.error ?? PreviewMediaError.videoEncoding("The MP4 writer did not finish.")
                    ))
                }
            }
        }
    }

    private func complete(_ result: Result<Void, Error>) {
        guard let completion else { return }
        self.completion = nil
        completion(result)
    }

    private static func even(_ value: Int) -> Int {
        max(2, value.isMultiple(of: 2) ? value : value + 1)
    }
}
