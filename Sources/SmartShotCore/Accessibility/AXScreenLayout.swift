import AppKit
import CoreGraphics

/// Coordinate conversion and visible-area calculations for a multi-display desktop.
public struct AXScreenLayout: Equatable, Sendable {
    public let appKitDisplayFrames: [CGRect]
    /// AppKit Y coordinate corresponding to Quartz global Y = 0.
    public let quartzReferenceTop: CGFloat

    public init(appKitDisplayFrames: [CGRect], quartzReferenceTop: CGFloat) {
        self.appKitDisplayFrames = appKitDisplayFrames.map(\.standardized)
        self.quartzReferenceTop = quartzReferenceTop
    }

    /// Builds the current layout. `NSScreen.screens.first` is the display that anchors
    /// the global Core Graphics coordinate system, even when another screen is above it.
    @MainActor
    public static func current() -> AXScreenLayout {
        let frames = NSScreen.screens.map(\.frame)
        let referenceTop = NSScreen.screens.first?.frame.maxY ?? 0
        return AXScreenLayout(appKitDisplayFrames: frames, quartzReferenceTop: referenceTop)
    }

    public var quartzDisplayFrames: [CGRect] {
        appKitDisplayFrames.map(appKitToQuartz)
    }

    public var visibleDesktopArea: CGFloat {
        appKitDisplayFrames.reduce(0) { partial, frame in
            partial + max(0, frame.width) * max(0, frame.height)
        }
    }

    public func point(
        _ point: CGPoint,
        from source: AccessibilityCoordinateSpace,
        to destination: AccessibilityCoordinateSpace
    ) -> CGPoint {
        guard source != destination else { return point }
        return CGPoint(x: point.x, y: quartzReferenceTop - point.y)
    }

    public func rect(
        _ rect: CGRect,
        from source: AccessibilityCoordinateSpace,
        to destination: AccessibilityCoordinateSpace
    ) -> CGRect {
        guard source != destination else { return rect.standardized }
        let rect = rect.standardized
        return CGRect(
            x: rect.minX,
            y: quartzReferenceTop - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    public func appKitToQuartz(_ point: CGPoint) -> CGPoint {
        self.point(point, from: .appKit, to: .quartz)
    }

    public func quartzToAppKit(_ point: CGPoint) -> CGPoint {
        self.point(point, from: .quartz, to: .appKit)
    }

    public func appKitToQuartz(_ rect: CGRect) -> CGRect {
        self.rect(rect, from: .appKit, to: .quartz)
    }

    public func quartzToAppKit(_ rect: CGRect) -> CGRect {
        self.rect(rect, from: .quartz, to: .appKit)
    }

    /// The area of a Quartz-coordinate rectangle actually covered by displays.
    public func visibleArea(ofQuartzRect rect: CGRect) -> CGFloat {
        guard rect.hasFinitePositiveArea else { return 0 }
        return quartzDisplayFrames.reduce(0) { partial, display in
            let intersection = rect.intersection(display)
            guard !intersection.isNull else { return partial }
            return partial + intersection.width * intersection.height
        }
    }
}

extension CGRect {
    fileprivate var hasFinitePositiveArea: Bool {
        let values = [minX, minY, width, height]
        return values.allSatisfy(\.isFinite) && width > 0 && height > 0 && !isNull && !isInfinite
    }
}
