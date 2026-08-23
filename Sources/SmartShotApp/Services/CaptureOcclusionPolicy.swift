import CoreGraphics
import Foundation

enum CaptureOcclusionPolicy {
    static func shouldIgnoreDebugTestHost(
        applicationName: String?,
        bundleIdentifier: String? = nil,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool {
#if DEBUG
        guard arguments.contains("--debug-ignore-test-host-overlays") else {
            return false
        }
        return applicationName == "ChatGPT Computer Use" ||
            applicationName == "Wind" ||
            applicationName == "Codex" ||
            bundleIdentifier == "com.wind.mac.Windotd"
#else
        return false
#endif
    }

    static func shouldIgnoreSystemWindow(
        ownerName: String?,
        layer: Int,
        frame: CGRect,
        captureFrame: CGRect
    ) -> Bool {
        if shouldIgnoreDebugTestHost(applicationName: ownerName) {
            return true
        }
        if ownerName == "Dock", layer == 20, frame.contains(captureFrame) {
            return true
        }
        return ownerName == "Window Server" &&
            layer == Int(CGWindowLevelForKey(.cursorWindow))
    }
}
