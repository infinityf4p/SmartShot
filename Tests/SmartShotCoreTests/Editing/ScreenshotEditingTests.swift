import CoreGraphics
import XCTest
@testable import SmartShotCore

final class ScreenshotEditingTests: XCTestCase {
    func testHistorySupportsUndoRedoAndReset() {
        var history = ScreenshotEditHistory()
        var edited = history.document
        edited.annotations.append(
            ScreenshotAnnotation(
                kind: .counter,
                start: NormalizedPoint(x: 0.5, y: 0.5),
                end: NormalizedPoint(x: 0.5, y: 0.5),
                counterValue: 1
            )
        )

        XCTAssertTrue(history.commit(edited))
        XCTAssertTrue(history.canUndo)
        XCTAssertFalse(history.canRedo)
        XCTAssertTrue(history.undo())
        XCTAssertTrue(history.document.annotations.isEmpty)
        XCTAssertTrue(history.canRedo)
        XCTAssertTrue(history.redo())
        XCTAssertEqual(history.document.annotations.count, 1)
        XCTAssertTrue(history.reset())
        XCTAssertEqual(history.document, ScreenshotEditDocument())
    }

    func testCropMapsLocalCoordinatesBackIntoOriginal() {
        let crop = NormalizedRect(minX: 0.2, minY: 0.1, maxX: 0.8, maxY: 0.9)

        let point = crop.pointInOriginal(fromLocal: NormalizedPoint(x: 0.5, y: 0.25))
        XCTAssertEqual(point.x, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(point.y, 0.3, accuracy: 0.000_001)

        let rect = crop.rectInOriginal(
            fromLocal: NormalizedRect(minX: 0.25, minY: 0.25, maxX: 0.75, maxY: 0.75)
        )
        XCTAssertEqual(rect.minX, 0.35, accuracy: 0.000_001)
        XCTAssertEqual(rect.minY, 0.3, accuracy: 0.000_001)
        XCTAssertEqual(rect.maxX, 0.65, accuracy: 0.000_001)
        XCTAssertEqual(rect.maxY, 0.7, accuracy: 0.000_001)
    }

    func testRendererCropsUsingTopLeftCoordinates() throws {
        let image = try makeRowsImageForEditing(
            width: 4,
            rows: [editingRed, editingGreen, editingBlue, editingYellow]
        )
        let result = try ScreenshotRenderer.render(
            original: image,
            logicalSize: CGSize(width: 4, height: 4),
            document: ScreenshotEditDocument(
                crop: NormalizedRect(minX: 0, minY: 0.25, maxX: 1, maxY: 0.75)
            )
        )

        XCTAssertEqual(result.image.width, 4)
        XCTAssertEqual(result.image.height, 2)
        XCTAssertEqual(result.logicalSize, CGSize(width: 4, height: 2))
        XCTAssertEqual(try editingRowColors(in: result.image), [editingGreen, editingBlue])
    }

    func testRendererDrawsRectangleAtExpectedTopLeftPosition() throws {
        let image = try makeSolidEditingImage(width: 40, height: 40, color: editingWhite)
        let annotation = ScreenshotAnnotation(
            kind: .rectangle,
            start: NormalizedPoint(x: 0.25, y: 0.25),
            end: NormalizedPoint(x: 0.75, y: 0.75),
            color: .red,
            lineWidthPoints: 2
        )
        let result = try ScreenshotRenderer.render(
            original: image,
            logicalSize: CGSize(width: 40, height: 40),
            document: ScreenshotEditDocument(annotations: [annotation])
        )
        let bytes = try normalizedBytes(of: result.image)

        let topBorder = editingPixel(bytes, width: 40, x: 20, y: 10)
        let untouched = editingPixel(bytes, width: 40, x: 20, y: 20)
        XCTAssertGreaterThan(topBorder.red, 200)
        XCTAssertLessThan(topBorder.green, 100)
        XCTAssertEqual(untouched, editingWhite)
    }

    func testRendererPixelatesMosaicRegion() throws {
        let image = try makeEditingCheckerboard(width: 24, height: 24)
        let annotation = ScreenshotAnnotation(
            kind: .mosaic,
            start: NormalizedPoint(x: 0, y: 0),
            end: NormalizedPoint(x: 1, y: 1)
        )
        let result = try ScreenshotRenderer.render(
            original: image,
            logicalSize: CGSize(width: 24, height: 24),
            document: ScreenshotEditDocument(annotations: [annotation])
        )
        let bytes = try normalizedBytes(of: result.image)

        let first = editingPixel(bytes, width: 24, x: 1, y: 1)
        let neighbor = editingPixel(bytes, width: 24, x: 6, y: 6)
        XCTAssertEqual(first, neighbor)
        XCTAssertGreaterThan(first.red, 60)
        XCTAssertLessThan(first.red, 200)
    }

    func testRendererDrawsArrowTextAndCounter() throws {
        let image = try makeSolidEditingImage(width: 160, height: 100, color: editingWhite)
        let result = try ScreenshotRenderer.render(
            original: image,
            logicalSize: CGSize(width: 160, height: 100),
            document: ScreenshotEditDocument(annotations: [
                ScreenshotAnnotation(
                    kind: .arrow,
                    start: NormalizedPoint(x: 0.05, y: 0.18),
                    end: NormalizedPoint(x: 0.30, y: 0.18),
                    color: .red,
                    lineWidthPoints: 3
                ),
                ScreenshotAnnotation(
                    kind: .text,
                    start: NormalizedPoint(x: 0.52, y: 0.10),
                    end: NormalizedPoint(x: 0.52, y: 0.10),
                    color: .black,
                    lineWidthPoints: 3,
                    text: "Note"
                ),
                ScreenshotAnnotation(
                    kind: .counter,
                    start: NormalizedPoint(x: 0.82, y: 0.55),
                    end: NormalizedPoint(x: 0.82, y: 0.55),
                    color: .blue,
                    lineWidthPoints: 3,
                    counterValue: 2
                ),
            ])
        )
        let bytes = try normalizedBytes(of: result.image)

        let arrowCenter = editingPixel(bytes, width: 160, x: 28, y: 18)
        XCTAssertGreaterThan(arrowCenter.red, 200)
        XCTAssertLessThan(arrowCenter.green, 100)

        let textInkCount = nonWhitePixelCount(
            bytes,
            width: 160,
            xRange: 80..<130,
            yRange: 8..<35
        )
        XCTAssertGreaterThan(textInkCount, 20)

        let counterCenter = editingPixel(bytes, width: 160, x: 131, y: 55)
        XCTAssertLessThan(counterCenter.red, 120)
        XCTAssertGreaterThan(counterCenter.blue, 150)
    }

    func testCounterSequenceUsesLargestExistingValue() {
        let document = ScreenshotEditDocument(annotations: [
            ScreenshotAnnotation(
                kind: .counter,
                start: NormalizedPoint(x: 0.2, y: 0.2),
                end: NormalizedPoint(x: 0.2, y: 0.2),
                counterValue: 2
            ),
            ScreenshotAnnotation(
                kind: .counter,
                start: NormalizedPoint(x: 0.4, y: 0.4),
                end: NormalizedPoint(x: 0.4, y: 0.4),
                counterValue: 7
            ),
        ])

        XCTAssertEqual(document.nextCounterValue, 8)
    }
}

private struct EditingColor: Equatable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
    let alpha: UInt8
}

private let editingRed = EditingColor(red: 255, green: 0, blue: 0, alpha: 255)
private let editingGreen = EditingColor(red: 0, green: 255, blue: 0, alpha: 255)
private let editingBlue = EditingColor(red: 0, green: 0, blue: 255, alpha: 255)
private let editingYellow = EditingColor(red: 255, green: 255, blue: 0, alpha: 255)
private let editingWhite = EditingColor(red: 255, green: 255, blue: 255, alpha: 255)
private let editingBlack = EditingColor(red: 0, green: 0, blue: 0, alpha: 255)

private func makeRowsImageForEditing(width: Int, rows: [EditingColor]) throws -> CGImage {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(width * rows.count * 4)
    for color in rows {
        for _ in 0..<width {
            bytes.append(contentsOf: [color.red, color.green, color.blue, color.alpha])
        }
    }
    return try makeTestImage(width: width, height: rows.count, bytes: bytes)
}

private func makeSolidEditingImage(width: Int, height: Int, color: EditingColor) throws -> CGImage {
    try makeRowsImageForEditing(width: width, rows: Array(repeating: color, count: height))
}

private func makeEditingCheckerboard(width: Int, height: Int) throws -> CGImage {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let color = (x + y).isMultiple(of: 2) ? editingWhite : editingBlack
            bytes.append(contentsOf: [color.red, color.green, color.blue, color.alpha])
        }
    }
    return try makeTestImage(width: width, height: height, bytes: bytes)
}

private func editingRowColors(in image: CGImage) throws -> [EditingColor] {
    let bytes = try normalizedBytes(of: image)
    return (0..<image.height).map { y in
        editingPixel(bytes, width: image.width, x: 0, y: y)
    }
}

private func editingPixel(_ bytes: [UInt8], width: Int, x: Int, y: Int) -> EditingColor {
    let offset = (y * width + x) * 4
    return EditingColor(
        red: bytes[offset],
        green: bytes[offset + 1],
        blue: bytes[offset + 2],
        alpha: bytes[offset + 3]
    )
}

private func nonWhitePixelCount(
    _ bytes: [UInt8],
    width: Int,
    xRange: Range<Int>,
    yRange: Range<Int>
) -> Int {
    var count = 0
    for y in yRange {
        for x in xRange where editingPixel(bytes, width: width, x: x, y: y) != editingWhite {
            count += 1
        }
    }
    return count
}
