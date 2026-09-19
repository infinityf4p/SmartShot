import Combine
import Foundation
import ServiceManagement
import SmartShotCore

@MainActor
protocol LoginItemManaging {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

@MainActor
private struct MainAppLoginItem: LoginItemManaging {
    var status: SMAppService.Status { SMAppService.mainApp.status }

    func register() throws {
        try SMAppService.mainApp.register()
    }

    func unregister() throws {
        try SMAppService.mainApp.unregister()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

@MainActor
final class LaunchAtLoginService: ObservableObject {
    @Published private(set) var status: SMAppService.Status
    @Published private(set) var errorMessage: String?

    private let loginItem: any LoginItemManaging

    init(loginItem: any LoginItemManaging = MainAppLoginItem()) {
        self.loginItem = loginItem
        status = loginItem.status
    }

    var isEnabled: Bool { status == .enabled }
    var requiresApproval: Bool { status == .requiresApproval }

    func refreshStatus() {
        status = loginItem.status
        errorMessage = nil
    }

    func setEnabled(_ enabled: Bool) {
        refreshStatus()

        // macOS requires the user to restore consent in System Settings.
        if enabled && requiresApproval {
            openSystemSettings()
            return
        }
        guard enabled != isEnabled else { return }

        // A new app can report .notFound until its first registration.
        // Let registration determine whether launch at login is available.
        defer { status = loginItem.status }
        do {
            if enabled {
                try loginItem.register()
            } else {
                try loginItem.unregister()
            }
        } catch {
            errorMessage = enabled
                ? L10n.format("Could not enable launch at login: %@", error.localizedDescription)
                : L10n.format("Could not disable launch at login: %@", error.localizedDescription)
        }
    }

    func openSystemSettings() {
        loginItem.openSystemSettings()
    }
}
