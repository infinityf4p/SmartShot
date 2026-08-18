import CoreGraphics
import XCTest
@testable import SmartShotCore

final class AXScreenLayoutTests: XCTestCase {
    func testPointAndRectConversionUsesMainDisplayTopAcrossMultipleScreens() {
        let layout = AXScreenLayout(
            appKitDisplayFrames: [
                CGRect(x: 0, y: 0, width: 1_440, height: 900),
                CGRect(x: 1_440, y: -180, width: 1_920, height: 1_080),
                CGRect(x: -1_280, y: 900, width: 1_280, height: 720),
            ],
            quartzReferenceTop: 900
        )

        XCTAssertEqual(
            layout.appKitToQuartz(CGPoint(x: 1_600, y: -100)),
            CGPoint(x: 1_600, y: 1_000)
        )

        let appKitRect = CGRect(x: -1_100, y: 1_000, width: 500, height: 300)
        let quartzRect = CGRect(x: -1_100, y: -400, width: 500, height: 300)
        XCTAssertEqual(layout.appKitToQuartz(appKitRect), quartzRect)
        XCTAssertEqual(layout.quartzToAppKit(quartzRect), appKitRect)
    }

    func testQuartzDisplayFramesPreservePerDisplayPlacement() {
        let layout = AXScreenLayout(
            appKitDisplayFrames: [
                CGRect(x: 0, y: 0, width: 1_000, height: 800),
                CGRect(x: 1_000, y: 200, width: 600, height: 400),
            ],
            quartzReferenceTop: 800
        )

        XCTAssertEqual(
            layout.quartzDisplayFrames,
            [
                CGRect(x: 0, y: 0, width: 1_000, height: 800),
                CGRect(x: 1_000, y: 200, width: 600, height: 400),
            ]
        )
        XCTAssertEqual(layout.visibleDesktopArea, 1_040_000)
    }

    func testVisibleAreaExcludesGapsBetweenDisplays() {
        let layout = AXScreenLayout(
            appKitDisplayFrames: [
                CGRect(x: 0, y: 0, width: 800, height: 600),
                CGRect(x: 1_000, y: 0, width: 800, height: 600),
            ],
            quartzReferenceTop: 600
        )

        let crossingRect = CGRect(x: 700, y: 100, width: 400, height: 200)
        XCTAssertEqual(layout.visibleArea(ofQuartzRect: crossingRect), 40_000)
    }
}
