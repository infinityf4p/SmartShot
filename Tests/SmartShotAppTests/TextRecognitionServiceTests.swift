import CoreGraphics
import XCTest

final class TextRecognitionServiceTests: XCTestCase {
    func testVisionCoordinatesAreMappedFromTileToOriginalTopLeftCoordinates() throws {
        let mapped = try XCTUnwrap(
            TextRecognitionGeometry.normalizedTopLeftRect(
                visionBoundingBox: CGRect(x: 0.25, y: 0.2, width: 0.5, height: 0.3),
                tilePixelRect: CGRect(x: 100, y: 500, width: 400, height: 800),
                imagePixelSize: CGSize(width: 1_000, height: 2_000)
            )
        )

        XCTAssertEqual(mapped.minX, 0.2, accuracy: 0.000_001)
        XCTAssertEqual(mapped.minY, 0.45, accuracy: 0.000_001)
        XCTAssertEqual(mapped.width, 0.2, accuracy: 0.000_001)
        XCTAssertEqual(mapped.height, 0.12, accuracy: 0.000_001)
    }

    func testVisionCoordinatesAreClippedToTheTileAndOriginalImage() throws {
        let mapped = try XCTUnwrap(
            TextRecognitionGeometry.normalizedTopLeftRect(
                visionBoundingBox: CGRect(x: -0.1, y: 0.9, width: 0.3, height: 0.2),
                tilePixelRect: CGRect(x: 0, y: 0, width: 100, height: 100),
                imagePixelSize: CGSize(width: 100, height: 100)
            )
        )

        XCTAssertEqual(mapped.minX, 0, accuracy: 0.000_001)
        XCTAssertEqual(mapped.minY, 0, accuracy: 0.000_001)
        XCTAssertEqual(mapped.width, 0.2, accuracy: 0.000_001)
        XCTAssertEqual(mapped.height, 0.1, accuracy: 0.000_001)
    }

    func testLongImageTilesAreBalancedBoundedAndOverlapping() {
        let tiles = TextRecognitionGeometry.tileRects(
            imageWidth: 1_000,
            imageHeight: 10_000,
            maximumTileWidth: 4_096,
            maximumTileHeight: 4_096,
            overlap: 192
        )

        XCTAssertEqual(tiles.count, 3)
        XCTAssertEqual(tiles.first?.minY, 0)
        XCTAssertEqual(tiles.last?.maxY, 10_000)
        XCTAssertTrue(tiles.allSatisfy { $0.width <= 4_096 && $0.height <= 4_096 })
        for (previous, current) in zip(tiles, tiles.dropFirst()) {
            XCTAssertEqual(previous.maxY - current.minY, 192)
        }
    }

    func testWideAndLongImageCreatesACompleteTileGrid() {
        let tiles = TextRecognitionGeometry.tileRects(
            imageWidth: 8_000,
            imageHeight: 10_000,
            maximumTileWidth: 4_096,
            maximumTileHeight: 4_096,
            overlap: 192
        )

        XCTAssertEqual(tiles.count, 6)
        XCTAssertEqual(Set(tiles.map(\.minX)), Set([0, 3_904]))
        XCTAssertEqual(tiles.map(\.maxX).max(), 8_000)
        XCTAssertEqual(tiles.map(\.maxY).max(), 10_000)
    }

    func testReadingOrderIsTopToBottomThenLeftToRightWithinRows() {
        let topRight = block("top-right", x: 0.6, y: 0.105)
        let bottom = block("bottom", x: 0.1, y: 0.5)
        let topLeft = block("top-left", x: 0.1, y: 0.1)

        let sorted = TextRecognitionPostProcessor.readingOrder([
            topRight,
            bottom,
            topLeft,
        ])

        XCTAssertEqual(sorted.map(\.text), ["top-left", "top-right", "bottom"])
    }

    func testDeduplicationNormalizesTextAndKeepsTheBestOverlappingObservation() {
        let lowerConfidence = block(
            "Account   123",
            x: 0.1,
            y: 0.2,
            width: 0.4,
            confidence: 0.65
        )
        let higherConfidence = block(
            "account 123",
            x: 0.11,
            y: 0.205,
            width: 0.39,
            confidence: 0.94
        )
        let legitimateRepeat = block(
            "Account 123",
            x: 0.1,
            y: 0.7,
            width: 0.4,
            confidence: 0.8
        )

        let result = TextRecognitionPostProcessor.process(
            [lowerConfidence, legitimateRepeat, higherConfidence],
            maximumCount: 10
        )

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.first?.id, higherConfidence.id)
        XCTAssertEqual(result.last?.id, legitimateRepeat.id)
    }

    func testSensitiveDetectorFindsEmailPhoneCardAndChineseID() {
        let text = "mail alice@example.com, phone +86 138-0013-8000, card 4111 1111 1111 1111, id 11010519491231002X"
        let matches = SensitiveTextDetector.matches(in: text)

        XCTAssertEqual(
            Set(matches.map(\.kind)),
            Set([.email, .phoneNumber, .paymentCard, .chineseNationalID])
        )
        let nsText = text as NSString
        XCTAssertTrue(matches.allSatisfy {
            nsText.substring(with: $0.utf16Range) == $0.value
        })
    }

    func testSensitiveDetectorRejectsInvalidChecksumsAndDates() {
        let text = "card 4111 1111 1111 1112, ids 110105194912310021 and 11010519990230002X"
        let matches = SensitiveTextDetector.matches(in: text)

        XCTAssertFalse(matches.contains { $0.kind == .paymentCard })
        XCTAssertFalse(matches.contains { $0.kind == .chineseNationalID })
    }

    func testPaymentCardValidationUsesLuhnAndAcceptsSeparators() {
        XCTAssertTrue(SensitiveTextDetector.isValidPaymentCard("4111-1111-1111-1111"))
        XCTAssertFalse(SensitiveTextDetector.isValidPaymentCard("4111-1111-1111-1112"))
        XCTAssertFalse(SensitiveTextDetector.isValidPaymentCard("1234567"))
    }

    func testChineseNationalIDValidationChecksDateAndChecksum() {
        XCTAssertTrue(SensitiveTextDetector.isValidChineseNationalID("11010519491231002X"))
        XCTAssertTrue(SensitiveTextDetector.isValidChineseNationalID("11010519491231002x"))
        XCTAssertFalse(SensitiveTextDetector.isValidChineseNationalID("11010519490230002X"))
        XCTAssertFalse(SensitiveTextDetector.isValidChineseNationalID("110105194912310021"))
    }

    func testAlreadyCancelledRecognitionDoesNotStartVisionWork() async throws {
        let image = try makeImage(width: 8, height: 8)
        let task = Task {
            try await TextRecognitionService().recognizeText(in: image)
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
    }

    private func block(
        _ text: String,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat = 0.2,
        height: CGFloat = 0.05,
        confidence: Float = 0.9
    ) -> RecognizedTextBlock {
        RecognizedTextBlock(
            text: text,
            confidence: confidence,
            normalizedBounds: CGRect(x: x, y: y, width: width, height: height)
        )
    }

    private func makeImage(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }
}
