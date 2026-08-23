import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

final class RecordingSampleRouter: NSObject, @unchecked Sendable {
    let sessionID: UUID
    let sampleQueue: DispatchQueue

    private let writer: RecordingAssetWriter
    private let failureHandler: @Sendable (UUID, Error) -> Void

    init(
        sessionID: UUID,
        writer: RecordingAssetWriter,
        failureHandler: @escaping @Sendable (UUID, Error) -> Void
    ) {
        self.sessionID = sessionID
        self.writer = writer
        self.failureHandler = failureHandler
        sampleQueue = writer.sampleQueue
    }
}

extension RecordingSampleRouter: SCStreamOutput {
    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        switch outputType {
        case .screen:
            writer.append(sampleBuffer, media: .screen)
        case .audio:
            writer.append(sampleBuffer, media: .systemAudio)
        case .microphone:
            writer.append(sampleBuffer, media: .microphone)
        @unknown default:
            break
        }
    }
}

extension RecordingSampleRouter: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        failureHandler(
            sessionID,
            ScreenRecordingError.streamStopped(error.localizedDescription)
        )
    }
}

extension RecordingSampleRouter: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        writer.append(sampleBuffer, media: .microphone)
    }
}
