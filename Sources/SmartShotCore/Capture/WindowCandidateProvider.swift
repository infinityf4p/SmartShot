import AppKit
import CoreGraphics
import Foundation

public struct WindowCandidateProvider: Sendable {
    private let ownProcessID: pid_t

    public init(ownProcessID: pid_t = ProcessInfo.processInfo.processIdentifier) {
        self.ownProcessID = ownProcessID
    }

    public func candidates(at cocoaPoint: CGPoint) -> [CaptureCandidate] {
        let quartzPoint = ScreenGeometry.cocoaToQuartz(cocoaPoint)
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        var matches: [CaptureCandidate] = []
        for info in windows {
            guard
                let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                ownerPID != ownProcessID,
                let layer = info[kCGWindowLayer as String] as? Int,
                layer == 0,
                let windowNumber = info[kCGWindowNumber as String] as? NSNumber,
                let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                let quartzRect = CGRect(dictionaryRepresentation: boundsDictionary),
                quartzRect.contains(quartzPoint)
            else {
                continue
            }

            let appName = info[kCGWindowOwnerName as String] as? String ?? "Window"
            let windowName = info[kCGWindowName as String] as? String
            let label = windowName.flatMap { $0.isEmpty ? nil : "\(appName) - \($0)" } ?? appName
            matches.append(
                CaptureCandidate(
                    rect: ScreenGeometry.quartzToCocoa(quartzRect),
                    source: .window,
                    label: label,
                    level: matches.count,
                    windowID: CGWindowID(windowNumber.uint32Value)
                )
            )

            // The first normal-level match is the visible window below SmartShot.
            break
        }
        return matches
    }
}
