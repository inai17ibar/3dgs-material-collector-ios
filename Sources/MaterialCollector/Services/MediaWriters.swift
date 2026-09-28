import AVFoundation
import CoreImage
import CoreVideo
import Foundation

/// Pixel buffers from ARKit are not Sendable; ownership is handed off to the writer queue.
struct PixelBufferBox: @unchecked Sendable {
    let buffer: CVPixelBuffer
}

/// Encodes camera frames to JPEG off the main thread.
actor PhotoWriter {
    private let context = CIContext()
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    func writeJPEG(_ box: PixelBufferBox, to url: URL, quality: Double = 0.92) throws {
        let image = CIImage(cvPixelBuffer: box.buffer)
        let key = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        try context.writeJPEGRepresentation(of: image, to: url, colorSpace: colorSpace, options: [key: quality])
    }
}

/// Records ARKit camera frames to an H.264 QuickTime movie.
final class VideoRecorder: @unchecked Sendable {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let queue = DispatchQueue(label: "video.recorder")
    private var startTime: Double?
    private var lastTime: Double = -1
    private let minFrameInterval = 1.0 / 30.0

    init(url: URL, width: Int, height: Int, transform: CGAffineTransform) throws {
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 24_000_000]
        ])
        input.expectsMediaDataInRealTime = true
        input.transform = transform
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
    }

    /// Seconds since the first appended frame.
    func relativeTime(_ timestamp: Double) -> Double? { startTime.map { timestamp - $0 } }

    func append(_ box: PixelBufferBox, timestamp: Double) {
        queue.async { [self] in
            if startTime == nil {
                guard writer.startWriting() else { return }
                writer.startSession(atSourceTime: CMTime(seconds: timestamp, preferredTimescale: 600))
                startTime = timestamp
            }
            guard timestamp - lastTime >= minFrameInterval * 0.9, input.isReadyForMoreMediaData else { return }
            if adaptor.append(box.buffer, withPresentationTime: CMTime(seconds: timestamp, preferredTimescale: 600)) {
                lastTime = timestamp
            }
        }
    }

    func finish() async -> Error? {
        await withCheckedContinuation { cont in
            queue.async { [self] in
                guard startTime != nil else {
                    writer.cancelWriting()
                    cont.resume(returning: CocoaError(.fileWriteUnknown))
                    return
                }
                input.markAsFinished()
                writer.finishWriting { [writer] in
                    cont.resume(returning: writer.status == .completed ? nil : writer.error)
                }
            }
        }
    }
}
