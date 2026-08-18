import AppKit
import CoreGraphics
import Foundation

public enum VerticalImageStitcher {
    public static func layout(
        for fragments: [VerticalCaptureFragment],
        limits: VerticalImageStitchingLimits = VerticalImageStitchingLimits()
    ) throws -> VerticalImageStitchingLayout {
        try makePlan(fragments: fragments, limits: limits).layout
    }

    public static func stitch(
        _ fragments: [VerticalCaptureFragment],
        limits: VerticalImageStitchingLimits = VerticalImageStitchingLimits()
    ) throws -> StitchedVerticalImage {
        let plan = try makePlan(fragments: fragments, limits: limits)
        let (byteCount, byteOverflow) = plan.pixelCount.multipliedReportingOverflow(
            by: RGBA8Image.bytesPerPixel
        )
        guard !byteOverflow else { throw VerticalImageStitchingError.dimensionsOverflow }

        var outputBytes = [UInt8](repeating: 0, count: byteCount)
        let destinationBytesPerRow = plan.layout.pixelWidth * RGBA8Image.bytesPerPixel

        for placement in plan.layout.placements {
            try Task.checkCancellation()
            let fragment = fragments[placement.fragmentIndex]
            guard let source = RGBA8Image(image: fragment.image) else {
                throw VerticalImageStitchingError.imageDecodingFailed(
                    fragmentIndex: placement.fragmentIndex
                )
            }

            let sourceY = Int(placement.sourceRect.minY)
            let rowCount = Int(placement.sourceRect.height)
            let sourceBytesPerRow = source.width * RGBA8Image.bytesPerPixel
            outputBytes.withUnsafeMutableBytes { destinationBuffer in
                source.bytes.withUnsafeBytes { sourceBuffer in
                    guard let destinationBase = destinationBuffer.baseAddress,
                          let sourceBase = sourceBuffer.baseAddress else {
                        return
                    }
                    for row in 0..<rowCount {
                        if row.isMultiple(of: 64), Task.isCancelled { return }
                        let sourceAddress = sourceBase.advanced(
                            by: (sourceY + row) * sourceBytesPerRow
                        )
                        let destinationAddress = destinationBase.advanced(
                            by: (placement.destinationY + row) * destinationBytesPerRow
                        )
                        destinationAddress.copyMemory(
                            from: sourceAddress,
                            byteCount: destinationBytesPerRow
                        )
                    }
                }
            }
            try Task.checkCancellation()
        }

        let bitmap = RGBA8Image(
            width: plan.layout.pixelWidth,
            height: plan.layout.pixelHeight,
            bytes: outputBytes
        )
        guard let image = bitmap.makeImage() else {
            throw VerticalImageStitchingError.imageCreationFailed
        }
        try Task.checkCancellation()
        let representation = NSBitmapImageRep(cgImage: image)
        guard let pngData = representation.representation(using: .png, properties: [:]) else {
            throw VerticalImageStitchingError.pngEncodingFailed
        }
        return StitchedVerticalImage(image: image, pngData: pngData, layout: plan.layout)
    }
}

private extension VerticalImageStitcher {
    struct StitchingPlan {
        let layout: VerticalImageStitchingLayout
        let pixelCount: Int
    }

    static func makePlan(
        fragments: [VerticalCaptureFragment],
        limits: VerticalImageStitchingLimits
    ) throws -> StitchingPlan {
        guard !fragments.isEmpty else { throw VerticalImageStitchingError.noFragments }
        guard limits.maximumPixelCount > 0 else {
            throw VerticalImageStitchingError.invalidMaximumPixelCount(limits.maximumPixelCount)
        }

        let first = fragments[0]
        let expectedWidth = first.image.width
        let expectedScale = first.scale
        guard expectedScale.isFinite, expectedScale > 0 else {
            throw VerticalImageStitchingError.invalidScale(fragmentIndex: 0)
        }
        guard first.verticalOffset.isFinite else {
            throw VerticalImageStitchingError.invalidVerticalOffset(fragmentIndex: 0)
        }

        let baseOffset = first.verticalOffset
        var previousOffset = baseOffset
        var stitchedHeight = 0
        var placements: [VerticalImagePlacement] = []
        placements.reserveCapacity(fragments.count)

        for (index, fragment) in fragments.enumerated() {
            guard fragment.image.width == expectedWidth else {
                throw VerticalImageStitchingError.widthMismatch(
                    fragmentIndex: index,
                    expected: expectedWidth,
                    actual: fragment.image.width
                )
            }
            guard fragment.scale.isFinite, fragment.scale > 0 else {
                throw VerticalImageStitchingError.invalidScale(fragmentIndex: index)
            }
            guard abs(fragment.scale - expectedScale) <= 0.000_001 else {
                throw VerticalImageStitchingError.scaleMismatch(
                    fragmentIndex: index,
                    expected: expectedScale,
                    actual: fragment.scale
                )
            }
            guard fragment.verticalOffset.isFinite else {
                throw VerticalImageStitchingError.invalidVerticalOffset(fragmentIndex: index)
            }
            guard index == 0 || fragment.verticalOffset >= previousOffset else {
                throw VerticalImageStitchingError.offsetsOutOfOrder(fragmentIndex: index)
            }
            previousOffset = fragment.verticalOffset

            guard fragment.sourceTopInsetPixels >= 0,
                  fragment.sourceBottomInsetPixels >= 0,
                  fragment.sourceTopInsetPixels < fragment.image.height,
                  fragment.sourceBottomInsetPixels
                    < fragment.image.height - fragment.sourceTopInsetPixels else {
                throw VerticalImageStitchingError.invalidSourceInsets(fragmentIndex: index)
            }
            let retainedHeight = fragment.image.height
                - fragment.sourceTopInsetPixels
                - fragment.sourceBottomInsetPixels

            let pixelOffsetValue = (fragment.verticalOffset - baseOffset) * expectedScale
            guard pixelOffsetValue.isFinite,
                  pixelOffsetValue >= 0 else {
                throw VerticalImageStitchingError.invalidVerticalOffset(fragmentIndex: index)
            }
            let roundedPixelOffset = pixelOffsetValue.rounded()
            guard roundedPixelOffset <= CGFloat(stitchedHeight) else {
                let actualPixel = roundedPixelOffset >= CGFloat(Int.max)
                    ? Int.max
                    : Int(roundedPixelOffset)
                throw VerticalImageStitchingError.gap(
                    fragmentIndex: index,
                    expectedAtMostPixel: stitchedHeight,
                    actualPixel: actualPixel
                )
            }
            let pixelOffset = Int(roundedPixelOffset)

            let overlap = stitchedHeight - pixelOffset
            guard overlap < retainedHeight else {
                throw VerticalImageStitchingError.fragmentAddsNoPixels(fragmentIndex: index)
            }
            let sourceY = fragment.sourceTopInsetPixels + overlap
            let contributionHeight = retainedHeight - overlap
            placements.append(
                VerticalImagePlacement(
                    fragmentIndex: index,
                    sourceRect: CGRect(
                        x: 0,
                        y: sourceY,
                        width: expectedWidth,
                        height: contributionHeight
                    ),
                    destinationY: stitchedHeight
                )
            )
            let (nextHeight, heightOverflow) = stitchedHeight.addingReportingOverflow(
                contributionHeight
            )
            guard !heightOverflow else {
                throw VerticalImageStitchingError.dimensionsOverflow
            }
            let (nextPixelCount, pixelCountOverflow) = expectedWidth.multipliedReportingOverflow(
                by: nextHeight
            )
            guard !pixelCountOverflow else {
                throw VerticalImageStitchingError.dimensionsOverflow
            }
            guard nextPixelCount <= limits.maximumPixelCount else {
                throw VerticalImageStitchingError.pixelLimitExceeded(
                    pixelCount: nextPixelCount,
                    maximum: limits.maximumPixelCount
                )
            }
            stitchedHeight = nextHeight
        }

        let (pixelCount, overflow) = expectedWidth.multipliedReportingOverflow(by: stitchedHeight)
        guard !overflow else { throw VerticalImageStitchingError.dimensionsOverflow }

        return StitchingPlan(
            layout: VerticalImageStitchingLayout(
                pixelWidth: expectedWidth,
                pixelHeight: stitchedHeight,
                scale: expectedScale,
                placements: placements
            ),
            pixelCount: pixelCount
        )
    }
}
