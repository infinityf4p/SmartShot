import XCTest

@MainActor
final class PermissionServiceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        suiteName = "com.infinityf4p.SmartShot.PermissionTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() async throws {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
    }

    func testFirstExplicitAllowRequestsBothSystemPermissions() {
        let stub = PermissionSystemStub()
        let service = PermissionService(defaults: defaults, system: stub.client)

        XCTAssertEqual(service.screenCaptureActionTitle, "Allow")
        XCTAssertEqual(service.accessibilityActionTitle, "Allow")

        service.requestScreenCapture()
        service.requestAccessibility()

        XCTAssertEqual(stub.screenCaptureRequestCount, 1)
        XCTAssertEqual(stub.accessibilityRequestCount, 1)
        XCTAssertEqual(stub.openedSettingsAnchors, ["Privacy_ScreenCapture"])
        XCTAssertEqual(service.screenCaptureActionTitle, "Allow")
        XCTAssertEqual(service.accessibilityActionTitle, "Allow")
    }

    func testExplicitAllowRetriesAfterDenial() {
        let stub = PermissionSystemStub()
        let service = PermissionService(defaults: defaults, system: stub.client)

        service.requestScreenCapture()
        service.requestAccessibility()
        service.requestScreenCapture()
        service.requestAccessibility()

        XCTAssertEqual(stub.screenCaptureRequestCount, 2)
        XCTAssertEqual(stub.accessibilityRequestCount, 2)
        XCTAssertEqual(
            stub.openedSettingsAnchors,
            ["Privacy_ScreenCapture", "Privacy_ScreenCapture"]
        )
    }

    func testExplicitAllowRetriesAfterTCCResetWithPersistentRequestMarker() {
        let stub = PermissionSystemStub()
        let service = PermissionService(defaults: defaults, system: stub.client)

        service.requestScreenCapture()
        service.requestAccessibility()
        stub.hasScreenCaptureAccess = true
        stub.hasAccessibilityAccess = true
        service.refresh()
        XCTAssertEqual(service.screenCaptureActionTitle, "Settings")
        XCTAssertEqual(service.accessibilityActionTitle, "Settings")

        stub.hasScreenCaptureAccess = false
        stub.hasAccessibilityAccess = false
        service.refresh()
        XCTAssertEqual(service.screenCaptureActionTitle, "Allow")
        XCTAssertEqual(service.accessibilityActionTitle, "Allow")

        service.requestScreenCapture()
        service.requestAccessibility()

        XCTAssertEqual(stub.screenCaptureRequestCount, 2)
        XCTAssertEqual(stub.accessibilityRequestCount, 2)
        XCTAssertEqual(
            stub.openedSettingsAnchors,
            ["Privacy_ScreenCapture", "Privacy_ScreenCapture"]
        )
    }

    func testScreenRequestThatGrantsAccessDoesNotOpenSettingsFallback() {
        let stub = PermissionSystemStub()
        stub.grantsScreenCaptureWhenRequested = true
        let service = PermissionService(defaults: defaults, system: stub.client)

        service.requestScreenCapture()

        XCTAssertTrue(service.hasScreenCaptureAccess)
        XCTAssertEqual(stub.screenCaptureRequestCount, 1)
        XCTAssertTrue(stub.openedSettingsAnchors.isEmpty)
    }

    func testGrantedPermissionOpensSettingsWithoutRequestingAgain() {
        let stub = PermissionSystemStub()
        stub.hasScreenCaptureAccess = true
        stub.hasAccessibilityAccess = true
        let service = PermissionService(defaults: defaults, system: stub.client)

        service.requestScreenCapture()
        service.requestAccessibility()

        XCTAssertEqual(stub.screenCaptureRequestCount, 0)
        XCTAssertEqual(stub.accessibilityRequestCount, 0)
        XCTAssertEqual(
            stub.openedSettingsAnchors,
            ["Privacy_ScreenCapture", "Privacy_Accessibility"]
        )
    }

    func testRefreshNeverRequestsAndFeatureAttemptsDoNotPromptRepeatedly() {
        let stub = PermissionSystemStub()
        let service = PermissionService(defaults: defaults, system: stub.client)

        service.refresh()
        service.refresh()
        XCTAssertEqual(stub.screenCaptureRequestCount, 0)
        XCTAssertEqual(stub.accessibilityRequestCount, 0)

        service.requestScreenCaptureIfNeeded()
        service.requestAccessibilityIfNeeded()
        service.requestScreenCaptureIfNeeded()
        service.requestAccessibilityIfNeeded()

        XCTAssertEqual(stub.screenCaptureRequestCount, 1)
        XCTAssertEqual(stub.accessibilityRequestCount, 1)
        XCTAssertEqual(stub.openedSettingsAnchors, ["Privacy_ScreenCapture"])
    }
}

@MainActor
private final class PermissionSystemStub {
    var hasScreenCaptureAccess = false
    var hasAccessibilityAccess = false
    var grantsScreenCaptureWhenRequested = false
    var screenCaptureRequestCount = 0
    var accessibilityRequestCount = 0
    var openedSettingsAnchors: [String] = []

    var client: PermissionSystemClient {
        PermissionSystemClient(
            preflightScreenCaptureAccess: { self.hasScreenCaptureAccess },
            requestScreenCaptureAccess: {
                self.screenCaptureRequestCount += 1
                if self.grantsScreenCaptureWhenRequested {
                    self.hasScreenCaptureAccess = true
                }
                return self.hasScreenCaptureAccess
            },
            isAccessibilityTrusted: { self.hasAccessibilityAccess },
            requestAccessibilityAccess: {
                self.accessibilityRequestCount += 1
                return self.hasAccessibilityAccess
            },
            openSettings: { self.openedSettingsAnchors.append($0) }
        )
    }
}
