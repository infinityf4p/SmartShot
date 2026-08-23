import CoreMedia
import XCTest

final class RecordingGIFExportTests: XCTestCase {
    func testDefaultPlanCapsLongVideoAtThirtySecondsAndFourHundredFiftyFrames() throws {
        let plan = try GIFFramePlan(videoDuration: 120)

        XCTAssertEqual(plan.duration, 30)
        XCTAssertEqual(plan.frameRate, 15)
        XCTAssertEqual(plan.maximumLongEdge, 1_280)
        XCTAssertEqual(plan.frameCount, 450)
        XCTAssertLessThan(CMTimeGetSeconds(plan.time(at: 449)), 30)
    }

    func testPlanUsesAvailableShortDuration() throws {
        let plan = try GIFFramePlan(
            videoDuration: 1.01,
            options: GIFExportOptions(maximumDuration: 10, frameRate: 10, maximumLongEdge: 800)
        )

        XCTAssertEqual(plan.duration, 1.01)
        XCTAssertEqual(plan.frameCount, 11)
        XCTAssertEqual(plan.frameDelay, 0.1, accuracy: 0.000_001)
        XCTAssertEqual(plan.maximumLongEdge, 800)
    }

    func testOptionsCannotExceedHardExportLimits() {
        let options = GIFExportOptions(
            maximumDuration: 300,
            frameRate: 120,
            maximumLongEdge: 8_000
        )

        XCTAssertEqual(options.maximumDuration, 30)
        XCTAssertEqual(options.frameRate, 15)
        XCTAssertEqual(options.maximumLongEdge, 1_280)
    }

    func testPlanRejectsInvalidDuration() {
        XCTAssertThrowsError(try GIFFramePlan(videoDuration: 0)) { error in
            XCTAssertEqual(error as? GIFExportError, .invalidVideoDuration)
        }
        XCTAssertThrowsError(try GIFFramePlan(videoDuration: .nan))
    }
}
