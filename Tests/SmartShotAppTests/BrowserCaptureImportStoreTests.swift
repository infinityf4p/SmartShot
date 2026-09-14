import CoreGraphics
import Foundation
import ImageIO
import XCTest

final class BrowserCaptureImportStoreTests: XCTestCase {
    func testImportsJSONDecodedPNGWithZeroAndOneNumbers() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let pngData = try makePNG(width: 2, height: 2)
        let encoded = pngData.base64EncodedString()

        let begin = fixture.store.handle(try jsonRoundTrip(envelope(
            type: "capture.import.begin",
            requestID: fixture.requestID,
            payload: beginPayload(
                pngData: pngData,
                encoded: encoded,
                chunkCount: 1,
                logicalWidth: 1,
                logicalHeight: 1
            )
        )))
        assertAccepted(begin, stage: "begin")
        guard (begin.response["payload"] as? [String: Any])?["accepted"] as? Bool == true else {
            return
        }

        let chunk = fixture.store.handle(try jsonRoundTrip(envelope(
            type: "capture.import.chunk",
            requestID: fixture.requestID,
            payload: ["index": 0, "data": encoded]
        )))
        assertAccepted(chunk, stage: "chunk", index: 0)

        let end = fixture.store.handle(try jsonRoundTrip(envelope(
            type: "capture.import.end",
            requestID: fixture.requestID,
            payload: ["byteLength": pngData.count, "chunkCount": 1]
        )))
        assertAccepted(end, stage: "end")
        let artifact = try fixture.store.consumeCompletedCapture(requestID: fixture.requestID)
        XCTAssertEqual(artifact.pngData, pngData)
        XCTAssertEqual(artifact.metadata.logicalWidth, 1)
        XCTAssertEqual(artifact.metadata.logicalHeight, 1)
    }

    func testRejectsJSONDecodedBooleansInNumericFields() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let pngData = try makePNG(width: 2, height: 2)
        let payload = beginPayload(
            pngData: pngData,
            encoded: pngData.base64EncodedString(),
            chunkCount: 1
        )
        for value in [true, false] {
            var message = envelope(
                type: "capture.import.begin",
                requestID: fixture.requestID,
                payload: payload
            )
            message["version"] = value
            assertRejected(fixture.store.handle(try jsonRoundTrip(message)), code: "invalid_envelope")

            for field in ["byteLength", "base64Length", "chunkCount", "logicalWidth", "logicalHeight"] {
                var invalidPayload = payload
                invalidPayload[field] = value
                assertRejected(fixture.store.handle(try jsonRoundTrip(envelope(
                    type: "capture.import.begin",
                    requestID: fixture.requestID,
                    payload: invalidPayload
                ))), code: "invalid_metadata")
            }
        }
        XCTAssertFalse(partialSessionExists(fixture))
    }

    func testRejectsJSONDecodedFractionalAndOutOfRangeNumbers() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let pngData = try makePNG(width: 2, height: 2)
        for value in [1.5, Double(Int.max), Double.greatestFiniteMagnitude] {
            var payload = beginPayload(
                pngData: pngData,
                encoded: pngData.base64EncodedString(),
                chunkCount: 1
            )
            payload["chunkCount"] = value
            assertRejected(fixture.store.handle(try jsonRoundTrip(envelope(
                type: "capture.import.begin",
                requestID: fixture.requestID,
                payload: payload
            ))), code: "invalid_metadata")
        }
        XCTAssertFalse(partialSessionExists(fixture))
    }

    func testImportsValidPNGAndConsumesInboxArtifact() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let pngData = try makePNG(width: 8, height: 6)
        let encoded = pngData.base64EncodedString()
        let chunks = split(
            encoded,
            maximumLength: BrowserCaptureImportProtocol.maximumChunkCharacters
        )

        let begin = fixture.store.handle(envelope(
            type: "capture.import.begin",
            requestID: fixture.requestID,
            payload: beginPayload(
                pngData: pngData,
                encoded: encoded,
                chunkCount: chunks.count,
                filename: "../X: post\u{0007}",
                kind: "X Post!",
                origin: "https://x.com/person/status/123?secret=yes#reply",
                logicalWidth: 400,
                logicalHeight: 300
            )
        ))
        assertAccepted(begin, stage: "begin")

        for (index, chunk) in chunks.enumerated() {
            let result = fixture.store.handle(envelope(
                type: "capture.import.chunk",
                requestID: fixture.requestID,
                payload: ["index": index, "data": chunk]
            ))
            assertAccepted(result, stage: "chunk", index: index)
        }

        let end = fixture.store.handle(envelope(
            type: "capture.import.end",
            requestID: fixture.requestID,
            payload: ["byteLength": pngData.count, "chunkCount": chunks.count]
        ))
        assertAccepted(end, stage: "end")
        XCTAssertEqual(end.completedRequestID, fixture.requestID)

        let loadedArtifact = try fixture.store.loadCompletedCapture(requestID: fixture.requestID)
        XCTAssertEqual(loadedArtifact.pngData, pngData)
        XCTAssertTrue(fixture.store.completedCaptureExists(requestID: fixture.requestID))

        let artifact = try fixture.store.consumeCompletedCapture(requestID: fixture.requestID)
        XCTAssertEqual(artifact.pngData, pngData)
        XCTAssertEqual(artifact.image.width, 8)
        XCTAssertEqual(artifact.image.height, 6)
        XCTAssertEqual(artifact.metadata.logicalWidth, 400)
        XCTAssertEqual(artifact.metadata.logicalHeight, 300)
        XCTAssertEqual(artifact.metadata.decodedByteLength, pngData.count)
        XCTAssertEqual(artifact.metadata.kind, "xpost")
        XCTAssertEqual(artifact.metadata.sourceOrigin, "https://x.com")
        XCTAssertFalse(artifact.metadata.filename.contains("/"))
        XCTAssertFalse(artifact.metadata.filename.contains(":"))

        let inbox = fixture.root.appendingPathComponent("Inbox", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: inbox.appendingPathComponent(fixture.requestID).appendingPathExtension("png").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: inbox.appendingPathComponent(fixture.requestID).appendingPathExtension("json").path
        ))
        XCTAssertFalse(fixture.store.completedCaptureExists(requestID: fixture.requestID))
    }

    func testCompletedMetadataValidationRejectsTamperedTransferFields() throws {
        let requestID = UUID().uuidString.lowercased()
        let pngData = try makePNG(width: 8, height: 6)
        let valid = BrowserCaptureImportMetadata(
            requestID: requestID,
            source: "safari",
            filename: "capture",
            kind: "x-post",
            sourceOrigin: "https://x.com",
            chunkCount: 1,
            base64Length: pngData.base64EncodedString().utf8.count,
            decodedByteLength: pngData.count,
            logicalWidth: 400,
            logicalHeight: 300,
            pixelWidth: 8,
            pixelHeight: 6,
            createdAt: Date()
        )
        XCTAssertNoThrow(try BrowserCaptureImportStore.validatedArtifact(
            pngData: pngData,
            metadata: valid,
            expectedRequestID: requestID,
            expectedSource: "safari"
        ))

        let tampered = BrowserCaptureImportMetadata(
            requestID: requestID,
            source: "safari",
            filename: "../capture",
            kind: "x-post",
            sourceOrigin: "https://x.com/path?secret=yes",
            chunkCount: 2,
            base64Length: valid.base64Length,
            decodedByteLength: valid.decodedByteLength + 1,
            logicalWidth: BrowserCaptureImportProtocol.maximumLogicalDimension + 1,
            logicalHeight: 300,
            pixelWidth: 8,
            pixelHeight: 6,
            createdAt: Date().addingTimeInterval(
                -(BrowserCaptureImportProtocol.maximumCompletedAge + 1)
            )
        )
        XCTAssertThrowsError(try BrowserCaptureImportStore.validatedArtifact(
            pngData: pngData,
            metadata: tampered,
            expectedRequestID: requestID,
            expectedSource: "safari"
        )) {
            guard case BrowserCaptureImportStoreError.invalidMetadata = $0 else {
                return XCTFail("Expected invalid metadata, got \($0)")
            }
        }
    }

    func testSafariNamedPasteboardTransfersPayloadAndAcknowledgement() throws {
        let requestID = UUID().uuidString.lowercased()
        defer { SafariBrowserCapturePasteboard.cleanup(requestID: requestID) }
        let pngData = try makePNG(width: 8, height: 6)
        let metadata = BrowserCaptureImportMetadata(
            requestID: requestID,
            source: "safari",
            filename: "capture",
            kind: "x-post",
            sourceOrigin: "https://x.com",
            chunkCount: 1,
            base64Length: pngData.base64EncodedString().utf8.count,
            decodedByteLength: pngData.count,
            logicalWidth: 400,
            logicalHeight: 300,
            pixelWidth: 8,
            pixelHeight: 6,
            createdAt: Date()
        )
        let artifact = try BrowserCaptureImportStore.validatedArtifact(
            pngData: pngData,
            metadata: metadata,
            expectedRequestID: requestID,
            expectedSource: "safari"
        )

        try SafariBrowserCapturePasteboard.publish(artifact)
        let payload = try SafariBrowserCapturePasteboard.payload(requestID: requestID)
        XCTAssertEqual(payload.pngData, pngData)
        XCTAssertEqual(payload.metadata, metadata)
        XCTAssertNil(try SafariBrowserCapturePasteboard.acknowledgement(requestID: requestID))

        try SafariBrowserCapturePasteboard.acknowledge(requestID: requestID, accepted: true)
        XCTAssertEqual(
            try SafariBrowserCapturePasteboard.acknowledgement(requestID: requestID),
            SafariBrowserCapturePasteboardAcknowledgement(
                requestID: requestID,
                accepted: true
            )
        )
    }

    func testRejectsOutOfOrderChunk() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let data = Data(
            repeating: 0x41,
            count: BrowserCaptureImportProtocol.maximumChunkCharacters
        )
        let encoded = data.base64EncodedString()
        let chunks = split(
            encoded,
            maximumLength: BrowserCaptureImportProtocol.maximumChunkCharacters
        )
        XCTAssertGreaterThan(chunks.count, 1)

        assertAccepted(fixture.store.handle(envelope(
            type: "capture.import.begin",
            requestID: fixture.requestID,
            payload: beginPayload(
                pngData: data,
                encoded: encoded,
                chunkCount: chunks.count
            )
        )), stage: "begin")

        let result = fixture.store.handle(envelope(
            type: "capture.import.chunk",
            requestID: fixture.requestID,
            payload: ["index": 1, "data": chunks[1]]
        ))
        assertRejected(result, code: "invalid_chunk")
        XCTAssertFalse(partialSessionExists(fixture))
    }

    func testRejectsBeginWhenChunkCountDoesNotMatchDeclaredLength() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let pngData = try makePNG(width: 2, height: 2)
        let encoded = pngData.base64EncodedString()

        let result = fixture.store.handle(envelope(
            type: "capture.import.begin",
            requestID: fixture.requestID,
            payload: beginPayload(pngData: pngData, encoded: encoded, chunkCount: 2)
        ))

        assertRejected(result, code: "invalid_metadata")
        XCTAssertFalse(partialSessionExists(fixture))
    }

    func testRejectsChunkThatExceedsDeclaredTransferLength() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let pngData = try makePNG(width: 2, height: 2)
        let encoded = pngData.base64EncodedString()
        assertAccepted(fixture.store.handle(envelope(
            type: "capture.import.begin",
            requestID: fixture.requestID,
            payload: beginPayload(pngData: pngData, encoded: encoded, chunkCount: 1)
        )), stage: "begin")

        let result = fixture.store.handle(envelope(
            type: "capture.import.chunk",
            requestID: fixture.requestID,
            payload: ["index": 0, "data": encoded + "AAAA"]
        ))

        assertRejected(result, code: "invalid_chunk")
        XCTAssertFalse(partialSessionExists(fixture))
    }

    func testRejectsInvalidPNGAtEnd() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let data = Data("not a png".utf8)
        let encoded = data.base64EncodedString()

        assertAccepted(fixture.store.handle(envelope(
            type: "capture.import.begin",
            requestID: fixture.requestID,
            payload: beginPayload(pngData: data, encoded: encoded, chunkCount: 1)
        )), stage: "begin")
        assertAccepted(fixture.store.handle(envelope(
            type: "capture.import.chunk",
            requestID: fixture.requestID,
            payload: ["index": 0, "data": encoded]
        )), stage: "chunk", index: 0)

        let result = fixture.store.handle(envelope(
            type: "capture.import.end",
            requestID: fixture.requestID,
            payload: ["byteLength": data.count, "chunkCount": 1]
        ))
        assertRejected(result, code: "invalid_png")
        XCTAssertNil(result.completedRequestID)
        XCTAssertFalse(partialSessionExists(fixture))
    }

    func testRejectsLogicalAspectMismatchBeforeAcknowledgingEnd() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let pngData = try makePNG(width: 8, height: 6)
        let encoded = pngData.base64EncodedString()

        assertAccepted(fixture.store.handle(envelope(
            type: "capture.import.begin",
            requestID: fixture.requestID,
            payload: beginPayload(
                pngData: pngData,
                encoded: encoded,
                chunkCount: 1,
                logicalWidth: 400,
                logicalHeight: 1_200
            )
        )), stage: "begin")
        assertAccepted(fixture.store.handle(envelope(
            type: "capture.import.chunk",
            requestID: fixture.requestID,
            payload: ["index": 0, "data": encoded]
        )), stage: "chunk", index: 0)

        let result = fixture.store.handle(envelope(
            type: "capture.import.end",
            requestID: fixture.requestID,
            payload: ["byteLength": pngData.count, "chunkCount": 1]
        ))
        assertRejected(result, code: "invalid_geometry")
        XCTAssertNil(result.completedRequestID)
        XCTAssertFalse(partialSessionExists(fixture))
        XCTAssertThrowsError(try fixture.store.consumeCompletedCapture(requestID: fixture.requestID)) {
            guard case BrowserCaptureImportStoreError.missingCapture = $0 else {
                return XCTFail("Expected missing capture, got \($0)")
            }
        }
    }

    func testRejectsInvalidRequestIDAndMismatchedEndMetadata() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let pngData = try makePNG(width: 2, height: 2)
        let encoded = pngData.base64EncodedString()

        let invalidID = fixture.store.handle(envelope(
            type: "capture.import.begin",
            requestID: "../../outside",
            payload: beginPayload(pngData: pngData, encoded: encoded, chunkCount: 1)
        ))
        assertRejected(invalidID, code: "invalid_request_id")

        assertAccepted(fixture.store.handle(envelope(
            type: "capture.import.begin",
            requestID: fixture.requestID,
            payload: beginPayload(pngData: pngData, encoded: encoded, chunkCount: 1)
        )), stage: "begin")
        assertAccepted(fixture.store.handle(envelope(
            type: "capture.import.chunk",
            requestID: fixture.requestID,
            payload: ["index": 0, "data": encoded]
        )), stage: "chunk", index: 0)

        let mismatchedEnd = fixture.store.handle(envelope(
            type: "capture.import.end",
            requestID: fixture.requestID,
            payload: ["byteLength": pngData.count + 1, "chunkCount": 1]
        ))
        assertRejected(mismatchedEnd, code: "invalid_metadata")
        XCTAssertFalse(partialSessionExists(fixture))
    }

    func testRejectsBooleanAndFractionalProtocolNumbers() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let pngData = try makePNG(width: 2, height: 2)
        let encoded = pngData.base64EncodedString()

        var booleanVersion = envelope(
            type: "capture.import.begin",
            requestID: fixture.requestID,
            payload: beginPayload(pngData: pngData, encoded: encoded, chunkCount: 1)
        )
        booleanVersion["version"] = true
        assertRejected(fixture.store.handle(booleanVersion), code: "invalid_envelope")

        var booleanDimension = beginPayload(
            pngData: pngData,
            encoded: encoded,
            chunkCount: 1
        )
        booleanDimension["logicalWidth"] = true
        assertRejected(fixture.store.handle(envelope(
            type: "capture.import.begin",
            requestID: fixture.requestID,
            payload: booleanDimension
        )), code: "invalid_metadata")

        var fractionalChunks = beginPayload(
            pngData: pngData,
            encoded: encoded,
            chunkCount: 1
        )
        fractionalChunks["chunkCount"] = 1.5
        assertRejected(fixture.store.handle(envelope(
            type: "capture.import.begin",
            requestID: fixture.requestID,
            payload: fractionalChunks
        )), code: "invalid_metadata")
    }

    func testInitializationCleansExpiredStagingWithoutRemovingFreshItems() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let partial = root.appendingPathComponent("Partial", isDirectory: true)
        let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
        let oldSession = partial.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let freshSession = partial.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: oldSession, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: freshSession, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let oldInbox = inbox.appendingPathComponent("old.png")
        let freshInbox = inbox.appendingPathComponent("fresh.png")
        try Data([1]).write(to: oldInbox)
        try Data([2]).write(to: freshInbox)

        let expired = Date().addingTimeInterval(-3_601)
        try FileManager.default.setAttributes([.modificationDate: expired], ofItemAtPath: oldSession.path)
        try FileManager.default.setAttributes([.modificationDate: expired], ofItemAtPath: oldInbox.path)

        _ = BrowserCaptureImportStore(rootDirectory: root, source: "chromium")

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldSession.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldInbox.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: freshSession.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: freshInbox.path))
    }

    func testRejectsBeginWhenStagingByteQuotaIsExhausted() throws {
        let fixture = try makeFixture(maximumStagedBytes: 32)
        defer { fixture.cleanup() }
        let inbox = fixture.root.appendingPathComponent("Inbox", isDirectory: true)
        try Data(repeating: 0x41, count: 33).write(to: inbox.appendingPathComponent("busy.png"))
        let pngData = try makePNG(width: 2, height: 2)
        let encoded = pngData.base64EncodedString()

        let result = fixture.store.handle(envelope(
            type: "capture.import.begin",
            requestID: fixture.requestID,
            payload: beginPayload(pngData: pngData, encoded: encoded, chunkCount: 1)
        ))

        assertRejected(result, code: "storage_limit")
        XCTAssertFalse(partialSessionExists(fixture))
    }

    func testRejectsBeginWhenStagingSessionQuotaIsExhausted() throws {
        let fixture = try makeFixture(maximumStagedSessions: 1)
        defer { fixture.cleanup() }
        let existing = fixture.root
            .appendingPathComponent("Partial", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        let pngData = try makePNG(width: 2, height: 2)
        let encoded = pngData.base64EncodedString()

        let result = fixture.store.handle(envelope(
            type: "capture.import.begin",
            requestID: fixture.requestID,
            payload: beginPayload(pngData: pngData, encoded: encoded, chunkCount: 1)
        ))

        assertRejected(result, code: "storage_limit")
        XCTAssertFalse(partialSessionExists(fixture))
        XCTAssertTrue(FileManager.default.fileExists(atPath: existing.path))
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SmartShotBrowserImportTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func makeFixture(
        maximumStagedBytes: Int = BrowserCaptureImportProtocol.maximumStagedBytes,
        maximumStagedSessions: Int = BrowserCaptureImportProtocol.maximumStagedSessions
    ) throws -> Fixture {
        let root = temporaryRoot()
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: nil
        )
        return Fixture(
            root: root,
            requestID: UUID().uuidString.lowercased(),
            store: BrowserCaptureImportStore(
                rootDirectory: root,
                source: "chromium",
                maximumStagedBytes: maximumStagedBytes,
                maximumStagedSessions: maximumStagedSessions
            )
        )
    }

    private func makePNG(width: Int, height: Int) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw TestError.fixtureCreationFailed
        }
        context.setFillColor(CGColor(red: 0.15, green: 0.55, blue: 0.85, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            throw TestError.fixtureCreationFailed
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            "public.png" as CFString,
            1,
            nil
        ) else {
            throw TestError.fixtureCreationFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw TestError.fixtureCreationFailed
        }
        return data as Data
    }

    private func beginPayload(
        pngData: Data,
        encoded: String,
        chunkCount: Int,
        filename: String = "capture",
        kind: String = "block",
        origin: String = "https://example.com/path?private=1",
        logicalWidth: Double = 2,
        logicalHeight: Double = 2
    ) -> [String: Any] {
        [
            "mimeType": "image/png",
            "encoding": "base64",
            "byteLength": pngData.count,
            "base64Length": encoded.utf8.count,
            "chunkCount": chunkCount,
            "filename": filename,
            "kind": kind,
            "sourceOrigin": origin,
            "logicalWidth": logicalWidth,
            "logicalHeight": logicalHeight,
        ]
    }

    private func envelope(
        type: String,
        requestID: String,
        payload: [String: Any]
    ) -> [String: Any] {
        [
            "protocol": BrowserCaptureImportProtocol.name,
            "version": BrowserCaptureImportProtocol.version,
            "type": type,
            "requestId": requestID,
            "payload": payload,
        ]
    }

    private func jsonRoundTrip(_ message: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: message)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func split(_ value: String, maximumLength: Int) -> [String] {
        stride(from: 0, to: value.count, by: maximumLength).map { offset in
            let start = value.index(value.startIndex, offsetBy: offset)
            let end = value.index(start, offsetBy: min(maximumLength, value.count - offset))
            return String(value[start..<end])
        }
    }

    private func partialSessionExists(_ fixture: Fixture) -> Bool {
        FileManager.default.fileExists(
            atPath: fixture.root
                .appendingPathComponent("Partial", isDirectory: true)
                .appendingPathComponent(fixture.requestID, isDirectory: true)
                .path
        )
    }

    private func assertAccepted(
        _ result: BrowserCaptureImportHandlingResult,
        stage: String,
        index: Int? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let payload = result.response["payload"] as? [String: Any]
        XCTAssertEqual(payload?["accepted"] as? Bool, true, file: file, line: line)
        XCTAssertEqual(payload?["stage"] as? String, stage, file: file, line: line)
        if let index {
            XCTAssertEqual(payload?["index"] as? Int, index, file: file, line: line)
        }
    }

    private func assertRejected(
        _ result: BrowserCaptureImportHandlingResult,
        code: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let payload = result.response["payload"] as? [String: Any]
        XCTAssertEqual(payload?["accepted"] as? Bool, false, file: file, line: line)
        XCTAssertEqual(payload?["errorCode"] as? String, code, file: file, line: line)
    }
}

private struct Fixture {
    let root: URL
    let requestID: String
    let store: BrowserCaptureImportStore

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private enum TestError: Error {
    case fixtureCreationFailed
}
