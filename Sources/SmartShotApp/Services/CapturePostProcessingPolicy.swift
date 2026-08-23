import Foundation

struct CapturePostProcessingPolicy: Equatable, Sendable {
    let isPrivateCapture: Bool
    let historyEnabled: Bool
    let automaticCopyEnabled: Bool

    var shouldSaveHistory: Bool { historyEnabled && !isPrivateCapture }
    var shouldAutomaticallyCopy: Bool { automaticCopyEnabled && !isPrivateCapture }
}
