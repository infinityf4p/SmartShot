import AppKit
import ApplicationServices
import SmartShotCore
import CoreGraphics
import Foundation

enum AccessibilityScrollTargetError: LocalizedError, Sendable {
    case unavailable
    case noScrollableArea
    case unsupportedScrollBar
    case areaMustBeOnOneDisplay
    case targetChanged
    case scrollFailed(AXError)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Accessibility could not inspect the selected application."
        case .noScrollableArea:
            "The selected block does not expose a vertical scroll area."
        case .unsupportedScrollBar:
            "This scroll area cannot be controlled reliably by SmartShot."
        case .areaMustBeOnOneDisplay:
            "Move the entire scroll area onto one display, then try again."
        case .targetChanged:
            "The selected scroll area moved or changed during capture."
        case let .scrollFailed(error):
            "The application rejected a scroll request (AX error \(error.rawValue))."
        }
    }
}

struct AccessibilityScrollCaptureTarget: @unchecked Sendable {
    let scrollArea: AXUIElement
    let verticalScrollBar: AXUIElement
    let horizontalScrollBar: AXUIElement?
    let window: AXUIElement
    let windowIdentifier: CGWindowID
    let processIdentifier: pid_t
    let scrollAreaAppKitFrame: CGRect
    let captureAppKitFrame: CGRect
    let windowAppKitFrame: CGRect
    let minimumValue: Double
    let maximumValue: Double
    let originalValue: Double
    let usesNormalizedFallbackRange: Bool

    var valueRange: ClosedRange<Double> { minimumValue ... maximumValue }

    static func resolveInBackground(
        at appKitPoint: CGPoint,
        matching expectedFrame: CGRect,
        expectedIdentity: AccessibilityScrollTargetIdentity
    ) async -> Result<Self, AccessibilityScrollTargetError> {
        await Task.detached(priority: .userInitiated) {
            do {
                return .success(try resolve(
                    at: appKitPoint,
                    matching: expectedFrame,
                    expectedIdentity: expectedIdentity
                ))
            } catch let error as AccessibilityScrollTargetError {
                return .failure(error)
            } catch {
                return .failure(.unavailable)
            }
        }.value
    }

    static func resolve(
        at appKitPoint: CGPoint,
        matching expectedFrame: CGRect? = nil,
        expectedIdentity: AccessibilityScrollTargetIdentity? = nil
    ) throws -> Self {
        let quartzPoint = ScreenGeometry.cocoaToQuartz(appKitPoint)
        guard let identity = expectedIdentity ?? identity(atQuartzPoint: quartzPoint) else {
            throw AccessibilityScrollTargetError.unavailable
        }
        let hitTestRoot = AXUIElementCreateApplication(identity.processIdentifier)
        _ = AXUIElementSetMessagingTimeout(hitTestRoot, 0.6)
        var hit: AXUIElement?
        let hitError = AXUIElementCopyElementAtPosition(
            hitTestRoot,
            Float(quartzPoint.x),
            Float(quartzPoint.y),
            &hit
        )
        guard hitError == .success, var current = hit else {
            throw AccessibilityScrollTargetError.unavailable
        }
        configureMessagingTimeout(for: current)

        var visited: [AXUIElement] = []
        var capabilityError: AccessibilityScrollTargetError?
        for _ in 0 ..< 32 {
            guard !visited.contains(where: { CFEqual($0, current) }) else { break }
            visited.append(current)
            configureMessagingTimeout(for: current)

            if copyString(kAXRoleAttribute as CFString, from: current) == kAXScrollAreaRole as String,
               let quartzFrame = copyFrame(from: current),
               expectedFrame.map({
                   framesMatch(ScreenGeometry.quartzToCocoa(quartzFrame), $0)
               }) ?? true {
                do {
                    return try makeTarget(
                        scrollArea: current,
                        expectedIdentity: identity
                    )
                } catch let error as AccessibilityScrollTargetError {
                    guard expectedFrame == nil else { throw error }
                    switch error {
                    case .noScrollableArea, .unsupportedScrollBar:
                        capabilityError = error
                    default:
                        throw error
                    }
                }
            }

            guard let parent = copyElement(kAXParentAttribute as CFString, from: current) else { break }
            current = parent
        }
        if let capabilityError { throw capabilityError }
        throw AccessibilityScrollTargetError.noScrollableArea
    }

    private static func makeTarget(
        scrollArea: AXUIElement,
        expectedIdentity: AccessibilityScrollTargetIdentity
    ) throws -> Self {
        configureMessagingTimeout(for: scrollArea)
        let quartzFrame = copyFrame(from: scrollArea)
        let scrollBar = verticalScrollBar(for: scrollArea)
        guard let quartzFrame else { throw AccessibilityScrollTargetError.noScrollableArea }
        guard let scrollBar else { throw AccessibilityScrollTargetError.unsupportedScrollBar }
        configureMessagingTimeout(for: scrollBar)
        var processIdentifier: pid_t = 0
        let processIdentifierError = AXUIElementGetPid(scrollArea, &processIdentifier)
        guard processIdentifierError == .success,
              processIdentifier != ProcessInfo.processInfo.processIdentifier,
              processIdentifier == expectedIdentity.processIdentifier else {
            throw AccessibilityScrollTargetError.unavailable
        }
        var settable = DarwinBoolean(false)
        let settableError = AXUIElementIsAttributeSettable(
            scrollBar,
            kAXValueAttribute as CFString,
            &settable
        )
        let value = copyNumber(kAXValueAttribute as CFString, from: scrollBar)
        let reportedMinimum = copyNumber(kAXMinValueAttribute as CFString, from: scrollBar)
        let reportedMaximum = copyNumber(kAXMaxValueAttribute as CFString, from: scrollBar)
        guard settableError == .success, settable.boolValue,
              let value, value.isFinite else {
            throw AccessibilityScrollTargetError.unsupportedScrollBar
        }
        let minimum: Double
        let maximum: Double
        let usesNormalizedFallbackRange: Bool
        if let reportedMinimum, let reportedMaximum,
           reportedMinimum.isFinite, reportedMaximum.isFinite,
           reportedMaximum > reportedMinimum,
           value >= reportedMinimum, value <= reportedMaximum {
            minimum = reportedMinimum
            maximum = reportedMaximum
            usesNormalizedFallbackRange = false
        } else if reportedMinimum == nil, reportedMaximum == nil,
                  value >= 0, value <= 1,
                  copyString(kAXRoleAttribute as CFString, from: scrollBar) == kAXScrollBarRole as String {
            minimum = 0
            maximum = 1
            usesNormalizedFallbackRange = true
        } else {
            throw AccessibilityScrollTargetError.unsupportedScrollBar
        }

        let window = copyElement(kAXWindowAttribute as CFString, from: scrollArea)
            ?? firstAncestor(withRole: kAXWindowRole as String, from: scrollArea)
        if let window { configureMessagingTimeout(for: window) }
        let windowQuartzFrame = window.flatMap(copyFrame)
        guard let window, let windowQuartzFrame else {
            throw AccessibilityScrollTargetError.unsupportedScrollBar
        }
        let appKitFrame = ScreenGeometry.quartzToCocoa(quartzFrame)
        let windowAppKitFrame = ScreenGeometry.quartzToCocoa(windowQuartzFrame)
        let windowIdentifier = targetWindowIdentifier(
            processIdentifier: processIdentifier,
            quartzFrame: windowQuartzFrame
        )
        guard let windowIdentifier,
              windowIdentifier == expectedIdentity.windowIdentifier else {
            throw AccessibilityScrollTargetError.targetChanged
        }
        let horizontalScrollBar = copyElement(
            kAXHorizontalScrollBarAttribute as CFString,
            from: scrollArea
        )
        if let horizontalScrollBar { configureMessagingTimeout(for: horizontalScrollBar) }
        let captureFrame = captureFrame(
            scrollAreaQuartzFrame: quartzFrame,
            verticalScrollBar: scrollBar,
            horizontalScrollBar: horizontalScrollBar,
            windowQuartzFrame: windowQuartzFrame
        )
        guard captureFrame.width >= 24, captureFrame.height >= 24 else {
            throw AccessibilityScrollTargetError.unsupportedScrollBar
        }
        guard let screen = NSScreen.screens.first(where: {
            $0.frame.contains(CGPoint(x: captureFrame.midX, y: captureFrame.midY))
        }), screen.frame.insetBy(dx: -1, dy: -1).contains(captureFrame) else {
            throw AccessibilityScrollTargetError.areaMustBeOnOneDisplay
        }
        guard targetWindowIsVisibleAndUnoccluded(
            windowIdentifier: windowIdentifier,
            processIdentifier: processIdentifier,
            expectedQuartzFrame: windowQuartzFrame,
            captureQuartzFrame: ScreenGeometry.cocoaToQuartz(captureFrame)
        ) else {
            throw AccessibilityScrollTargetError.targetChanged
        }
        return Self(
            scrollArea: scrollArea,
            verticalScrollBar: scrollBar,
            horizontalScrollBar: horizontalScrollBar,
            window: window,
            windowIdentifier: windowIdentifier,
            processIdentifier: processIdentifier,
            scrollAreaAppKitFrame: appKitFrame,
            captureAppKitFrame: captureFrame,
            windowAppKitFrame: windowAppKitFrame,
            minimumValue: minimum,
            maximumValue: maximum,
            originalValue: value,
            usesNormalizedFallbackRange: usesNormalizedFallbackRange
        )
    }

    func setValue(_ value: Double) throws {
        let clamped = min(max(value, minimumValue), maximumValue)
        let error = AXUIElementSetAttributeValue(
            verticalScrollBar,
            kAXValueAttribute as CFString,
            NSNumber(value: clamped)
        )
        guard error == .success else { throw AccessibilityScrollTargetError.scrollFailed(error) }
    }

    func currentValue() -> Double? {
        Self.copyNumber(kAXValueAttribute as CFString, from: verticalScrollBar)
    }

    func validate() throws {
        var currentProcessIdentifier: pid_t = 0
        let processError = AXUIElementGetPid(scrollArea, &currentProcessIdentifier)
        guard processError == .success,
              currentProcessIdentifier == processIdentifier else {
            throw AccessibilityScrollTargetError.targetChanged
        }

        let currentRole = Self.copyString(kAXRoleAttribute as CFString, from: scrollArea)
        guard currentRole == kAXScrollAreaRole as String else {
            throw AccessibilityScrollTargetError.targetChanged
        }

        guard let currentQuartzFrame = Self.copyFrame(from: scrollArea) else {
            throw AccessibilityScrollTargetError.targetChanged
        }
        let currentAppKitFrame = ScreenGeometry.quartzToCocoa(currentQuartzFrame)
        guard Self.framesMatch(currentAppKitFrame, scrollAreaAppKitFrame) else {
            throw AccessibilityScrollTargetError.targetChanged
        }

        guard Self.rangeIsCompatible(
            scrollBar: verticalScrollBar,
            expectedMinimum: minimumValue,
            expectedMaximum: maximumValue,
            usesNormalizedFallback: usesNormalizedFallbackRange
        ) else {
            throw AccessibilityScrollTargetError.targetChanged
        }

        guard NSRunningApplication(processIdentifier: processIdentifier) != nil else {
            throw AccessibilityScrollTargetError.targetChanged
        }

        guard let currentWindowFrame = Self.copyFrame(from: window).map({
            ScreenGeometry.quartzToCocoa($0)
        }), Self.framesMatch(currentWindowFrame, windowAppKitFrame) else {
            throw AccessibilityScrollTargetError.targetChanged
        }

        let currentCaptureFrame = Self.captureFrame(
            scrollAreaQuartzFrame: currentQuartzFrame,
            verticalScrollBar: verticalScrollBar,
            horizontalScrollBar: horizontalScrollBar,
            windowQuartzFrame: Self.copyFrame(from: window)
        )
        guard Self.framesMatch(currentCaptureFrame, captureAppKitFrame) else {
            throw AccessibilityScrollTargetError.targetChanged
        }
        guard Self.targetWindowIsVisibleAndUnoccluded(
            windowIdentifier: windowIdentifier,
            processIdentifier: processIdentifier,
            expectedQuartzFrame: Self.copyFrame(from: window) ?? .null,
            captureQuartzFrame: ScreenGeometry.cocoaToQuartz(captureAppKitFrame)
        ) else {
            throw AccessibilityScrollTargetError.targetChanged
        }
    }

    private static func framesMatch(_ first: CGRect, _ second: CGRect) -> Bool {
        let first = first.standardized
        let second = second.standardized
        return abs(first.minX - second.minX) <= 3 &&
            abs(first.minY - second.minY) <= 3 &&
            abs(first.width - second.width) <= 6 &&
            abs(first.height - second.height) <= 6
    }

    private static func rangeMatches(
        minimum: Double?,
        maximum: Double?,
        expectedMinimum: Double,
        expectedMaximum: Double
    ) -> Bool {
        guard let minimum, let maximum else { return false }
        let tolerance = max(0.000_001, abs(expectedMaximum - expectedMinimum) * 0.000_1)
        return abs(minimum - expectedMinimum) <= tolerance &&
            abs(maximum - expectedMaximum) <= tolerance
    }

    private static func rangeIsCompatible(
        scrollBar: AXUIElement,
        expectedMinimum: Double,
        expectedMaximum: Double,
        usesNormalizedFallback: Bool
    ) -> Bool {
        if usesNormalizedFallback {
            guard let value = copyNumber(kAXValueAttribute as CFString, from: scrollBar),
                  value.isFinite else { return false }
            return value >= -0.000_001 && value <= 1.000_001
        }
        return rangeMatches(
            minimum: copyNumber(kAXMinValueAttribute as CFString, from: scrollBar),
            maximum: copyNumber(kAXMaxValueAttribute as CFString, from: scrollBar),
            expectedMinimum: expectedMinimum,
            expectedMaximum: expectedMaximum
        )
    }

    static func identity(at appKitPoint: CGPoint) -> AccessibilityScrollTargetIdentity? {
        identity(atQuartzPoint: ScreenGeometry.cocoaToQuartz(appKitPoint))
    }

    private static func identity(atQuartzPoint quartzPoint: CGPoint) -> AccessibilityScrollTargetIdentity? {
        guard let window = windowSnapshots().first(where: {
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier &&
                $0.layer == 0 &&
                $0.alpha > 0.01 &&
                $0.frame.contains(quartzPoint)
        }) else { return nil }
        return AccessibilityScrollTargetIdentity(
            processIdentifier: window.processIdentifier,
            windowIdentifier: window.identifier
        )
    }

    private struct WindowSnapshot {
        let identifier: CGWindowID
        let processIdentifier: pid_t
        let ownerName: String?
        let layer: Int
        let alpha: Double
        let frame: CGRect
    }

    private static func targetWindowIdentifier(
        processIdentifier: pid_t,
        quartzFrame: CGRect
    ) -> CGWindowID? {
        windowSnapshots()
            .filter { $0.processIdentifier == processIdentifier && $0.layer == 0 }
            .map { snapshot in
                (
                    identifier: snapshot.identifier,
                    difference: frameDifference(snapshot.frame, quartzFrame)
                )
            }
            .filter { $0.difference <= 24 }
            .min { $0.difference < $1.difference }?
            .identifier
    }

    private static func targetWindowIsVisibleAndUnoccluded(
        windowIdentifier: CGWindowID,
        processIdentifier: pid_t,
        expectedQuartzFrame: CGRect,
        captureQuartzFrame: CGRect
    ) -> Bool {
        let windows = windowSnapshots()
        guard let targetIndex = windows.firstIndex(where: {
            $0.identifier == windowIdentifier &&
                $0.processIdentifier == processIdentifier &&
                $0.layer == 0
        }), frameDifference(windows[targetIndex].frame, expectedQuartzFrame) <= 24 else {
            return false
        }

        let blockShotPID = ProcessInfo.processInfo.processIdentifier
        for window in windows[..<targetIndex] {
            guard window.processIdentifier != blockShotPID,
                  window.alpha > 0.01,
                  !window.frame.isEmpty,
                  window.frame.intersects(captureQuartzFrame) else { continue }
            if CaptureOcclusionPolicy.shouldIgnoreSystemWindow(
                ownerName: window.ownerName,
                layer: window.layer,
                frame: window.frame,
                captureFrame: captureQuartzFrame
            ) {
                continue
            }
            return false
        }
        return true
    }

    private static func windowSnapshots() -> [WindowSnapshot] {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        return windows.compactMap { info in
            guard let identifier = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let processIdentifier = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds) else { return nil }
            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            return WindowSnapshot(
                identifier: identifier,
                processIdentifier: processIdentifier,
                ownerName: info[kCGWindowOwnerName as String] as? String,
                layer: layer,
                alpha: alpha,
                frame: frame.standardized
            )
        }
    }

    private static func frameDifference(_ first: CGRect, _ second: CGRect) -> CGFloat {
        abs(first.minX - second.minX) + abs(first.minY - second.minY) +
            abs(first.width - second.width) + abs(first.height - second.height)
    }

    private static func firstAncestor(withRole role: String, from element: AXUIElement) -> AXUIElement? {
        var current = copyElement(kAXParentAttribute as CFString, from: element)
        var visited: [AXUIElement] = []
        for _ in 0..<32 {
            guard let element = current,
                  !visited.contains(where: { CFEqual($0, element) }) else { return nil }
            visited.append(element)
            if copyString(kAXRoleAttribute as CFString, from: element) == role { return element }
            current = copyElement(kAXParentAttribute as CFString, from: element)
        }
        return nil
    }

    private static func verticalScrollBar(for element: AXUIElement) -> AXUIElement? {
        if let direct = copyElement(kAXVerticalScrollBarAttribute as CFString, from: element) {
            return direct
        }
        return copyElements(kAXChildrenAttribute as CFString, from: element).first { child in
            copyString(kAXRoleAttribute as CFString, from: child) == kAXScrollBarRole as String &&
                copyString(kAXOrientationAttribute as CFString, from: child) ==
                kAXVerticalOrientationValue as String
        }
    }

    private static func captureFrame(
        scrollAreaQuartzFrame: CGRect,
        verticalScrollBar: AXUIElement,
        horizontalScrollBar: AXUIElement?,
        windowQuartzFrame: CGRect?
    ) -> CGRect {
        var frame = scrollAreaQuartzFrame.standardized
        if let windowQuartzFrame {
            frame = frame.intersection(windowQuartzFrame.standardized)
        }

        if let bar = copyFrame(from: verticalScrollBar),
           bar.width > 0, bar.width < frame.width * 0.25,
           bar.intersects(frame) {
            if bar.midX >= frame.midX {
                frame.size.width = max(0, bar.minX - frame.minX)
            } else {
                let maximumX = frame.maxX
                frame.origin.x = bar.maxX
                frame.size.width = max(0, maximumX - frame.minX)
            }
        }

        if let horizontalScrollBar,
           let bar = copyFrame(from: horizontalScrollBar),
           bar.height > 0, bar.height < frame.height * 0.25,
           bar.intersects(frame) {
            if bar.midY >= frame.midY {
                frame.size.height = max(0, bar.minY - frame.minY)
            } else {
                let maximumY = frame.maxY
                frame.origin.y = bar.maxY
                frame.size.height = max(0, maximumY - frame.minY)
            }
        }
        return ScreenGeometry.quartzToCocoa(frame.standardized)
    }

    private static func copyAttribute(_ name: CFString, from element: AXUIElement) -> CFTypeRef? {
        configureMessagingTimeout(for: element)
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name, &value) == .success ? value : nil
    }

    private static func configureMessagingTimeout(for element: AXUIElement) {
        _ = AXUIElementSetMessagingTimeout(element, 0.6)
    }

    private static func copyElement(_ name: CFString, from element: AXUIElement) -> AXUIElement? {
        guard let value = copyAttribute(name, from: element),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }


    private static func copyElements(_ name: CFString, from element: AXUIElement) -> [AXUIElement] {
        guard let value = copyAttribute(name, from: element),
              CFGetTypeID(value) == CFArrayGetTypeID(),
              let values = value as? [Any] else { return [] }
        return values.compactMap { value in
            let reference = value as CFTypeRef
            guard CFGetTypeID(reference) == AXUIElementGetTypeID() else { return nil }
            return unsafeDowncast(reference, to: AXUIElement.self)
        }
    }

    private static func copyString(_ name: CFString, from element: AXUIElement) -> String? {
        copyAttribute(name, from: element) as? String
    }

    private static func copyNumber(_ name: CFString, from element: AXUIElement) -> Double? {
        (copyAttribute(name, from: element) as? NSNumber)?.doubleValue
    }

    private static func copyFrame(from element: AXUIElement) -> CGRect? {
        guard let raw = copyAttribute("AXFrame" as CFString, from: element),
              CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let value = unsafeDowncast(raw, to: AXValue.self)
        guard AXValueGetType(value) == .cgRect else { return nil }
        var frame = CGRect.zero
        return AXValueGetValue(value, .cgRect, &frame) ? frame.standardized : nil
    }
}
