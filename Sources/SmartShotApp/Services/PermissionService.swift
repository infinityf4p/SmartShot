import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

@MainActor
final class PermissionService: ObservableObject {
    @Published private(set) var hasScreenCaptureAccess = false
    @Published private(set) var hasAccessibilityAccess = false

    init() {
        refresh()
    }

    func refresh() {
        hasScreenCaptureAccess = CGPreflightScreenCaptureAccess()
        hasAccessibilityAccess = AXIsProcessTrusted()
    }

    func requestScreenCapture() {
        _ = CGRequestScreenCaptureAccess()
        refresh()
    }

    func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refresh()
    }

    func openScreenCaptureSettings() {
        openSettings(anchor: "Privacy_ScreenCapture")
    }

    func openAccessibilitySettings() {
        openSettings(anchor: "Privacy_Accessibility")
    }

    private func openSettings(anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }
}
