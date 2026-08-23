import CoreGraphics
import XCTest

final class ManualScrollAttemptTrackerTests: XCTestCase {
    func testCountsOneAttemptPerContinuousGesture() {
        var tracker = ManualScrollAttemptTracker(captureRect: CGRect(x: 10, y: 20, width: 300, height: 200))

        XCTAssertTrue(tracker.observe(sample(phaseBegan: true, timestamp: 1)))
        XCTAssertFalse(tracker.observe(sample(phaseChanged: true, timestamp: 1.1)))
        XCTAssertFalse(tracker.observe(sample(hasMomentum: true, timestamp: 1.2)))
        XCTAssertFalse(tracker.observe(sample(phaseEnded: true, timestamp: 1.3)))
        XCTAssertTrue(tracker.observe(sample(phaseChanged: true, timestamp: 2)))
        XCTAssertEqual(tracker.attemptCount, 2)
    }

    func testIgnoresEventsOutsideSelectionAndHorizontalScrolling() {
        var tracker = ManualScrollAttemptTracker(captureRect: CGRect(x: 10, y: 20, width: 300, height: 200))

        XCTAssertFalse(tracker.observe(sample(location: CGPoint(x: 400, y: 400), phaseBegan: true)))
        XCTAssertFalse(tracker.observe(sample(verticalDelta: 1, horizontalDelta: 8, phaseBegan: true)))
        XCTAssertEqual(tracker.attemptCount, 0)
    }

    func testDebouncesUnphasedMouseWheelEvents() {
        var tracker = ManualScrollAttemptTracker(captureRect: CGRect(x: 10, y: 20, width: 300, height: 200))

        XCTAssertTrue(tracker.observe(sample(timestamp: 1)))
        XCTAssertFalse(tracker.observe(sample(timestamp: 1.1)))
        XCTAssertTrue(tracker.observe(sample(timestamp: 1.5)))
        XCTAssertEqual(tracker.attemptCount, 2)
    }

    func testAutomaticFinishRequiresAcceptedMovementAndANewNoMovementAttempt() {
        XCTAssertFalse(
            ManualLongCaptureCompletionPolicy.shouldAutomaticallyFinish(
                framesAreEquivalent: true,
                fragmentCount: 1,
                acceptedScrollAttemptCount: 1,
                currentScrollAttemptCount: 2
            )
        )
        XCTAssertFalse(
            ManualLongCaptureCompletionPolicy.shouldAutomaticallyFinish(
                framesAreEquivalent: true,
                fragmentCount: 3,
                acceptedScrollAttemptCount: 2,
                currentScrollAttemptCount: 2
            )
        )
        XCTAssertFalse(
            ManualLongCaptureCompletionPolicy.shouldAutomaticallyFinish(
                framesAreEquivalent: false,
                fragmentCount: 3,
                acceptedScrollAttemptCount: 2,
                currentScrollAttemptCount: 3
            )
        )
        XCTAssertTrue(
            ManualLongCaptureCompletionPolicy.shouldAutomaticallyFinish(
                framesAreEquivalent: true,
                fragmentCount: 3,
                acceptedScrollAttemptCount: 2,
                currentScrollAttemptCount: 3
            )
        )
    }

#if DEBUG
    func testDebugCaptureSessionGateRejectsSupersededAndInvalidatedSessions() {
        var gate = DebugCaptureSessionGate()
        let first = gate.begin()

        XCTAssertTrue(gate.contains(first))

        let second = gate.begin()
        XCTAssertFalse(gate.contains(first))
        XCTAssertTrue(gate.contains(second))

        gate.invalidate()
        XCTAssertFalse(gate.contains(second))
    }
#endif

    private func sample(
        location: CGPoint = CGPoint(x: 100, y: 100),
        verticalDelta: Double = 8,
        horizontalDelta: Double = 0,
        phaseBegan: Bool = false,
        phaseChanged: Bool = false,
        phaseEnded: Bool = false,
        hasMomentum: Bool = false,
        timestamp: TimeInterval = 0
    ) -> ManualScrollEventSample {
        ManualScrollEventSample(
            location: location,
            verticalDelta: verticalDelta,
            horizontalDelta: horizontalDelta,
            phaseBegan: phaseBegan,
            phaseChanged: phaseChanged,
            phaseEnded: phaseEnded,
            hasMomentum: hasMomentum,
            timestamp: timestamp
        )
    }
}
