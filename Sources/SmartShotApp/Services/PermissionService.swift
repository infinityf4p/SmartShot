import SmartShotCore
import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import Foundation

@MainActor
struct PermissionSystemClient {
    let preflightScreenCaptureAccess: @MainActor () -> Bool
    let requestScreenCaptureAccess: @MainActor () -> Bool
    let isAccessibilityTrusted: @MainActor () -> Bool
    let requestAccessibilityAccess: @MainActor () -> Bool
    let openSettings: @MainActor (String) -> Void

    static let live = PermissionSystemClient(
        preflightScreenCaptureAccess: { CGPreflightScreenCaptureAccess() },
        requestScreenCaptureAccess: { CGRequestScreenCaptureAccess() },
        isAccessibilityTrusted: { AXIsProcessTrusted() },
        requestAccessibilityAccess: {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        },
        openSettings: { anchor in
            guard let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
            ) else { return }
            NSWorkspace.shared.open(url)
        }
    )
}

@MainActor
final class PermissionService: ObservableObject {
    @Published private(set) var hasScreenCaptureAccess = false
    @Published private(set) var hasAccessibilityAccess = false
    @Published private(set) var hasMicrophoneAccess = false
    @Published private(set) var microphoneAuthorizationStatus: AVAuthorizationStatus = .notDetermined

    private enum DefaultsKey {
        static let requestedScreenCapture = "permissions.requestedScreenCapture.v1"
        static let requestedAccessibility = "permissions.requestedAccessibility.v1"
    }

    private let defaults: UserDefaults
    private let system: PermissionSystemClient

    init(
        defaults: UserDefaults = .standard,
        system: PermissionSystemClient = .live
    ) {
        self.defaults = defaults
        self.system = system
        refresh()
    }

    var screenCaptureActionTitle: String {
        hasScreenCaptureAccess ? L10n.text("Settings") : L10n.text("Allow")
    }

    var accessibilityActionTitle: String {
        hasAccessibilityAccess ? L10n.text("Settings") : L10n.text("Allow")
    }

    var microphoneActionTitle: String {
        microphoneAuthorizationStatus == .notDetermined ? L10n.text("Allow") : L10n.text("Settings")
    }

    func refresh() {
        hasScreenCaptureAccess = system.preflightScreenCaptureAccess()
        hasAccessibilityAccess = system.isAccessibilityTrusted()
        microphoneAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophoneAccess = microphoneAuthorizationStatus == .authorized
    }

    func requestScreenCapture() {
        refresh()
        guard !hasScreenCaptureAccess else {
            openScreenCaptureSettings()
            return
        }
        requestScreenCaptureAccess()
    }

    func requestScreenCaptureIfNeeded() {
        refresh()
        guard !hasScreenCaptureAccess,
              !defaults.bool(forKey: DefaultsKey.requestedScreenCapture) else { return }
        requestScreenCaptureAccess()
    }

    private func requestScreenCaptureAccess() {
        defaults.set(true, forKey: DefaultsKey.requestedScreenCapture)
        let granted = system.requestScreenCaptureAccess()
        refresh()
        if !granted, !hasScreenCaptureAccess {
            openScreenCaptureSettings()
        }
    }

    func requestAccessibility() {
        refresh()
        guard !hasAccessibilityAccess else {
            openAccessibilitySettings()
            return
        }
        requestAccessibilityAccess()
    }

    func requestAccessibilityIfNeeded() {
        refresh()
        guard !hasAccessibilityAccess,
              !defaults.bool(forKey: DefaultsKey.requestedAccessibility) else { return }
        requestAccessibilityAccess()
    }

    private func requestAccessibilityAccess() {
        defaults.set(true, forKey: DefaultsKey.requestedAccessibility)
        // The prompt-enabled AX call owns the recovery UI; opening Settings here can duplicate it.
        _ = system.requestAccessibilityAccess()
        refresh()
    }

    func requestMicrophone() {
        refresh()
        guard !hasMicrophoneAccess else {
            openMicrophoneSettings()
            return
        }
        guard microphoneAuthorizationStatus == .notDetermined else {
            openMicrophoneSettings()
            return
        }
        requestInitialMicrophoneAccess()
    }

    func requestMicrophoneIfNeeded() {
        refresh()
        guard !hasMicrophoneAccess,
              microphoneAuthorizationStatus == .notDetermined else { return }
        requestInitialMicrophoneAccess()
    }

    private func requestInitialMicrophoneAccess() {
        Task { [weak self] in
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            self?.refresh()
        }
    }

    func openScreenCaptureSettings() {
        openSettings(anchor: "Privacy_ScreenCapture")
    }

    func openAccessibilitySettings() {
        openSettings(anchor: "Privacy_Accessibility")
    }

    func openMicrophoneSettings() {
        openSettings(anchor: "Privacy_Microphone")
    }

    private func openSettings(anchor: String) {
        system.openSettings(anchor)
    }
}
