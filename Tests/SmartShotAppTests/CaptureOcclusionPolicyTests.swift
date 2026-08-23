import CoreGraphics
import XCTest

final class CaptureOcclusionPolicyTests: XCTestCase {
    private let captureFrame = CGRect(x: 100, y: 80, width: 900, height: 600)

    func testIgnoresFullScreenDockShield() {
        XCTAssertTrue(
            CaptureOcclusionPolicy.shouldIgnoreSystemWindow(
                ownerName: "Dock",
                layer: 20,
                frame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
                captureFrame: captureFrame
            )
        )
    }

    func testDoesNotIgnoreVisibleDockWindowThatDoesNotCoverCapture() {
        XCTAssertFalse(
            CaptureOcclusionPolicy.shouldIgnoreSystemWindow(
                ownerName: "Dock",
                layer: 20,
                frame: CGRect(x: 0, y: 850, width: 1_440, height: 50),
                captureFrame: captureFrame
            )
        )
    }

    func testIgnoresWindowServerCursorWindow() {
        XCTAssertTrue(
            CaptureOcclusionPolicy.shouldIgnoreSystemWindow(
                ownerName: "Window Server",
                layer: Int(CGWindowLevelForKey(.cursorWindow)),
                frame: CGRect(x: 500, y: 300, width: 24, height: 24),
                captureFrame: captureFrame
            )
        )
    }

    func testDoesNotIgnoreOtherWindowServerLayers() {
        XCTAssertFalse(
            CaptureOcclusionPolicy.shouldIgnoreSystemWindow(
                ownerName: "Window Server",
                layer: Int(CGWindowLevelForKey(.cursorWindow)) - 1,
                frame: CGRect(x: 500, y: 300, width: 200, height: 100),
                captureFrame: captureFrame
            )
        )
    }

    func testDoesNotIgnoreRegularFloatingWindow() {
        XCTAssertFalse(
            CaptureOcclusionPolicy.shouldIgnoreSystemWindow(
                ownerName: "Example App",
                layer: 20,
                frame: CGRect(x: 500, y: 300, width: 200, height: 100),
                captureFrame: captureFrame
            )
        )
    }

    func testDebugHostFilterDoesNotIgnoreNotificationCenter() {
        XCTAssertFalse(
            CaptureOcclusionPolicy.shouldIgnoreDebugTestHost(
                applicationName: "Notification Center",
                arguments: ["--debug-ignore-test-host-overlays"]
            )
        )
    }

    func testDebugHostFilterIgnoresOnlyKnownAutomationHostWhenEnabled() {
        XCTAssertTrue(
            CaptureOcclusionPolicy.shouldIgnoreDebugTestHost(
                applicationName: "Codex",
                arguments: ["--debug-ignore-test-host-overlays"]
            )
        )
        XCTAssertFalse(
            CaptureOcclusionPolicy.shouldIgnoreDebugTestHost(
                applicationName: "Codex",
                arguments: []
            )
        )
    }
}
