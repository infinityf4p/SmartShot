import CoreGraphics
import Foundation
import ImageIO
import XCTest

final class CaptureHistoryStoreTests: XCTestCase {
    func testSaveLoadArtifactAndDelete() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let first = try makePayload(label: "X post", createdAt: Date(timeIntervalSince1970: 10))

        let saved = try await fixture.store.save(first, limit: 10)
        XCTAssertEqual(saved.map(\.id), [first.id])
        XCTAssertFalse(saved[0].thumbnailData.isEmpty)

        let artifact = try await fixture.store.loadArtifact(id: first.id)
        XCTAssertEqual(artifact.item.label, "X post")
        XCTAssertEqual(artifact.pngData, first.pngData)

        let remaining = try await fixture.store.delete(id: first.id)
        XCTAssertTrue(remaining.isEmpty)
        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.store.loadArtifact(id: first.id)
        }
    }

    func testRetentionKeepsNewestItems() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let first = try makePayload(label: "First", createdAt: Date(timeIntervalSince1970: 10))
        let second = try makePayload(label: "Second", createdAt: Date(timeIntervalSince1970: 20))
        let third = try makePayload(label: "Third", createdAt: Date(timeIntervalSince1970: 30))

        _ = try await fixture.store.save(first, limit: 2)
        _ = try await fixture.store.save(second, limit: 2)
        let items = try await fixture.store.save(third, limit: 2)
        XCTAssertEqual(items.map(\.id), [third.id, second.id])
        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.store.loadArtifact(id: first.id)
        }
    }

    func testDeleteAllRemovesEverySavedArtifact() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let first = try makePayload(label: "First", createdAt: Date(timeIntervalSince1970: 10))
        let second = try makePayload(label: "Second", createdAt: Date(timeIntervalSince1970: 20))
        _ = try await fixture.store.save(first, limit: 10)
        _ = try await fixture.store.save(second, limit: 10)
        try Data("incomplete".utf8).write(
            to: fixture.root.appendingPathComponent("orphan.png")
        )
        try Data("{}".utf8).write(
            to: fixture.root.appendingPathComponent("broken.json")
        )
        try Data("hidden".utf8).write(
            to: fixture.root.appendingPathComponent(".stale")
        )

        let deletedItems = try await fixture.store.deleteAll()
        let loadedItems = try await fixture.store.loadItems()
        let remainingURLs = try FileManager.default.contentsOfDirectory(
            at: fixture.root,
            includingPropertiesForKeys: nil,
            options: []
        )
        XCTAssertTrue(deletedItems.isEmpty)
        XCTAssertTrue(loadedItems.isEmpty)
        XCTAssertTrue(remainingURLs.isEmpty)
        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.store.loadArtifact(id: first.id)
        }
    }

    func testIncompleteEntryIsIgnored() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try Data("{}".utf8).write(
            to: fixture.root.appendingPathComponent("broken.json")
        )
        let items = try await fixture.store.loadItems()
        XCTAssertTrue(items.isEmpty)
    }

    func testSavingSameIDReplacesOriginalAndThumbnail() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let first = try makePayload(label: "Original", createdAt: Date(timeIntervalSince1970: 10))
        _ = try await fixture.store.save(first, limit: 10)
        let replacement = try makePayload(
            id: first.id,
            label: "Redacted",
            createdAt: first.createdAt,
            color: CGColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1)
        )

        let items = try await fixture.store.save(replacement, limit: 10)
        let artifact = try await fixture.store.loadArtifact(id: first.id)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(artifact.item.label, "Redacted")
        XCTAssertEqual(artifact.pngData, replacement.pngData)
        XCTAssertNotEqual(artifact.pngData, first.pngData)
    }

    func testSearchMatchesLabelsCaseWidthAndDiacriticInsensitively() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let older = try makePayload(
            label: "Quarterly Résumé",
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let newer = try makePayload(
            label: "ＲＥＳＵＭＥ notes",
            createdAt: Date(timeIntervalSince1970: 20)
        )
        _ = try await fixture.store.save(older, limit: 10)
        _ = try await fixture.store.save(newer, limit: 10)

        let results = try await fixture.store.searchItems(matching: "resume")

        XCTAssertEqual(results.map(\.id), [newer.id, older.id])
    }

    func testSearchMatchesSanitizedFilenameAndTermsAcrossFields() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let payload = try makePayload(
            label: "Invoice",
            createdAt: Date(timeIntervalSince1970: 10),
            searchIndex: CaptureHistorySearchIndex(
                filename: "/Users/alice/Desktop/July Report.PNG"
            )
        )
        let saved = try await fixture.store.save(payload, limit: 10)

        let results = try await fixture.store.searchItems(matching: "invoice july png")

        XCTAssertEqual(saved.first?.filename, "July Report.PNG")
        XCTAssertEqual(results.map(\.id), [payload.id])
    }

    func testOCRTextIsSearchableOnlyWhenExplicitlyEnabled() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let payload = try makePayload(
            label: "Document",
            createdAt: Date(timeIntervalSince1970: 10),
            searchIndex: CaptureHistorySearchIndex(
                ocrText: "Confirmation code ALPHA-7391",
                ocrIndexingPolicy: .enabled
            )
        )
        _ = try await fixture.store.save(payload, limit: 10)

        let included = try await fixture.store.searchItems(matching: "alpha-7391")
        let excluded = try await fixture.store.searchItems(
            matching: "alpha-7391",
            options: CaptureHistorySearchOptions(includesOCRText: false)
        )

        XCTAssertEqual(included.map(\.id), [payload.id])
        XCTAssertTrue(excluded.isEmpty)
        let artifact = try await fixture.store.loadArtifact(id: payload.id)
        XCTAssertEqual(artifact.searchIndex.ocrText, "Confirmation code ALPHA-7391")
        XCTAssertEqual(artifact.searchIndex.ocrIndexingPolicy, .enabled)
    }

    func testDefaultAndPrivatePoliciesDoNotPersistOCRText() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let defaultSecret = "DEFAULT-SECRET-7294"
        let privateSecret = "PRIVATE-SECRET-1938"
        let defaultIndex = CaptureHistorySearchIndex(ocrText: defaultSecret)
        let privateIndex = CaptureHistorySearchIndex(
            ocrText: privateSecret,
            ocrIndexingPolicy: .privateCapture
        )
        XCTAssertNil(defaultIndex.ocrText)
        XCTAssertNil(privateIndex.ocrText)

        let defaultPayload = try makePayload(
            label: "Default",
            createdAt: Date(timeIntervalSince1970: 10),
            searchIndex: defaultIndex
        )
        let privatePayload = try makePayload(
            label: "Private",
            createdAt: Date(timeIntervalSince1970: 20),
            searchIndex: privateIndex
        )
        _ = try await fixture.store.save(defaultPayload, limit: 10)
        _ = try await fixture.store.save(privatePayload, limit: 10)

        let defaultMetadata = try metadataText(root: fixture.root, id: defaultPayload.id)
        let privateMetadata = try metadataText(root: fixture.root, id: privatePayload.id)
        XCTAssertFalse(defaultMetadata.contains(defaultSecret))
        XCTAssertFalse(privateMetadata.contains(privateSecret))
        XCTAssertFalse(defaultMetadata.contains("ocrTextIndex"))
        XCTAssertFalse(privateMetadata.contains("ocrTextIndex"))
        let defaultResults = try await fixture.store.searchItems(matching: defaultSecret)
        let privateResults = try await fixture.store.searchItems(matching: privateSecret)
        XCTAssertTrue(defaultResults.isEmpty)
        XCTAssertTrue(privateResults.isEmpty)
    }

    func testReplacingAnItemWithoutAnIndexRemovesItsPreviousOCRIndex() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let secret = "REPLACE-ME-5812"
        let indexed = try makePayload(
            label: "Original",
            createdAt: Date(timeIntervalSince1970: 10),
            searchIndex: CaptureHistorySearchIndex(
                ocrText: secret,
                ocrIndexingPolicy: .enabled
            )
        )
        _ = try await fixture.store.save(indexed, limit: 10)
        let indexedResults = try await fixture.store.searchItems(matching: secret)
        XCTAssertEqual(indexedResults.map(\.id), [indexed.id])

        let replacement = try makePayload(
            id: indexed.id,
            label: "Redacted",
            createdAt: indexed.createdAt
        )
        _ = try await fixture.store.save(replacement, limit: 10)

        let replacementResults = try await fixture.store.searchItems(matching: secret)
        XCTAssertTrue(replacementResults.isEmpty)
        XCTAssertFalse(try metadataText(root: fixture.root, id: indexed.id).contains(secret))
    }

    func testRemovingAllOCRIndexesPreservesCapturesAndFilenames() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let secret = "PURGE-ME-4826"
        let payload = try makePayload(
            label: "Indexed document",
            createdAt: Date(timeIntervalSince1970: 10),
            searchIndex: CaptureHistorySearchIndex(
                filename: "/private/source/receipt.png",
                ocrText: secret,
                ocrIndexingPolicy: .enabled
            )
        )
        _ = try await fixture.store.save(payload, limit: 10)

        let items = try await fixture.store.removeAllOCRTextIndexes()
        let artifact = try await fixture.store.loadArtifact(id: payload.id)
        let secretResults = try await fixture.store.searchItems(matching: secret)
        let filenameResults = try await fixture.store.searchItems(matching: "receipt.png")
        let metadata = try metadataText(root: fixture.root, id: payload.id)

        XCTAssertEqual(items.map(\.id), [payload.id])
        XCTAssertEqual(artifact.pngData, payload.pngData)
        XCTAssertEqual(artifact.item.filename, "receipt.png")
        XCTAssertEqual(artifact.searchIndex, CaptureHistorySearchIndex(filename: "receipt.png"))
        XCTAssertTrue(secretResults.isEmpty)
        XCTAssertEqual(filenameResults.map(\.id), [payload.id])
        XCTAssertFalse(metadata.contains(secret))
        XCTAssertFalse(metadata.contains("ocrTextIndex"))
    }

    func testRemovingOCRTextFromInMemoryIndexPreservesOnlyFilename() {
        let index = CaptureHistorySearchIndex(
            filename: "capture.png",
            ocrText: "sensitive text",
            ocrIndexingPolicy: .enabled
        )

        XCTAssertEqual(
            index.removingOCRText,
            CaptureHistorySearchIndex(filename: "capture.png")
        )
    }

    func testRemovingOCRIndexesAlsoScrubsIncompleteHistoryMetadata() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let secret = "ORPHANED-SECRET-8572"
        let payload = try makePayload(
            label: "Incomplete",
            createdAt: Date(timeIntervalSince1970: 10),
            searchIndex: CaptureHistorySearchIndex(
                ocrText: secret,
                ocrIndexingPolicy: .enabled
            )
        )
        _ = try await fixture.store.save(payload, limit: 10)
        try FileManager.default.removeItem(
            at: fixture.root
                .appendingPathComponent(payload.id.uuidString.lowercased())
                .appendingPathExtension("thumb.jpg")
        )

        let items = try await fixture.store.removeAllOCRTextIndexes()
        let metadata = try metadataText(root: fixture.root, id: payload.id)

        XCTAssertTrue(items.isEmpty)
        XCTAssertFalse(metadata.contains(secret))
        XCTAssertFalse(metadata.contains("ocrTextIndex"))
    }

    func testSearchHonorsResultLimitAndEmptyQueryReturnsNewest() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let first = try makePayload(label: "First", createdAt: Date(timeIntervalSince1970: 10))
        let second = try makePayload(label: "Second", createdAt: Date(timeIntervalSince1970: 20))
        let third = try makePayload(label: "Third", createdAt: Date(timeIntervalSince1970: 30))
        _ = try await fixture.store.save(first, limit: 10)
        _ = try await fixture.store.save(second, limit: 10)
        _ = try await fixture.store.save(third, limit: 10)

        let results = try await fixture.store.searchItems(
            matching: "   ",
            options: CaptureHistorySearchOptions(maximumResults: 2)
        )

        XCTAssertEqual(results.map(\.id), [third.id, second.id])
    }

    func testMetadataWithoutSearchFieldsRemainsReadable() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let payload = try makePayload(
            label: "Legacy capture",
            createdAt: Date(timeIntervalSince1970: 10),
            searchIndex: CaptureHistorySearchIndex(
                filename: "legacy.png",
                ocrText: "legacy indexed text",
                ocrIndexingPolicy: .enabled
            )
        )
        _ = try await fixture.store.save(payload, limit: 10)

        let metadataURL = fixture.root
            .appendingPathComponent(payload.id.uuidString.lowercased())
            .appendingPathExtension("json")
        let metadataData = try Data(contentsOf: metadataURL)
        var metadata = try XCTUnwrap(
            JSONSerialization.jsonObject(with: metadataData) as? [String: Any]
        )
        XCTAssertNotNil(metadata.removeValue(forKey: "filename"))
        XCTAssertNotNil(metadata.removeValue(forKey: "ocrTextIndex"))
        try JSONSerialization.data(withJSONObject: metadata).write(to: metadataURL, options: .atomic)

        let items = try await fixture.store.loadItems()

        XCTAssertEqual(items.map(\.id), [payload.id])
        XCTAssertEqual(items.first?.label, "Legacy capture")
        XCTAssertNil(items.first?.filename)
    }

    private func makeFixture() throws -> HistoryFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SmartShotHistoryTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return HistoryFixture(root: root, store: CaptureHistoryStore(rootDirectory: root))
    }

    private func makePayload(
        id: UUID = UUID(),
        label: String,
        createdAt: Date,
        color: CGColor = CGColor(red: 0.2, green: 0.7, blue: 0.3, alpha: 1),
        searchIndex: CaptureHistorySearchIndex = .none
    ) throws -> CaptureHistoryPayload {
        let width = 12
        let height = 8
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw HistoryTestError.fixtureCreationFailed
        }
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            throw HistoryTestError.fixtureCreationFailed
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            "public.png" as CFString,
            1,
            nil
        ) else {
            throw HistoryTestError.fixtureCreationFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw HistoryTestError.fixtureCreationFailed
        }
        return CaptureHistoryPayload(
            id: id,
            createdAt: createdAt,
            label: label,
            logicalRect: CGRect(x: 5, y: 6, width: 6, height: 4),
            pixelWidth: width,
            pixelHeight: height,
            pngData: data as Data,
            searchIndex: searchIndex
        )
    }

    private func metadataText(root: URL, id: UUID) throws -> String {
        let url = root
            .appendingPathComponent(id.uuidString.lowercased())
            .appendingPathExtension("json")
        return try XCTUnwrap(String(data: Data(contentsOf: url), encoding: .utf8))
    }
}

private struct HistoryFixture {
    let root: URL
    let store: CaptureHistoryStore

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private enum HistoryTestError: Error {
    case fixtureCreationFailed
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected an error to be thrown.", file: file, line: line)
    } catch {
        // Expected.
    }
}
