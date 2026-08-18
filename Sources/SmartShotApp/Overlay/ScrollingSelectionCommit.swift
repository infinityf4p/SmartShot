import SmartShotCore
import CoreGraphics

struct AccessibilityScrollTargetIdentity: Equatable, Sendable {
    let processIdentifier: pid_t
    let windowIdentifier: CGWindowID
}

struct ScrollingSelectionCommit: Equatable, Sendable {
    let requestID: Int
    let hitPoint: CGPoint
    let expectedFrame: CGRect
    let targetIdentity: AccessibilityScrollTargetIdentity

    init?(
        appliedRequestID: Int,
        currentRequestID: Int,
        hitPoint: CGPoint,
        clickPoint: CGPoint,
        candidate: CaptureCandidate,
        targetIdentity: AccessibilityScrollTargetIdentity
    ) {
        guard appliedRequestID == currentRequestID,
              candidate.rect.insetBy(dx: -2, dy: -2).contains(clickPoint) else {
            return nil
        }
        requestID = appliedRequestID
        self.hitPoint = hitPoint
        expectedFrame = candidate.rect
        self.targetIdentity = targetIdentity
    }
}

enum ScrollingSelectionDecision: Equatable, Sendable {
    case resolve(ScrollingSelectionCommit)
    case refresh
    case unsupported

    static func decide(
        appliedRequestID: Int?,
        currentRequestID: Int,
        appliedHitPoint: CGPoint?,
        clickPoint: CGPoint,
        candidate: CaptureCandidate?,
        targetIdentity: AccessibilityScrollTargetIdentity?
    ) -> Self {
        guard let appliedRequestID,
              let appliedHitPoint,
              appliedRequestID == currentRequestID,
              pointsMatch(appliedHitPoint, clickPoint) else {
            return .refresh
        }
        guard let candidate, let targetIdentity,
              let selection = ScrollingSelectionCommit(
                  appliedRequestID: appliedRequestID,
                  currentRequestID: currentRequestID,
                  hitPoint: appliedHitPoint,
                  clickPoint: clickPoint,
                  candidate: candidate,
                  targetIdentity: targetIdentity
              ) else {
            return .unsupported
        }
        return .resolve(selection)
    }

    private static func pointsMatch(_ lhs: CGPoint, _ rhs: CGPoint) -> Bool {
        abs(lhs.x - rhs.x) <= 1 && abs(lhs.y - rhs.y) <= 1
    }
}
