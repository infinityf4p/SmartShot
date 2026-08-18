import AppKit
import CoreGraphics
import XCTest
@testable import SmartShotCore

final class VerticalImageStitcherTests: XCTestCase {
    func testStitchesTwoAdjacentFragmentsAndEncodesPNG() throws {
        let first = try makeRowsImage(width: 4, rows: [red, green, blue])
        let second = try makeRowsImage(width: 4, rows: [yellow, cyan])

        let result = try VerticalImageStitcher.stitch([
            VerticalCaptureFragment(image: first, verticalOffset: 0, scale: 1),
            VerticalCaptureFragment(image: second, verticalOffset: 3, scale: 1),
        ])

        XCTAssertEqual(result.layout.pixelWidth, 4)
        XCTAssertEqual(result.layout.pixelHeight, 5)
        XCTAssertEqual(result.layout.logicalSize, CGSize(width: 4, height: 5))
        XCTAssertEqual(try rowColors(in: result.image), [red, green, blue, yellow, cyan])
        let png = try XCTUnwrap(NSBitmapImageRep(data: result.pngData))
        XCTAssertEqual(png.pixelsWide, 4)
        XCTAssertEqual(png.pixelsHigh, 5)
    }

    func testCropsOverlapFromTopOfLaterFragment() throws {
        let first = try makeRowsImage(width: 3, rows: [red, green, blue, yellow])
        let second = try makeRowsImage(width: 3, rows: [blue, yellow, cyan, magenta])

        let result = try VerticalImageStitcher.stitch([
            VerticalCaptureFragment(image: first, verticalOffset: 0, scale: 1),
            VerticalCaptureFragment(image: second, verticalOffset: 2, scale: 1),
        ])

        XCTAssertEqual(result.layout.pixelHeight, 6)
        XCTAssertEqual(
            result.layout.placements[1],
            VerticalImagePlacement(
                fragmentIndex: 1,
                sourceRect: CGRect(x: 0, y: 2, width: 3, height: 2),
                destinationY: 4
            )
        )
        XCTAssertEqual(
            try rowColors(in: result.image),
            [red, green, blue, yellow, cyan, magenta]
        )
    }

    func testRejectsDifferentWidths() throws {
        let first = try makeRowsImage(width: 3, rows: [red, green])
        let second = try makeRowsImage(width: 4, rows: [blue, yellow])

        assertStitchingError(
            .widthMismatch(fragmentIndex: 1, expected: 3, actual: 4)
        ) {
            try VerticalImageStitcher.layout(for: [
                VerticalCaptureFragment(image: first, verticalOffset: 0, scale: 1),
                VerticalCaptureFragment(image: second, verticalOffset: 2, scale: 1),
            ])
        }
    }

    func testRejectsDifferentScales() throws {
        let first = try makeRowsImage(width: 3, rows: [red, green])
        let second = try makeRowsImage(width: 3, rows: [blue, yellow])

        assertStitchingError(
            .scaleMismatch(fragmentIndex: 1, expected: 2, actual: 1)
        ) {
            try VerticalImageStitcher.layout(for: [
                VerticalCaptureFragment(image: first, verticalOffset: 0, scale: 2),
                VerticalCaptureFragment(image: second, verticalOffset: 1, scale: 1),
            ])
        }
    }

    func testRejectsPixelCountAboveLimit() throws {
        let first = try makeRowsImage(width: 4, rows: [red, green, blue])
        let second = try makeRowsImage(width: 4, rows: [yellow, cyan])

        assertStitchingError(.pixelLimitExceeded(pixelCount: 20, maximum: 19)) {
            try VerticalImageStitcher.layout(
                for: [
                    VerticalCaptureFragment(image: first, verticalOffset: 0, scale: 1),
                    VerticalCaptureFragment(image: second, verticalOffset: 3, scale: 1),
                ],
                limits: VerticalImageStitchingLimits(maximumPixelCount: 19)
            )
        }
    }

    func testRejectsOverflowingSourceInsets() throws {
        let image = try makeRowsImage(width: 3, rows: [red, green])

        assertStitchingError(.invalidSourceInsets(fragmentIndex: 0)) {
            try VerticalImageStitcher.layout(for: [
                VerticalCaptureFragment(
                    image: image,
                    verticalOffset: 0,
                    scale: 1,
                    sourceTopInsetPixels: Int.max,
                    sourceBottomInsetPixels: Int.max
                ),
            ])
        }
    }

    func testRejectsGapBetweenFragments() throws {
        let first = try makeRowsImage(width: 3, rows: [red, green])
        let second = try makeRowsImage(width: 3, rows: [blue, yellow])

        assertStitchingError(
            .gap(fragmentIndex: 1, expectedAtMostPixel: 2, actualPixel: 3)
        ) {
            try VerticalImageStitcher.layout(for: [
                VerticalCaptureFragment(image: first, verticalOffset: 0, scale: 1),
                VerticalCaptureFragment(image: second, verticalOffset: 3, scale: 1),
            ])
        }
    }

    func testTopInsetCanRemoveFixedChromeBeforeOverlapCropping() throws {
        let first = try makeRowsImage(width: 3, rows: [red, green, blue, yellow])
        let second = try makeRowsImage(width: 3, rows: [magenta, blue, yellow, cyan])

        let result = try VerticalImageStitcher.stitch([
            VerticalCaptureFragment(image: first, verticalOffset: 0, scale: 1),
            VerticalCaptureFragment(
                image: second,
                verticalOffset: 2,
                scale: 1,
                sourceTopInsetPixels: 1
            ),
        ])

        XCTAssertEqual(try rowColors(in: result.image), [red, green, blue, yellow, cyan])
        XCTAssertEqual(result.layout.placements[1].sourceRect.minY, 3)
    }

    private func assertStitchingError<T>(
        _ expected: VerticalImageStitchingError,
        operation: () throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual(error as? VerticalImageStitchingError, expected, file: file, line: line)
        }
    }
}

private struct RGBAColor: Equatable {
    let r: UInt8
    let g: UInt8
    let b: UInt8
    let a: UInt8
}

private let red = RGBAColor(r: 255, g: 0, b: 0, a: 255)
private let green = RGBAColor(r: 0, g: 255, b: 0, a: 255)
private let blue = RGBAColor(r: 0, g: 0, b: 255, a: 255)
private let yellow = RGBAColor(r: 255, g: 255, b: 0, a: 255)
private let cyan = RGBAColor(r: 0, g: 255, b: 255, a: 255)
private let magenta = RGBAColor(r: 255, g: 0, b: 255, a: 255)

private func makeRowsImage(width: Int, rows: [RGBAColor]) throws -> CGImage {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(width * rows.count * 4)
    for color in rows {
        for _ in 0..<width {
            bytes.append(contentsOf: [color.r, color.g, color.b, color.a])
        }
    }
    return try makeTestImage(width: width, height: rows.count, bytes: bytes)
}

private func rowColors(in image: CGImage) throws -> [RGBAColor] {
    let bytes = try normalizedBytes(of: image)
    return (0..<image.height).map { y in
        let offset = y * image.width * 4
        return RGBAColor(
            r: bytes[offset],
            g: bytes[offset + 1],
            b: bytes[offset + 2],
            a: bytes[offset + 3]
        )
    }
}

func makeTestImage(width: Int, height: Int, bytes: [UInt8]) throws -> CGImage {
    let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
    let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
    let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
        CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
    )
    return try XCTUnwrap(
        CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    )
}

func normalizedBytes(of image: CGImage) throws -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: buffer.baseAddress,
                  width: image.width,
                  height: image.height,
                  bitsPerComponent: 8,
                  bytesPerRow: image.width * 4,
                  space: colorSpace,
                  bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                      | CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return false
        }
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return true
    }
    XCTAssertTrue(rendered)
    return bytes
}
