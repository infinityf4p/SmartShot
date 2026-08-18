import ApplicationServices
import Foundation

public enum AccessibilityTrustStatus: Equatable, Sendable {
    case trusted
    case notTrusted
}

public protocol AccessibilityPermissionProviding {
    /// Checks trust without presenting system UI.
    var trustStatus: AccessibilityTrustStatus { get }
    /// Explicitly asks macOS to present its Accessibility permission guidance.
    @discardableResult
    func promptForAccess() -> AccessibilityTrustStatus
}

public struct AccessibilityPermissionController: AccessibilityPermissionProviding {
    public init() {}

    public var trustStatus: AccessibilityTrustStatus {
        AXIsProcessTrustedWithOptions(nil) ? .trusted : .notTrusted
    }

    @discardableResult
    public func promptForAccess() -> AccessibilityTrustStatus {
        let options = [
            "AXTrustedCheckOptionPrompt": true
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options) ? .trusted : .notTrusted
    }
}
