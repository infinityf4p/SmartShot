import Foundation
import ObjectiveC.runtime
import SafariServices

enum SafariExtensionIntegrationStatus: Equatable, Sendable {
    case checking
    case enabled
    case disabled
    case preferencesOpened
    case unavailable(String)

    static func resolved(isEnabled: Bool?, errorDescription: String?) -> Self {
        if let errorDescription {
            let detail = errorDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            return .unavailable(
                "Could not read Safari extension status: \(detail.isEmpty ? "Unknown error." : detail)"
            )
        }
        guard let isEnabled else {
            return .unavailable("Safari did not return the extension state.")
        }
        return isEnabled ? .enabled : .disabled
    }

    var message: String {
        switch self {
        case .checking:
            "Checking Safari extension..."
        case .enabled:
            "Safari extension is enabled."
        case .disabled:
            "Safari extension is off. Enable SmartShot Web Selector in Safari Settings. Local development requires Apple signing or Sign to Run Locally."
        case .preferencesOpened:
            "Safari Extensions settings opened. Enable SmartShot Web Selector, then click Refresh. If it is not listed, use Apple signing or Sign to Run Locally."
        case let .unavailable(message):
            message
        }
    }

    var isEnabled: Bool {
        self == .enabled
    }

    var hasError: Bool {
        if case .unavailable = self { true } else { false }
    }
}

private typealias SafariExtensionStateReply = @convention(block) (
    SFSafariExtensionState?,
    NSError?
) -> Void

private typealias SafariExtensionStateMethod = @convention(c) (
    AnyClass,
    Selector,
    NSString,
    SafariExtensionStateReply
) -> Void

enum SafariExtensionService {
    static let extensionIdentifier = "com.infinityf4p.SmartShot.SafariExtension"

    static func currentStatus() async -> SafariExtensionIntegrationStatus {
        await withCheckedContinuation { continuation in
            let didStart = requestCurrentState { isEnabled, errorDescription in
                continuation.resume(
                    returning: .resolved(
                        isEnabled: isEnabled,
                        errorDescription: errorDescription
                    )
                )
            }
            if !didStart {
                continuation.resume(
                    returning: .unavailable("Safari extension state API is unavailable.")
                )
            }
        }
    }

    static func openPreferences() async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            SFSafariApplication.showPreferencesForExtension(
                withIdentifier: extensionIdentifier
            ) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private static func requestCurrentState(
        completion: @escaping @Sendable (Bool?, String?) -> Void
    ) -> Bool {
        let selector = NSSelectorFromString(
            "getStateOfSafariExtensionWithIdentifier:completionHandler:"
        )
        guard let method = class_getClassMethod(SFSafariExtensionManager.self, selector) else {
            return false
        }
        let function = unsafeBitCast(
            method_getImplementation(method),
            to: SafariExtensionStateMethod.self
        )
        let reply: SafariExtensionStateReply = { state, error in
            completion(state?.isEnabled, error?.localizedDescription)
        }

        // SafariServices marks this reply MainActor but delivers it on its XPC reply queue.
        // Calling the stable Objective-C selector avoids Swift's invalid executor precondition.
        function(
            SFSafariExtensionManager.self,
            selector,
            extensionIdentifier as NSString,
            reply
        )
        return true
    }
}
