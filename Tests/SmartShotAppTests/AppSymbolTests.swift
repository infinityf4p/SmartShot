import AppKit
import XCTest

final class AppSymbolTests: XCTestCase {
    func testScrollingCaptureSymbolExists() {
        XCTAssertNotNil(
            NSImage(
                systemSymbolName: AppSymbol.scrollingCapture,
                accessibilityDescription: nil
            )
        )
    }
}
