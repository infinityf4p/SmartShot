import SmartShotCore
import AVFoundation
import CoreMedia
import Foundation

struct RecordingWorkingFiles: Equatable, Sendable {
    let workingDirectory: URL
    let rawRecordingURL: URL
    let completedRecordingURL: URL
}

struct RecordingExportMetadata: Equatable, Sendable {
    let duration: TimeInterval
    let pixelSize: CGSize
}

struct RecordingTemporaryCleanupResult: Equatable, Sendable {
    let removedWorkingDirectories: Int
    let removedCompletedRecordings: Int
}

enum RecordingOutputService {
    static func prepareWorkingFiles(
        sessionID: UUID,
        rootDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> RecordingWorkingFiles {
        let root = resolvedRootDirectory(rootDirectory, fileManager: fileManager)
        let workingDirectory = root
            .appendingPathComponent("Working", isDirectory: true)
            .appendingPathComponent(sessionID.uuidString.lowercased(), isDirectory: true)
        let completedDirectory = root.appendingPathComponent("Completed", isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: workingDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.createDirectory(
                at: completedDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: workingDirectory.path
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: completedDirectory.path
            )
        } catch {
            try? fileManager.removeItem(at: workingDirectory)
            throw ScreenRecordingError.cannotCreateWorkingDirectory
        }

        return RecordingWorkingFiles(
            workingDirectory: workingDirectory,
            rawRecordingURL: workingDirectory.appendingPathComponent("capture.mov"),
            completedRecordingURL: completedDirectory
                .appendingPathComponent(sessionID.uuidString.lowercased())
                .appendingPathExtension("mp4")
        )
    }

    static func removeWorkingFiles(
        _ files: RecordingWorkingFiles,
        includeCompletedFile: Bool,
        fileManager: FileManager = .default
    ) {
        try? fileManager.removeItem(at: files.workingDirectory)
        if includeCompletedFile {
            try? fileManager.removeItem(at: files.completedRecordingURL)
        }
    }

    @discardableResult
    static func removeStaleTemporaryFiles(
        rootDirectory: URL? = nil,
        now: Date = Date(),
        workingRetention: TimeInterval = 24 * 60 * 60,
        completedRetention: TimeInterval = 7 * 24 * 60 * 60,
        fileManager: FileManager = .default
    ) -> RecordingTemporaryCleanupResult {
        let root = resolvedRootDirectory(rootDirectory, fileManager: fileManager)
        let workingDirectory = root.appendingPathComponent("Working", isDirectory: true)
        let completedDirectory = root.appendingPathComponent("Completed", isDirectory: true)
        let keys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey
        ]

        var removedWorkingDirectories = 0
        if workingRetention.isFinite, workingRetention >= 0,
           let entries = try? fileManager.contentsOfDirectory(
               at: workingDirectory,
               includingPropertiesForKeys: Array(keys),
               options: [.skipsHiddenFiles]
           ) {
            for entry in entries where UUID(uuidString: entry.lastPathComponent) != nil {
                guard let values = try? entry.resourceValues(forKeys: keys),
                      values.isDirectory == true,
                      values.isSymbolicLink != true,
                      isStale(
                          modificationDate: values.contentModificationDate,
                          now: now,
                          retention: workingRetention
                      ) else { continue }
                do {
                    try fileManager.removeItem(at: entry)
                    removedWorkingDirectories += 1
                } catch {
                    continue
                }
            }
        }

        var removedCompletedRecordings = 0
        if completedRetention.isFinite, completedRetention >= 0,
           let entries = try? fileManager.contentsOfDirectory(
               at: completedDirectory,
               includingPropertiesForKeys: Array(keys),
               options: [.skipsHiddenFiles]
           ) {
            for entry in entries where entry.pathExtension.lowercased() == "mp4" {
                guard UUID(uuidString: entry.deletingPathExtension().lastPathComponent) != nil,
                      let values = try? entry.resourceValues(forKeys: keys),
                      values.isRegularFile == true,
                      values.isSymbolicLink != true,
                      isStale(
                          modificationDate: values.contentModificationDate,
                          now: now,
                          retention: completedRetention
                      ) else { continue }
                do {
                    try fileManager.removeItem(at: entry)
                    removedCompletedRecordings += 1
                } catch {
                    continue
                }
            }
        }

        return RecordingTemporaryCleanupResult(
            removedWorkingDirectories: removedWorkingDirectories,
            removedCompletedRecordings: removedCompletedRecordings
        )
    }

    private static func resolvedRootDirectory(
        _ rootDirectory: URL?,
        fileManager: FileManager
    ) -> URL {
        rootDirectory ?? fileManager.temporaryDirectory
            .appendingPathComponent("SmartShotRecording", isDirectory: true)
    }

    private static func isStale(
        modificationDate: Date?,
        now: Date,
        retention: TimeInterval
    ) -> Bool {
        guard let modificationDate else { return false }
        let age = now.timeIntervalSince(modificationDate)
        return age.isFinite && age >= retention
    }
}

enum RecordingDestinationInstallerError: LocalizedError, Equatable {
    case stagingFileOutsideDestinationDirectory

    var errorDescription: String? {
        switch self {
        case .stagingFileOutsideDestinationDirectory:
            L10n.text("The recording staging file is not in the destination directory.")
        }
    }
}

enum RecordingDestinationInstaller {
    static func stagingURL(for destinationURL: URL) -> URL {
        let destination = destinationURL.standardizedFileURL
        let filename = ".smartshot-\(UUID().uuidString.lowercased())"
        let staging = destination.deletingLastPathComponent().appendingPathComponent(filename)
        guard !destination.pathExtension.isEmpty else { return staging }
        return staging.appendingPathExtension(destination.pathExtension)
    }

    static func copyReplacingDestination(
        sourceURL: URL,
        destinationURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let source = sourceURL.resolvingSymlinksInPath().standardizedFileURL
        let destination = destinationURL.standardizedFileURL
        guard source != destination.resolvingSymlinksInPath().standardizedFileURL else {
            return
        }

        let stagingURL = stagingURL(for: destination)
        defer { try? fileManager.removeItem(at: stagingURL) }
        try fileManager.copyItem(at: source, to: stagingURL)
        try installStagedFile(
            at: stagingURL,
            destinationURL: destination,
            fileManager: fileManager
        )
    }

    static func installStagedFile(
        at stagingURL: URL,
        destinationURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let staging = stagingURL.standardizedFileURL
        let destination = destinationURL.standardizedFileURL
        let stagingDirectory = staging.deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let destinationDirectory = destination.deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard stagingDirectory == destinationDirectory else {
            throw RecordingDestinationInstallerError.stagingFileOutsideDestinationDirectory
        }

        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(
                destination,
                withItemAt: staging,
                backupItemName: nil,
                options: [.usingNewMetadataOnly]
            )
        } else {
            try fileManager.moveItem(at: staging, to: destination)
        }
    }
}

enum RecordingMP4Exporter {
    static func export(
        rawRecordingURL: URL,
        destinationURL: URL,
        fileManager: FileManager = .default
    ) async throws -> RecordingExportMetadata {
        guard !fileManager.fileExists(atPath: destinationURL.path) else {
            throw ScreenRecordingError.exportFailed(L10n.text("The destination file already exists."))
        }

        let source = AVURLAsset(url: rawRecordingURL)
        let duration: CMTime
        let videoTracks: [AVAssetTrack]
        let audioTracks: [AVAssetTrack]
        do {
            async let loadedDuration = source.load(.duration)
            async let loadedVideoTracks = source.loadTracks(withMediaType: .video)
            async let loadedAudioTracks = source.loadTracks(withMediaType: .audio)
            (duration, videoTracks, audioTracks) = try await (
                loadedDuration,
                loadedVideoTracks,
                loadedAudioTracks
            )
        } catch {
            throw ScreenRecordingError.exportFailed(error.localizedDescription)
        }

        guard duration.isValid,
              duration.isNumeric,
              CMTimeCompare(duration, .zero) > 0,
              let sourceVideoTrack = videoTracks.first else {
            throw ScreenRecordingError.exportFailed(L10n.text("The temporary recording has no video track."))
        }

        let composition = AVMutableComposition()
        do {
            let sourceVideoTimeRange = try await sourceVideoTrack.load(.timeRange)
            guard sourceVideoTimeRange.isValid,
                  !sourceVideoTimeRange.isEmpty,
                  CMTimeCompare(sourceVideoTimeRange.duration, .zero) > 0 else {
                throw ScreenRecordingError.exportFailed(L10n.text("The video track has no usable duration."))
            }
            guard let videoTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                throw ScreenRecordingError.exportFailed(L10n.text("A video composition track could not be created."))
            }
            try videoTrack.insertTimeRange(sourceVideoTimeRange, of: sourceVideoTrack, at: .zero)
            videoTrack.preferredTransform = try await sourceVideoTrack.load(.preferredTransform)

            var mixParameters: [AVMutableAudioMixInputParameters] = []
            let audioVolume: Float = audioTracks.count > 1 ? 0.72 : 1
            for sourceAudioTrack in audioTracks {
                let sourceAudioTimeRange = try await sourceAudioTrack.load(.timeRange)
                let clippedTimeRange = CMTimeRangeGetIntersection(
                    sourceAudioTimeRange,
                    otherRange: sourceVideoTimeRange
                )
                guard clippedTimeRange.isValid,
                      !clippedTimeRange.isEmpty,
                      CMTimeCompare(clippedTimeRange.duration, .zero) > 0 else {
                    continue
                }
                guard let audioTrack = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                ) else {
                    throw ScreenRecordingError.exportFailed(
                        L10n.text("An audio composition track could not be created.")
                    )
                }
                let insertionTime = CMTimeSubtract(
                    clippedTimeRange.start,
                    sourceVideoTimeRange.start
                )
                try audioTrack.insertTimeRange(
                    clippedTimeRange,
                    of: sourceAudioTrack,
                    at: insertionTime
                )
                let parameters = AVMutableAudioMixInputParameters(track: audioTrack)
                parameters.setVolume(audioVolume, at: .zero)
                mixParameters.append(parameters)
            }

            guard let exporter = AVAssetExportSession(
                asset: composition,
                presetName: AVAssetExportPresetHighestQuality
            ), exporter.supportedFileTypes.contains(.mp4) else {
                throw ScreenRecordingError.exportFailed(L10n.text("H.264 MP4 export is unavailable."))
            }
            exporter.outputURL = destinationURL
            exporter.outputFileType = .mp4
            exporter.shouldOptimizeForNetworkUse = true
            if !mixParameters.isEmpty {
                let audioMix = AVMutableAudioMix()
                audioMix.inputParameters = mixParameters
                exporter.audioMix = audioMix
            }

            try await run(exporter)
            let metadata = try await inspect(url: destinationURL)
            guard try await containsH264Video(url: destinationURL) else {
                throw ScreenRecordingError.exportFailed(L10n.text("The exported video is not H.264."))
            }
            guard try await containsOnlyAACAudio(url: destinationURL) else {
                throw ScreenRecordingError.exportFailed(L10n.text("The exported audio is not AAC."))
            }
            return metadata
        } catch {
            try? fileManager.removeItem(at: destinationURL)
            if let recordingError = error as? ScreenRecordingError {
                throw recordingError
            }
            throw ScreenRecordingError.exportFailed(error.localizedDescription)
        }
    }

    private static func run(_ exporter: AVAssetExportSession) async throws {
        let box = ExportSessionBox(exporter)
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            box.session.exportAsynchronously {
                switch box.session.status {
                case .completed:
                    continuation.resume()
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                default:
                    continuation.resume(
                        throwing: ScreenRecordingError.exportFailed(
                            box.session.error?.localizedDescription ?? L10n.text("Unknown export failure.")
                        )
                    )
                }
            }
        }
    }

    private static func inspect(url: URL) async throws -> RecordingExportMetadata {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ScreenRecordingError.exportFailed(L10n.text("The exported file has no video track."))
        }
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let transformed = CGRect(origin: .zero, size: naturalSize)
            .applying(transform)
            .standardized
        let durationSeconds = CMTimeGetSeconds(duration)
        guard durationSeconds.isFinite,
              durationSeconds > 0,
              transformed.width.isFinite,
              transformed.height.isFinite,
              transformed.width > 0,
              transformed.height > 0 else {
            throw ScreenRecordingError.exportFailed(L10n.text("The exported media metadata is invalid."))
        }
        return RecordingExportMetadata(
            duration: durationSeconds,
            pixelSize: transformed.size
        )
    }

    private static func containsH264Video(url: URL) async throws -> Bool {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            return false
        }
        return try await track.load(.formatDescriptions).contains { description in
            CMFormatDescriptionGetMediaSubType(description) == kCMVideoCodecType_H264
        }
    }

    private static func containsOnlyAACAudio(url: URL) async throws -> Bool {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        for track in tracks {
            let descriptions = try await track.load(.formatDescriptions)
            guard !descriptions.isEmpty,
                  descriptions.allSatisfy({ description in
                      CMFormatDescriptionGetMediaSubType(description) == kAudioFormatMPEG4AAC
                  }) else {
                return false
            }
        }
        return true
    }
}

private final class ExportSessionBox: @unchecked Sendable {
    let session: AVAssetExportSession

    init(_ session: AVAssetExportSession) {
        self.session = session
    }
}
