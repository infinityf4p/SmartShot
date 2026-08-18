import CoreGraphics
import Foundation

/// The two global coordinate systems used by AppKit and the Accessibility API.
public enum AccessibilityCoordinateSpace: Sendable {
    /// AppKit's global coordinate space, whose Y axis points up.
    case appKit
    /// Core Graphics and Accessibility global coordinates, whose Y axis points down.
    case quartz
}

/// A serializable view of an Accessibility element.
///
/// The native `AXUIElement` is intentionally not exposed so hierarchy providers can
/// be replaced in tests and by future browser-specific providers.
public struct AccessibilityElementSnapshot: Equatable, Sendable, Identifiable {
    public let id: String
    public let role: String?
    public let subrole: String?
    public let title: String?
    public let elementDescription: String?
    public let value: String?
    /// The element frame in Accessibility/Core Graphics global coordinates.
    public let frame: CGRect?
    /// Zero for the element under the pointer, increasing toward the application root.
    public let hierarchyLevel: Int

    public init(
        id: String,
        role: String? = nil,
        subrole: String? = nil,
        title: String? = nil,
        elementDescription: String? = nil,
        value: String? = nil,
        frame: CGRect? = nil,
        hierarchyLevel: Int
    ) {
        self.id = id
        self.role = role
        self.subrole = subrole
        self.title = title
        self.elementDescription = elementDescription
        self.value = value
        self.frame = frame
        self.hierarchyLevel = hierarchyLevel
    }

    public var displayLabel: String {
        for identifier in [subrole, role] {
            guard let identifier else { continue }
            let normalized = identifier
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "AX", with: "", options: [.anchored])
            guard !normalized.isEmpty else { continue }
            return normalized.replacingOccurrences(
                of: "([a-z0-9])([A-Z])",
                with: "$1 $2",
                options: .regularExpression
            )
        }
        return "Accessibility element"
    }
}

/// A screenshot candidate backed by one Accessibility hierarchy node.
public struct AccessibilityBlockCandidate: Equatable, Sendable, Identifiable {
    public var id: String { element.id }
    public let element: AccessibilityElementSnapshot
    public let quartzFrame: CGRect
    public let appKitFrame: CGRect

    public init(
        element: AccessibilityElementSnapshot,
        quartzFrame: CGRect,
        appKitFrame: CGRect
    ) {
        self.element = element
        self.quartzFrame = quartzFrame.standardized
        self.appKitFrame = appKitFrame.standardized
    }

    public func captureCandidate(in coordinateSpace: AccessibilityCoordinateSpace = .appKit) -> CaptureCandidate {
        CaptureCandidate(
            rect: coordinateSpace == .appKit ? appKitFrame : quartzFrame,
            source: .accessibility,
            label: element.displayLabel,
            level: element.hierarchyLevel
        )
    }
}

public struct AccessibilityDetectionResult: Equatable, Sendable {
    public let hitPointInQuartz: CGPoint
    /// The unfiltered path from the hit element to the application root.
    public let hierarchy: [AccessibilityElementSnapshot]
    /// The visible, size-filtered and rectangle-deduplicated screenshot candidates.
    public let candidates: [AccessibilityBlockCandidate]

    public init(
        hitPointInQuartz: CGPoint,
        hierarchy: [AccessibilityElementSnapshot],
        candidates: [AccessibilityBlockCandidate]
    ) {
        self.hitPointInQuartz = hitPointInQuartz
        self.hierarchy = hierarchy
        self.candidates = candidates
    }

    public func captureCandidates(
        in coordinateSpace: AccessibilityCoordinateSpace = .appKit
    ) -> [CaptureCandidate] {
        candidates.map { $0.captureCandidate(in: coordinateSpace) }
    }
}

public struct AccessibilityCandidateFilter: Equatable, Sendable {
    public var minimumSize: CGSize
    /// Candidates larger than this fraction of visible desktop area are ignored.
    public var maximumDesktopAreaFraction: CGFloat
    /// Candidates with less than this fraction visible on a display are ignored.
    public var minimumVisibleFraction: CGFloat
    public var duplicateTolerance: CGFloat
    public var maximumHierarchyDepth: Int

    public init(
        minimumSize: CGSize = CGSize(width: 24, height: 18),
        maximumDesktopAreaFraction: CGFloat = 0.98,
        minimumVisibleFraction: CGFloat = 0.5,
        duplicateTolerance: CGFloat = 1,
        maximumHierarchyDepth: Int = 32
    ) {
        self.minimumSize = minimumSize
        self.maximumDesktopAreaFraction = maximumDesktopAreaFraction
        self.minimumVisibleFraction = minimumVisibleFraction
        self.duplicateTolerance = duplicateTolerance
        self.maximumHierarchyDepth = maximumHierarchyDepth
    }
}
