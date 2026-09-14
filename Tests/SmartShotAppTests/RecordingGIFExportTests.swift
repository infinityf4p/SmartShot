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
        XCTAssertEqual(plan.frameCount, 10)
        XCTAssertEqual(plan.frameDelay(at: 0), 0.1, accuracy: 0.000_001)
        XCTAssertEqual(plan.frameDelay(at: 9), 0.11, accuracy: 0.000_001)
        XCTAssertEqual(plan.maximumLongEdge, 800)
    }

    func testFrameTimingPreservesDurationAcrossSupportedFrameRates() throws {
        for frameRate in 1...GIFExportOptions.maximumSupportedFrameRate {
            for duration in [0.001, 0.019, 0.02, 0.033, 0.066, 0.067, 0.07, 0.101, 0.131, 1.01, 14.6, 30] {
                let plan = try GIFFramePlan(
                    videoDuration: duration,
                    options: GIFExportOptions(frameRate: frameRate)
                )
                var elapsed: TimeInterval = 0
                for index in 0..<plan.frameCount {
                    let delay = plan.frameDelay(at: index)
                    XCTAssertGreaterThanOrEqual(delay, 0.02)
                    XCTAssertEqual(delay * 100, (delay * 100).rounded(), accuracy: 0.000_001)
                    XCTAssertEqual(elapsed, CMTimeGetSeconds(plan.time(at: index)), accuracy: 0.005_000_001)
                    XCTAssertLessThan(CMTimeGetSeconds(plan.time(at: index)), duration)
                    elapsed += delay
                }
                XCTAssertEqual(elapsed, max(0.02, duration), accuracy: 0.005_000_001)
            }
        }
    }

    func testDefaultFrameRateDoesNotAccumulateRoundingError() throws {
        let plan = try GIFFramePlan(videoDuration: 14.6)
        let delays = (0..<plan.frameCount).map { plan.frameDelay(at: $0) }

        XCTAssertEqual(plan.frameCount, 219)
        XCTAssertEqual(Set(delays), [0.06, 0.07])
        XCTAssertEqual(delays.reduce(0, +), 14.6, accuracy: 0.000_001)
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
