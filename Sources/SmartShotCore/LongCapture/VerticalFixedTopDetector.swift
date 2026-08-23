import CoreGraphics
import Foundation

public struct VerticalFixedTopDetectorConfiguration: Equatable, Sendable {
    public var minimumHeightPixels: Int
    public var maximumHeightFraction: Double
    public var horizontalInsetFraction: Double
    public var maximumStableRowDifference: Double
    public var maximumStablePrefixDifference: Double
    public var minimumChangedRowDifference: Double
    public var minimumChangedRows: Int
    public var changedProbeHeightPixels: Int
    public var maximumUnstablePrefixFraction: Double
    public var maximumSampleColumns: Int
    public var maximumInputPixelCount: Int

    public init(
        minimumHeightPixels: Int = 8,
        maximumHeightFraction: Double = 0.35,
        horizontalInsetFraction: Double = 0.08,
        maximumStableRowDifference: Double = 0.030,
        maximumStablePrefixDifference: Double = 0.025,
        minimumChangedRowDifference: Double = 0.035,
        minimumChangedRows: Int = 4,
        changedProbeHeightPixels: Int = 12,
        maximumUnstablePrefixFraction: Double = 0.10,
        maximumSampleColumns: Int = 96,
        maximumInputPixelCount: Int = 32_000_000
    ) {
        self.minimumHeightPixels = minimumHeightPixels
        self.maximumHeightFraction = maximumHeightFraction
        self.horizontalInsetFraction = horizontalInsetFraction
        self.maximumStableRowDifference = maximumStableRowDifference
        self.maximumStablePrefixDifference = maximumStablePrefixDifference
        self.minimumChangedRowDifference = minimumChangedRowDifference
        self.minimumChangedRows = minimumChangedRows
        self.changedProbeHeightPixels = changedProbeHeightPixels
        self.maximumUnstablePrefixFraction = maximumUnstablePrefixFraction
        self.maximumSampleColumns = maximumSampleColumns
        self.maximumInputPixelCount = maximumInputPixelCount
    }
}

public enum VerticalFixedTopDetectionError: Error, Equatable, LocalizedError, Sendable {
    case invalidConfiguration
    case widthMismatch(expected: Int, actual: Int)
    case heightMismatch(expected: Int, actual: Int)
    case dimensionsOverflow
    case pixelLimitExceeded(pixelCount: Int, maximum: Int)
    case imageDecodingFailed(imageIndex: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "The fixed-header detector configuration is invalid."
        case let .widthMismatch(expected, actual):
            "The current image is \(actual) pixels wide, but \(expected) pixels were expected."
        case let .heightMismatch(expected, actual):
            "The current image is \(actual) pixels high, but \(expected) pixels were expected."
        case .dimensionsOverflow:
            "An input image is too large to inspect."
        case let .pixelLimitExceeded(pixelCount, maximum):
            "The input contains \(pixelCount) pixels, exceeding the \(maximum)-pixel limit."
        case let .imageDecodingFailed(index):
            "Image \(index) could not be decoded."
        }
    }
}

public enum VerticalFixedTopDetector {
    /// Returns a conservative fixed top height. Zero means no reliable fixed region was found.
    public static func detect(
        previous: CGImage,
        current: CGImage,
        configuration: VerticalFixedTopDetectorConfiguration = .init()
    ) throws -> Int {
        try validate(configuration)
        guard previous.width == current.width else {
            throw VerticalFixedTopDetectionError.widthMismatch(
                expected: previous.width,
                actual: current.width
            )
        }
        guard previous.height == current.height else {
            throw VerticalFixedTopDetectionError.heightMismatch(
                expected: previous.height,
                actual: current.height
            )
        }
        try validatePixelCount(
            width: previous.width,
            height: previous.height,
            maximum: configuration.maximumInputPixelCount
        )
        guard let previousPixels = RGBA8Image(image: previous) else {
            throw VerticalFixedTopDetectionError.imageDecodingFailed(imageIndex: 0)
        }
        guard let currentPixels = RGBA8Image(image: current) else {
            throw VerticalFixedTopDetectionError.imageDecodingFailed(imageIndex: 1)
        }
        guard previousPixels.bytes != currentPixels.bytes else { return 0 }

        let maximumHeaderHeight = min(
            previousPixels.height - configuration.changedProbeHeightPixels,
            Int(floor(Double(previousPixels.height) * configuration.maximumHeightFraction))
        )
        guard maximumHeaderHeight >= configuration.minimumHeightPixels else { return 0 }

        let horizontalRange = sampledHorizontalRange(
            width: previousPixels.width,
            insetFraction: configuration.horizontalInsetFraction
        )
        let inspectedHeight = min(
            previousPixels.height,
            maximumHeaderHeight + configuration.changedProbeHeightPixels
        )
        var rowDifferences = [Double]()
        rowDifferences.reserveCapacity(inspectedHeight)
        for y in 0..<inspectedHeight {
            if y.isMultiple(of: 64) { try Task.checkCancellation() }
            rowDifferences.append(
                rowDifference(
                    previous: previousPixels,
                    current: currentPixels,
                    y: y,
                    horizontalRange: horizontalRange,
                    maximumColumns: configuration.maximumSampleColumns
                )
            )
        }

        var prefixDifference = 0.0
        var unstablePrefixRows = 0
        for boundary in 1...maximumHeaderHeight {
            let latest = rowDifferences[boundary - 1]
            prefixDifference += latest
            if latest > configuration.maximumStableRowDifference {
                unstablePrefixRows += 1
            }
            guard boundary >= configuration.minimumHeightPixels else { continue }

            let prefixMean = prefixDifference / Double(boundary)
            let unstableFraction = Double(unstablePrefixRows) / Double(boundary)
            guard prefixMean <= configuration.maximumStablePrefixDifference,
                  unstableFraction <= configuration.maximumUnstablePrefixFraction else {
                continue
            }

            let probeEnd = min(rowDifferences.count, boundary + configuration.changedProbeHeightPixels)
            guard probeEnd - boundary >= configuration.minimumChangedRows else { continue }
            let probe = rowDifferences[boundary..<probeEnd]
            let changedRows = probe.reduce(into: 0) { count, difference in
                if difference >= configuration.minimumChangedRowDifference { count += 1 }
            }
            let probeMean = probe.reduce(0, +) / Double(probe.count)
            guard changedRows >= configuration.minimumChangedRows,
                  probeMean >= configuration.minimumChangedRowDifference,
                  probeMean >= max(0.01, prefixMean * 3) else {
                continue
            }
            guard let firstChangedOffset = probe.firstIndex(where: {
                $0 >= configuration.minimumChangedRowDifference
            }) else { continue }
            let candidateBoundary = firstChangedOffset
            let candidatePrefix = rowDifferences[..<candidateBoundary]
            let candidateMean = candidatePrefix.reduce(0, +) / Double(candidatePrefix.count)
            let candidateUnstableRows = candidatePrefix.reduce(into: 0) { count, difference in
                if difference > configuration.maximumStableRowDifference { count += 1 }
            }
            let candidateUnstableFraction = Double(candidateUnstableRows) /
                Double(candidatePrefix.count)
            guard candidateBoundary >= configuration.minimumHeightPixels,
                  candidateBoundary <= maximumHeaderHeight,
                  candidateMean <= configuration.maximumStablePrefixDifference,
                  candidateUnstableFraction <= configuration.maximumUnstablePrefixFraction else {
                continue
            }
            return candidateBoundary
        }
        return 0
    }
}

private extension VerticalFixedTopDetector {
    static func validate(_ configuration: VerticalFixedTopDetectorConfiguration) throws {
        guard configuration.minimumHeightPixels > 0,
              configuration.maximumHeightFraction > 0,
              configuration.maximumHeightFraction < 0.5,
              configuration.horizontalInsetFraction >= 0,
              configuration.horizontalInsetFraction < 0.5,
              configuration.maximumStableRowDifference >= 0,
              configuration.maximumStablePrefixDifference >= 0,
              configuration.minimumChangedRowDifference > configuration.maximumStablePrefixDifference,
              configuration.minimumChangedRowDifference <= 1,
              configuration.minimumChangedRows > 0,
              configuration.changedProbeHeightPixels >= configuration.minimumChangedRows,
              configuration.maximumUnstablePrefixFraction >= 0,
              configuration.maximumUnstablePrefixFraction < 0.5,
              configuration.maximumSampleColumns > 0,
              configuration.maximumInputPixelCount > 0 else {
            throw VerticalFixedTopDetectionError.invalidConfiguration
        }
    }

    static func validatePixelCount(width: Int, height: Int, maximum: Int) throws {
        let (pixelCount, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow else { throw VerticalFixedTopDetectionError.dimensionsOverflow }
        guard pixelCount <= maximum else {
            throw VerticalFixedTopDetectionError.pixelLimitExceeded(
                pixelCount: pixelCount,
                maximum: maximum
            )
        }
    }

    static func sampledHorizontalRange(width: Int, insetFraction: Double) -> Range<Int> {
        let inset = Int(floor(Double(width) * insetFraction))
        let lower = min(inset, max(0, width - 1))
        return lower..<max(lower + 1, width - inset)
    }

    static func rowDifference(
        previous: RGBA8Image,
        current: RGBA8Image,
        y: Int,
        horizontalRange: Range<Int>,
        maximumColumns: Int
    ) -> Double {
        let stride = max(1, (horizontalRange.count - 1) / maximumColumns + 1)
        var total: UInt64 = 0
        var componentCount: UInt64 = 0
        for x in Swift.stride(
            from: horizontalRange.lowerBound,
            to: horizontalRange.upperBound,
            by: stride
        ) {
            let previousOffset = previous.byteOffset(x: x, y: y)
            let currentOffset = current.byteOffset(x: x, y: y)
            for component in 0..<3 {
                total += UInt64(
                    abs(
                        Int(previous.bytes[previousOffset + component])
                            - Int(current.bytes[currentOffset + component])
                    )
                )
                componentCount += 1
            }
        }
        guard componentCount > 0 else { return 1 }
        return Double(total) / (Double(componentCount) * 255)
    }
}
