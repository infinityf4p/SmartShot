import SmartShotCore
import CoreGraphics
import XCTest

final class ScrollingSelectionCommitTests: XCTestCase {
    func testCommitsTheCandidateFromTheCurrentRequest() {
        let candidate = makeCandidate(rect: CGRect(x: 100, y: 80, width: 500, height: 400))

        let selection = ScrollingSelectionCommit(
            appliedRequestID: 7,
            currentRequestID: 7,
            hitPoint: CGPoint(x: 180, y: 160),
            clickPoint: CGPoint(x: 181, y: 159),
            candidate: candidate,
            targetIdentity: makeIdentity()
        )

        XCTAssertEqual(selection?.requestID, 7)
        XCTAssertEqual(selection?.hitPoint, CGPoint(x: 180, y: 160))
        XCTAssertEqual(selection?.expectedFrame, candidate.rect)
        XCTAssertEqual(selection?.targetIdentity, makeIdentity())
    }

    func testRejectsAStaleHighlightWhileNewDetectionIsPending() {
        let selection = ScrollingSelectionCommit(
            appliedRequestID: 7,
            currentRequestID: 8,
            hitPoint: CGPoint(x: 180, y: 160),
            clickPoint: CGPoint(x: 180, y: 160),
            candidate: makeCandidate(rect: CGRect(x: 100, y: 80, width: 500, height: 400)),
            targetIdentity: makeIdentity()
        )

        XCTAssertNil(selection)
    }

    func testRejectsClickOutsideTheHighlightedCandidate() {
        let selection = ScrollingSelectionCommit(
            appliedRequestID: 7,
            currentRequestID: 7,
            hitPoint: CGPoint(x: 180, y: 160),
            clickPoint: CGPoint(x: 700, y: 600),
            candidate: makeCandidate(rect: CGRect(x: 100, y: 80, width: 500, height: 400)),
            targetIdentity: makeIdentity()
        )

        XCTAssertNil(selection)
    }

    func testPreservesTheCycledOuterCandidateFrame() {
        let outer = makeCandidate(
            rect: CGRect(x: 50, y: 40, width: 900, height: 700),
            level: 5
        )

        let selection = ScrollingSelectionCommit(
            appliedRequestID: 12,
            currentRequestID: 12,
            hitPoint: CGPoint(x: 250, y: 220),
            clickPoint: CGPoint(x: 250, y: 220),
            candidate: outer,
            targetIdentity: makeIdentity()
        )

        XCTAssertEqual(selection?.expectedFrame, outer.rect)
    }

    func testDecisionRefreshesWhenTheHighlightWasMeasuredAtAnotherPoint() {
        let decision = ScrollingSelectionDecision.decide(
            appliedRequestID: 7,
            currentRequestID: 7,
            appliedHitPoint: CGPoint(x: 180, y: 160),
            clickPoint: CGPoint(x: 230, y: 200),
            candidate: makeCandidate(rect: CGRect(x: 100, y: 80, width: 500, height: 400)),
            targetIdentity: makeIdentity()
        )

        XCTAssertEqual(decision, .refresh)
    }

    func testDecisionRejectsCurrentPointWithoutASupportedCandidate() {
        let decision = ScrollingSelectionDecision.decide(
            appliedRequestID: 7,
            currentRequestID: 7,
            appliedHitPoint: CGPoint(x: 180, y: 160),
            clickPoint: CGPoint(x: 180, y: 160),
            candidate: nil,
            targetIdentity: makeIdentity()
        )

        XCTAssertEqual(decision, .unsupported)
    }

    func testDecisionResolvesTheCurrentSupportedCandidate() {
        let candidate = makeCandidate(rect: CGRect(x: 100, y: 80, width: 500, height: 400))
        let decision = ScrollingSelectionDecision.decide(
            appliedRequestID: 7,
            currentRequestID: 7,
            appliedHitPoint: CGPoint(x: 180, y: 160),
            clickPoint: CGPoint(x: 180, y: 160),
            candidate: candidate,
            targetIdentity: makeIdentity()
        )

        XCTAssertEqual(
            decision,
            .resolve(
                ScrollingSelectionCommit(
                    appliedRequestID: 7,
                    currentRequestID: 7,
                    hitPoint: CGPoint(x: 180, y: 160),
                    clickPoint: CGPoint(x: 180, y: 160),
                    candidate: candidate,
                    targetIdentity: makeIdentity()
                )!
            )
        )
    }

    private func makeCandidate(rect: CGRect, level: Int = 2) -> CaptureCandidate {
        CaptureCandidate(
            rect: rect,
            source: .accessibility,
            label: "Scroll Area",
            level: level
        )
    }

    private func makeIdentity() -> AccessibilityScrollTargetIdentity {
        AccessibilityScrollTargetIdentity(
            processIdentifier: 1234,
            windowIdentifier: 5678
        )
    }
}
