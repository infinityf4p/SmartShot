import XCTest

final class RecordingAssetWriterTests: XCTestCase {
    func testBitRatePlannerIsBounded() {
        XCTAssertEqual(
            RecordingEncodingPlanner.averageVideoBitRate(
                width: 320,
                height: 180,
                frameRate: 24
            ),
            2_000_000
        )
        XCTAssertEqual(
            RecordingEncodingPlanner.averageVideoBitRate(
                width: 7_680,
                height: 4_320,
                frameRate: 60
            ),
            32_000_000
        )
    }

    func testBitRatePlannerScalesWithPixelRate() {
        let low = RecordingEncodingPlanner.averageVideoBitRate(
            width: 1_280,
            height: 720,
            frameRate: 30
        )
        let high = RecordingEncodingPlanner.averageVideoBitRate(
            width: 1_920,
            height: 1_080,
            frameRate: 60
        )
        XCTAssertGreaterThan(high, low)
    }
}
