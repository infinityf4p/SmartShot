import CoreGraphics
import Foundation

struct ManualScrollEventSample: Sendable {
    let location: CGPoint
    let verticalDelta: Double
    let horizontalDelta: Double
    let phaseBegan: Bool
    let phaseChanged: Bool
    let phaseEnded: Bool
    let hasMomentum: Bool
    let timestamp: TimeInterval
}

struct ManualScrollAttemptTracker: Sendable {
    let captureRect: CGRect
    var unphasedDebounceInterval: TimeInterval = 0.35

    private(set) var attemptCount = 0
    private var continuousGestureIsActive = false
    private var lastUnphasedAttemptTimestamp = -Double.infinity

    init(captureRect: CGRect, unphasedDebounceInterval: TimeInterval = 0.35) {
        self.captureRect = captureRect
        self.unphasedDebounceInterval = unphasedDebounceInterval
    }

    @discardableResult
    mutating func observe(_ sample: ManualScrollEventSample) -> Bool {
        if sample.phaseEnded {
            continuousGestureIsActive = false
            return false
        }
        guard captureRect.contains(sample.location),
              abs(sample.verticalDelta) >= 0.5,
              abs(sample.verticalDelta) > abs(sample.horizontalDelta) else {
            return false
        }

        if sample.phaseBegan || (sample.phaseChanged && !continuousGestureIsActive) {
            continuousGestureIsActive = true
            attemptCount += 1
            return true
        }
        if sample.phaseChanged || sample.hasMomentum {
            return false
        }
        guard sample.timestamp - lastUnphasedAttemptTimestamp >= unphasedDebounceInterval else {
            return false
        }
        lastUnphasedAttemptTimestamp = sample.timestamp
        attemptCount += 1
        return true
    }
}

enum ManualLongCaptureCompletionPolicy {
    static func shouldAutomaticallyFinish(
        framesAreEquivalent: Bool,
        fragmentCount: Int,
        acceptedScrollAttemptCount: Int,
        currentScrollAttemptCount: Int
    ) -> Bool {
        framesAreEquivalent
            && fragmentCount > 1
            && currentScrollAttemptCount > acceptedScrollAttemptCount
    }
}

#if DEBUG
struct DebugCaptureSessionGate: Sendable {
    private var currentID: UUID?

    mutating func begin() -> UUID {
        let id = UUID()
        currentID = id
        return id
    }

    mutating func invalidate() {
        currentID = nil
    }

    func contains(_ id: UUID) -> Bool {
        currentID == id
    }
}
#endif
