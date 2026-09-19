import SmartShotCore
import CoreGraphics
import Foundation
import Vision

struct RecognizedTextBlock: Identifiable, Equatable, Sendable {
    let id: UUID
    let text: String
    let confidence: Float
    /// Unit coordinates in the original image, with the origin at the top-left.
    let normalizedBounds: CGRect

    init(
        id: UUID = UUID(),
        text: String,
        confidence: Float,
        normalizedBounds: CGRect
    ) {
        self.id = id
        self.text = text
        self.confidence = confidence
        self.normalizedBounds = normalizedBounds
    }
}

struct TextRecognitionConfiguration: Equatable, Sendable {
    var maximumTileWidthPixels = 4_096
    var maximumTileHeightPixels = 4_096
    var tileOverlapPixels = 192
    var maximumImagePixelCount = 64_000_000
    var maximumRecognizedBlocks = 2_000
    var minimumConfidence: Float = 0.1
    var recognitionLanguages: [String] = []
}

enum TextRecognitionError: LocalizedError, Equatable {
    case invalidImage
    case invalidConfiguration
    case imageTooLarge
    case tileCreationFailed
    case visionRequestFailed

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            L10n.text("The image cannot be recognized.")
        case .invalidConfiguration:
            L10n.text("The text recognition configuration is invalid.")
        case .imageTooLarge:
            L10n.text("The image is too large for text recognition.")
        case .tileCreationFailed:
            L10n.text("The image could not be divided for text recognition.")
        case .visionRequestFailed:
            L10n.text("Text recognition failed.")
        }
    }
}

struct TextRecognitionService: Sendable {
    let configuration: TextRecognitionConfiguration

    init(configuration: TextRecognitionConfiguration = TextRecognitionConfiguration()) {
        self.configuration = configuration
    }

    func recognizeText(in image: CGImage) async throws -> [RecognizedTextBlock] {
        try Task.checkCancellation()
        try validate(image: image)

        let imageSize = CGSize(width: image.width, height: image.height)
        let tileRects = TextRecognitionGeometry.tileRects(
            imageWidth: image.width,
            imageHeight: image.height,
            maximumTileWidth: configuration.maximumTileWidthPixels,
            maximumTileHeight: configuration.maximumTileHeightPixels,
            overlap: configuration.tileOverlapPixels
        )
        guard !tileRects.isEmpty else {
            throw TextRecognitionError.invalidConfiguration
        }

        var blocks: [RecognizedTextBlock] = []
        blocks.reserveCapacity(min(configuration.maximumRecognizedBlocks, tileRects.count * 24))

        for tileRect in tileRects {
            try Task.checkCancellation()
            guard let tileImage = image.cropping(to: tileRect) else {
                throw TextRecognitionError.tileCreationFailed
            }
            let tile = TextRecognitionImageTile(image: tileImage)
            let observations = try await recognize(tile: tile)
            for observation in observations {
                guard observation.confidence >= configuration.minimumConfidence,
                      let bounds = TextRecognitionGeometry.normalizedTopLeftRect(
                        visionBoundingBox: observation.boundingBox,
                        tilePixelRect: tileRect,
                        imagePixelSize: imageSize
                      ) else {
                    continue
                }
                blocks.append(
                    RecognizedTextBlock(
                        text: observation.text,
                        confidence: observation.confidence,
                        normalizedBounds: bounds
                    )
                )
            }
        }

        try Task.checkCancellation()
        return TextRecognitionPostProcessor.process(
            blocks,
            maximumCount: configuration.maximumRecognizedBlocks
        )
    }

    private func validate(image: CGImage) throws {
        guard image.width > 0, image.height > 0 else {
            throw TextRecognitionError.invalidImage
        }
        guard configuration.maximumTileWidthPixels > configuration.tileOverlapPixels,
              configuration.maximumTileHeightPixels > configuration.tileOverlapPixels,
              configuration.tileOverlapPixels >= 0,
              configuration.maximumImagePixelCount > 0,
              configuration.maximumRecognizedBlocks > 0,
              configuration.minimumConfidence.isFinite,
              (0...1).contains(configuration.minimumConfidence) else {
            throw TextRecognitionError.invalidConfiguration
        }
        let (pixelCount, overflow) = image.width.multipliedReportingOverflow(by: image.height)
        guard !overflow, pixelCount <= configuration.maximumImagePixelCount else {
            throw TextRecognitionError.imageTooLarge
        }
    }

    private func recognize(tile: TextRecognitionImageTile) async throws -> [VisionTextObservation] {
        let cancellation = VisionRequestCancellationState()
        let configuration = configuration
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = configuration.recognitionLanguages.isEmpty
            if !configuration.recognitionLanguages.isEmpty {
                request.recognitionLanguages = configuration.recognitionLanguages
            }

            guard cancellation.install(request) else {
                throw CancellationError()
            }
            defer { cancellation.clear(request) }

            do {
                let handler = VNImageRequestHandler(cgImage: tile.image, options: [:])
                try handler.perform([request])
                try Task.checkCancellation()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled || cancellation.isCancelled {
                    throw CancellationError()
                }
                throw TextRecognitionError.visionRequestFailed
            }

            let observations: [VisionTextObservation] = (request.results ?? []).compactMap {
                observation -> VisionTextObservation? in
                guard let candidate = observation.topCandidates(1).first else {
                    return nil
                }
                let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return VisionTextObservation(
                    text: text,
                    confidence: candidate.confidence,
                    boundingBox: observation.boundingBox
                )
            }
            return observations
        }

        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            cancellation.cancel()
            worker.cancel()
        }
    }
}

enum TextRecognitionGeometry {
    static func tileRects(
        imageWidth: Int,
        imageHeight: Int,
        maximumTileWidth: Int,
        maximumTileHeight: Int,
        overlap: Int
    ) -> [CGRect] {
        let horizontal = axisSegments(
            length: imageWidth,
            maximumLength: maximumTileWidth,
            overlap: overlap
        )
        let vertical = axisSegments(
            length: imageHeight,
            maximumLength: maximumTileHeight,
            overlap: overlap
        )
        guard !horizontal.isEmpty, !vertical.isEmpty else { return [] }

        return vertical.flatMap { yRange in
            horizontal.map { xRange in
                CGRect(
                    x: xRange.lowerBound,
                    y: yRange.lowerBound,
                    width: xRange.count,
                    height: yRange.count
                )
            }
        }
    }

    static func normalizedTopLeftRect(
        visionBoundingBox: CGRect,
        tilePixelRect: CGRect,
        imagePixelSize: CGSize
    ) -> CGRect? {
        guard imagePixelSize.width.isFinite,
              imagePixelSize.height.isFinite,
              imagePixelSize.width > 0,
              imagePixelSize.height > 0,
              tilePixelRect.isFiniteAndPositive,
              visionBoundingBox.isFiniteAndPositive else {
            return nil
        }

        let unitRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        let local = visionBoundingBox.standardized.intersection(unitRect)
        guard !local.isNull, !local.isEmpty else { return nil }

        // Vision uses bottom-left normalized coordinates. CGImage cropping and the editor
        // use top-left pixel coordinates, so the vertical axis is flipped within the tile.
        let globalPixels = CGRect(
            x: tilePixelRect.minX + local.minX * tilePixelRect.width,
            y: tilePixelRect.minY + (1 - local.maxY) * tilePixelRect.height,
            width: local.width * tilePixelRect.width,
            height: local.height * tilePixelRect.height
        )
        let normalized = CGRect(
            x: globalPixels.minX / imagePixelSize.width,
            y: globalPixels.minY / imagePixelSize.height,
            width: globalPixels.width / imagePixelSize.width,
            height: globalPixels.height / imagePixelSize.height
        ).intersection(unitRect)
        guard !normalized.isNull, !normalized.isEmpty else { return nil }
        return normalized
    }

    private static func axisSegments(
        length: Int,
        maximumLength: Int,
        overlap: Int
    ) -> [Range<Int>] {
        guard length > 0,
              maximumLength > overlap,
              overlap >= 0 else {
            return []
        }
        guard length > maximumLength else { return [0..<length] }

        let stride = maximumLength - overlap
        let segmentCount = Int(
            ceil(Double(length - overlap) / Double(stride))
        )
        let balancedLength = Int(
            ceil(Double(length + overlap * (segmentCount - 1)) / Double(segmentCount))
        )
        guard balancedLength <= maximumLength else { return [] }

        var segments: [Range<Int>] = []
        var lowerBound = 0
        for index in 0..<segmentCount {
            let upperBound = index == segmentCount - 1
                ? length
                : min(length, lowerBound + balancedLength)
            guard upperBound > lowerBound else { return [] }
            segments.append(lowerBound..<upperBound)
            lowerBound = upperBound - overlap
        }
        return segments
    }
}

enum TextRecognitionPostProcessor {
    static func process(
        _ blocks: [RecognizedTextBlock],
        maximumCount: Int,
        duplicateOverlapThreshold: CGFloat = 0.6
    ) -> [RecognizedTextBlock] {
        guard maximumCount > 0 else { return [] }
        let unique = deduplicated(
            blocks,
            overlapThreshold: duplicateOverlapThreshold
        )
        return Array(readingOrder(unique).prefix(maximumCount))
    }

    static func deduplicated(
        _ blocks: [RecognizedTextBlock],
        overlapThreshold: CGFloat = 0.6
    ) -> [RecognizedTextBlock] {
        var result: [RecognizedTextBlock] = []
        for block in blocks where block.normalizedBounds.isFiniteAndPositive {
            let comparisonText = normalizedText(block.text)
            guard !comparisonText.isEmpty else { continue }
            let duplicateIndices = result.indices.filter { index in
                normalizedText(result[index].text) == comparisonText
                    && overlapCoefficient(
                        block.normalizedBounds,
                        result[index].normalizedBounds
                    ) >= overlapThreshold
            }
            guard !duplicateIndices.isEmpty else {
                result.append(block)
                continue
            }

            var winner = block
            for index in duplicateIndices {
                winner = preferred(winner, result[index])
            }
            for index in duplicateIndices.reversed() {
                result.remove(at: index)
            }
            result.append(winner)
        }
        return result
    }

    static func readingOrder(_ blocks: [RecognizedTextBlock]) -> [RecognizedTextBlock] {
        let validBlocks = blocks
            .filter { $0.normalizedBounds.isFiniteAndPositive }
            .sorted(by: geometricOrder)
        var rows: [TextRecognitionRow] = []

        for block in validBlocks {
            if let rowIndex = rows.lastIndex(where: { $0.accepts(block.normalizedBounds) }) {
                rows[rowIndex].append(block)
            } else {
                rows.append(TextRecognitionRow(block: block))
            }
        }

        rows.sort {
            if $0.minY != $1.minY { return $0.minY < $1.minY }
            return $0.minX < $1.minX
        }
        return rows.flatMap { row in
            row.blocks.sorted {
                if $0.normalizedBounds.minX != $1.normalizedBounds.minX {
                    return $0.normalizedBounds.minX < $1.normalizedBounds.minX
                }
                return geometricOrder($0, $1)
            }
        }
    }

    private static func normalizedText(_ value: String) -> String {
        value
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
    }

    private static func overlapCoefficient(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        let smallerArea = min(lhs.width * lhs.height, rhs.width * rhs.height)
        guard smallerArea > 0 else { return 0 }
        return intersection.width * intersection.height / smallerArea
    }

    private static func preferred(
        _ lhs: RecognizedTextBlock,
        _ rhs: RecognizedTextBlock
    ) -> RecognizedTextBlock {
        if lhs.confidence != rhs.confidence {
            return lhs.confidence > rhs.confidence ? lhs : rhs
        }
        let lhsArea = lhs.normalizedBounds.width * lhs.normalizedBounds.height
        let rhsArea = rhs.normalizedBounds.width * rhs.normalizedBounds.height
        return lhsArea > rhsArea ? lhs : rhs
    }

    private static func geometricOrder(
        _ lhs: RecognizedTextBlock,
        _ rhs: RecognizedTextBlock
    ) -> Bool {
        if lhs.normalizedBounds.minY != rhs.normalizedBounds.minY {
            return lhs.normalizedBounds.minY < rhs.normalizedBounds.minY
        }
        if lhs.normalizedBounds.minX != rhs.normalizedBounds.minX {
            return lhs.normalizedBounds.minX < rhs.normalizedBounds.minX
        }
        return lhs.text < rhs.text
    }
}

enum SensitiveTextKind: String, CaseIterable, Equatable, Sendable {
    case email
    case phoneNumber
    case paymentCard
    case chineseNationalID
}

struct SensitiveTextMatch: Equatable, Sendable {
    let kind: SensitiveTextKind
    let value: String
    /// UTF-16 range so it can be applied directly to Foundation text APIs.
    let utf16Range: NSRange
}

enum SensitiveTextDetector {
    static func matches(in text: String) -> [SensitiveTextMatch] {
        guard !text.isEmpty else { return [] }
        var matches: [SensitiveTextMatch] = []

        appendRegexMatches(
            pattern: #"(?<![A-Z0-9._%+\-])[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,63}(?![A-Z0-9._%+\-])"#,
            options: [.caseInsensitive],
            kind: .email,
            text: text,
            accepting: { _ in true },
            into: &matches
        )
        appendRegexMatches(
            pattern: #"(?<![0-9A-Za-z])\d{17}[0-9Xx](?![0-9A-Za-z])"#,
            kind: .chineseNationalID,
            text: text,
            accepting: isValidChineseNationalID,
            into: &matches
        )
        appendRegexMatches(
            pattern: #"(?<!\d)(?:\d[ \-]?){12,18}\d(?!\d)"#,
            kind: .paymentCard,
            text: text,
            accepting: isValidPaymentCard,
            excludingOverlapsWith: matches.map(\.utf16Range),
            into: &matches
        )
        appendRegexMatches(
            pattern: #"(?<!\d)(?:\+\d{1,3}[\s.\-]?)?(?:\(?\d{2,4}\)?[\s.\-]?)?\d{3,4}[\s.\-]?\d{4}(?!\d)"#,
            kind: .phoneNumber,
            text: text,
            accepting: isPlausiblePhoneNumber,
            excludingOverlapsWith: matches.map(\.utf16Range),
            into: &matches
        )

        return matches.sorted {
            if $0.utf16Range.location != $1.utf16Range.location {
                return $0.utf16Range.location < $1.utf16Range.location
            }
            if $0.utf16Range.length != $1.utf16Range.length {
                return $0.utf16Range.length > $1.utf16Range.length
            }
            return $0.kind.rawValue < $1.kind.rawValue
        }
    }

    static func isValidPaymentCard(_ value: String) -> Bool {
        let digits = value.compactMap(\.wholeNumberValue)
        guard (13...19).contains(digits.count) else { return false }
        var total = 0
        for (index, digit) in digits.reversed().enumerated() {
            if index.isMultiple(of: 2) {
                total += digit
            } else {
                let doubled = digit * 2
                total += doubled > 9 ? doubled - 9 : doubled
            }
        }
        return total.isMultiple(of: 10)
    }

    static func isValidChineseNationalID(_ value: String) -> Bool {
        let characters = Array(value.uppercased())
        guard characters.count == 18,
              characters.prefix(17).allSatisfy({ $0.wholeNumberValue != nil }),
              characters[17].wholeNumberValue != nil || characters[17] == "X" else {
            return false
        }

        let region = characters.prefix(6).compactMap(\.wholeNumberValue)
        guard region.contains(where: { $0 != 0 }) else { return false }
        let dateDigits = characters[6..<14].compactMap(\.wholeNumberValue)
        guard dateDigits.count == 8 else { return false }
        let year = dateDigits[0] * 1_000 + dateDigits[1] * 100 + dateDigits[2] * 10 + dateDigits[3]
        let month = dateDigits[4] * 10 + dateDigits[5]
        let day = dateDigits[6] * 10 + dateDigits[7]
        guard (1800...2099).contains(year), isValidDate(year: year, month: month, day: day) else {
            return false
        }

        let weights = [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2]
        let checks: [Character] = ["1", "0", "X", "9", "8", "7", "6", "5", "4", "3", "2"]
        let sum = zip(characters.prefix(17), weights).reduce(0) { partial, pair in
            partial + (pair.0.wholeNumberValue ?? 0) * pair.1
        }
        return characters[17] == checks[sum % 11]
    }

    private static func isPlausiblePhoneNumber(_ value: String) -> Bool {
        let digitCount = value.compactMap(\.wholeNumberValue).count
        return (7...15).contains(digitCount)
    }

    private static func isValidDate(year: Int, month: Int, day: Int) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let components = DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day
        )
        guard let date = calendar.date(from: components) else { return false }
        let resolved = calendar.dateComponents([.year, .month, .day], from: date)
        return resolved.year == year && resolved.month == month && resolved.day == day
    }

    private static func appendRegexMatches(
        pattern: String,
        options: NSRegularExpression.Options = [],
        kind: SensitiveTextKind,
        text: String,
        accepting: (String) -> Bool,
        excludingOverlapsWith excludedRanges: [NSRange] = [],
        into output: inout [SensitiveTextMatch]
    ) {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else {
            return
        }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let nsText = text as NSString
        for result in expression.matches(in: text, range: fullRange) {
            guard !excludedRanges.contains(where: { NSIntersectionRange($0, result.range).length > 0 }) else {
                continue
            }
            let value = nsText.substring(with: result.range)
            guard accepting(value) else { continue }
            output.append(
                SensitiveTextMatch(kind: kind, value: value, utf16Range: result.range)
            )
        }
    }
}

private struct TextRecognitionImageTile: @unchecked Sendable {
    let image: CGImage
}

private struct VisionTextObservation: Equatable, Sendable {
    let text: String
    let confidence: Float
    let boundingBox: CGRect
}

private struct TextRecognitionRow {
    private(set) var blocks: [RecognizedTextBlock]
    private(set) var bounds: CGRect

    init(block: RecognizedTextBlock) {
        blocks = [block]
        bounds = block.normalizedBounds
    }

    var minX: CGFloat { bounds.minX }
    var minY: CGFloat { bounds.minY }

    mutating func append(_ block: RecognizedTextBlock) {
        blocks.append(block)
        bounds = bounds.union(block.normalizedBounds)
    }

    func accepts(_ candidate: CGRect) -> Bool {
        let overlap = max(0, min(bounds.maxY, candidate.maxY) - max(bounds.minY, candidate.minY))
        let smallerHeight = min(bounds.height, candidate.height)
        let centerTolerance = max(0.004, smallerHeight * 0.45)
        return (smallerHeight > 0 && overlap / smallerHeight >= 0.35)
            || abs(bounds.midY - candidate.midY) <= centerTolerance
    }
}

private final class VisionRequestCancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private var request: VNRequest?
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func install(_ request: VNRequest) -> Bool {
        lock.withLock {
            guard !cancelled else {
                request.cancel()
                return false
            }
            self.request = request
            return true
        }
    }

    func clear(_ request: VNRequest) {
        lock.withLock {
            if self.request === request {
                self.request = nil
            }
        }
    }

    func cancel() {
        let request = lock.withLock { () -> VNRequest? in
            cancelled = true
            return self.request
        }
        request?.cancel()
    }
}

private extension CGRect {
    var isFiniteAndPositive: Bool {
        minX.isFinite && minY.isFinite && width.isFinite && height.isFinite
            && width > 0 && height > 0
    }
}
