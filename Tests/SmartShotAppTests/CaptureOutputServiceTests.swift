import AppKit
import Foundation
import XCTest

final class CaptureOutputServiceTests: XCTestCase {
    func testFilenameStylesSanitizeLabelsAndUseExpectedExtension() {
        let date = Date(timeIntervalSince1970: 0)
        let labeled = CaptureOutputService.filename(
            label: "Post:/\\\u{0007}",
            date: date,
            format: .jpeg,
            style: .labelTimestamp
        )
        XCTAssertTrue(labeled.hasPrefix("Post "))
        XCTAssertTrue(labeled.hasSuffix(".jpg"))
        XCTAssertFalse(labeled.contains(":"))
        XCTAssertFalse(labeled.contains("/"))
        XCTAssertFalse(labeled.contains("\\"))

        let standard = CaptureOutputService.filename(
            label: "Ignored",
            date: date,
            format: .png,
            style: .smartShotTimestamp
        )
        XCTAssertTrue(standard.hasPrefix("SmartShot "))
        XCTAssertTrue(standard.hasSuffix(".png"))
    }

    func testAvailableURLAvoidsExistingNames() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SmartShotOutputTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("Capture.png"))
        try Data().write(to: root.appendingPathComponent("Capture 2.png"))

        XCTAssertEqual(
            CaptureOutputService.availableURL(
                directory: root,
                preferredFilename: "Capture.png"
            ).lastPathComponent,
            "Capture 3.png"
        )
    }

    func testJPEGEncodingProducesJPEGData() throws {
        let width = 4
        let height = 3
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let capture = try CapturedImage.encoded(
            cgImage: image,
            logicalRect: CGRect(x: 0, y: 0, width: width, height: height),
            label: "Fixture"
        )

        let data = try CaptureOutputService.encodedData(for: capture, format: .jpeg)
        XCTAssertEqual(Array(data.prefix(2)), [0xFF, 0xD8])
    }
}
