import CoreGraphics
import XCTest
@testable import SmartShotCore

final class AccessibilityBlockDetectorTests: XCTestCase {
    func testDetectionPreservesHierarchyAndFiltersInvalidSmallLargeOffscreenAndDuplicateFrames() throws {
        let hierarchy = [
            element("text", role: "AXStaticText", frame: CGRect(x: 120, y: 140, width: 8, height: 10), level: 0),
            element("post", role: "AXGroup", title: "A post", frame: CGRect(x: 100, y: 100, width: 300, height: 200), level: 1),
            element("post-duplicate", role: "AXGroup", frame: CGRect(x: 100.5, y: 99.5, width: 300, height: 200), level: 2),
            element("timeline", role: "AXGroup", frame: CGRect(x: 50, y: 50, width: 500, height: 400), level: 3),
            element("mostly-offscreen", role: "AXGroup", frame: CGRect(x: 900, y: 100, width: 400, height: 300), level: 4),
            element("window", role: "AXWindow", frame: CGRect(x: 0, y: 0, width: 1_000, height: 800), level: 5),
            element("application", role: "AXApplication", frame: nil, level: 6),
        ]
        let provider = RecordingHierarchyProvider(hierarchy: hierarchy)
        let detector = AccessibilityBlockDetector(
            provider: provider,
            filter: AccessibilityCandidateFilter(
                minimumSize: CGSize(width: 24, height: 18),
                maximumDesktopAreaFraction: 0.9,
                minimumVisibleFraction: 0.5,
                duplicateTolerance: 1,
                maximumHierarchyDepth: 20
            )
        )
        let layout = AXScreenLayout(
            appKitDisplayFrames: [CGRect(x: 0, y: 0, width: 1_000, height: 800)],
            quartzReferenceTop: 800
        )

        let result = try detector.detect(
            at: CGPoint(x: 250, y: 650),
            in: .appKit,
            screenLayout: layout
        )

        XCTAssertEqual(provider.receivedPoint, CGPoint(x: 250, y: 150))
        XCTAssertEqual(provider.receivedMaximumDepth, 20)
        XCTAssertEqual(result.hitPointInQuartz, CGPoint(x: 250, y: 150))
        XCTAssertEqual(result.hierarchy.map(\.id), hierarchy.map(\.id))
        XCTAssertEqual(result.candidates.map(\.id), ["post", "timeline"])
        XCTAssertEqual(result.candidates[0].quartzFrame, CGRect(x: 100, y: 100, width: 300, height: 200))
        XCTAssertEqual(result.candidates[0].appKitFrame, CGRect(x: 100, y: 500, width: 300, height: 200))
    }

    func testCandidatesStayInHitToRootOrderRatherThanSortingByArea() throws {
        let hierarchy = [
            element("hit", role: "AXButton", frame: CGRect(x: 20, y: 20, width: 80, height: 40), level: 0),
            element("row", role: "AXGroup", frame: CGRect(x: 10, y: 10, width: 300, height: 100), level: 1),
            element("scroll-area", role: "AXScrollArea", frame: CGRect(x: 0, y: 0, width: 700, height: 500), level: 2),
        ]
        let detector = AccessibilityBlockDetector(provider: StubHierarchyProvider(hierarchy: hierarchy))
        let layout = AXScreenLayout(
            appKitDisplayFrames: [CGRect(x: 0, y: 0, width: 1_000, height: 800)],
            quartzReferenceTop: 800
        )

        let result = try detector.detect(
            at: CGPoint(x: 30, y: 30),
            in: .quartz,
            screenLayout: layout
        )

        XCTAssertEqual(result.candidates.map(\.id), ["hit", "row", "scroll-area"])
        XCTAssertEqual(result.candidates.map(\.element.hierarchyLevel), [0, 1, 2])
    }

    func testCaptureCandidateMappingUsesRequestedCoordinateSpaceAndMetadata() throws {
        let hierarchy = [
            element(
                "post",
                role: "AXGroup",
                title: "Kevin's post",
                frame: CGRect(x: 80, y: 120, width: 320, height: 240),
                level: 2
            ),
        ]
        let detector = AccessibilityBlockDetector(provider: StubHierarchyProvider(hierarchy: hierarchy))
        let layout = AXScreenLayout(
            appKitDisplayFrames: [CGRect(x: 0, y: 0, width: 1_000, height: 800)],
            quartzReferenceTop: 800
        )
        let result = try detector.detect(
            at: .zero,
            in: .quartz,
            screenLayout: layout
        )

        let quartzCandidate = try XCTUnwrap(result.captureCandidates(in: .quartz).first)
        XCTAssertEqual(quartzCandidate.rect, CGRect(x: 80, y: 120, width: 320, height: 240))
        XCTAssertEqual(quartzCandidate.source, .accessibility)
        XCTAssertEqual(quartzCandidate.label, "Group")
        XCTAssertEqual(quartzCandidate.level, 2)

        let appKitCandidate = try XCTUnwrap(result.captureCandidates(in: .appKit).first)
        XCTAssertEqual(appKitCandidate.rect, CGRect(x: 80, y: 440, width: 320, height: 240))
    }

    func testCandidateLabelDoesNotExposeAccessibilityTextOrValue() {
        let snapshot = AccessibilityElementSnapshot(
            id: "password",
            role: "AXTextField",
            title: "Account password",
            elementDescription: "Private form field",
            value: "correct horse battery staple",
            frame: CGRect(x: 0, y: 0, width: 200, height: 32),
            hierarchyLevel: 0
        )

        XCTAssertEqual(snapshot.displayLabel, "Text Field")
        XCTAssertFalse(snapshot.displayLabel.contains("password"))
        XCTAssertFalse(snapshot.displayLabel.contains("correct horse"))
    }

    private func element(
        _ id: String,
        role: String,
        title: String? = nil,
        frame: CGRect?,
        level: Int
    ) -> AccessibilityElementSnapshot {
        AccessibilityElementSnapshot(
            id: id,
            role: role,
            title: title,
            frame: frame,
            hierarchyLevel: level
        )
    }
}

private struct StubHierarchyProvider: AccessibilityHierarchyProviding {
    let hierarchy: [AccessibilityElementSnapshot]

    func hierarchy(
        atQuartzPoint point: CGPoint,
        maximumDepth: Int
    ) throws -> [AccessibilityElementSnapshot] {
        Array(hierarchy.prefix(maximumDepth))
    }
}

private final class RecordingHierarchyProvider: AccessibilityHierarchyProviding {
    let hierarchyToReturn: [AccessibilityElementSnapshot]
    private(set) var receivedPoint: CGPoint?
    private(set) var receivedMaximumDepth: Int?

    init(hierarchy: [AccessibilityElementSnapshot]) {
        hierarchyToReturn = hierarchy
    }

    func hierarchy(
        atQuartzPoint point: CGPoint,
        maximumDepth: Int
    ) throws -> [AccessibilityElementSnapshot] {
        receivedPoint = point
        receivedMaximumDepth = maximumDepth
        return hierarchyToReturn
    }
}
