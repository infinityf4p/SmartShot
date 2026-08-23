import XCTest

final class SmartShotCommandTests: XCTestCase {
    func testCaptureCommandsRoundTripThroughURL() throws {
        for mode in SmartShotCaptureMode.allCases {
            let command = SmartShotExternalCommand.capture(mode)
            XCTAssertEqual(SmartShotExternalCommand(url: command.url), command)
        }
    }

    func testActionCommandsRoundTripThroughURL() throws {
        for command in [SmartShotExternalCommand.quickSave, .show] {
            XCTAssertEqual(SmartShotExternalCommand(url: command.url), command)
        }
    }

    func testCaptureCommandsPreserveTheFrontmostApplication() {
        for mode in SmartShotCaptureMode.allCases {
            XCTAssertFalse(SmartShotExternalCommand.capture(mode).activatesApplication)
        }
        XCTAssertFalse(SmartShotExternalCommand.quickSave.activatesApplication)
    }

    func testShowCommandActivatesSmartShot() {
        XCTAssertTrue(SmartShotExternalCommand.show.activatesApplication)
    }

    func testCLIParsesDefaultAndExplicitCaptureModes() throws {
        XCTAssertEqual(
            try SmartShotCLIParser.parse(arguments: []),
            .command(.capture(.smart))
        )
        XCTAssertEqual(
            try SmartShotCLIParser.parse(arguments: ["capture", "--mode", "app-scroll"]),
            .command(.capture(.appScroll))
        )
    }

    func testCLIParsesActionsAndHelp() throws {
        XCTAssertEqual(try SmartShotCLIParser.parse(arguments: ["quick-save"]), .command(.quickSave))
        XCTAssertEqual(try SmartShotCLIParser.parse(arguments: ["show"]), .command(.show))
        XCTAssertEqual(try SmartShotCLIParser.parse(arguments: ["--help"]), .help)
    }

    func testCLIRejectsMalformedCommands() {
        XCTAssertThrowsError(try SmartShotCLIParser.parse(arguments: ["capture", "--mode"]))
        XCTAssertThrowsError(try SmartShotCLIParser.parse(arguments: ["capture", "--mode", "page"]))
        XCTAssertThrowsError(try SmartShotCLIParser.parse(arguments: ["save"]))
        XCTAssertNil(SmartShotExternalCommand(url: URL(string: "smartshot://capture?mode=page")!))
        XCTAssertNil(SmartShotExternalCommand(url: URL(string: "https://example.com/capture")!))
    }
}
