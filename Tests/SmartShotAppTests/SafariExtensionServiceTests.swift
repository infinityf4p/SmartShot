import XCTest

final class SafariExtensionServiceTests: XCTestCase {
    func testStatusMapsEnabledAndDisabledStates() {
        XCTAssertEqual(
            SafariExtensionIntegrationStatus.resolved(
                isEnabled: true,
                errorDescription: nil
            ),
            .enabled
        )
        XCTAssertEqual(
            SafariExtensionIntegrationStatus.resolved(
                isEnabled: false,
                errorDescription: nil
            ),
            .disabled
        )
    }

    func testStatusMapsServiceErrorsBeforeReturnedState() {
        let status = SafariExtensionIntegrationStatus.resolved(
            isEnabled: true,
            errorDescription: "Extension lookup failed"
        )

        XCTAssertEqual(
            status,
            .unavailable("Could not read Safari extension status: Extension lookup failed")
        )
        XCTAssertTrue(status.hasError)
        XCTAssertFalse(status.isEnabled)
    }

    func testStatusMapsMissingStateToVisibleError() {
        let status = SafariExtensionIntegrationStatus.resolved(
            isEnabled: nil,
            errorDescription: nil
        )

        XCTAssertEqual(
            status,
            .unavailable("Safari did not return the extension state.")
        )
        XCTAssertEqual(status.message, "Safari did not return the extension state.")
    }

    func testStatusPresentationProperties() {
        XCTAssertEqual(SafariExtensionIntegrationStatus.checking.message, "Checking Safari extension...")
        XCTAssertEqual(SafariExtensionIntegrationStatus.enabled.message, "Safari extension is enabled.")
        XCTAssertTrue(SafariExtensionIntegrationStatus.enabled.isEnabled)
        XCTAssertFalse(SafariExtensionIntegrationStatus.disabled.hasError)
        XCTAssertEqual(
            SafariExtensionIntegrationStatus.preferencesOpened.message,
            "Safari Extensions settings opened. Enable SmartShot there, then click Refresh."
        )
    }

    func testUsesEmbeddedSafariExtensionBundleIdentifier() {
        XCTAssertEqual(
            SafariExtensionService.extensionIdentifier,
            "com.infinityf4p.SmartShot.SafariExtension"
        )
    }

    @MainActor
    func testCurrentStatusCanResumeWhenSafariRepliesOffMainActor() async {
        let status = await SafariExtensionService.currentStatus()

        XCTAssertFalse(status.message.isEmpty)
    }
}
