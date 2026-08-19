import Carbon.HIToolbox
import XCTest

final class SelectionOverlayKeyCommandTests: XCTestCase {
    func testEscapeCancels() {
        XCTAssertEqual(
            SelectionOverlayKeyCommand.command(for: UInt16(kVK_Escape)),
            .cancel
        )
    }

    func testReturnKeysConfirm() {
        XCTAssertEqual(
            SelectionOverlayKeyCommand.command(for: UInt16(kVK_Return)),
            .confirm
        )
        XCTAssertEqual(
            SelectionOverlayKeyCommand.command(for: UInt16(kVK_ANSI_KeypadEnter)),
            .confirm
        )
    }

    func testArrowKeysCycleInExpectedDirection() {
        XCTAssertEqual(
            SelectionOverlayKeyCommand.command(for: UInt16(kVK_LeftArrow)),
            .cycle(-1)
        )
        XCTAssertEqual(
            SelectionOverlayKeyCommand.command(for: UInt16(kVK_DownArrow)),
            .cycle(-1)
        )
        XCTAssertEqual(
            SelectionOverlayKeyCommand.command(for: UInt16(kVK_RightArrow)),
            .cycle(1)
        )
        XCTAssertEqual(
            SelectionOverlayKeyCommand.command(for: UInt16(kVK_UpArrow)),
            .cycle(1)
        )
    }

    func testUnrelatedKeyPassesThrough() {
        XCTAssertEqual(
            SelectionOverlayKeyCommand.command(for: UInt16(kVK_ANSI_A)),
            .passThrough
        )
    }
}
