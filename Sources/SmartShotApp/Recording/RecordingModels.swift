import CoreGraphics
import CoreMedia
import Foundation

enum RecordingSource: Equatable, Sendable {
    case display(displayID: CGDirectDisplayID)
    /// `displayLocalRect` uses ScreenCaptureKit's display-local logical points,
    /// with the same top-left coordinate convention as `SCStreamConfiguration.sourceRect`.
    case region(displayID: CGDirectDisplayID, displayLocalRect: CGRect)

    var displayID: CGDirectDisplayID {
        switch self {
        case let .display(displayID), let .region(displayID, _):
            displayID
        }
    }
}

struct RecordingOptions: Equatable, Sendable {
    static let supportedFrameRateRange = 1...60
    static let supportedMaximumLongEdgeRange = 2...7_680

    var capturesSystemAudio: Bool
    var capturesMicrophone: Bool
    var showsCursor: Bool
    var frameRate: Int
    var maximumLongEdge: Int

    init(
        capturesSystemAudio: Bool = true,
        capturesMicrophone: Bool = false,
        showsCursor: Bool = true,
        frameRate: Int = 30,
        maximumLongEdge: Int = 3_840
    ) {
        self.capturesSystemAudio = capturesSystemAudio
        self.capturesMicrophone = capturesMicrophone
        self.showsCursor = showsCursor
        self.frameRate = Self.supportedFrameRateRange.clamped(frameRate)
        self.maximumLongEdge = Self.supportedMaximumLongEdgeRange.clamped(maximumLongEdge)
    }
}

struct RecordingVideoPlan: Equatable, Sendable {
    let sourceSize: CGSize
    let pixelSize: CGSize
    let frameRate: Int

    var width: Int { Int(pixelSize.width) }
    var height: Int { Int(pixelSize.height) }
    var minimumFrameInterval: CMTime {
        CMTime(value: 1, timescale: CMTimeScale(frameRate))
    }
}

enum RecordingVideoPlanner {
    static func plan(
        sourceSize: CGSize,
        pointPixelScale: CGFloat,
        options: RecordingOptions
    ) throws -> RecordingVideoPlan {
        guard sourceSize.width.isFinite,
              sourceSize.height.isFinite,
              sourceSize.width > 0,
              sourceSize.height > 0,
              pointPixelScale.isFinite,
              pointPixelScale > 0 else {
            throw ScreenRecordingError.invalidSourceGeometry
        }

        let nativeWidth = sourceSize.width * pointPixelScale
        let nativeHeight = sourceSize.height * pointPixelScale
        guard nativeWidth.isFinite, nativeHeight.isFinite else {
            throw ScreenRecordingError.invalidSourceGeometry
        }

        let maximumNativeEdge = max(nativeWidth, nativeHeight)
        let downscale = min(1, CGFloat(options.maximumLongEdge) / maximumNativeEdge)
        let width = evenPixelDimension(nativeWidth * downscale)
        let height = evenPixelDimension(nativeHeight * downscale)
        guard width >= 2, height >= 2 else {
            throw ScreenRecordingError.invalidSourceGeometry
        }

        return RecordingVideoPlan(
            sourceSize: sourceSize,
            pixelSize: CGSize(width: width, height: height),
            frameRate: options.frameRate
        )
    }

    private static func evenPixelDimension(_ value: CGFloat) -> Int {
        let roundedDown = Int(value.rounded(.down))
        return max(2, roundedDown - (roundedDown % 2))
    }
}

enum RecordingSessionState: Equatable, Sendable {
    case idle
    case preparing(UUID)
    case recording(UUID)
    case stopping(UUID)
    case finished(UUID)
    case cancelled(UUID)
    case failed(UUID, String)

    var sessionID: UUID? {
        switch self {
        case .idle:
            nil
        case let .preparing(id), let .recording(id), let .stopping(id),
             let .finished(id), let .cancelled(id), let .failed(id, _):
            id
        }
    }

    var isActive: Bool {
        switch self {
        case .preparing, .recording, .stopping:
            true
        case .idle, .finished, .cancelled, .failed:
            false
        }
    }
}

struct RecordingSessionStateMachine: Equatable, Sendable {
    private(set) var state: RecordingSessionState = .idle

    mutating func begin(sessionID: UUID) throws {
        guard !state.isActive else { throw ScreenRecordingError.sessionAlreadyActive }
        state = .preparing(sessionID)
    }

    mutating func didStart(sessionID: UUID) throws {
        guard state == .preparing(sessionID) else {
            throw ScreenRecordingError.invalidSessionTransition
        }
        state = .recording(sessionID)
    }

    @discardableResult
    mutating func requestStop(sessionID: UUID) throws -> Bool {
        switch state {
        case .recording(sessionID):
            state = .stopping(sessionID)
            return true
        case .stopping(sessionID), .finished(sessionID):
            return false
        default:
            throw ScreenRecordingError.sessionNotActive
        }
    }

    mutating func finish(sessionID: UUID) throws {
        guard state == .stopping(sessionID) else {
            throw ScreenRecordingError.invalidSessionTransition
        }
        state = .finished(sessionID)
    }

    mutating func cancel(sessionID: UUID) {
        guard state.sessionID == sessionID else { return }
        state = .cancelled(sessionID)
    }

    mutating func fail(sessionID: UUID, error: Error) {
        guard state.sessionID == sessionID else { return }
        state = .failed(sessionID, error.localizedDescription)
    }
}

struct RecordingArtifact: Equatable, Sendable {
    let sessionID: UUID
    let fileURL: URL
    let duration: TimeInterval
    let pixelSize: CGSize
    let capturesSystemAudio: Bool
    let capturesMicrophone: Bool
}

enum ScreenRecordingError: LocalizedError, Equatable {
    case sessionAlreadyActive
    case sessionNotActive
    case invalidSessionTransition
    case screenCapturePermissionDenied
    case microphonePermissionDenied
    case displayUnavailable
    case invalidSourceGeometry
    case cannotCreateWorkingDirectory
    case cannotConfigureWriter(String)
    case cannotConfigureMicrophone(String)
    case noVideoFrames
    case writerFailed(String)
    case exportFailed(String)
    case streamStopped(String)

    var errorDescription: String? {
        switch self {
        case .sessionAlreadyActive:
            "A screen recording is already active."
        case .sessionNotActive:
            "There is no active screen recording."
        case .invalidSessionTransition:
            "The screen recording changed state unexpectedly."
        case .screenCapturePermissionDenied:
            "Screen Recording access is required."
        case .microphonePermissionDenied:
            "Microphone access is required when microphone recording is enabled."
        case .displayUnavailable:
            "The selected display is no longer available."
        case .invalidSourceGeometry:
            "The selected recording area is invalid or crosses a display boundary."
        case .cannotCreateWorkingDirectory:
            "SmartShot could not create a temporary recording directory."
        case let .cannotConfigureWriter(message):
            "SmartShot could not configure the video encoder: \(message)"
        case let .cannotConfigureMicrophone(message):
            "SmartShot could not configure the microphone: \(message)"
        case .noVideoFrames:
            "The recording ended before any video frames were captured."
        case let .writerFailed(message):
            "SmartShot could not finish the recording: \(message)"
        case let .exportFailed(message):
            "SmartShot could not export the recording: \(message)"
        case let .streamStopped(message):
            "Screen capture stopped unexpectedly: \(message)"
        }
    }
}

private extension ClosedRange where Bound == Int {
    func clamped(_ value: Int) -> Int {
        Swift.min(upperBound, Swift.max(lowerBound, value))
    }
}
