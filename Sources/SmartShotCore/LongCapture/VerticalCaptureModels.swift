import CoreGraphics
import Foundation

/// One viewport image positioned in a vertically scrolling logical coordinate space.
///
/// `verticalOffset` identifies the first retained source row after the pixel insets
/// are removed. The scale converts that logical offset to output pixels.
public struct VerticalCaptureFragment: @unchecked Sendable {
    public let image: CGImage
    public let verticalOffset: CGFloat
    public let scale: CGFloat
    public let sourceTopInsetPixels: Int
    public let sourceBottomInsetPixels: Int

    public init(
        image: CGImage,
        verticalOffset: CGFloat,
        scale: CGFloat,
        sourceTopInsetPixels: Int = 0,
        sourceBottomInsetPixels: Int = 0
    ) {
        self.image = image
        self.verticalOffset = verticalOffset
        self.scale = scale
        self.sourceTopInsetPixels = sourceTopInsetPixels
        self.sourceBottomInsetPixels = sourceBottomInsetPixels
    }
}

public struct VerticalImageStitchingLimits: Equatable, Sendable {
    public var maximumPixelCount: Int

    public init(maximumPixelCount: Int = 120_000_000) {
        self.maximumPixelCount = maximumPixelCount
    }
}

public struct VerticalImagePlacement: Equatable, Sendable {
    public let fragmentIndex: Int
    /// The retained source rectangle in top-left-origin image pixel coordinates.
    public let sourceRect: CGRect
    /// The top edge in the stitched image's top-left-origin pixel coordinates.
    public let destinationY: Int

    public init(fragmentIndex: Int, sourceRect: CGRect, destinationY: Int) {
        self.fragmentIndex = fragmentIndex
        self.sourceRect = sourceRect
        self.destinationY = destinationY
    }
}

public struct VerticalImageStitchingLayout: Equatable, Sendable {
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let scale: CGFloat
    public let placements: [VerticalImagePlacement]

    public init(
        pixelWidth: Int,
        pixelHeight: Int,
        scale: CGFloat,
        placements: [VerticalImagePlacement]
    ) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scale = scale
        self.placements = placements
    }

    public var logicalSize: CGSize {
        CGSize(width: CGFloat(pixelWidth) / scale, height: CGFloat(pixelHeight) / scale)
    }
}

public struct StitchedVerticalImage: @unchecked Sendable {
    public let image: CGImage
    public let pngData: Data
    public let layout: VerticalImageStitchingLayout

    public init(image: CGImage, pngData: Data, layout: VerticalImageStitchingLayout) {
        self.image = image
        self.pngData = pngData
        self.layout = layout
    }
}

public enum VerticalImageStitchingError: Error, Equatable, LocalizedError, Sendable {
    case noFragments
    case invalidMaximumPixelCount(Int)
    case invalidScale(fragmentIndex: Int)
    case scaleMismatch(fragmentIndex: Int, expected: CGFloat, actual: CGFloat)
    case invalidVerticalOffset(fragmentIndex: Int)
    case offsetsOutOfOrder(fragmentIndex: Int)
    case invalidSourceInsets(fragmentIndex: Int)
    case widthMismatch(fragmentIndex: Int, expected: Int, actual: Int)
    case gap(fragmentIndex: Int, expectedAtMostPixel: Int, actualPixel: Int)
    case fragmentAddsNoPixels(fragmentIndex: Int)
    case dimensionsOverflow
    case pixelLimitExceeded(pixelCount: Int, maximum: Int)
    case imageDecodingFailed(fragmentIndex: Int)
    case imageCreationFailed
    case pngEncodingFailed

    public var errorDescription: String? {
        switch self {
        case .noFragments:
            "At least one image fragment is required."
        case .invalidMaximumPixelCount:
            "The maximum pixel count must be greater than zero."
        case let .invalidScale(index):
            "Fragment \(index) has an invalid image scale."
        case let .scaleMismatch(index, expected, actual):
            "Fragment \(index) uses scale \(actual), but scale \(expected) was expected."
        case let .invalidVerticalOffset(index):
            "Fragment \(index) has an invalid vertical offset."
        case let .offsetsOutOfOrder(index):
            "Fragment \(index) is positioned before the preceding fragment."
        case let .invalidSourceInsets(index):
            "Fragment \(index) has invalid source insets."
        case let .widthMismatch(index, expected, actual):
            "Fragment \(index) is \(actual) pixels wide, but \(expected) pixels were expected."
        case let .gap(index, expected, actual):
            "Fragment \(index) starts at pixel \(actual), leaving a gap after pixel \(expected)."
        case let .fragmentAddsNoPixels(index):
            "Fragment \(index) adds no new pixels."
        case .dimensionsOverflow:
            "The stitched image dimensions are too large."
        case let .pixelLimitExceeded(pixelCount, maximum):
            "The stitched image requires \(pixelCount) pixels, exceeding the \(maximum)-pixel limit."
        case let .imageDecodingFailed(index):
            "Fragment \(index) could not be decoded."
        case .imageCreationFailed:
            "The stitched image could not be created."
        case .pngEncodingFailed:
            "The stitched image could not be encoded as PNG."
        }
    }
}
