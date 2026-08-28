import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

enum GIFConverterError: LocalizedError {
    case emptyVideo
    case tooLong(TimeInterval)
    case destinationFailed
    case noFramesDecoded
    case finalizeFailed

    var errorDescription: String? {
        switch self {
        case .emptyVideo: return "Recorded video is empty."
        case .tooLong(let d): return String(format: "Recording too long for GIF (%.0fs, max 60s). Save as video instead.", d)
        case .destinationFailed: return "Couldn't create GIF file."
        case .noFramesDecoded: return "Couldn't read any frames from the recording."
        case .finalizeFailed: return "Couldn't finalize GIF."
        }
    }
}

enum GIFConverter {
    static func convert(
        videoURL: URL,
        outputURL: URL,
        fps: Int = 12,
        maxDimension: CGFloat = 720
    ) async throws {
        let asset = AVURLAsset(url: videoURL)

        let duration = try await asset.load(.duration).seconds
        guard duration > 0 else { throw GIFConverterError.emptyVideo }
        // Hard cap — prevents OOM/disk fill on long recordings (industry: 30s default, 60s max).
        guard duration <= 60 else { throw GIFConverterError.tooLong(duration) }
        let effectiveDuration = min(duration, 30)
        let totalFrames = max(1, Int(effectiveDuration * Double(fps)))
        if duration > 30 {
            // Clamp to 30s of frames; caller shows toast. Log for debugging.
            print("ShotX: GIF duration \(duration)s clamped to 30s (\(totalFrames) frames)")
        }
        let frameDelay = 1.0 / Double(fps)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        if let track = try await asset.loadTracks(withMediaType: .video).first {
            let natural = try await track.load(.naturalSize)
            let largest = max(natural.width, natural.height)
            let scale = largest > maxDimension ? maxDimension / largest : 1.0
            generator.maximumSize = CGSize(width: natural.width * scale, height: natural.height * scale)
        }

        try? FileManager.default.removeItem(at: outputURL)

        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.gif.identifier as CFString,
            totalFrames,
            nil
        ) else {
            throw GIFConverterError.destinationFailed
        }

        let fileProperties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFLoopCount: 0
            ]
        ]
        CGImageDestinationSetProperties(destination, fileProperties as CFDictionary)

        let frameProperties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: frameDelay,
                kCGImagePropertyGIFUnclampedDelayTime: frameDelay
            ]
        ]

        var addedFrames = 0
        for index in 0..<totalFrames {
            let time = CMTime(seconds: Double(index) * frameDelay, preferredTimescale: 600)
            do {
                let result = try await generator.image(at: time)
                CGImageDestinationAddImage(destination, result.image, frameProperties as CFDictionary)
                addedFrames += 1
            } catch {
                continue
            }
        }

        // Finalizing a zero-frame destination can still "succeed", handing the
        // caller a GIF that no viewer can open. Fail loudly instead.
        guard addedFrames > 0 else {
            try? FileManager.default.removeItem(at: outputURL)
            throw GIFConverterError.noFramesDecoded
        }

        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: outputURL)
            throw GIFConverterError.finalizeFailed
        }
    }
}
