import CoreGraphics
import Testing
@testable import SmartShotCore

struct CandidateFilterTests {
    @Test func preservesWindowIdentityWhenNormalizing() {
        let candidate = CaptureCandidate(
            rect: CGRect(x: 10, y: 10, width: 100, height: 80),
            source: .window,
            label: "Window",
            windowID: 42
        )

        let result = CandidateFilter.normalized(
            [candidate],
            within: CGRect(x: 0, y: 0, width: 200, height: 200)
        )

        #expect(result.first?.windowID == 42)
    }

    @Test func convertsCoordinatesAroundPrimaryDisplayTop() {
        let appKitRect = CGRect(x: -1200, y: 950, width: 300, height: 200)

        let quartzRect = ScreenGeometry.cocoaToQuartz(appKitRect, referenceTop: 900)

        #expect(quartzRect == CGRect(x: -1200, y: -250, width: 300, height: 200))
        #expect(ScreenGeometry.quartzToCocoa(quartzRect, referenceTop: 900) == appKitRect)
    }

    @Test func removesDuplicatesAndSmallCandidates() {
        let candidates = [
            CaptureCandidate(rect: CGRect(x: 10, y: 10, width: 100, height: 80), source: .manual, label: "A"),
            CaptureCandidate(rect: CGRect(x: 10.2, y: 10.1, width: 100, height: 80), source: .manual, label: "B"),
            CaptureCandidate(rect: CGRect(x: 0, y: 0, width: 4, height: 4), source: .manual, label: "small")
        ]

        let result = CandidateFilter.normalized(candidates, within: CGRect(x: 0, y: 0, width: 500, height: 500))

        #expect(result.count == 1)
        #expect(result[0].label == "A")
    }

    @Test func clipsCandidatesToDesktopBounds() {
        let candidate = CaptureCandidate(
            rect: CGRect(x: -20, y: 10, width: 100, height: 80),
            source: .manual,
            label: "Clipped"
        )

        let result = CandidateFilter.normalized([candidate], within: CGRect(x: 0, y: 0, width: 500, height: 500))

        #expect(result.first?.rect == CGRect(x: 0, y: 10, width: 80, height: 80))
    }
}
