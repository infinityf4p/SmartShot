import CoreGraphics
import XCTest

final class RecordingSourceMapperTests: XCTestCase {
    func testMapsBottomLeftAppKitRegionToTopLeftDisplayCoordinates() throws {
        let result = try RecordingSourceMapper.mapRegion(
            appKitRect: CGRect(x: 100, y: 100, width: 800, height: 200),
            screenFrame: CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
            displayID: 42,
            quartzReferenceTop: 1_080
        )

        XCTAssertEqual(result.appKitRect, CGRect(x: 100, y: 100, width: 800, height: 200))
        XCTAssertEqual(
            result.source,
            .region(
                displayID: 42,
                displayLocalRect: CGRect(x: 100, y: 780, width: 800, height: 200)
            )
        )
    }

    func testMappingUsesTheSelectedDisplaysLocalOrigin() throws {
        let screen = CGRect(x: -1_280, y: 200, width: 1_280, height: 800)
        let result = try RecordingSourceMapper.mapRegion(
            appKitRect: CGRect(x: -1_200, y: 300, width: 500, height: 240),
            screenFrame: screen,
            displayID: 9,
            quartzReferenceTop: 1_080
        )

        XCTAssertEqual(
            result.source,
            .region(
                displayID: 9,
                displayLocalRect: CGRect(x: 80, y: 460, width: 500, height: 240)
            )
        )
    }

    func testRejectsCrossDisplaySelectionInsteadOfSilentlyClippingIt() {
        XCTAssertThrowsError(
            try RecordingSourceMapper.mapRegion(
                appKitRect: CGRect(x: 1_800, y: 100, width: 300, height: 300),
                screenFrame: CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
                displayID: 1,
                quartzReferenceTop: 1_080
            )
        ) { error in
            XCTAssertEqual(error as? ScreenRecordingError, .invalidSourceGeometry)
        }
    }

    func testRejectsRegionOutsideDisplay() {
        XCTAssertThrowsError(
            try RecordingSourceMapper.mapRegion(
                appKitRect: CGRect(x: 2_000, y: 100, width: 100, height: 100),
                screenFrame: CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
                displayID: 1,
                quartzReferenceTop: 1_080
            )
        ) { error in
            XCTAssertEqual(error as? ScreenRecordingError, .invalidSourceGeometry)
        }
    }
}
