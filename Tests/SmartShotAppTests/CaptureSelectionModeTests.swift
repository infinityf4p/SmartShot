import XCTest
@testable import SmartShotCore

final class CaptureSelectionModeTests: XCTestCase {
    func testUnifiedToolbarKeepsExpectedModeOrder() {
        XCTAssertEqual(CaptureSelectionMode.allCases, [.smart, .region, .long, .appScroll])
    }

    func testEveryModeHasDistinctPresentationAndAccessibleHelp() {
        let modes = CaptureSelectionMode.allCases

        XCTAssertEqual(Set(modes.map(\.title)).count, modes.count)
        XCTAssertEqual(Set(modes.map(\.systemImage)).count, modes.count)
        XCTAssertTrue(modes.allSatisfy { !$0.accessibilityHelp.isEmpty })
    }
}
