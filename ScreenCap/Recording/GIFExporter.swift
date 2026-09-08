import AppKit
import AVFoundation
import UniformTypeIdentifiers

enum GIFExporter {
    enum ExportError: LocalizedError {
        case noVideoTrack, destinationFailed, finalizeFailed
        var errorDescription: String? {
            switch self {
            case .noVideoTrack: return "The recording has no video track."
            case .destinationFailed: return "Couldn't create the GIF file."
            case .finalizeFailed: return "Couldn't finish writing the GIF."
            }
        }
    }

    /// Samples the video at `fps`, downscales to `maxWidth`, and writes a looping GIF.
    static func export(video: URL, to gifURL: URL, fps: Int, maxWidth: Int,
                       progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: video)
        let duration = try await asset.load(.duration).seconds
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ExportError.noVideoTrack }
        let natural = try await track.load(.naturalSize)
        let scale = min(1, CGFloat(maxWidth) / max(natural.width, 1))
        let outSize = CGSize(width: (natural.width * scale).rounded(.down), height: (natural.height * scale).rounded(.down))

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = outSize
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: CMTimeScale(fps * 2))

        let frameCount = max(1, Int(duration * Double(fps)))
        let times = (0..<frameCount).map { CMTime(value: CMTimeValue($0), timescale: CMTimeScale(fps)) }

        var frames: [CGImage] = []
        frames.reserveCapacity(frameCount)
        for await result in generator.images(for: times) {
            if let image = try? result.image { frames.append(image) }
            progress(Double(frames.count) / Double(frameCount) * 0.85)
        }
        guard !frames.isEmpty else { throw ExportError.noVideoTrack }

        guard let dest = CGImageDestinationCreateWithURL(gifURL as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else {
            throw ExportError.destinationFailed
        }
        let fileProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary
        CGImageDestinationSetProperties(dest, fileProps)
        let delay = 1.0 / Double(fps)
        let frameProps = [kCGImagePropertyGIFDictionary: [
            kCGImagePropertyGIFDelayTime: delay,
            kCGImagePropertyGIFUnclampedDelayTime: delay,
        ]] as CFDictionary
        for (i, frame) in frames.enumerated() {
            CGImageDestinationAddImage(dest, frame, frameProps)
            progress(0.85 + 0.15 * Double(i + 1) / Double(frames.count))
        }
        guard CGImageDestinationFinalize(dest) else { throw ExportError.finalizeFailed }
    }
}
