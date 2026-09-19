import SmartShotCore
import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation
import ScreenCaptureKit

enum RecordingMediaSample: Sendable {
    case screen
    case systemAudio
    case microphone
}

struct RawRecordingResult: Equatable, Sendable {
    let fileURL: URL
    let duration: TimeInterval
}

enum RecordingEncodingPlanner {
    static func averageVideoBitRate(width: Int, height: Int, frameRate: Int) -> Int {
        let estimated = Double(width) * Double(height) * Double(frameRate) * 0.10
        return min(32_000_000, max(2_000_000, Int(estimated.rounded())))
    }
}

final class RecordingAssetWriter: @unchecked Sendable {
    let sampleQueue: DispatchQueue

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let systemAudioInput: AVAssetWriterInput?
    private let microphoneInput: AVAssetWriterInput?
    private let outputURL: URL
    private let failureHandler: @Sendable (Error) -> Void

    private var sessionStartTime: CMTime?
    private var latestVideoEndTime: CMTime?
    private var isFinishing = false
    private var didReportFailure = false

    init(
        outputURL: URL,
        videoPlan: RecordingVideoPlan,
        capturesSystemAudio: Bool,
        capturesMicrophone: Bool,
        failureHandler: @escaping @Sendable (Error) -> Void
    ) throws {
        self.outputURL = outputURL
        self.failureHandler = failureHandler
        sampleQueue = DispatchQueue(
            label: "com.infinityf4p.SmartShot.recording.samples.\(UUID().uuidString)",
            qos: .userInitiated
        )

        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        } catch {
            throw ScreenRecordingError.cannotConfigureWriter(error.localizedDescription)
        }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: videoPlan.width,
            AVVideoHeightKey: videoPlan.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: RecordingEncodingPlanner.averageVideoBitRate(
                    width: videoPlan.width,
                    height: videoPlan.height,
                    frameRate: videoPlan.frameRate
                ),
                AVVideoExpectedSourceFrameRateKey: videoPlan.frameRate,
                AVVideoMaxKeyFrameIntervalKey: videoPlan.frameRate * 2,
                AVVideoAllowFrameReorderingKey: false
            ]
        ]
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true

        systemAudioInput = capturesSystemAudio
            ? Self.makeAudioInput(channelCount: 2, bitRate: 192_000)
            : nil
        microphoneInput = capturesMicrophone
            ? Self.makeAudioInput(channelCount: 1, bitRate: 96_000)
            : nil

        guard writer.canAdd(videoInput) else {
            throw ScreenRecordingError.cannotConfigureWriter(L10n.text("H.264 video input is unavailable."))
        }
        writer.add(videoInput)

        if let systemAudioInput {
            guard writer.canAdd(systemAudioInput) else {
                throw ScreenRecordingError.cannotConfigureWriter(L10n.text("System audio input is unavailable."))
            }
            writer.add(systemAudioInput)
        }
        if let microphoneInput {
            guard writer.canAdd(microphoneInput) else {
                throw ScreenRecordingError.cannotConfigureWriter(L10n.text("Microphone audio input is unavailable."))
            }
            writer.add(microphoneInput)
        }
    }

    func append(_ sampleBuffer: CMSampleBuffer, media: RecordingMediaSample) {
        dispatchPrecondition(condition: .onQueue(sampleQueue))
        guard !isFinishing, sampleBuffer.isValid else { return }

        if writer.status == .failed {
            reportFailureIfNeeded(writer.error)
            return
        }

        switch media {
        case .screen:
            appendScreen(sampleBuffer)
        case .systemAudio:
            appendAudio(sampleBuffer, to: systemAudioInput)
        case .microphone:
            appendAudio(sampleBuffer, to: microphoneInput)
        }
    }

    func finish() async throws -> RawRecordingResult {
        try await withCheckedThrowingContinuation { continuation in
            sampleQueue.async { [self] in
                guard !isFinishing else {
                    continuation.resume(
                        throwing: ScreenRecordingError.invalidSessionTransition
                    )
                    return
                }
                isFinishing = true

                guard let sessionStartTime else {
                    writer.cancelWriting()
                    continuation.resume(throwing: ScreenRecordingError.noVideoFrames)
                    return
                }

                videoInput.markAsFinished()
                systemAudioInput?.markAsFinished()
                microphoneInput?.markAsFinished()
                writer.finishWriting { [self] in
                    sampleQueue.async { [self] in
                        guard writer.status == .completed else {
                            continuation.resume(
                                throwing: ScreenRecordingError.writerFailed(
                                    writer.error?.localizedDescription ?? L10n.text("Unknown encoder failure.")
                                )
                            )
                            return
                        }
                        let endTime = latestVideoEndTime ?? sessionStartTime
                        let duration = max(
                            0,
                            CMTimeGetSeconds(CMTimeSubtract(endTime, sessionStartTime))
                        )
                        continuation.resume(
                            returning: RawRecordingResult(
                                fileURL: outputURL,
                                duration: duration.isFinite ? duration : 0
                            )
                        )
                    }
                }
            }
        }
    }

    func cancel() async {
        await withCheckedContinuation { continuation in
            sampleQueue.async { [self] in
                isFinishing = true
                if writer.status == .writing || writer.status == .unknown {
                    writer.cancelWriting()
                }
                continuation.resume()
            }
        }
    }

    private func appendScreen(_ sampleBuffer: CMSampleBuffer) {
        guard Self.isCompleteScreenFrame(sampleBuffer) else { return }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard presentationTime.isValid, presentationTime.isNumeric else { return }

        if sessionStartTime == nil {
            guard writer.startWriting() else {
                reportFailureIfNeeded(writer.error)
                return
            }
            writer.startSession(atSourceTime: presentationTime)
            sessionStartTime = presentationTime
        }

        guard videoInput.isReadyForMoreMediaData else { return }
        guard videoInput.append(sampleBuffer) else {
            reportFailureIfNeeded(writer.error)
            return
        }

        let duration = CMSampleBufferGetDuration(sampleBuffer)
        latestVideoEndTime = duration.isValid && duration.isNumeric
            ? CMTimeAdd(presentationTime, duration)
            : presentationTime
    }

    private func appendAudio(
        _ sampleBuffer: CMSampleBuffer,
        to input: AVAssetWriterInput?
    ) {
        guard let input, let sessionStartTime else { return }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard presentationTime.isValid,
              presentationTime.isNumeric,
              CMTimeCompare(presentationTime, sessionStartTime) >= 0,
              input.isReadyForMoreMediaData else {
            return
        }
        if !input.append(sampleBuffer) {
            reportFailureIfNeeded(writer.error)
        }
    }

    private func reportFailureIfNeeded(_ error: Error?) {
        guard !didReportFailure else { return }
        didReportFailure = true
        failureHandler(
            ScreenRecordingError.writerFailed(
                error?.localizedDescription ?? L10n.text("Unknown encoder failure.")
            )
        )
    }

    private static func makeAudioInput(
        channelCount: Int,
        bitRate: Int
    ) -> AVAssetWriterInput {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: channelCount,
            AVEncoderBitRateKey: bitRate
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        return input
    }

    private static func isCompleteScreenFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
        let attachment = attachments.first,
        let rawStatus = attachment[.status] as? Int,
        let status = SCFrameStatus(rawValue: rawStatus) else {
            return false
        }
        return status == .complete
    }
}
