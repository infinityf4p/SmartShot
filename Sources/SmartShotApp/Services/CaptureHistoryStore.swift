import SmartShotCore
import CoreGraphics
import Foundation
import ImageIO

struct CaptureHistoryItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let createdAt: Date
    let label: String
    let filename: String?
    let logicalRect: CGRect
    let pixelWidth: Int
    let pixelHeight: Int
    let thumbnailData: Data
}

enum CaptureHistoryOCRIndexingPolicy: Equatable, Sendable {
    case disabled
    case enabled
    case privateCapture
}

struct CaptureHistorySearchIndex: Equatable, Sendable {
    static let none = CaptureHistorySearchIndex()

    let filename: String?
    let ocrText: String?
    let ocrIndexingPolicy: CaptureHistoryOCRIndexingPolicy

    init(
        filename: String? = nil,
        ocrText: String? = nil,
        ocrIndexingPolicy: CaptureHistoryOCRIndexingPolicy = .disabled
    ) {
        self.filename = filename
        self.ocrIndexingPolicy = ocrIndexingPolicy
        self.ocrText = ocrIndexingPolicy == .enabled ? ocrText : nil
    }

    var removingOCRText: CaptureHistorySearchIndex {
        CaptureHistorySearchIndex(filename: filename)
    }
}

struct CaptureHistorySearchOptions: Equatable, Sendable {
    var includesOCRText: Bool
    var maximumResults: Int

    init(includesOCRText: Bool = true, maximumResults: Int = 500) {
        self.includesOCRText = includesOCRText
        self.maximumResults = maximumResults
    }
}

struct CaptureHistoryPayload: Sendable {
    let id: UUID
    let createdAt: Date
    let label: String
    let logicalRect: CGRect
    let pixelWidth: Int
    let pixelHeight: Int
    let pngData: Data
    let searchIndex: CaptureHistorySearchIndex

    init(
        id: UUID,
        createdAt: Date,
        label: String,
        logicalRect: CGRect,
        pixelWidth: Int,
        pixelHeight: Int,
        pngData: Data,
        searchIndex: CaptureHistorySearchIndex = .none
    ) {
        self.id = id
        self.createdAt = createdAt
        self.label = label
        self.logicalRect = logicalRect
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.pngData = pngData
        self.searchIndex = searchIndex
    }
}

struct CaptureHistoryArtifact: Sendable {
    let item: CaptureHistoryItem
    let pngData: Data
    let searchIndex: CaptureHistorySearchIndex
}

enum CaptureHistoryStoreError: LocalizedError {
    case invalidCapture
    case missingCapture
    case thumbnailEncodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidCapture:
            L10n.text("The screenshot could not be added to history.")
        case .missingCapture:
            L10n.text("The history item is no longer available.")
        case .thumbnailEncodingFailed:
            L10n.text("The screenshot thumbnail could not be created.")
        }
    }
}

actor CaptureHistoryStore {
    private struct Metadata: Codable, Equatable, Sendable {
        let id: UUID
        let createdAt: Date
        let label: String
        let filename: String?
        let ocrTextIndex: String?
        let logicalX: Double
        let logicalY: Double
        let logicalWidth: Double
        let logicalHeight: Double
        let pixelWidth: Int
        let pixelHeight: Int

        var logicalRect: CGRect {
            CGRect(
                x: logicalX,
                y: logicalY,
                width: logicalWidth,
                height: logicalHeight
            )
        }
    }

    private let rootDirectory: URL
    private let fileManager: FileManager

    init(rootDirectory: URL? = nil, fileManager: FileManager = .default) {
        if let rootDirectory {
            self.rootDirectory = rootDirectory
        } else {
            let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? fileManager.temporaryDirectory
            self.rootDirectory = applicationSupport
                .appendingPathComponent("SmartShot", isDirectory: true)
                .appendingPathComponent("History", isDirectory: true)
        }
        self.fileManager = fileManager
    }

    func loadItems() throws -> [CaptureHistoryItem] {
        try prepareDirectory()
        return try loadValidItems().sorted { $0.createdAt > $1.createdAt }
    }

    func searchItems(
        matching query: String,
        options: CaptureHistorySearchOptions = CaptureHistorySearchOptions()
    ) throws -> [CaptureHistoryItem] {
        try prepareDirectory()
        let maximumResults = min(500, max(0, options.maximumResults))
        guard maximumResults > 0 else { return [] }

        let terms = Self.searchTerms(query)
        let entries = try loadValidMetadata().sorted {
            $0.createdAt > $1.createdAt
        }
        let matches = entries.lazy.filter { metadata in
            guard !terms.isEmpty else { return true }
            var fields = [Self.normalizedSearchValue(metadata.label)]
            if let filename = metadata.filename {
                fields.append(Self.normalizedSearchValue(filename))
            }
            if options.includesOCRText, let ocrText = metadata.ocrTextIndex {
                fields.append(Self.normalizedSearchValue(ocrText))
            }
            return terms.allSatisfy { term in
                fields.contains { $0.contains(term) }
            }
        }

        var results: [CaptureHistoryItem] = []
        results.reserveCapacity(min(maximumResults, entries.count))
        for metadata in matches {
            guard let thumbnailData = fileManager.contents(
                atPath: thumbnailURL(id: metadata.id).path
            ) else {
                continue
            }
            results.append(item(metadata: metadata, thumbnailData: thumbnailData))
            if results.count == maximumResults { break }
        }
        return results
    }

    func save(_ payload: CaptureHistoryPayload, limit: Int) throws -> [CaptureHistoryItem] {
        guard payload.pngData.count > 8,
              payload.logicalRect.width.isFinite,
              payload.logicalRect.height.isFinite,
              payload.logicalRect.width > 0,
              payload.logicalRect.height > 0,
              payload.pixelWidth > 0,
              payload.pixelHeight > 0 else {
            throw CaptureHistoryStoreError.invalidCapture
        }
        try prepareDirectory()
        let thumbnailData = try Self.makeThumbnail(from: payload.pngData)
        let metadata = Metadata(
            id: payload.id,
            createdAt: payload.createdAt,
            label: Self.sanitizedLabel(payload.label),
            filename: Self.sanitizedFilename(payload.searchIndex.filename),
            ocrTextIndex: payload.searchIndex.ocrIndexingPolicy == .enabled
                ? Self.sanitizedOCRText(payload.searchIndex.ocrText)
                : nil,
            logicalX: payload.logicalRect.minX,
            logicalY: payload.logicalRect.minY,
            logicalWidth: payload.logicalRect.width,
            logicalHeight: payload.logicalRect.height,
            pixelWidth: payload.pixelWidth,
            pixelHeight: payload.pixelHeight
        )
        let pngURL = self.pngURL(id: payload.id)
        let thumbnailURL = self.thumbnailURL(id: payload.id)
        let metadataURL = self.metadataURL(id: payload.id)
        do {
            try payload.pngData.write(to: pngURL, options: .atomic)
            try thumbnailData.write(to: thumbnailURL, options: .atomic)
            try JSONEncoder().encode(metadata).write(to: metadataURL, options: .atomic)
        } catch {
            try? fileManager.removeItem(at: pngURL)
            try? fileManager.removeItem(at: thumbnailURL)
            try? fileManager.removeItem(at: metadataURL)
            throw error
        }

        var items = try loadValidItems().sorted { $0.createdAt > $1.createdAt }
        let safeLimit = min(500, max(1, limit))
        if items.count > safeLimit {
            for item in items.dropFirst(safeLimit) {
                removeFiles(id: item.id)
            }
            items.removeLast(items.count - safeLimit)
        }
        return items
    }

    func enforceLimit(_ limit: Int) throws -> [CaptureHistoryItem] {
        var items = try loadItems()
        let safeLimit = min(500, max(1, limit))
        if items.count > safeLimit {
            for item in items.dropFirst(safeLimit) {
                removeFiles(id: item.id)
            }
            items.removeLast(items.count - safeLimit)
        }
        return items
    }

    func loadArtifact(id: UUID) throws -> CaptureHistoryArtifact {
        let metadata = try loadMetadata(id: id)
        guard let thumbnailData = fileManager.contents(atPath: thumbnailURL(id: id).path),
              let pngData = fileManager.contents(atPath: pngURL(id: id).path) else {
            throw CaptureHistoryStoreError.missingCapture
        }
        return CaptureHistoryArtifact(
            item: item(metadata: metadata, thumbnailData: thumbnailData),
            pngData: pngData,
            searchIndex: CaptureHistorySearchIndex(
                filename: metadata.filename,
                ocrText: metadata.ocrTextIndex,
                ocrIndexingPolicy: metadata.ocrTextIndex == nil ? .disabled : .enabled
            )
        )
    }

    func delete(id: UUID) throws -> [CaptureHistoryItem] {
        removeFiles(id: id)
        return try loadItems()
    }

    func deleteAll() throws -> [CaptureHistoryItem] {
        try prepareDirectory()
        let urls = try fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: nil,
            options: []
        )
        for url in urls {
            try fileManager.removeItem(at: url)
        }
        return []
    }

    func removeAllOCRTextIndexes() throws -> [CaptureHistoryItem] {
        try prepareDirectory()
        let encoder = JSONEncoder()
        for entry in try loadDecodableMetadata() where entry.metadata.ocrTextIndex != nil {
            let metadata = entry.metadata
            let updated = Metadata(
                id: metadata.id,
                createdAt: metadata.createdAt,
                label: metadata.label,
                filename: metadata.filename,
                ocrTextIndex: nil,
                logicalX: metadata.logicalX,
                logicalY: metadata.logicalY,
                logicalWidth: metadata.logicalWidth,
                logicalHeight: metadata.logicalHeight,
                pixelWidth: metadata.pixelWidth,
                pixelHeight: metadata.pixelHeight
            )
            try encoder.encode(updated).write(
                to: entry.url,
                options: .atomic
            )
        }
        return try loadItems()
    }

    private func prepareDirectory() throws {
        try fileManager.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private func loadValidItems() throws -> [CaptureHistoryItem] {
        try loadValidMetadata().compactMap { metadata in
            guard let thumbnailData = fileManager.contents(
                atPath: thumbnailURL(id: metadata.id).path
            ) else {
                return nil
            }
            return item(metadata: metadata, thumbnailData: thumbnailData)
        }
    }

    private func loadValidMetadata() throws -> [Metadata] {
        try loadDecodableMetadata().compactMap { entry in
            let metadata = entry.metadata
            guard fileManager.fileExists(atPath: thumbnailURL(id: metadata.id).path),
                  fileManager.fileExists(atPath: pngURL(id: metadata.id).path),
                  metadata.logicalRect.width.isFinite,
                  metadata.logicalRect.height.isFinite,
                  metadata.logicalRect.width > 0,
                  metadata.logicalRect.height > 0,
                  metadata.pixelWidth > 0,
                  metadata.pixelHeight > 0 else {
                return nil
            }
            return metadata
        }
    }

    private func loadDecodableMetadata() throws -> [(url: URL, metadata: Metadata)] {
        let urls = try fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> (url: URL, metadata: Metadata)? in
                guard let data = fileManager.contents(atPath: url.path),
                      let metadata = try? JSONDecoder().decode(Metadata.self, from: data),
                      url.deletingPathExtension().lastPathComponent
                        == metadata.id.uuidString.lowercased() else {
                    return nil
                }
                return (url, metadata)
            }
    }

    private func loadMetadata(id: UUID) throws -> Metadata {
        let url = metadataURL(id: id)
        guard let data = fileManager.contents(atPath: url.path),
              let metadata = try? JSONDecoder().decode(Metadata.self, from: data),
              metadata.id == id else {
            throw CaptureHistoryStoreError.missingCapture
        }
        return metadata
    }

    private func item(metadata: Metadata, thumbnailData: Data) -> CaptureHistoryItem {
        CaptureHistoryItem(
            id: metadata.id,
            createdAt: metadata.createdAt,
            label: metadata.label,
            filename: metadata.filename,
            logicalRect: metadata.logicalRect,
            pixelWidth: metadata.pixelWidth,
            pixelHeight: metadata.pixelHeight,
            thumbnailData: thumbnailData
        )
    }

    private func removeFiles(id: UUID) {
        try? fileManager.removeItem(at: pngURL(id: id))
        try? fileManager.removeItem(at: thumbnailURL(id: id))
        try? fileManager.removeItem(at: metadataURL(id: id))
    }

    private func pngURL(id: UUID) -> URL {
        rootDirectory
            .appendingPathComponent(id.uuidString.lowercased())
            .appendingPathExtension("png")
    }

    private func thumbnailURL(id: UUID) -> URL {
        rootDirectory
            .appendingPathComponent(id.uuidString.lowercased())
            .appendingPathExtension("thumb.jpg")
    }

    private func metadataURL(id: UUID) -> URL {
        rootDirectory
            .appendingPathComponent(id.uuidString.lowercased())
            .appendingPathExtension("json")
    }

    private static func sanitizedLabel(_ value: String) -> String {
        let filtered = value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }
        let label = filtered.map(String.init).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String((label.isEmpty ? "Capture" : label).prefix(120))
    }

    private static func sanitizedFilename(_ value: String?) -> String? {
        guard let value else { return nil }
        let basename = value.split { character in
            character == "/" || character == "\\"
        }.last.map(String.init) ?? value
        let filtered = basename.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }
        let filename = filtered.map(String.init).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !filename.isEmpty else { return nil }
        return String(filename.prefix(255))
    }

    private static func sanitizedOCRText(_ value: String?) -> String? {
        guard let value else { return nil }
        let text = value
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !text.isEmpty else { return nil }
        return String(text.prefix(100_000))
    }

    private static func searchTerms(_ query: String) -> [String] {
        normalizedSearchValue(String(query.prefix(512)))
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }

    private static func normalizedSearchValue(_ value: String) -> String {
        value
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func makeThumbnail(from pngData: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(pngData as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 360,
                ] as CFDictionary
              ) else {
            throw CaptureHistoryStoreError.invalidCapture
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            "public.jpeg" as CFString,
            1,
            nil
        ) else {
            throw CaptureHistoryStoreError.thumbnailEncodingFailed
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: 0.78] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw CaptureHistoryStoreError.thumbnailEncodingFailed
        }
        return data as Data
    }
}
