import CoreGraphics
import Foundation

public struct AccessibilityBlockDetector<Provider: AccessibilityHierarchyProviding> {
    public let provider: Provider
    public var filter: AccessibilityCandidateFilter

    public init(
        provider: Provider,
        filter: AccessibilityCandidateFilter = AccessibilityCandidateFilter()
    ) {
        self.provider = provider
        self.filter = filter
    }

    public func detect(
        at point: CGPoint,
        in coordinateSpace: AccessibilityCoordinateSpace,
        screenLayout: AXScreenLayout
    ) throws -> AccessibilityDetectionResult {
        let quartzPoint = screenLayout.point(point, from: coordinateSpace, to: .quartz)
        let hierarchy = try provider.hierarchy(
            atQuartzPoint: quartzPoint,
            maximumDepth: max(0, filter.maximumHierarchyDepth)
        )
        let candidates = normalizedCandidates(from: hierarchy, screenLayout: screenLayout)
        return AccessibilityDetectionResult(
            hitPointInQuartz: quartzPoint,
            hierarchy: hierarchy,
            candidates: candidates
        )
    }

    private func normalizedCandidates(
        from hierarchy: [AccessibilityElementSnapshot],
        screenLayout: AXScreenLayout
    ) -> [AccessibilityBlockCandidate] {
        let desktopArea = screenLayout.visibleDesktopArea
        guard desktopArea > 0 else { return [] }

        var acceptedFrames: [CGRect] = []
        var candidates: [AccessibilityBlockCandidate] = []

        for element in hierarchy {
            guard let rawFrame = element.frame else { continue }
            let frame = rawFrame.standardized
            guard frame.isUsableAXFrame,
                  frame.width >= filter.minimumSize.width,
                  frame.height >= filter.minimumSize.height else {
                continue
            }

            let area = frame.width * frame.height
            let visibleArea = screenLayout.visibleArea(ofQuartzRect: frame)
            guard visibleArea > 0,
                  area / desktopArea <= filter.maximumDesktopAreaFraction,
                  visibleArea / area >= filter.minimumVisibleFraction else {
                continue
            }

            guard !acceptedFrames.contains(where: {
                $0.isApproximatelyEqual(to: frame, tolerance: max(0, filter.duplicateTolerance))
            }) else {
                continue
            }

            acceptedFrames.append(frame)
            candidates.append(
                AccessibilityBlockCandidate(
                    element: element,
                    quartzFrame: frame,
                    appKitFrame: screenLayout.quartzToAppKit(frame)
                )
            )
        }

        return candidates
    }
}

private extension CGRect {
    var isUsableAXFrame: Bool {
        let values = [minX, minY, width, height]
        return values.allSatisfy(\.isFinite) && width > 0 && height > 0 && !isNull && !isInfinite
    }

    func isApproximatelyEqual(to other: CGRect, tolerance: CGFloat) -> Bool {
        abs(minX - other.minX) <= tolerance
            && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance
            && abs(height - other.height) <= tolerance
    }
}
