import ApplicationServices
import CoreGraphics
import Foundation

public protocol AccessibilityHierarchyProviding {
    /// Returns the hit element followed by each parent, ending at the application root.
    func hierarchy(
        atQuartzPoint point: CGPoint,
        maximumDepth: Int
    ) throws -> [AccessibilityElementSnapshot]
}

public enum AccessibilityHierarchyError: Error, Equatable, Sendable {
    case invalidPoint
    case hitTestFailed(code: Int32)
}

/// Reads the native Accessibility tree with `AXUIElementCopyElementAtPosition`.
public struct SystemAccessibilityHierarchyProvider: AccessibilityHierarchyProviding {
    private let excludedProcessID: pid_t

    public init(excludedProcessID: pid_t = ProcessInfo.processInfo.processIdentifier) {
        self.excludedProcessID = excludedProcessID
    }

    public func hierarchy(
        atQuartzPoint point: CGPoint,
        maximumDepth: Int
    ) throws -> [AccessibilityElementSnapshot] {
        guard point.x.isFinite, point.y.isFinite else {
            throw AccessibilityHierarchyError.invalidPoint
        }
        guard maximumDepth > 0 else { return [] }

        let application = applicationUnderPoint(point)
        if let application {
            _ = AXUIElementSetMessagingTimeout(application, 0.18)
        }
        let hitTestRoot = application ?? AXUIElementCreateSystemWide()
        var hitElement: AXUIElement?
        let hitTestError = AXUIElementCopyElementAtPosition(
            hitTestRoot,
            Float(point.x),
            Float(point.y),
            &hitElement
        )
        guard hitTestError == .success, let hitElement else {
            throw AccessibilityHierarchyError.hitTestFailed(code: hitTestError.rawValue)
        }

        var hierarchy: [AccessibilityElementSnapshot] = []
        var visited: [AXUIElement] = []
        var current: AXUIElement? = hitElement

        while let element = current, hierarchy.count < maximumDepth {
            guard !visited.contains(where: { CFEqual($0, element) }) else { break }
            visited.append(element)

            hierarchy.append(snapshot(of: element, level: hierarchy.count))
            current = copyElementAttribute(kAXParentAttribute as CFString, from: element)
        }

        return hierarchy
    }

    private func applicationUnderPoint(_ point: CGPoint) -> AXUIElement? {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        for info in windows {
            guard
                let processID = info[kCGWindowOwnerPID as String] as? pid_t,
                processID != excludedProcessID,
                let layer = info[kCGWindowLayer as String] as? Int,
                layer == 0,
                let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                let frame = CGRect(dictionaryRepresentation: bounds),
                frame.contains(point)
            else {
                continue
            }
            return AXUIElementCreateApplication(processID)
        }
        return nil
    }

    private func snapshot(
        of element: AXUIElement,
        level: Int
    ) -> AccessibilityElementSnapshot {
        AccessibilityElementSnapshot(
            id: nativeIdentifier(for: element),
            role: copyTextAttribute(kAXRoleAttribute as CFString, from: element),
            subrole: copyTextAttribute(kAXSubroleAttribute as CFString, from: element),
            title: copyTextAttribute(kAXTitleAttribute as CFString, from: element),
            elementDescription: copyTextAttribute(kAXDescriptionAttribute as CFString, from: element),
            value: copyTextAttribute(kAXValueAttribute as CFString, from: element),
            frame: copyFrame(from: element),
            hierarchyLevel: level
        )
    }

    private func nativeIdentifier(for element: AXUIElement) -> String {
        let pointer = Unmanaged.passUnretained(element).toOpaque()
        return String(UInt(bitPattern: pointer), radix: 16)
    }

    private func copyAttribute(_ name: CFString, from element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else {
            return nil
        }
        return value
    }

    private func copyElementAttribute(_ name: CFString, from element: AXUIElement) -> AXUIElement? {
        guard let value = copyAttribute(name, from: element),
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func copyTextAttribute(_ name: CFString, from element: AXUIElement) -> String? {
        guard let value = copyAttribute(name, from: element) else { return nil }

        if CFGetTypeID(value) == CFStringGetTypeID() {
            return value as? String
        }
        if CFGetTypeID(value) == CFBooleanGetTypeID() || CFGetTypeID(value) == CFNumberGetTypeID() {
            return (value as? NSNumber)?.stringValue
        }
        return nil
    }

    private func copyFrame(from element: AXUIElement) -> CGRect? {
        if let frame = copyRectAttribute("AXFrame" as CFString, from: element) {
            return frame.standardized
        }
        guard let position = copyPointAttribute(kAXPositionAttribute as CFString, from: element),
              let size = copySizeAttribute(kAXSizeAttribute as CFString, from: element) else {
            return nil
        }
        return CGRect(origin: position, size: size).standardized
    }

    private func copyRectAttribute(_ name: CFString, from element: AXUIElement) -> CGRect? {
        guard let value = copyAXValueAttribute(name, from: element),
              AXValueGetType(value) == .cgRect else { return nil }
        var result = CGRect.zero
        return AXValueGetValue(value, .cgRect, &result) ? result : nil
    }

    private func copyPointAttribute(_ name: CFString, from element: AXUIElement) -> CGPoint? {
        guard let value = copyAXValueAttribute(name, from: element),
              AXValueGetType(value) == .cgPoint else { return nil }
        var result = CGPoint.zero
        return AXValueGetValue(value, .cgPoint, &result) ? result : nil
    }

    private func copySizeAttribute(_ name: CFString, from element: AXUIElement) -> CGSize? {
        guard let value = copyAXValueAttribute(name, from: element),
              AXValueGetType(value) == .cgSize else { return nil }
        var result = CGSize.zero
        return AXValueGetValue(value, .cgSize, &result) ? result : nil
    }

    private func copyAXValueAttribute(_ name: CFString, from element: AXUIElement) -> AXValue? {
        guard let value = copyAttribute(name, from: element),
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        return unsafeDowncast(value, to: AXValue.self)
    }
}
