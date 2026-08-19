import CoreGraphics
import XCTest
@testable import SmartShotCore

final class VerticalFixedTopDetectorTests: XCTestCase {
    func testDetectsFixedTopAboveMovingBody() throws {
        let headerHeight = 18
        let previous = try makeFixedTopViewport(
            width: 48,
            height: 90,
            headerHeight: headerHeight,
            bodyOffset: 0
        )
        let current = try makeFixedTopViewport(
            width: 48,
            height: 90,
            headerHeight: headerHeight,
            bodyOffset: 17
        )

        XCTAssertEqual(
            try VerticalFixedTopDetector.detect(previous: previous, current: current),
            headerHeight
        )
    }

    func testReturnsZeroWhenWholeViewportMoves() throws {
        let document = try makeDetectorPattern(width: 48, height: 130, seed: 5)
        let previous = try XCTUnwrap(
            document.cropping(to: CGRect(x: 0, y: 0, width: 48, height: 90))
        )
        let current = try XCTUnwrap(
            document.cropping(to: CGRect(x: 0, y: 16, width: 48, height: 90))
        )

        XCTAssertEqual(
            try VerticalFixedTopDetector.detect(previous: previous, current: current),
            0
        )
    }

    func testReturnsZeroForIdenticalFrames() throws {
        let image = try makeDetectorPattern(width: 48, height: 90, seed: 11)

        XCTAssertEqual(
            try VerticalFixedTopDetector.detect(previous: image, current: image),
            0
        )
    }

    func testToleratesOneNoisyHeaderRow() throws {
        let headerHeight = 20
        let previous = try makeFixedTopViewport(
            width: 48,
            height: 96,
            headerHeight: headerHeight,
            bodyOffset: 0
        )
        var bytes = try normalizedBytes(of: makeFixedTopViewport(
            width: 48,
            height: 96,
            headerHeight: headerHeight,
            bodyOffset: 19
        ))
        for x in 8..<40 {
            bytes[(7 * 48 + x) * 4] &+= 3
        }
        let current = try makeTestImage(width: 48, height: 96, bytes: bytes)

        XCTAssertEqual(
            try VerticalFixedTopDetector.detect(previous: previous, current: current),
            headerHeight
        )
    }
}

private func makeFixedTopViewport(
    width: Int,
    height: Int,
    headerHeight: Int,
    bodyOffset: Int
) throws -> CGImage {
    var bytes = [UInt8]()
    bytes.reserveCapacity(width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            if y < headerHeight {
                bytes.append(UInt8(truncatingIfNeeded: 30 + x * 3))
                bytes.append(UInt8(truncatingIfNeeded: 80 + y * 7))
                bytes.append(UInt8(truncatingIfNeeded: 170 + x + y * 2))
            } else {
                let documentY = y - headerHeight + bodyOffset
                bytes.append(UInt8(truncatingIfNeeded: x * 37 + documentY * 17 + x * documentY * 3))
                bytes.append(UInt8(truncatingIfNeeded: x * 11 + documentY * 67 + documentY * documentY * 5))
                bytes.append(UInt8(truncatingIfNeeded: x * 97 + documentY * 23 + (x + documentY) * 7))
            }
            bytes.append(255)
        }
    }
    return try makeTestImage(width: width, height: height, bytes: bytes)
}

private func makeDetectorPattern(width: Int, height: Int, seed: Int) throws -> CGImage {
    var bytes = [UInt8]()
    bytes.reserveCapacity(width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            bytes.append(UInt8(truncatingIfNeeded: x * 31 + y * 43 + seed * 17))
            bytes.append(UInt8(truncatingIfNeeded: x * 73 + y * 19 + x * y + seed * 29))
            bytes.append(UInt8(truncatingIfNeeded: x * 13 + y * 89 + y * y + seed * 7))
            bytes.append(255)
        }
    }
    return try makeTestImage(width: width, height: height, bytes: bytes)
}
