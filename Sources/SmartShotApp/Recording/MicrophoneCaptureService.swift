import SmartShotCore
import AVFoundation
import Foundation

enum MicrophoneAuthorizationState: Equatable, Sendable {
    case notDetermined
    case restricted
    case denied
    case authorized
}

final class MicrophoneCaptureService: @unchecked Sendable {
    private let controlQueue = DispatchQueue(
        label: "com.infinityf4p.SmartShot.recording.microphone",
        qos: .userInitiated
    )
    private var captureSession: AVCaptureSession?
    private var audioOutput: AVCaptureAudioDataOutput?

    static var authorizationState: MicrophoneAuthorizationState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            .notDetermined
        case .restricted:
            .restricted
        case .denied:
            .denied
        case .authorized:
            .authorized
        @unknown default:
            .denied
        }
    }

    static func requestAuthorization() async -> Bool {
        switch authorizationState {
        case .authorized:
            true
        case .restricted, .denied:
            false
        case .notDetermined:
            await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    func start(router: RecordingSampleRouter) async throws {
        guard Bundle.main.object(
            forInfoDictionaryKey: "NSMicrophoneUsageDescription"
        ) as? String != nil else {
            throw ScreenRecordingError.cannotConfigureMicrophone(
                L10n.text("NSMicrophoneUsageDescription is missing from the application Info.plist.")
            )
        }
        guard await Self.requestAuthorization() else {
            throw ScreenRecordingError.microphonePermissionDenied
        }

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            controlQueue.async { [self] in
                guard captureSession == nil else {
                    continuation.resume(
                        throwing: ScreenRecordingError.cannotConfigureMicrophone(
                            L10n.text("A microphone session is already running.")
                        )
                    )
                    return
                }

                do {
                    let session = AVCaptureSession()
                    let output = AVCaptureAudioDataOutput()
                    session.beginConfiguration()
                    do {
                        guard let device = AVCaptureDevice.default(for: .audio) else {
                            throw ScreenRecordingError.cannotConfigureMicrophone(
                                L10n.text("No audio input device is available.")
                            )
                        }
                        let input = try AVCaptureDeviceInput(device: device)
                        guard session.canAddInput(input), session.canAddOutput(output) else {
                            throw ScreenRecordingError.cannotConfigureMicrophone(
                                L10n.text("The selected audio input cannot be connected.")
                            )
                        }
                        session.addInput(input)
                        session.addOutput(output)
                        output.setSampleBufferDelegate(router, queue: router.sampleQueue)
                        session.commitConfiguration()
                    } catch {
                        session.commitConfiguration()
                        throw error
                    }

                    session.startRunning()
                    guard session.isRunning else {
                        output.setSampleBufferDelegate(nil, queue: nil)
                        throw ScreenRecordingError.cannotConfigureMicrophone(
                            L10n.text("The audio capture session did not start.")
                        )
                    }
                    captureSession = session
                    audioOutput = output
                    continuation.resume()
                } catch let error as ScreenRecordingError {
                    continuation.resume(throwing: error)
                } catch {
                    continuation.resume(
                        throwing: ScreenRecordingError.cannotConfigureMicrophone(
                            error.localizedDescription
                        )
                    )
                }
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            controlQueue.async { [self] in
                audioOutput?.setSampleBufferDelegate(nil, queue: nil)
                if captureSession?.isRunning == true {
                    captureSession?.stopRunning()
                }
                audioOutput = nil
                captureSession = nil
                continuation.resume()
            }
        }
    }
}
