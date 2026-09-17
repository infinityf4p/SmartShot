import ServiceManagement
import XCTest

final class LaunchAtLoginServiceTests: XCTestCase {
    @MainActor
    func testReadsSystemStateWithoutChangingRegistration() async {
        let loginItem = TestLoginItem(status: .enabled)
        let service = LaunchAtLoginService(loginItem: loginItem)
        XCTAssertTrue(service.isEnabled)

        // A change made in System Settings must not be silently undone.
        loginItem.status = .requiresApproval
        service.refreshStatus()
        XCTAssertFalse(service.isEnabled)
        XCTAssertTrue(service.requiresApproval)
        XCTAssertEqual(loginItem.registerCalls, 0)
        XCTAssertEqual(loginItem.unregisterCalls, 0)
        XCTAssertEqual(loginItem.openSettingsCalls, 0)
    }

    @MainActor
    func testEnablesAndDisablesTheLoginItem() async {
        let loginItem = TestLoginItem()
        let service = LaunchAtLoginService(loginItem: loginItem)

        service.setEnabled(true)
        XCTAssertTrue(service.isEnabled)
        XCTAssertEqual(loginItem.registerCalls, 1)
        XCTAssertNil(service.errorMessage)

        service.setEnabled(false)
        XCTAssertFalse(service.isEnabled)
        XCTAssertEqual(loginItem.unregisterCalls, 1)
        XCTAssertNil(service.errorMessage)
    }

    @MainActor
    func testRegistrationFailureKeepsActualStateAndCanBeRetried() async {
        let loginItem = TestLoginItem()
        loginItem.error = TestFailure.denied
        let service = LaunchAtLoginService(loginItem: loginItem)

        service.setEnabled(true)
        XCTAssertFalse(service.isEnabled)
        XCTAssertNotNil(service.errorMessage)
        XCTAssertEqual(loginItem.registerCalls, 1)

        loginItem.error = nil
        service.setEnabled(true)
        XCTAssertTrue(service.isEnabled)
        XCTAssertNil(service.errorMessage)
        XCTAssertEqual(loginItem.registerCalls, 2)
    }

    @MainActor
    func testUnregistrationFailureDoesNotPretendLoginItemIsDisabled() async {
        let loginItem = TestLoginItem(status: .enabled)
        loginItem.error = TestFailure.denied
        let service = LaunchAtLoginService(loginItem: loginItem)

        service.setEnabled(false)
        XCTAssertTrue(service.isEnabled)
        XCTAssertNotNil(service.errorMessage)
        XCTAssertEqual(loginItem.unregisterCalls, 1)
    }

    @MainActor
    func testRegistrationNeedingApprovalStaysOffUntilSystemApproves() async {
        let loginItem = TestLoginItem()
        loginItem.statusAfterRegistration = .requiresApproval
        let service = LaunchAtLoginService(loginItem: loginItem)

        service.setEnabled(true)
        XCTAssertFalse(service.isEnabled)
        XCTAssertTrue(service.requiresApproval)
        XCTAssertNil(service.errorMessage)

        service.setEnabled(true)
        XCTAssertEqual(loginItem.registerCalls, 1)
        XCTAssertEqual(loginItem.openSettingsCalls, 1)

        loginItem.status = .enabled
        service.refreshStatus()
        XCTAssertTrue(service.isEnabled)
        XCTAssertFalse(service.requiresApproval)
    }

    @MainActor
    func testChecksCurrentSystemStateBeforeChangingRegistration() async {
        let loginItem = TestLoginItem()
        let service = LaunchAtLoginService(loginItem: loginItem)

        loginItem.status = .enabled
        service.setEnabled(true)
        XCTAssertTrue(service.isEnabled)
        XCTAssertEqual(loginItem.registerCalls, 0)

        loginItem.status = .notRegistered
        service.setEnabled(false)
        XCTAssertFalse(service.isEnabled)
        XCTAssertEqual(loginItem.unregisterCalls, 0)
    }
}

private enum TestFailure: Error {
    case denied
}

@MainActor
private final class TestLoginItem: LoginItemManaging {
    var status: SMAppService.Status
    var statusAfterRegistration: SMAppService.Status = .enabled
    var error: (any Error)?
    private(set) var registerCalls = 0
    private(set) var unregisterCalls = 0
    private(set) var openSettingsCalls = 0

    init(status: SMAppService.Status = .notRegistered) {
        self.status = status
    }

    func register() throws {
        registerCalls += 1
        if let error { throw error }
        status = statusAfterRegistration
    }

    func unregister() throws {
        unregisterCalls += 1
        if let error { throw error }
        status = .notRegistered
    }

    func openSystemSettings() {
        openSettingsCalls += 1
    }
}
