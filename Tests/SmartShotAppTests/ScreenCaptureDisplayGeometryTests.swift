import CoreGraphics
import XCTest

final class ScreenCaptureDisplayGeometryTests: XCTestCase {
    func testMatchesASelectionFullyInsideOneDisplayWithoutChangingIt() throws {
        let rect = CGRect(x: 1_120, y: 80, width: 600, height: 420)
        let match = try XCTUnwrap(ScreenCaptureDisplayGeometry.match(
            rect: rect,
            displayFrames: [
                CGRect(x: 0, y: 0, width: 1_000, height: 800),
                CGRect(x: 1_000, y: 0, width: 1_000, height: 800),
            ]
        ))

        XCTAssertEqual(match.displayIndex, 1)
        XCTAssertEqual(match.captureRect, rect)
    }

    func testRejectsASelectionThatCrossesAdjacentDisplays() {
        XCTAssertNil(ScreenCaptureDisplayGeometry.match(
            rect: CGRect(x: 900, y: 100, width: 200, height: 300),
            displayFrames: [
                CGRect(x: 0, y: 0, width: 1_000, height: 800),
                CGRect(x: 1_000, y: 0, width: 1_000, height: 800),
            ]
        ))
    }

    func testRejectsASelectionThatIsPartiallyOffscreen() {
        XCTAssertNil(ScreenCaptureDisplayGeometry.match(
            rect: CGRect(x: -12, y: 100, width: 300, height: 240),
            displayFrames: [CGRect(x: 0, y: 0, width: 1_000, height: 800)]
        ))
    }

    func testNormalizesOnlySubPointDisplayEdgeRounding() throws {
        let frame = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let match = try XCTUnwrap(ScreenCaptureDisplayGeometry.match(
            rect: CGRect(x: -0.25, y: 40, width: 300.25, height: 240),
            displayFrames: [frame]
        ))

        XCTAssertEqual(match.captureRect, CGRect(x: 0, y: 40, width: 300, height: 240))
        XCTAssertNil(ScreenCaptureDisplayGeometry.match(
            rect: CGRect(x: -0.51, y: 40, width: 300.51, height: 240),
            displayFrames: [frame]
        ))
    }
}
