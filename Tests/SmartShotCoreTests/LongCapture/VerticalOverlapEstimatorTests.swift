import CoreGraphics
import XCTest
@testable import SmartShotCore

final class VerticalOverlapEstimatorTests: XCTestCase {
    func testEstimatesKnownVerticalTranslation() throws {
        let content = try makePatternImage(width: 48, height: 150, seed: 7)
        let previous = try XCTUnwrap(content.cropping(to: CGRect(x: 0, y: 0, width: 48, height: 80)))
        let current = try XCTUnwrap(content.cropping(to: CGRect(x: 0, y: 23, width: 48, height: 80)))

        let estimate = try VerticalOverlapEstimator.estimate(
            previous: previous,
            current: current,
            configuration: testConfiguration()
        )

        XCTAssertEqual(estimate.overlapHeightPixels, 57)
        XCTAssertEqual(estimate.scrollDeltaPixels, 23)
        XCTAssertEqual(estimate.addedHeightPixels, 23)
        XCTAssertEqual(estimate.currentContentOffsetPixels, 23)
        XCTAssertEqual(estimate.currentSourceTopInsetPixels, 0)
        XCTAssertGreaterThan(estimate.confidence, 0.9)
        XCTAssertEqual(estimate.meanAbsoluteDifference, 0, accuracy: 0.000_001)
    }

    func testOverlapPreferenceDoesNotOverrideKnownTranslation() throws {
        let content = try makePatternImage(width: 48, height: 150, seed: 37)
        let previous = try XCTUnwrap(content.cropping(to: CGRect(x: 0, y: 0, width: 48, height: 80)))
        let current = try XCTUnwrap(content.cropping(to: CGRect(x: 0, y: 23, width: 48, height: 80)))
        var configuration = testConfiguration()
        configuration.overlapPreferenceWeight = 0.02

        let estimate = try VerticalOverlapEstimator.estimate(
            previous: previous,
            current: current,
            configuration: configuration
        )

        XCTAssertEqual(estimate.overlapHeightPixels, 57)
        XCTAssertEqual(estimate.scrollDeltaPixels, 23)
    }

    func testEstimatesOnePixelFinalTranslationWhenConfiguredForFullRange() throws {
        let content = try makePatternImage(width: 48, height: 81, seed: 9)
        let previous = try XCTUnwrap(content.cropping(to: CGRect(x: 0, y: 0, width: 48, height: 80)))
        let current = try XCTUnwrap(content.cropping(to: CGRect(x: 0, y: 1, width: 48, height: 80)))
        var configuration = testConfiguration()
        configuration.maximumOverlapFraction = 0.999_999

        let estimate = try VerticalOverlapEstimator.estimate(
            previous: previous,
            current: current,
            configuration: configuration
        )

        XCTAssertEqual(estimate.overlapHeightPixels, 79)
        XCTAssertEqual(estimate.scrollDeltaPixels, 1)
        XCTAssertEqual(estimate.addedHeightPixels, 1)
    }

    func testIgnoresFixedTopChromeWhenEstimatingTranslation() throws {
        let headerHeight = 12
        let bodyHeight = 68
        let delta = 17
        let previous = try makeViewport(
            width: 48,
            headerHeight: headerHeight,
            bodyHeight: bodyHeight,
            bodyStart: 0
        )
        let current = try makeViewport(
            width: 48,
            headerHeight: headerHeight,
            bodyHeight: bodyHeight,
            bodyStart: delta
        )
        var configuration = testConfiguration()
        configuration.fixedTopHeightPixels = headerHeight

        let estimate = try VerticalOverlapEstimator.estimate(
            previous: previous,
            current: current,
            configuration: configuration
        )

        XCTAssertEqual(estimate.overlapHeightPixels, bodyHeight - delta)
        XCTAssertEqual(estimate.scrollDeltaPixels, delta)
        XCTAssertEqual(estimate.addedHeightPixels, delta)
        XCTAssertEqual(estimate.currentContentOffsetPixels, headerHeight + delta)
        XCTAssertEqual(estimate.currentSourceTopInsetPixels, headerHeight)
        XCTAssertGreaterThan(estimate.confidence, 0.9)
    }

    func testEstimateFeedsStitcherWithFixedTopChrome() throws {
        let headerHeight = 12
        let bodyHeight = 68
        let delta = 17
        let previous = try makeViewport(
            width: 48,
            headerHeight: headerHeight,
            bodyHeight: bodyHeight,
            bodyStart: 0
        )
        let current = try makeViewport(
            width: 48,
            headerHeight: headerHeight,
            bodyHeight: bodyHeight,
            bodyStart: delta
        )
        let expected = try makeViewport(
            width: 48,
            headerHeight: headerHeight,
            bodyHeight: bodyHeight + delta,
            bodyStart: 0
        )
        var configuration = testConfiguration()
        configuration.fixedTopHeightPixels = headerHeight
        let estimate = try VerticalOverlapEstimator.estimate(
            previous: previous,
            current: current,
            configuration: configuration
        )

        let stitched = try VerticalImageStitcher.stitch([
            VerticalCaptureFragment(image: previous, verticalOffset: 0, scale: 1),
            VerticalCaptureFragment(
                image: current,
                verticalOffset: CGFloat(estimate.currentContentOffsetPixels),
                scale: 1,
                sourceTopInsetPixels: estimate.currentSourceTopInsetPixels
            ),
        ])

        XCTAssertEqual(stitched.image.width, expected.width)
        XCTAssertEqual(stitched.image.height, expected.height)
        XCTAssertEqual(try normalizedBytes(of: stitched.image), try normalizedBytes(of: expected))
    }

    func testThreeFrameFixedTopOffsetsAccumulateOnlyBodyScroll() throws {
        let headerHeight = 12
        let bodyHeight = 68
        let delta = 17
        let frames = try [0, delta, delta * 2].map {
            try makeViewport(
                width: 48,
                headerHeight: headerHeight,
                bodyHeight: bodyHeight,
                bodyStart: $0
            )
        }
        var configuration = testConfiguration()
        configuration.fixedTopHeightPixels = headerHeight
        let firstEstimate = try VerticalOverlapEstimator.estimate(
            previous: frames[0],
            current: frames[1],
            configuration: configuration
        )
        let secondEstimate = try VerticalOverlapEstimator.estimate(
            previous: frames[1],
            current: frames[2],
            configuration: configuration
        )
        let firstCumulativeScroll = firstEstimate.scrollDeltaPixels
        let secondCumulativeScroll = firstCumulativeScroll + secondEstimate.scrollDeltaPixels

        let stitched = try VerticalImageStitcher.stitch([
            VerticalCaptureFragment(image: frames[0], verticalOffset: 0, scale: 1),
            VerticalCaptureFragment(
                image: frames[1],
                verticalOffset: CGFloat(headerHeight + firstCumulativeScroll),
                scale: 1,
                sourceTopInsetPixels: headerHeight
            ),
            VerticalCaptureFragment(
                image: frames[2],
                verticalOffset: CGFloat(headerHeight + secondCumulativeScroll),
                scale: 1,
                sourceTopInsetPixels: headerHeight
            ),
        ])
        let expected = try makeViewport(
            width: 48,
            headerHeight: headerHeight,
            bodyHeight: bodyHeight + delta * 2,
            bodyStart: 0
        )

        XCTAssertEqual(try normalizedBytes(of: stitched.image), try normalizedBytes(of: expected))
    }

    func testManualPolicyStitchesRepeatedTextAcrossLargerScrollSteps() throws {
        let width = 64
        let headerHeight = 12
        let bodyHeight = 100
        let delta = 36
        let frames = try [0, delta, delta * 2].map {
            try makeRepeatedTextViewport(
                width: width,
                headerHeight: headerHeight,
                bodyHeight: bodyHeight,
                bodyStart: $0
            )
        }
        let configuration = ManualLongCaptureOverlapPolicy.configuration(
            bodyHeightPixels: bodyHeight,
            fixedTopHeightPixels: headerHeight,
            maximumInputPixelCount: 32_000_000
        )
        let firstEstimate = try VerticalOverlapEstimator.estimate(
            previous: frames[0],
            current: frames[1],
            configuration: configuration
        )
        let secondEstimate = try VerticalOverlapEstimator.estimate(
            previous: frames[1],
            current: frames[2],
            configuration: configuration
        )

        XCTAssertEqual(firstEstimate.scrollDeltaPixels, delta)
        XCTAssertEqual(secondEstimate.scrollDeltaPixels, delta)

        let stitched = try VerticalImageStitcher.stitch([
            VerticalCaptureFragment(image: frames[0], verticalOffset: 0, scale: 1),
            VerticalCaptureFragment(
                image: frames[1],
                verticalOffset: CGFloat(headerHeight + firstEstimate.scrollDeltaPixels),
                scale: 1,
                sourceTopInsetPixels: headerHeight
            ),
            VerticalCaptureFragment(
                image: frames[2],
                verticalOffset: CGFloat(
                    headerHeight
                        + firstEstimate.scrollDeltaPixels
                        + secondEstimate.scrollDeltaPixels
                ),
                scale: 1,
                sourceTopInsetPixels: headerHeight
            ),
        ])
        let expected = try makeRepeatedTextViewport(
            width: width,
            headerHeight: headerHeight,
            bodyHeight: bodyHeight + delta * 2,
            bodyStart: 0
        )

        XCTAssertEqual(try normalizedBytes(of: stitched.image), try normalizedBytes(of: expected))
    }

    func testManualPolicyRejectsAmbiguousPeriodicContent() throws {
        let width = 64
        let bodyHeight = 100
        let previous = try makePeriodicViewport(
            width: width,
            height: bodyHeight,
            documentStart: 0,
            period: 20
        )
        let current = try makePeriodicViewport(
            width: width,
            height: bodyHeight,
            documentStart: 30,
            period: 20
        )
        let configuration = ManualLongCaptureOverlapPolicy.configuration(
            bodyHeightPixels: bodyHeight,
            fixedTopHeightPixels: 0,
            maximumInputPixelCount: 32_000_000
        )

        assertEstimationError(.noReliableOverlap) {
            try VerticalOverlapEstimator.estimate(
                previous: previous,
                current: current,
                configuration: configuration
            )
        }
    }

    func testRejectsImagesWithoutReliableOverlap() throws {
        let previous = try makePatternImage(width: 48, height: 80, seed: 11)
        let current = try makePatternImage(width: 48, height: 80, seed: 193)

        assertEstimationError(.noReliableOverlap) {
            try VerticalOverlapEstimator.estimate(
                previous: previous,
                current: current,
                configuration: testConfiguration()
            )
        }
    }

    func testRejectsInvalidOverlapPreferenceWeight() throws {
        let previous = try makePatternImage(width: 48, height: 80, seed: 11)
        let current = try makePatternImage(width: 48, height: 80, seed: 12)
        var configuration = testConfiguration()
        configuration.overlapPreferenceWeight = -0.01

        assertEstimationError(.invalidConfiguration) {
            try VerticalOverlapEstimator.estimate(
                previous: previous,
                current: current,
                configuration: configuration
            )
        }
    }

    func testRejectsIdenticalImages() throws {
        let image = try makePatternImage(width: 48, height: 80, seed: 21)

        assertEstimationError(.identicalImages) {
            try VerticalOverlapEstimator.estimate(
                previous: image,
                current: image,
                configuration: testConfiguration()
            )
        }
    }

    func testSamePositionDifferenceSeparatesIdleNoiseFromDifferentContent() throws {
        let original = try makePatternImage(width: 48, height: 80, seed: 21)
        var lightlyChangedBytes = try normalizedBytes(of: original)
        for index in stride(from: 0, to: 40, by: 4) {
            lightlyChangedBytes[index] = lightlyChangedBytes[index] &+ 12
        }
        let lightlyChanged = try makeTestImage(
            width: original.width,
            height: original.height,
            bytes: lightlyChangedBytes
        )
        let different = try makePatternImage(width: 48, height: 80, seed: 193)

        let idleDifference = try VerticalOverlapEstimator.meanAbsoluteDifferenceAtSamePosition(
            first: original,
            second: lightlyChanged,
            horizontalInsetFraction: 0,
            maximumSampleRows: 80,
            maximumSampleColumns: 48
        )
        let contentDifference = try VerticalOverlapEstimator.meanAbsoluteDifferenceAtSamePosition(
            first: original,
            second: different,
            horizontalInsetFraction: 0,
            maximumSampleRows: 80,
            maximumSampleColumns: 48
        )

        XCTAssertLessThan(idleDifference, 0.001)
        XCTAssertGreaterThan(contentDifference, 0.10)
    }

    private func testConfiguration() -> VerticalOverlapEstimatorConfiguration {
        VerticalOverlapEstimatorConfiguration(
            minimumOverlapHeightPixels: 12,
            maximumOverlapFraction: 0.95,
            horizontalInsetFraction: 0.08,
            maximumMeanAbsoluteDifference: 0.02,
            minimumConfidence: 0.80,
            maximumSampleRows: 48,
            maximumSampleColumns: 40
        )
    }

    private func assertEstimationError<T>(
        _ expected: VerticalOverlapEstimationError,
        operation: () throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual(error as? VerticalOverlapEstimationError, expected, file: file, line: line)
        }
    }
}

private func makePatternImage(width: Int, height: Int, seed: Int) throws -> CGImage {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            bytes.append(UInt8(truncatingIfNeeded: x * 37 + y * 17 + x * y * 3 + seed * 53))
            bytes.append(UInt8(truncatingIfNeeded: x * 11 + y * 67 + y * y * 5 + seed * 29))
            bytes.append(UInt8(truncatingIfNeeded: x * 97 + y * 23 + (x + y) * 7 + seed * 13))
            bytes.append(255)
        }
    }
    return try makeTestImage(width: width, height: height, bytes: bytes)
}

private func makeViewport(
    width: Int,
    headerHeight: Int,
    bodyHeight: Int,
    bodyStart: Int
) throws -> CGImage {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(width * (headerHeight + bodyHeight) * 4)
    for y in 0..<headerHeight {
        for x in 0..<width {
            bytes.append(UInt8(truncatingIfNeeded: 40 + x * 2))
            bytes.append(UInt8(truncatingIfNeeded: 90 + y * 5))
            bytes.append(UInt8(truncatingIfNeeded: 180 + x + y))
            bytes.append(255)
        }
    }
    for localY in 0..<bodyHeight {
        let y = bodyStart + localY
        for x in 0..<width {
            bytes.append(UInt8(truncatingIfNeeded: x * 37 + y * 17 + x * y * 3 + 7 * 53))
            bytes.append(UInt8(truncatingIfNeeded: x * 11 + y * 67 + y * y * 5 + 7 * 29))
            bytes.append(UInt8(truncatingIfNeeded: x * 97 + y * 23 + (x + y) * 7 + 7 * 13))
            bytes.append(255)
        }
    }
    return try makeTestImage(
        width: width,
        height: headerHeight + bodyHeight,
        bytes: bytes
    )
}

private func makeRepeatedTextViewport(
    width: Int,
    headerHeight: Int,
    bodyHeight: Int,
    bodyStart: Int
) throws -> CGImage {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(width * (headerHeight + bodyHeight) * 4)
    for y in 0..<(headerHeight + bodyHeight) {
        for x in 0..<width {
            if y < headerHeight {
                bytes.append(UInt8(38 + x % 9))
                bytes.append(UInt8(72 + y % 7))
                bytes.append(UInt8(104 + (x + y) % 11))
            } else {
                let documentY = bodyStart + y - headerHeight
                let line = documentY / 8
                let rowInLine = documentY % 8
                let drawsGlyph = (2...4).contains(rowInLine)
                    && x >= 6
                    && x < width - 6
                    && (x + line * 3) % 11 < 7
                let shade = drawsGlyph ? UInt8(48 + line % 9) : UInt8(247)
                bytes.append(shade)
                bytes.append(shade)
                bytes.append(shade)
            }
            bytes.append(255)
        }
    }
    return try makeTestImage(
        width: width,
        height: headerHeight + bodyHeight,
        bytes: bytes
    )
}

private func makePeriodicViewport(
    width: Int,
    height: Int,
    documentStart: Int,
    period: Int
) throws -> CGImage {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(width * height * 4)
    for localY in 0..<height {
        let periodicY = (documentStart + localY) % period
        for x in 0..<width {
            let drawsGlyph = (3...6).contains(periodicY % 10)
                && x >= 6
                && x < width - 6
                && (x + periodicY * 3) % 13 < 8
            let shade = drawsGlyph ? UInt8(42 + periodicY) : UInt8(246)
            bytes.append(shade)
            bytes.append(shade)
            bytes.append(shade)
            bytes.append(255)
        }
    }
    return try makeTestImage(width: width, height: height, bytes: bytes)
}
