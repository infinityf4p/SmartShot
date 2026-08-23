import XCTest

final class CapturePostProcessingPolicyTests: XCTestCase {
    func testPrivateCaptureSuppressesPersistentAndClipboardCopies() {
        let policy = CapturePostProcessingPolicy(
            isPrivateCapture: true,
            historyEnabled: true,
            automaticCopyEnabled: true
        )
        XCTAssertFalse(policy.shouldSaveHistory)
        XCTAssertFalse(policy.shouldAutomaticallyCopy)
    }

    func testNormalCaptureHonorsIndependentPreferences() {
        XCTAssertEqual(
            CapturePostProcessingPolicy(
                isPrivateCapture: false,
                historyEnabled: true,
                automaticCopyEnabled: false
            ),
            CapturePostProcessingPolicy(
                isPrivateCapture: false,
                historyEnabled: true,
                automaticCopyEnabled: false
            )
        )
        XCTAssertTrue(CapturePostProcessingPolicy(
            isPrivateCapture: false,
            historyEnabled: true,
            automaticCopyEnabled: false
        ).shouldSaveHistory)
        XCTAssertFalse(CapturePostProcessingPolicy(
            isPrivateCapture: false,
            historyEnabled: true,
            automaticCopyEnabled: false
        ).shouldAutomaticallyCopy)
    }
}
