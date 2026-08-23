import CoreGraphics
import XCTest

final class RecordingModelsTests: XCTestCase {
    func testVideoPlannerPreservesAspectAndProducesEvenCappedDimensions() throws {
        let plan = try RecordingVideoPlanner.plan(
            sourceSize: CGSize(width: 3_000, height: 2_000),
            pointPixelScale: 2,
            options: RecordingOptions(frameRate: 30, maximumLongEdge: 3_840)
        )

        XCTAssertEqual(plan.width, 3_840)
        XCTAssertEqual(plan.height, 2_560)
        XCTAssertEqual(plan.width % 2, 0)
        XCTAssertEqual(plan.height % 2, 0)
        XCTAssertEqual(plan.frameRate, 30)
    }

    func testVideoPlannerDoesNotUpscaleSmallSources() throws {
        let plan = try RecordingVideoPlanner.plan(
            sourceSize: CGSize(width: 640, height: 360),
            pointPixelScale: 1,
            options: RecordingOptions(maximumLongEdge: 3_840)
        )

        XCTAssertEqual(plan.pixelSize, CGSize(width: 640, height: 360))
    }

    func testVideoPlannerRejectsNonFiniteGeometry() {
        XCTAssertThrowsError(
            try RecordingVideoPlanner.plan(
                sourceSize: CGSize(width: CGFloat.infinity, height: 100),
                pointPixelScale: 1,
                options: RecordingOptions()
            )
        ) { error in
            XCTAssertEqual(error as? ScreenRecordingError, .invalidSourceGeometry)
        }
    }

    func testOptionsClampUnsafeValues() {
        let options = RecordingOptions(frameRate: 1_000, maximumLongEdge: 1)
        XCTAssertEqual(options.frameRate, 60)
        XCTAssertEqual(options.maximumLongEdge, 2)
    }

    func testStateMachineStopIsIdempotent() throws {
        let id = UUID()
        var machine = RecordingSessionStateMachine()
        try machine.begin(sessionID: id)
        try machine.didStart(sessionID: id)

        XCTAssertTrue(try machine.requestStop(sessionID: id))
        XCTAssertFalse(try machine.requestStop(sessionID: id))
        try machine.finish(sessionID: id)
        XCTAssertFalse(try machine.requestStop(sessionID: id))
        XCTAssertEqual(machine.state, .finished(id))
    }

    func testStateMachineRejectsStopWhilePreparing() throws {
        let id = UUID()
        var machine = RecordingSessionStateMachine()
        try machine.begin(sessionID: id)

        XCTAssertThrowsError(try machine.requestStop(sessionID: id)) { error in
            XCTAssertEqual(error as? ScreenRecordingError, .sessionNotActive)
        }
        XCTAssertEqual(machine.state, .preparing(id))
    }

    func testStateMachineCanBeginAgainAfterCancellation() throws {
        let cancelledID = UUID()
        let replacementID = UUID()
        var machine = RecordingSessionStateMachine()
        try machine.begin(sessionID: cancelledID)
        machine.cancel(sessionID: cancelledID)

        try machine.begin(sessionID: replacementID)

        XCTAssertEqual(machine.state, .preparing(replacementID))
    }

    func testStateMachineIgnoresStaleCancellation() throws {
        let current = UUID()
        var machine = RecordingSessionStateMachine()
        try machine.begin(sessionID: current)
        machine.cancel(sessionID: UUID())
        XCTAssertEqual(machine.state, .preparing(current))
    }
}
