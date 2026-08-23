import CoreGraphics
import XCTest

final class RecordingSourceResolverTests: XCTestCase {
    func testRegionValidatorAcceptsARegionInsideOneDisplay() throws {
        let rect = CGRect(x: 12, y: 24, width: 800, height: 600)
        XCTAssertEqual(
            try RecordingRegionValidator.validated(
                rect,
                within: CGSize(width: 1_920, height: 1_080)
            ),
            rect
        )
    }

    func testRegionValidatorStandardizesNegativeDimensions() throws {
        let result = try RecordingRegionValidator.validated(
            CGRect(x: 200, y: 150, width: -100, height: -50),
            within: CGSize(width: 1_920, height: 1_080)
        )
        XCTAssertEqual(result, CGRect(x: 100, y: 100, width: 100, height: 50))
    }

    func testRegionValidatorRejectsCrossDisplayCoordinates() {
        XCTAssertThrowsError(
            try RecordingRegionValidator.validated(
                CGRect(x: 1_800, y: 20, width: 200, height: 200),
                within: CGSize(width: 1_920, height: 1_080)
            )
        ) { error in
            XCTAssertEqual(error as? ScreenRecordingError, .invalidSourceGeometry)
        }
    }

    func testRegionValidatorRejectsNaN() {
        XCTAssertThrowsError(
            try RecordingRegionValidator.validated(
                CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100),
                within: CGSize(width: 1_920, height: 1_080)
            )
        )
    }
}
