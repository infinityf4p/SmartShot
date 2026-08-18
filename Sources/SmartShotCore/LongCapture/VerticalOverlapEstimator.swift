import CoreGraphics
import Foundation

public struct VerticalOverlapEstimatorConfiguration: Equatable, Sendable {
    public var minimumOverlapHeightPixels: Int
    public var maximumOverlapFraction: Double
    public var horizontalInsetFraction: Double
    public var fixedTopHeightPixels: Int
    public var maximumMeanAbsoluteDifference: Double
    public var minimumConfidence: Double
    public var maximumSampleRows: Int
    public var maximumSampleColumns: Int
    public var maximumInputPixelCount: Int
    public var overlapPreferenceWeight: Double

    public init(
        minimumOverlapHeightPixels: Int = 24,
        maximumOverlapFraction: Double = 0.95,
        horizontalInsetFraction: Double = 0.08,
        fixedTopHeightPixels: Int = 0,
        maximumMeanAbsoluteDifference: Double = 0.035,
        minimumConfidence: Double = 0.82,
        maximumSampleRows: Int = 48,
        maximumSampleColumns: Int = 64,
        maximumInputPixelCount: Int = 50_000_000,
        overlapPreferenceWeight: Double = 0
    ) {
        self.minimumOverlapHeightPixels = minimumOverlapHeightPixels
        self.maximumOverlapFraction = maximumOverlapFraction
        self.horizontalInsetFraction = horizontalInsetFraction
        self.fixedTopHeightPixels = fixedTopHeightPixels
        self.maximumMeanAbsoluteDifference = maximumMeanAbsoluteDifference
        self.minimumConfidence = minimumConfidence
        self.maximumSampleRows = maximumSampleRows
        self.maximumSampleColumns = maximumSampleColumns
        self.maximumInputPixelCount = maximumInputPixelCount
        self.overlapPreferenceWeight = overlapPreferenceWeight
    }
}

public struct VerticalOverlapEstimate: Equatable, Sendable {
    public let overlapHeightPixels: Int
    public let addedHeightPixels: Int
    public let scrollDeltaPixels: Int
    /// Offset from the previous raw image top to the first retained row of the current image.
    public let currentContentOffsetPixels: Int
    public let currentSourceTopInsetPixels: Int
    public let confidence: Double
    public let meanAbsoluteDifference: Double

    public init(
        overlapHeightPixels: Int,
        addedHeightPixels: Int,
        scrollDeltaPixels: Int,
        currentContentOffsetPixels: Int,
        currentSourceTopInsetPixels: Int,
        confidence: Double,
        meanAbsoluteDifference: Double
    ) {
        self.overlapHeightPixels = overlapHeightPixels
        self.addedHeightPixels = addedHeightPixels
        self.scrollDeltaPixels = scrollDeltaPixels
        self.currentContentOffsetPixels = currentContentOffsetPixels
        self.currentSourceTopInsetPixels = currentSourceTopInsetPixels
        self.confidence = confidence
        self.meanAbsoluteDifference = meanAbsoluteDifference
    }
}

public enum VerticalOverlapEstimationError: Error, Equatable, LocalizedError, Sendable {
    case invalidConfiguration
    case widthMismatch(expected: Int, actual: Int)
    case heightMismatch(expected: Int, actual: Int)
    case fixedTopHeightOutOfRange(Int)
    case identicalImages
    case dimensionsOverflow
    case pixelLimitExceeded(imageIndex: Int, pixelCount: Int, maximum: Int)
    case imageDecodingFailed(imageIndex: Int)
    case noReliableOverlap

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "The overlap estimator configuration is invalid."
        case let .widthMismatch(expected, actual):
            "The current image is \(actual) pixels wide, but \(expected) pixels were expected."
        case let .heightMismatch(expected, actual):
            "The current image is \(actual) pixels high, but \(expected) pixels were expected."
        case let .fixedTopHeightOutOfRange(height):
            "The fixed top height \(height) is outside the image body."
        case .identicalImages:
            "The images are identical and contain no scrolling progress."
        case .dimensionsOverflow:
            "An input image is too large to inspect."
        case let .pixelLimitExceeded(index, pixelCount, maximum):
            "Image \(index) contains \(pixelCount) pixels, exceeding the \(maximum)-pixel limit."
        case let .imageDecodingFailed(index):
            "Image \(index) could not be decoded."
        case .noReliableOverlap:
            "No reliable vertical overlap was found."
        }
    }
}

public enum VerticalOverlapEstimator {
    public static func meanAbsoluteDifferenceAtSamePosition(
        first: CGImage,
        second: CGImage,
        horizontalInsetFraction: Double = 0.08,
        maximumSampleRows: Int = 64,
        maximumSampleColumns: Int = 72,
        maximumInputPixelCount: Int = 50_000_000
    ) throws -> Double {
        guard horizontalInsetFraction >= 0,
              horizontalInsetFraction < 0.5,
              maximumSampleRows > 0,
              maximumSampleColumns > 0,
              maximumInputPixelCount > 0 else {
            throw VerticalOverlapEstimationError.invalidConfiguration
        }
        guard first.width == second.width else {
            throw VerticalOverlapEstimationError.widthMismatch(
                expected: first.width,
                actual: second.width
            )
        }
        guard first.height == second.height else {
            throw VerticalOverlapEstimationError.heightMismatch(
                expected: first.height,
                actual: second.height
            )
        }
        try validatePixelCount(
            width: first.width,
            height: first.height,
            index: 0,
            maximum: maximumInputPixelCount
        )
        try validatePixelCount(
            width: second.width,
            height: second.height,
            index: 1,
            maximum: maximumInputPixelCount
        )
        guard let firstPixels = RGBA8Image(image: first) else {
            throw VerticalOverlapEstimationError.imageDecodingFailed(imageIndex: 0)
        }
        guard let secondPixels = RGBA8Image(image: second) else {
            throw VerticalOverlapEstimationError.imageDecodingFailed(imageIndex: 1)
        }

        return meanAbsoluteDifference(
            previous: firstPixels,
            current: secondPixels,
            overlap: firstPixels.height,
            currentStartY: 0,
            horizontalRange: sampledHorizontalRange(
                width: firstPixels.width,
                insetFraction: horizontalInsetFraction
            ),
            maximumRows: maximumSampleRows,
            maximumColumns: maximumSampleColumns
        )
    }

    public static func estimate(
        previous: CGImage,
        current: CGImage,
        configuration: VerticalOverlapEstimatorConfiguration = VerticalOverlapEstimatorConfiguration()
    ) throws -> VerticalOverlapEstimate {
        try validate(configuration)
        guard previous.width == current.width else {
            throw VerticalOverlapEstimationError.widthMismatch(
                expected: previous.width,
                actual: current.width
            )
        }
        guard configuration.fixedTopHeightPixels < previous.height,
              configuration.fixedTopHeightPixels < current.height else {
            throw VerticalOverlapEstimationError.fixedTopHeightOutOfRange(
                configuration.fixedTopHeightPixels
            )
        }
        try validatePixelCount(
            width: previous.width,
            height: previous.height,
            index: 0,
            maximum: configuration.maximumInputPixelCount
        )
        try validatePixelCount(
            width: current.width,
            height: current.height,
            index: 1,
            maximum: configuration.maximumInputPixelCount
        )

        guard let previousPixels = RGBA8Image(image: previous) else {
            throw VerticalOverlapEstimationError.imageDecodingFailed(imageIndex: 0)
        }
        guard let currentPixels = RGBA8Image(image: current) else {
            throw VerticalOverlapEstimationError.imageDecodingFailed(imageIndex: 1)
        }
        if previousPixels.width == currentPixels.width,
           previousPixels.height == currentPixels.height,
           previousPixels.bytes == currentPixels.bytes {
            throw VerticalOverlapEstimationError.identicalImages
        }

        let fixedTop = configuration.fixedTopHeightPixels
        let previousBodyHeight = previousPixels.height - fixedTop
        let currentBodyHeight = currentPixels.height - fixedTop
        let maximumPossibleOverlap = min(previousBodyHeight, currentBodyHeight) - 1
        let fractionalMaximum = Int(
            floor(Double(min(previousBodyHeight, currentBodyHeight)) * configuration.maximumOverlapFraction)
        )
        let maximumOverlap = min(maximumPossibleOverlap, fractionalMaximum)
        guard configuration.minimumOverlapHeightPixels <= maximumOverlap else {
            throw VerticalOverlapEstimationError.noReliableOverlap
        }

        let horizontalRange = sampledHorizontalRange(
            width: previousPixels.width,
            insetFraction: configuration.horizontalInsetFraction
        )
        let overlapNormalization = Double(min(previousBodyHeight, currentBodyHeight))
        var scores: [(overlap: Int, difference: Double, rankingScore: Double)] = []
        scores.reserveCapacity(maximumOverlap - configuration.minimumOverlapHeightPixels + 1)

        for overlap in configuration.minimumOverlapHeightPixels...maximumOverlap {
            if overlap.isMultiple(of: 32) { try Task.checkCancellation() }
            let difference = meanAbsoluteDifference(
                previous: previousPixels,
                current: currentPixels,
                overlap: overlap,
                currentStartY: fixedTop,
                horizontalRange: horizontalRange,
                maximumRows: configuration.maximumSampleRows,
                maximumColumns: configuration.maximumSampleColumns
            )
            scores.append(
                (
                    overlap: overlap,
                    difference: difference,
                    rankingScore: difference
                        - configuration.overlapPreferenceWeight
                        * Double(overlap) / overlapNormalization
                )
            )
        }

        let sorted = scores.sorted {
            if $0.rankingScore == $1.rankingScore { return $0.overlap > $1.overlap }
            return $0.rankingScore < $1.rankingScore
        }
        guard let best = sorted.first,
              best.difference <= configuration.maximumMeanAbsoluteDifference else {
            throw VerticalOverlapEstimationError.noReliableOverlap
        }

        let secondRankingScore = sorted.dropFirst().first?.rankingScore
            ?? best.rankingScore + configuration.maximumMeanAbsoluteDifference
        let samePositionDifference = meanAbsoluteDifference(
            previous: previousPixels,
            current: currentPixels,
            overlap: min(previousBodyHeight, currentBodyHeight),
            currentStartY: fixedTop,
            horizontalRange: horizontalRange,
            maximumRows: configuration.maximumSampleRows,
            maximumColumns: configuration.maximumSampleColumns
        )
        let texture = textureStandardDeviation(
            image: previousPixels,
            startY: previousPixels.height - best.overlap,
            height: best.overlap,
            horizontalRange: horizontalRange,
            maximumRows: configuration.maximumSampleRows,
            maximumColumns: configuration.maximumSampleColumns
        )
        let matchQuality = clamped(
            1 - best.difference / configuration.maximumMeanAbsoluteDifference
        )
        let uniquenessScale = max(0.005, configuration.maximumMeanAbsoluteDifference * 0.5)
        let uniqueness = clamped((secondRankingScore - best.rankingScore) / uniquenessScale)
        let visualDetail = clamped(texture / 0.08)
        let relativeImprovement = clamped(
            (samePositionDifference - best.difference) / max(0.01, samePositionDifference)
        )
        let confidence = 0.50 * relativeImprovement
            + 0.25 * matchQuality
            + 0.15 * uniqueness
            + 0.10 * visualDetail
        guard confidence >= configuration.minimumConfidence else {
            throw VerticalOverlapEstimationError.noReliableOverlap
        }

        return VerticalOverlapEstimate(
            overlapHeightPixels: best.overlap,
            addedHeightPixels: currentBodyHeight - best.overlap,
            scrollDeltaPixels: previousBodyHeight - best.overlap,
            currentContentOffsetPixels: previousPixels.height - best.overlap,
            currentSourceTopInsetPixels: fixedTop,
            confidence: confidence,
            meanAbsoluteDifference: best.difference
        )
    }
}

private extension VerticalOverlapEstimator {
    static func validate(_ configuration: VerticalOverlapEstimatorConfiguration) throws {
        guard configuration.minimumOverlapHeightPixels > 0,
              configuration.maximumOverlapFraction > 0,
              configuration.maximumOverlapFraction < 1,
              configuration.horizontalInsetFraction >= 0,
              configuration.horizontalInsetFraction < 0.5,
              configuration.fixedTopHeightPixels >= 0,
              configuration.maximumMeanAbsoluteDifference > 0,
              configuration.maximumMeanAbsoluteDifference <= 1,
              configuration.minimumConfidence >= 0,
              configuration.minimumConfidence <= 1,
              configuration.maximumSampleRows > 0,
              configuration.maximumSampleColumns > 0,
              configuration.maximumInputPixelCount > 0,
              configuration.overlapPreferenceWeight >= 0,
              configuration.overlapPreferenceWeight <= 1 else {
            throw VerticalOverlapEstimationError.invalidConfiguration
        }
    }

    static func validatePixelCount(
        width: Int,
        height: Int,
        index: Int,
        maximum: Int
    ) throws {
        let (pixelCount, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow else { throw VerticalOverlapEstimationError.dimensionsOverflow }
        guard pixelCount <= maximum else {
            throw VerticalOverlapEstimationError.pixelLimitExceeded(
                imageIndex: index,
                pixelCount: pixelCount,
                maximum: maximum
            )
        }
    }

    static func sampledHorizontalRange(width: Int, insetFraction: Double) -> Range<Int> {
        let inset = Int(floor(Double(width) * insetFraction))
        let lowerBound = min(inset, max(0, width - 1))
        let upperBound = max(lowerBound + 1, width - inset)
        return lowerBound..<min(width, upperBound)
    }

    static func meanAbsoluteDifference(
        previous: RGBA8Image,
        current: RGBA8Image,
        overlap: Int,
        currentStartY: Int,
        horizontalRange: Range<Int>,
        maximumRows: Int,
        maximumColumns: Int
    ) -> Double {
        let rowStride = max(1, (overlap - 1) / maximumRows + 1)
        let columnStride = max(1, (horizontalRange.count - 1) / maximumColumns + 1)
        var totalDifference: UInt64 = 0
        var componentCount: UInt64 = 0

        for rowOffset in stride(from: 0, to: overlap, by: rowStride) {
            let previousY = previous.height - overlap + rowOffset
            let currentY = currentStartY + rowOffset
            for x in stride(
                from: horizontalRange.lowerBound,
                to: horizontalRange.upperBound,
                by: columnStride
            ) {
                let previousOffset = previous.byteOffset(x: x, y: previousY)
                let currentOffset = current.byteOffset(x: x, y: currentY)
                for component in 0..<3 {
                    totalDifference += UInt64(
                        abs(
                            Int(previous.bytes[previousOffset + component])
                                - Int(current.bytes[currentOffset + component])
                        )
                    )
                    componentCount += 1
                }
            }
        }

        guard componentCount > 0 else { return 1 }
        return Double(totalDifference) / (Double(componentCount) * 255)
    }

    static func textureStandardDeviation(
        image: RGBA8Image,
        startY: Int,
        height: Int,
        horizontalRange: Range<Int>,
        maximumRows: Int,
        maximumColumns: Int
    ) -> Double {
        let rowStride = max(1, (height - 1) / maximumRows + 1)
        let columnStride = max(1, (horizontalRange.count - 1) / maximumColumns + 1)
        var sum = 0.0
        var squaredSum = 0.0
        var count = 0.0

        for y in stride(from: startY, to: startY + height, by: rowStride) {
            for x in stride(
                from: horizontalRange.lowerBound,
                to: horizontalRange.upperBound,
                by: columnStride
            ) {
                let offset = image.byteOffset(x: x, y: y)
                let luminance = (
                    0.2126 * Double(image.bytes[offset])
                        + 0.7152 * Double(image.bytes[offset + 1])
                        + 0.0722 * Double(image.bytes[offset + 2])
                ) / 255
                sum += luminance
                squaredSum += luminance * luminance
                count += 1
            }
        }

        guard count > 0 else { return 0 }
        let mean = sum / count
        return sqrt(max(0, squaredSum / count - mean * mean))
    }

    static func clamped(_ value: Double) -> Double {
        min(1, max(0, value))
    }
}
