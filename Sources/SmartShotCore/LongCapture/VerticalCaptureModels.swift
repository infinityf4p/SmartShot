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
            L10n.text("At least one image fragment is required.")
        case .invalidMaximumPixelCount:
            L10n.text("The maximum pixel count must be greater than zero.")
        case let .invalidScale(index):
            L10n.format("Fragment %@ has an invalid image scale.", String(describing: index))
        case let .scaleMismatch(index, expected, actual):
            L10n.format("Fragment %@ uses scale %@, but scale %@ was expected.", String(describing: index), String(describing: actual), String(describing: expected))
        case let .invalidVerticalOffset(index):
            L10n.format("Fragment %@ has an invalid vertical offset.", String(describing: index))
        case let .offsetsOutOfOrder(index):
            L10n.format("Fragment %@ is positioned before the preceding fragment.", String(describing: index))
        case let .invalidSourceInsets(index):
            L10n.format("Fragment %@ has invalid source insets.", String(describing: index))
        case let .widthMismatch(index, expected, actual):
            L10n.format("Fragment %@ is %@ pixels wide, but %@ pixels were expected.", String(describing: index), String(describing: actual), String(describing: expected))
        case let .gap(index, expected, actual):
            L10n.format("Fragment %@ starts at pixel %@, leaving a gap after pixel %@.", String(describing: index), String(describing: actual), String(describing: expected))
        case let .fragmentAddsNoPixels(index):
            L10n.format("Fragment %@ adds no new pixels.", String(describing: index))
        case .dimensionsOverflow:
            L10n.text("The stitched image dimensions are too large.")
        case let .pixelLimitExceeded(pixelCount, maximum):
            L10n.format("The stitched image requires %@ pixels, exceeding the %@-pixel limit.", String(describing: pixelCount), String(describing: maximum))
        case let .imageDecodingFailed(index):
            L10n.format("Fragment %@ could not be decoded.", String(describing: index))
        case .imageCreationFailed:
            L10n.text("The stitched image could not be created.")
        case .pngEncodingFailed:
            L10n.text("The stitched image could not be encoded as PNG.")
        }
    }
}
