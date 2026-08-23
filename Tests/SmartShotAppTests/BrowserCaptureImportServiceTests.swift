import Foundation
import XCTest

@MainActor
final class BrowserCaptureImportServiceTests: XCTestCase {
    func testRequestNormalizationIgnoresQueryOrderAndUUIDCase() throws {
        let requestID = UUID().uuidString
        let first = try BrowserCaptureImportRequest(url: try XCTUnwrap(URL(
            string: "smartshot://import?requestId=\(requestID.uppercased())&source=safari"
        )))
        let second = try BrowserCaptureImportRequest(url: try XCTUnwrap(URL(
            string: "smartshot://import?source=SAFARI&requestId=\(requestID.lowercased())"
        )))

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.requestID, requestID.lowercased())
        XCTAssertEqual(first.source, .safari)
    }

    func testRequestParserRejectsAmbiguousOrExpandedURLs() throws {
        let requestID = UUID().uuidString.lowercased()
        let invalidURLs = [
            "smartshot://import/path?requestId=\(requestID)&source=safari",
            "smartshot://import?requestId=\(requestID)&source=safari#fragment",
            "smartshot://import?requestId=\(requestID)&source=safari&extra=value",
            "smartshot://import?requestId=\(requestID)&requestId=\(requestID)&source=safari",
            "smartshot://import?requestId=not-a-uuid&source=safari",
            "smartshot://import?requestId=\(requestID)&source=unknown",
        ]

        for value in invalidURLs {
            XCTAssertThrowsError(try BrowserCaptureImportRequest(
                url: try XCTUnwrap(URL(string: value))
            ), "Expected rejection for \(value)")
        }
    }

    func testQueueDeduplicatesBoundsAndRetainsOnlySuccessfulCompletions() throws {
        var queue = BrowserCaptureImportQueue(maximumOutstanding: 2, maximumCompleted: 2)
        let first = try request(source: .safari)
        let second = try request(source: .chromium)
        let third = try request(source: .safari)

        XCTAssertEqual(queue.enqueue(first), .enqueued)
        XCTAssertEqual(queue.enqueue(first), .duplicate)
        XCTAssertEqual(queue.startNext(), first)
        XCTAssertEqual(queue.enqueue(second), .enqueued)
        XCTAssertEqual(queue.enqueue(third), .full)

        queue.finishActive(first, completedSuccessfully: true)
        XCTAssertEqual(queue.enqueue(first), .alreadyCompleted)
        XCTAssertEqual(queue.startNext(), second)
        queue.finishActive(second, completedSuccessfully: false)
        XCTAssertEqual(queue.enqueue(second), .enqueued)

        XCTAssertEqual(queue.startNext(), second)
        queue.finishActive(second, completedSuccessfully: true)
        XCTAssertEqual(queue.enqueue(third), .enqueued)
        XCTAssertEqual(queue.startNext(), third)
        queue.finishActive(third, completedSuccessfully: true)
        XCTAssertEqual(queue.completed, [second, third])
        XCTAssertEqual(queue.enqueue(first), .enqueued)
    }

    func testDefaultQueueRejectsASecondOutstandingImport() throws {
        var queue = BrowserCaptureImportQueue()
        let first = try request(source: .safari)
        let second = try request(source: .chromium)

        XCTAssertEqual(queue.enqueue(first), .enqueued)
        XCTAssertEqual(queue.startNext(), first)
        XCTAssertEqual(queue.enqueue(second), .full)
    }

    func testRemovingPendingLeavesActiveRequestForExplicitCancellation() throws {
        var queue = BrowserCaptureImportQueue(maximumOutstanding: 3)
        let active = try request(source: .safari)
        let pending = try request(source: .chromium)
        XCTAssertEqual(queue.enqueue(active), .enqueued)
        XCTAssertEqual(queue.startNext(), active)
        XCTAssertEqual(queue.enqueue(pending), .enqueued)

        XCTAssertEqual(queue.removePending(), [pending])
        XCTAssertEqual(queue.active, active)
        XCTAssertTrue(queue.pending.isEmpty)
    }

    private func request(
        source: BrowserCaptureImportSource
    ) throws -> BrowserCaptureImportRequest {
        try BrowserCaptureImportRequest(url: XCTUnwrap(URL(
            string: "smartshot://import?requestId=\(UUID().uuidString)&source=\(source.rawValue)"
        )))
    }
}
