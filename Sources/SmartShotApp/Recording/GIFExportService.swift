import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct GIFExportOptions: Equatable, Sendable {
    static let maximumSupportedDuration: TimeInterval = 30
    static let maximumSupportedFrameRate = 15
    static let maximumSupportedLongEdge = 1_280

    let maximumDuration: TimeInterval
    let frameRate: Int
    let maximumLongEdge: Int

    init(
        maximumDuration: TimeInterval = Self.maximumSupportedDuration,
        frameRate: Int = Self.maximumSupportedFrameRate,
        maximumLongEdge: Int = Self.maximumSupportedLongEdge
    ) {
        self.maximumDuration = min(
            Self.maximumSupportedDuration,
            max(0.1, maximumDuration.isFinite ? maximumDuration : Self.maximumSupportedDuration)
        )
        self.frameRate = min(Self.maximumSupportedFrameRate, max(1, frameRate))
        self.maximumLongEdge = min(Self.maximumSupportedLongEdge, max(2, maximumLongEdge))
    }
}

struct GIFFramePlan: Equatable, Sendable {
    let duration: TimeInterval
    let frameRate: Int
    let maximumLongEdge: Int
    let frameCount: Int

    init(videoDuration: TimeInterval, options: GIFExportOptions = GIFExportOptions()) throws {
        guard videoDuration.isFinite, videoDuration > 0 else {
            throw GIFExportError.invalidVideoDuration
        }
        duration = min(videoDuration, options.maximumDuration)
        frameRate = options.frameRate
        maximumLongEdge = options.maximumLongEdge
        frameCount = max(1, min(
            Int(ceil(duration * Double(frameRate))),
            Int(GIFExportOptions.maximumSupportedDuration)
                * GIFExportOptions.maximumSupportedFrameRate
        ))
    }

    var frameDelay: TimeInterval { 1 / Double(frameRate) }

    func time(at index: Int) -> CMTime {
        precondition((0..<frameCount).contains(index))
        return CMTime(value: CMTimeValue(index), timescale: CMTimeScale(frameRate))
    }
}

enum GIFExportError: LocalizedError, Equatable {
    case invalidVideoDuration
    case destinationExists
    case cannotCreateDestination
    case frameGenerationFailed(String)
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidVideoDuration:
            "The selected video has no GIF-exportable frames."
        case .destinationExists:
            "The GIF destination already exists."
        case .cannotCreateDestination:
            "SmartShot could not create the GIF destination."
        case let .frameGenerationFailed(message):
            "SmartShot could not decode a GIF frame: \(message)"
        case .encodingFailed:
            "SmartShot could not finish encoding the GIF."
        }
    }
}

enum GIFExportService {
    static func export(
        videoURL: URL,
        destinationURL: URL,
        options: GIFExportOptions = GIFExportOptions(),
        fileManager: FileManager = .default
    ) async throws -> URL {
        guard !fileManager.fileExists(atPath: destinationURL.path) else {
            throw GIFExportError.destinationExists
        }

        let asset = AVURLAsset(url: videoURL)
        let duration: CMTime
        do {
            duration = try await asset.load(.duration)
        } catch {
            throw GIFExportError.frameGenerationFailed(error.localizedDescription)
        }
        let plan = try GIFFramePlan(
            videoDuration: CMTimeGetSeconds(duration),
            options: options
        )

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(
            width: plan.maximumLongEdge,
            height: plan.maximumLongEdge
        )
        let tolerance = CMTime(value: 1, timescale: CMTimeScale(plan.frameRate * 2))
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        let generatorBox = ImageGeneratorBox(generator)

        guard let destination = CGImageDestinationCreateWithURL(
            destinationURL as CFURL,
            UTType.gif.identifier as CFString,
            plan.frameCount,
            nil
        ) else {
            throw GIFExportError.cannotCreateDestination
        }

        CGImageDestinationSetProperties(
            destination,
            [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFLoopCount: 0
                ]
            ] as CFDictionary
        )
        let frameProperties = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: plan.frameDelay,
                kCGImagePropertyGIFUnclampedDelayTime: plan.frameDelay
            ]
        ] as CFDictionary

        do {
            for index in 0..<plan.frameCount {
                try Task.checkCancellation()
                let image = try await generateFrame(
                    with: generatorBox,
                    at: plan.time(at: index)
                )
                CGImageDestinationAddImage(destination, image, frameProperties)
            }
            try Task.checkCancellation()
            guard CGImageDestinationFinalize(destination) else {
                throw GIFExportError.encodingFailed
            }
            return destinationURL
        } catch {
            generator.cancelAllCGImageGeneration()
            try? fileManager.removeItem(at: destinationURL)
            throw error
        }
    }

    private static func generateFrame(
        with box: ImageGeneratorBox,
        at time: CMTime
    ) async throws -> CGImage {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                box.generator.generateCGImagesAsynchronously(
                    forTimes: [NSValue(time: time)]
                ) { _, image, _, result, error in
                    switch result {
                    case .succeeded:
                        guard let image else {
                            continuation.resume(
                                throwing: GIFExportError.frameGenerationFailed(
                                    "The decoder returned an empty image."
                                )
                            )
                            return
                        }
                        continuation.resume(returning: image)
                    case .cancelled:
                        continuation.resume(throwing: CancellationError())
                    case .failed:
                        continuation.resume(
                            throwing: GIFExportError.frameGenerationFailed(
                                error?.localizedDescription ?? "Unknown frame decoder failure."
                            )
                        )
                    @unknown default:
                        continuation.resume(
                            throwing: GIFExportError.frameGenerationFailed(
                                "Unknown frame decoder result."
                            )
                        )
                    }
                }
            }
        } onCancel: {
            box.generator.cancelAllCGImageGeneration()
        }
    }
}

private final class ImageGeneratorBox: @unchecked Sendable {
    let generator: AVAssetImageGenerator

    init(_ generator: AVAssetImageGenerator) {
        self.generator = generator
    }
}
