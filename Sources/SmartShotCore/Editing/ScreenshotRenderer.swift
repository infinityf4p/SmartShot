import CoreGraphics
import CoreText
import Foundation

public enum ScreenshotRenderingError: Error, Equatable, LocalizedError, Sendable {
    case invalidImage
    case invalidLogicalSize
    case emptyCrop
    case outputTooLarge
    case contextCreationFailed
    case imageCreationFailed

    public var errorDescription: String? {
        switch self {
        case .invalidImage:
            L10n.text("The screenshot image is invalid.")
        case .invalidLogicalSize:
            L10n.text("The screenshot size is invalid.")
        case .emptyCrop:
            L10n.text("The crop area is empty.")
        case .outputTooLarge:
            L10n.text("The edited screenshot is too large to render safely.")
        case .contextCreationFailed:
            L10n.text("The screenshot editor could not create a drawing surface.")
        case .imageCreationFailed:
            L10n.text("The screenshot editor could not create the edited image.")
        }
    }
}

public struct ScreenshotRenderResult {
    public let image: CGImage
    public let logicalSize: CGSize
    public let cropPixelRect: CGRect

    public init(image: CGImage, logicalSize: CGSize, cropPixelRect: CGRect) {
        self.image = image
        self.logicalSize = logicalSize
        self.cropPixelRect = cropPixelRect
    }
}

public enum ScreenshotRenderer {
    public static func render(
        original: CGImage,
        logicalSize: CGSize,
        document: ScreenshotEditDocument,
        maximumDimensionPixels: Int? = nil,
        maximumPixelCount: Int = 50_000_000
    ) throws -> ScreenshotRenderResult {
        guard original.width > 0, original.height > 0 else {
            throw ScreenshotRenderingError.invalidImage
        }
        guard logicalSize.width.isFinite, logicalSize.height.isFinite,
              logicalSize.width > 0, logicalSize.height > 0 else {
            throw ScreenshotRenderingError.invalidLogicalSize
        }
        guard maximumPixelCount > 0 else { throw ScreenshotRenderingError.outputTooLarge }

        let crop = cropPixelRect(
            document.crop,
            imageWidth: original.width,
            imageHeight: original.height
        )
        guard crop.width >= 1, crop.height >= 1,
              let cropped = original.cropping(to: crop) else {
            throw ScreenshotRenderingError.emptyCrop
        }

        let requestedLimit = maximumDimensionPixels.map { max(1, $0) }
        let dimensionScale: Double
        if let requestedLimit {
            dimensionScale = min(
                1,
                Double(requestedLimit) / Double(max(cropped.width, cropped.height))
            )
        } else {
            dimensionScale = 1
        }
        let outputWidth = max(1, Int((Double(cropped.width) * dimensionScale).rounded()))
        let outputHeight = max(1, Int((Double(cropped.height) * dimensionScale).rounded()))
        let (pixelCount, overflow) = outputWidth.multipliedReportingOverflow(by: outputHeight)
        guard !overflow, pixelCount <= maximumPixelCount else {
            throw ScreenshotRenderingError.outputTooLarge
        }

        let originalPixelsPerPointX = Double(original.width) / logicalSize.width
        let originalPixelsPerPointY = Double(original.height) / logicalSize.height
        let outputLogicalSize = CGSize(
            width: Double(cropped.width) / originalPixelsPerPointX,
            height: Double(cropped.height) / originalPixelsPerPointY
        )
        var bitmap = try makeScaledBitmap(
            image: cropped,
            width: outputWidth,
            height: outputHeight
        )
        let mapping = CoordinateMapping(
            originalWidth: original.width,
            originalHeight: original.height,
            crop: crop,
            outputWidth: outputWidth,
            outputHeight: outputHeight,
            logicalSize: outputLogicalSize
        )

        for annotation in document.annotations where annotation.kind == .redaction {
            redact(bitmap: &bitmap, rect: mapping.rect(from: annotation))
        }
        for annotation in document.annotations where annotation.kind == .mosaic {
            pixelate(
                bitmap: &bitmap,
                rect: mapping.rect(from: annotation),
                pixelsPerPoint: mapping.pixelsPerPoint
            )
        }
        for annotation in document.annotations where annotation.kind == .blur {
            blur(
                bitmap: &bitmap,
                rect: mapping.rect(from: annotation),
                pixelsPerPoint: mapping.pixelsPerPoint
            )
        }

        let privacySafePixels = bitmap.bytes
        let spotlights = document.annotations.filter { $0.kind == .spotlight }
        if !spotlights.isEmpty {
            dimOutside(
                bitmap: &bitmap,
                focusRects: spotlights.map(mapping.rect(from:))
            )
        }
        for annotation in document.annotations where annotation.kind == .magnifier {
            magnify(
                bitmap: &bitmap,
                sourcePixels: privacySafePixels,
                annotation: annotation,
                mapping: mapping
            )
        }

        try drawVectorAnnotations(
            document.annotations.filter {
                ![.mosaic, .blur, .redaction, .spotlight].contains($0.kind)
            },
            bitmap: &bitmap,
            mapping: mapping
        )
        guard let image = bitmap.makeImage() else {
            throw ScreenshotRenderingError.imageCreationFailed
        }
        return ScreenshotRenderResult(
            image: image,
            logicalSize: outputLogicalSize,
            cropPixelRect: crop
        )
    }
}

private extension ScreenshotRenderer {
    struct CoordinateMapping {
        let originalWidth: Int
        let originalHeight: Int
        let crop: CGRect
        let outputWidth: Int
        let outputHeight: Int
        let logicalSize: CGSize

        var scaleX: Double { Double(outputWidth) / crop.width }
        var scaleY: Double { Double(outputHeight) / crop.height }
        var pixelsPerPoint: Double {
            (Double(outputWidth) / logicalSize.width + Double(outputHeight) / logicalSize.height) / 2
        }

        func point(_ point: NormalizedPoint) -> CGPoint {
            CGPoint(
                x: (point.x * Double(originalWidth) - crop.minX) * scaleX,
                y: (point.y * Double(originalHeight) - crop.minY) * scaleY
            )
        }

        func rect(from annotation: ScreenshotAnnotation) -> CGRect {
            let first = point(annotation.start)
            let second = point(annotation.end)
            return CGRect(
                x: min(first.x, second.x),
                y: min(first.y, second.y),
                width: abs(first.x - second.x),
                height: abs(first.y - second.y)
            )
        }

        func points(from annotation: ScreenshotAnnotation) -> [CGPoint] {
            (annotation.points.isEmpty ? [annotation.start, annotation.end] : annotation.points)
                .map(point)
        }
    }

    static func cropPixelRect(
        _ crop: NormalizedRect,
        imageWidth: Int,
        imageHeight: Int
    ) -> CGRect {
        let minX = max(0, min(imageWidth, Int(floor(crop.minX * Double(imageWidth)))))
        let minY = max(0, min(imageHeight, Int(floor(crop.minY * Double(imageHeight)))))
        let maxX = max(minX, min(imageWidth, Int(ceil(crop.maxX * Double(imageWidth)))))
        let maxY = max(minY, min(imageHeight, Int(ceil(crop.maxY * Double(imageHeight)))))
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    static func makeScaledBitmap(image: CGImage, width: Int, height: Int) throws -> RGBA8Image {
        let byteCount = try checkedByteCount(width: width, height: height)
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let baseAddress = buffer.baseAddress,
                  let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                      data: baseAddress,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: width * RGBA8Image.bytesPerPixel,
                      space: colorSpace,
                      bitmapInfo: bitmapInfo.rawValue
                  ) else {
                return false
            }
            context.setBlendMode(.copy)
            context.interpolationQuality = width < image.width || height < image.height ? .high : .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { throw ScreenshotRenderingError.contextCreationFailed }
        return RGBA8Image(width: width, height: height, bytes: bytes)
    }

    static func drawVectorAnnotations(
        _ annotations: [ScreenshotAnnotation],
        bitmap: inout RGBA8Image,
        mapping: CoordinateMapping
    ) throws {
        let rendered = bitmap.bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let baseAddress = buffer.baseAddress,
                  let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                      data: baseAddress,
                      width: bitmap.width,
                      height: bitmap.height,
                      bitsPerComponent: 8,
                      bytesPerRow: bitmap.width * RGBA8Image.bytesPerPixel,
                      space: colorSpace,
                      bitmapInfo: bitmapInfo.rawValue
                  ) else {
                return false
            }
            context.translateBy(x: 0, y: CGFloat(bitmap.height))
            context.scaleBy(x: 1, y: -1)
            context.clip(to: CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height))

            for annotation in annotations {
                context.saveGState()
                context.setStrokeColor(annotation.color.cgColor)
                context.setFillColor(annotation.color.cgColor)
                let lineWidth = max(1, annotation.lineWidthPoints * mapping.pixelsPerPoint)
                context.setLineWidth(lineWidth)
                context.setLineCap(.round)
                context.setLineJoin(.round)
                switch annotation.kind {
                case .freehand:
                    drawFreehand(annotation, context: context, mapping: mapping)
                case .rectangle:
                    context.stroke(mapping.rect(from: annotation))
                case .ellipse:
                    context.strokeEllipse(in: mapping.rect(from: annotation))
                case .arrow:
                    drawArrow(
                        annotation,
                        context: context,
                        mapping: mapping,
                        lineWidth: lineWidth
                    )
                case .text:
                    drawText(annotation, context: context, mapping: mapping)
                case .counter:
                    drawCounter(
                        annotation,
                        context: context,
                        mapping: mapping,
                        lineWidth: lineWidth
                    )
                case .magnifier:
                    let center = mapping.point(annotation.end)
                    let radius = magnifierRadius(
                        lineWidth: lineWidth,
                        pixelsPerPoint: mapping.pixelsPerPoint
                    )
                    context.setStrokeColor(ScreenshotColor.white.cgColor)
                    context.setLineWidth(max(2, mapping.pixelsPerPoint * 2))
                    context.strokeEllipse(in: CGRect(
                        x: center.x - radius,
                        y: center.y - radius,
                        width: radius * 2,
                        height: radius * 2
                    ))
                    context.setStrokeColor(ScreenshotColor.black.cgColor)
                    context.setLineWidth(max(1, mapping.pixelsPerPoint))
                    context.strokeEllipse(in: CGRect(
                        x: center.x - radius + mapping.pixelsPerPoint,
                        y: center.y - radius + mapping.pixelsPerPoint,
                        width: radius * 2 - mapping.pixelsPerPoint * 2,
                        height: radius * 2 - mapping.pixelsPerPoint * 2
                    ))
                case .mosaic, .blur, .redaction, .spotlight:
                    break
                }
                context.restoreGState()
            }
            return true
        }
        guard rendered else { throw ScreenshotRenderingError.contextCreationFailed }
    }

    static func drawArrow(
        _ annotation: ScreenshotAnnotation,
        context: CGContext,
        mapping: CoordinateMapping,
        lineWidth: Double
    ) {
        let start = mapping.point(annotation.start)
        let end = mapping.point(annotation.end)
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length >= 1 else { return }

        context.move(to: start)
        context.addLine(to: end)
        context.strokePath()

        let unitX = dx / length
        let unitY = dy / length
        let headLength = max(8 * mapping.pixelsPerPoint, lineWidth * 4)
        let wing = headLength * 0.52
        let base = CGPoint(x: end.x - unitX * headLength, y: end.y - unitY * headLength)
        let perpendicular = CGPoint(x: -unitY * wing, y: unitX * wing)
        context.move(to: end)
        context.addLine(to: CGPoint(x: base.x + perpendicular.x, y: base.y + perpendicular.y))
        context.move(to: end)
        context.addLine(to: CGPoint(x: base.x - perpendicular.x, y: base.y - perpendicular.y))
        context.strokePath()
    }

    static func drawFreehand(
        _ annotation: ScreenshotAnnotation,
        context: CGContext,
        mapping: CoordinateMapping
    ) {
        let points = mapping.points(from: annotation)
        guard let first = points.first, points.count > 1 else { return }
        context.move(to: first)
        for point in points.dropFirst() {
            context.addLine(to: point)
        }
        context.strokePath()
    }

    static func drawText(
        _ annotation: ScreenshotAnnotation,
        context: CGContext,
        mapping: CoordinateMapping
    ) {
        guard let text = annotation.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return }
        let fontSize = max(13, annotation.lineWidthPoints * 5) * mapping.pixelsPerPoint
        let line = makeTextLine(
            text,
            fontSize: fontSize,
            foregroundColor: annotation.color.cgColor,
            fontName: "HelveticaNeue-Medium"
        )
        let point = mapping.point(annotation.start)
        drawTextLine(line, at: point, fontSize: fontSize, context: context)
    }

    static func drawCounter(
        _ annotation: ScreenshotAnnotation,
        context: CGContext,
        mapping: CoordinateMapping,
        lineWidth: Double
    ) {
        guard let value = annotation.counterValue else { return }
        let center = mapping.point(annotation.start)
        let diameter = max(22 * mapping.pixelsPerPoint, lineWidth * 5)
        let circle = CGRect(
            x: center.x - diameter / 2,
            y: center.y - diameter / 2,
            width: diameter,
            height: diameter
        )
        context.fillEllipse(in: circle)

        let fontSize = diameter * 0.54
        let line = makeTextLine(
            String(value),
            fontSize: fontSize,
            foregroundColor: ScreenshotColor.white.cgColor,
            fontName: "HelveticaNeue-Bold"
        )
        let bounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
        let origin = CGPoint(
            x: center.x - bounds.width / 2 - bounds.minX,
            y: center.y - fontSize * 0.48
        )
        drawTextLine(line, at: origin, fontSize: fontSize, context: context)
    }

    static func makeTextLine(
        _ text: String,
        fontSize: Double,
        foregroundColor: CGColor,
        fontName: String
    ) -> CTLine {
        let font = CTFontCreateWithName(fontName as CFString, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): foregroundColor,
        ]
        return CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: attributes)
        )
    }

    static func drawTextLine(
        _ line: CTLine,
        at point: CGPoint,
        fontSize: Double,
        context: CGContext
    ) {
        context.saveGState()
        context.translateBy(x: point.x, y: point.y + fontSize)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }

    static func pixelate(bitmap: inout RGBA8Image, rect: CGRect, pixelsPerPoint: Double) {
        let clipped = rect.standardized.intersection(
            CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height)
        )
        guard clipped.width >= 2, clipped.height >= 2 else { return }
        let minX = max(0, Int(floor(clipped.minX)))
        let minY = max(0, Int(floor(clipped.minY)))
        let maxX = min(bitmap.width, Int(ceil(clipped.maxX)))
        let maxY = min(bitmap.height, Int(ceil(clipped.maxY)))
        let blockSize = max(6, Int((8 * pixelsPerPoint).rounded()))

        for blockY in stride(from: minY, to: maxY, by: blockSize) {
            for blockX in stride(from: minX, to: maxX, by: blockSize) {
                let endX = min(maxX, blockX + blockSize)
                let endY = min(maxY, blockY + blockSize)
                var totals = [UInt64](repeating: 0, count: 4)
                var count: UInt64 = 0
                for y in blockY..<endY {
                    for x in blockX..<endX {
                        let offset = bitmap.byteOffset(x: x, y: y)
                        for component in 0..<4 {
                            totals[component] += UInt64(bitmap.bytes[offset + component])
                        }
                        count += 1
                    }
                }
                guard count > 0 else { continue }
                let average = totals.map { UInt8(clamping: Int($0 / count)) }
                for y in blockY..<endY {
                    for x in blockX..<endX {
                        let offset = bitmap.byteOffset(x: x, y: y)
                        for component in 0..<4 {
                            bitmap.bytes[offset + component] = average[component]
                        }
                    }
                }
            }
        }
    }

    static func redact(bitmap: inout RGBA8Image, rect: CGRect) {
        guard let bounds = integerBounds(for: rect, in: bitmap) else { return }
        let color: [UInt8] = [15, 15, 18, 255]
        for y in bounds.minY..<bounds.maxY {
            for x in bounds.minX..<bounds.maxX {
                let offset = bitmap.byteOffset(x: x, y: y)
                bitmap.bytes.replaceSubrange(offset..<(offset + 4), with: color)
            }
        }
    }

    static func blur(bitmap: inout RGBA8Image, rect: CGRect, pixelsPerPoint: Double) {
        guard let bounds = integerBounds(for: rect, in: bitmap) else { return }
        let radius = max(2, min(24, Int((5 * pixelsPerPoint).rounded())))
        let width = bounds.maxX - bounds.minX
        let height = bounds.maxY - bounds.minY
        guard width > 1, height > 1 else { return }

        var line = [UInt8](repeating: 0, count: max(width, height) * 4)
        for y in bounds.minY..<bounds.maxY {
            for index in 0..<width {
                let source = bitmap.byteOffset(x: bounds.minX + index, y: y)
                line.replaceSubrange((index * 4)..<(index * 4 + 4), with: bitmap.bytes[source..<(source + 4)])
            }
            boxBlurLine(&line, count: width, radius: radius) { index, component, value in
                bitmap.bytes[bitmap.byteOffset(x: bounds.minX + index, y: y) + component] = value
            }
        }
        for x in bounds.minX..<bounds.maxX {
            for index in 0..<height {
                let source = bitmap.byteOffset(x: x, y: bounds.minY + index)
                line.replaceSubrange((index * 4)..<(index * 4 + 4), with: bitmap.bytes[source..<(source + 4)])
            }
            boxBlurLine(&line, count: height, radius: radius) { index, component, value in
                bitmap.bytes[bitmap.byteOffset(x: x, y: bounds.minY + index) + component] = value
            }
        }
    }

    static func boxBlurLine(
        _ source: inout [UInt8],
        count: Int,
        radius: Int,
        write: (_ index: Int, _ component: Int, _ value: UInt8) -> Void
    ) {
        guard count > 0 else { return }
        for component in 0..<3 {
            var sum = 0
            var lower = 0
            var upper = min(count - 1, radius)
            for index in lower...upper { sum += Int(source[index * 4 + component]) }
            for index in 0..<count {
                let sampleCount = upper - lower + 1
                write(index, component, UInt8(clamping: sum / sampleCount))
                let nextLower = max(0, index + 1 - radius)
                let nextUpper = min(count - 1, index + 1 + radius)
                while lower < nextLower {
                    sum -= Int(source[lower * 4 + component])
                    lower += 1
                }
                while upper < nextUpper {
                    upper += 1
                    sum += Int(source[upper * 4 + component])
                }
            }
        }
    }

    static func dimOutside(bitmap: inout RGBA8Image, focusRects: [CGRect]) {
        let clipped = focusRects.map {
            $0.standardized.intersection(CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height))
        }.filter { !$0.isNull && !$0.isEmpty }
        guard !clipped.isEmpty else { return }
        for y in 0..<bitmap.height {
            for x in 0..<bitmap.width where !clipped.contains(where: { $0.contains(CGPoint(x: x, y: y)) }) {
                let offset = bitmap.byteOffset(x: x, y: y)
                for component in 0..<3 {
                    bitmap.bytes[offset + component] = UInt8(
                        (Double(bitmap.bytes[offset + component]) * 0.30).rounded()
                    )
                }
            }
        }
    }

    static func magnify(
        bitmap: inout RGBA8Image,
        sourcePixels: [UInt8],
        annotation: ScreenshotAnnotation,
        mapping: CoordinateMapping
    ) {
        let sourceCenter = mapping.point(annotation.start)
        let lensCenter = mapping.point(annotation.end)
        let radius = magnifierRadius(
            lineWidth: annotation.lineWidthPoints * mapping.pixelsPerPoint,
            pixelsPerPoint: mapping.pixelsPerPoint
        )
        let minX = max(0, Int(floor(lensCenter.x - radius)))
        let maxX = min(bitmap.width, Int(ceil(lensCenter.x + radius)))
        let minY = max(0, Int(floor(lensCenter.y - radius)))
        let maxY = min(bitmap.height, Int(ceil(lensCenter.y + radius)))
        let radiusSquared = radius * radius
        for y in minY..<maxY {
            for x in minX..<maxX {
                let dx = Double(x) + 0.5 - lensCenter.x
                let dy = Double(y) + 0.5 - lensCenter.y
                guard dx * dx + dy * dy <= radiusSquared else { continue }
                let sourceX = min(bitmap.width - 1, max(0, Int((sourceCenter.x + dx / annotation.magnification).rounded())))
                let sourceY = min(bitmap.height - 1, max(0, Int((sourceCenter.y + dy / annotation.magnification).rounded())))
                let sourceOffset = bitmap.byteOffset(x: sourceX, y: sourceY)
                let destinationOffset = bitmap.byteOffset(x: x, y: y)
                bitmap.bytes.replaceSubrange(
                    destinationOffset..<(destinationOffset + 4),
                    with: sourcePixels[sourceOffset..<(sourceOffset + 4)]
                )
            }
        }
    }

    static func magnifierRadius(lineWidth: Double, pixelsPerPoint: Double) -> Double {
        max(28 * pixelsPerPoint, lineWidth * 10)
    }

    static func integerBounds(for rect: CGRect, in bitmap: RGBA8Image) -> (minX: Int, minY: Int, maxX: Int, maxY: Int)? {
        let clipped = rect.standardized.intersection(
            CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height)
        )
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else { return nil }
        let minX = max(0, Int(floor(clipped.minX)))
        let minY = max(0, Int(floor(clipped.minY)))
        let maxX = min(bitmap.width, Int(ceil(clipped.maxX)))
        let maxY = min(bitmap.height, Int(ceil(clipped.maxY)))
        return minX < maxX && minY < maxY ? (minX, minY, maxX, maxY) : nil
    }

    static func checkedByteCount(width: Int, height: Int) throws -> Int {
        let (pixelCount, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        let (byteCount, byteOverflow) = pixelCount.multipliedReportingOverflow(
            by: RGBA8Image.bytesPerPixel
        )
        guard !pixelOverflow, !byteOverflow else {
            throw ScreenshotRenderingError.outputTooLarge
        }
        return byteCount
    }

    static let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
        CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
    )
}

private extension ScreenshotColor {
    var cgColor: CGColor {
        CGColor(
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            components: [red, green, blue, alpha]
        )!
    }
}
