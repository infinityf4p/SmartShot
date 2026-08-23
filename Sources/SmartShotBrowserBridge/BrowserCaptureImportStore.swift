import CoreGraphics
import Foundation
import ImageIO

enum BrowserCaptureImportProtocol {
    static let name = "com.infinityf4p.smartshot"
    static let version = 1
    static let acknowledgementType = "capture.import.ack"
    static let maximumDecodedBytes = 64 * 1_024 * 1_024
    static let maximumBase64Length = ((maximumDecodedBytes + 2) / 3) * 4
    static let maximumChunkCharacters = 192 * 1_024
    static let maximumChunkCount = 512
    static let maximumPixelDimension = 16_384
    static let maximumPixelCount = 32_000_000
    static let maximumLogicalDimension = 20_000.0
    static let maximumAspectRatioRelativeDifference = 0.08
    static let maximumMetadataBytes = 16 * 1_024
    static let maximumCompletedAge: TimeInterval = 3_600
    static let maximumFutureClockSkew: TimeInterval = 60
    static let maximumStagedBytes = 4 * maximumDecodedBytes
    static let maximumStagedSessions = 8
}

struct BrowserCaptureImportMetadata: Codable, Equatable, Sendable {
    let requestID: String
    let source: String
    let filename: String
    let kind: String
    let sourceOrigin: String
    let chunkCount: Int
    let base64Length: Int
    let decodedByteLength: Int
    let logicalWidth: Double
    let logicalHeight: Double
    let pixelWidth: Int?
    let pixelHeight: Int?
    let createdAt: Date
}

struct BrowserCaptureImportArtifact: @unchecked Sendable {
    let image: CGImage
    let pngData: Data
    let metadata: BrowserCaptureImportMetadata
}

struct BrowserCaptureImportHandlingResult {
    let response: [String: Any]
    let completedRequestID: String?
}

enum BrowserCaptureImportStoreError: LocalizedError {
    case invalidEnvelope
    case invalidRequestID
    case invalidMetadata
    case invalidChunk
    case missingSession
    case incompleteSession
    case imageTooLarge
    case storageLimitExceeded
    case invalidPNG
    case invalidGeometry
    case missingCapture

    var errorDescription: String? {
        switch self {
        case .invalidEnvelope:
            "The browser import message is invalid."
        case .invalidRequestID:
            "The browser import request identifier is invalid."
        case .invalidMetadata:
            "The browser import metadata is invalid."
        case .invalidChunk:
            "A browser import chunk is invalid."
        case .missingSession:
            "The browser import session no longer exists."
        case .incompleteSession:
            "The browser import did not receive every image chunk."
        case .imageTooLarge:
            "The browser capture exceeds SmartShot's import limits."
        case .storageLimitExceeded:
            "SmartShot's browser import staging area is full."
        case .invalidPNG:
            "The browser capture is not a valid PNG image."
        case .invalidGeometry:
            "The browser capture dimensions are inconsistent."
        case .missingCapture:
            "The browser capture is no longer available."
        }
    }

    var code: String {
        switch self {
        case .invalidEnvelope: "invalid_envelope"
        case .invalidRequestID: "invalid_request_id"
        case .invalidMetadata: "invalid_metadata"
        case .invalidChunk: "invalid_chunk"
        case .missingSession: "missing_session"
        case .incompleteSession: "incomplete_session"
        case .imageTooLarge: "image_too_large"
        case .storageLimitExceeded: "storage_limit"
        case .invalidPNG: "invalid_png"
        case .invalidGeometry: "invalid_geometry"
        case .missingCapture: "missing_capture"
        }
    }
}

final class BrowserCaptureImportStore {
    private let rootDirectory: URL
    private let source: String
    private let fileManager: FileManager
    private let maximumStagedBytes: Int
    private let maximumStagedSessions: Int
    private let lock = NSLock()

    init(
        rootDirectory: URL,
        source: String,
        fileManager: FileManager = .default,
        maximumStagedBytes: Int = BrowserCaptureImportProtocol.maximumStagedBytes,
        maximumStagedSessions: Int = BrowserCaptureImportProtocol.maximumStagedSessions
    ) {
        precondition(maximumStagedBytes > 0)
        precondition(maximumStagedSessions > 0)
        self.rootDirectory = rootDirectory
        self.source = source
        self.fileManager = fileManager
        self.maximumStagedBytes = maximumStagedBytes
        self.maximumStagedSessions = maximumStagedSessions

        if (try? prepareDirectories()) != nil {
            cleanupExpiredItems()
        }
    }

    func handle(_ message: [String: Any]) -> BrowserCaptureImportHandlingResult {
        lock.lock()
        defer { lock.unlock() }

        let requestID = message["requestId"] as? String ?? ""
        let messageType = message["type"] as? String
        do {
            let validatedRequestID = try Self.validatedRequestID(requestID)
            guard message["protocol"] as? String == BrowserCaptureImportProtocol.name,
                  Self.integer(message["version"]) == BrowserCaptureImportProtocol.version,
                  let type = message["type"] as? String,
                  let payload = message["payload"] as? [String: Any] else {
                throw BrowserCaptureImportStoreError.invalidEnvelope
            }

            let completedRequestID: String?
            let stage: String
            let acknowledgementIndex: Int?
            switch type {
            case "capture.import.begin":
                try begin(requestID: validatedRequestID, payload: payload)
                completedRequestID = nil
                stage = "begin"
                acknowledgementIndex = nil
            case "capture.import.chunk":
                acknowledgementIndex = try appendChunk(
                    requestID: validatedRequestID,
                    payload: payload
                )
                completedRequestID = nil
                stage = "chunk"
            case "capture.import.end":
                try finish(requestID: validatedRequestID, payload: payload)
                completedRequestID = validatedRequestID
                stage = "end"
                acknowledgementIndex = nil
            default:
                throw BrowserCaptureImportStoreError.invalidEnvelope
            }

            return BrowserCaptureImportHandlingResult(
                response: Self.acknowledgement(
                    requestID: validatedRequestID,
                    accepted: true,
                    stage: stage,
                    index: acknowledgementIndex
                ),
                completedRequestID: completedRequestID
            )
        } catch let error as BrowserCaptureImportStoreError {
            discardPartialCaptureAfterRejectedTransfer(
                requestID: requestID,
                messageType: messageType
            )
            return BrowserCaptureImportHandlingResult(
                response: Self.acknowledgement(
                    requestID: requestID,
                    accepted: false,
                    errorCode: error.code
                ),
                completedRequestID: nil
            )
        } catch {
            discardPartialCaptureAfterRejectedTransfer(
                requestID: requestID,
                messageType: messageType
            )
            return BrowserCaptureImportHandlingResult(
                response: Self.acknowledgement(
                    requestID: requestID,
                    accepted: false,
                    errorCode: "io_failure"
                ),
                completedRequestID: nil
            )
        }
    }

    func discardCompletedCapture(requestID: String) {
        guard let requestID = try? Self.validatedRequestID(requestID) else { return }
        try? fileManager.removeItem(at: completedPNGURL(requestID: requestID))
        try? fileManager.removeItem(at: completedMetadataURL(requestID: requestID))
    }

    func completedCaptureExists(requestID: String) -> Bool {
        guard let requestID = try? Self.validatedRequestID(requestID) else { return false }
        return fileManager.fileExists(atPath: completedPNGURL(requestID: requestID).path) ||
            fileManager.fileExists(atPath: completedMetadataURL(requestID: requestID).path)
    }

    func consumeCompletedCapture(requestID: String) throws -> BrowserCaptureImportArtifact {
        let artifact = try loadCompletedCapture(requestID: requestID)
        let requestID = try Self.validatedRequestID(requestID)
        try fileManager.removeItem(at: completedPNGURL(requestID: requestID))
        try fileManager.removeItem(at: completedMetadataURL(requestID: requestID))
        return artifact
    }

    func loadCompletedCapture(requestID: String) throws -> BrowserCaptureImportArtifact {
        let requestID = try Self.validatedRequestID(requestID)
        let metadataURL = completedMetadataURL(requestID: requestID)
        let pngURL = completedPNGURL(requestID: requestID)
        guard fileManager.fileExists(atPath: metadataURL.path),
              fileManager.fileExists(atPath: pngURL.path) else {
            throw BrowserCaptureImportStoreError.missingCapture
        }

        let metadataValues = try metadataURL.resourceValues(
            forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
        )
        guard metadataValues.isRegularFile == true,
              metadataValues.isSymbolicLink != true,
              let metadataSize = metadataValues.fileSize,
              metadataSize > 0,
              metadataSize <= BrowserCaptureImportProtocol.maximumMetadataBytes else {
            throw BrowserCaptureImportStoreError.invalidMetadata
        }
        let pngValues = try pngURL.resourceValues(
            forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
        )
        guard pngValues.isRegularFile == true,
              pngValues.isSymbolicLink != true,
              let pngSize = pngValues.fileSize,
              pngSize > 0,
              pngSize <= BrowserCaptureImportProtocol.maximumDecodedBytes else {
            throw BrowserCaptureImportStoreError.imageTooLarge
        }
        let metadata = try JSONDecoder().decode(
            BrowserCaptureImportMetadata.self,
            from: Data(contentsOf: metadataURL, options: .mappedIfSafe)
        )
        let pngData = try Data(contentsOf: pngURL, options: .mappedIfSafe)
        let artifact = try Self.validatedArtifact(
            pngData: pngData,
            metadata: metadata,
            expectedRequestID: requestID,
            expectedSource: source
        )
        return artifact
    }

    static func validatedArtifact(
        pngData: Data,
        metadata: BrowserCaptureImportMetadata,
        expectedRequestID: String,
        expectedSource: String
    ) throws -> BrowserCaptureImportArtifact {
        try validateCompletedMetadata(
            metadata,
            expectedRequestID: expectedRequestID,
            expectedSource: expectedSource,
            decodedByteLength: pngData.count
        )
        let image = try validatedPNGImage(pngData)
        guard metadata.pixelWidth == image.width,
              metadata.pixelHeight == image.height else {
            throw BrowserCaptureImportStoreError.invalidPNG
        }
        try validateGeometry(
            image: image,
            logicalWidth: metadata.logicalWidth,
            logicalHeight: metadata.logicalHeight
        )
        return BrowserCaptureImportArtifact(image: image, pngData: pngData, metadata: metadata)
    }

    static func validateCompletedMetadata(
        _ metadata: BrowserCaptureImportMetadata,
        expectedRequestID: String,
        expectedSource: String,
        decodedByteLength: Int? = nil,
        now: Date = Date()
    ) throws {
        let requestID = try validatedRequestID(expectedRequestID)
        let age = now.timeIntervalSince(metadata.createdAt)
        guard metadata.requestID == requestID,
              metadata.source == expectedSource,
              metadata.filename == sanitizedLabel(metadata.filename, fallback: "SmartShot"),
              metadata.kind == sanitizedKind(metadata.kind),
              metadata.sourceOrigin == sanitizedOrigin(metadata.sourceOrigin),
              metadata.chunkCount > 0,
              metadata.chunkCount <= BrowserCaptureImportProtocol.maximumChunkCount,
              metadata.base64Length > 0,
              metadata.base64Length <= BrowserCaptureImportProtocol.maximumBase64Length,
              metadata.decodedByteLength > 0,
              metadata.decodedByteLength <= BrowserCaptureImportProtocol.maximumDecodedBytes,
              metadata.base64Length == ((metadata.decodedByteLength + 2) / 3) * 4,
              metadata.chunkCount == requiredChunkCount(base64Length: metadata.base64Length),
              metadata.logicalWidth.isFinite,
              metadata.logicalHeight.isFinite,
              metadata.logicalWidth > 0,
              metadata.logicalHeight > 0,
              metadata.logicalWidth <= BrowserCaptureImportProtocol.maximumLogicalDimension,
              metadata.logicalHeight <= BrowserCaptureImportProtocol.maximumLogicalDimension,
              let pixelWidth = metadata.pixelWidth,
              let pixelHeight = metadata.pixelHeight,
              pixelWidth > 0,
              pixelHeight > 0,
              pixelWidth <= BrowserCaptureImportProtocol.maximumPixelDimension,
              pixelHeight <= BrowserCaptureImportProtocol.maximumPixelDimension,
              age >= -BrowserCaptureImportProtocol.maximumFutureClockSkew,
              age <= BrowserCaptureImportProtocol.maximumCompletedAge else {
            throw BrowserCaptureImportStoreError.invalidMetadata
        }
        let (pixelCount, overflow) = pixelWidth.multipliedReportingOverflow(by: pixelHeight)
        guard !overflow,
              pixelCount <= BrowserCaptureImportProtocol.maximumPixelCount,
              decodedByteLength == nil || decodedByteLength == metadata.decodedByteLength else {
            throw BrowserCaptureImportStoreError.invalidMetadata
        }
    }

    static func applicationSupportRoot(fileManager: FileManager = .default) throws -> URL {
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw BrowserCaptureImportStoreError.missingSession
        }
        return applicationSupport
            .appendingPathComponent("SmartShot", isDirectory: true)
            .appendingPathComponent("BrowserImports", isDirectory: true)
    }

    private func begin(requestID: String, payload: [String: Any]) throws {
        guard payload["mimeType"] as? String == "image/png",
              payload["encoding"] as? String == "base64",
              let chunkCount = Self.integer(payload["chunkCount"]),
              (1...BrowserCaptureImportProtocol.maximumChunkCount).contains(chunkCount),
              let base64Length = Self.integer(payload["base64Length"]),
              base64Length > 0,
              base64Length <= BrowserCaptureImportProtocol.maximumBase64Length,
              chunkCount == Self.requiredChunkCount(base64Length: base64Length),
              let decodedByteLength = Self.integer(payload["byteLength"]),
              decodedByteLength > 0,
              decodedByteLength <= BrowserCaptureImportProtocol.maximumDecodedBytes,
              base64Length == ((decodedByteLength + 2) / 3) * 4,
              let logicalWidth = Self.double(payload["logicalWidth"]),
              let logicalHeight = Self.double(payload["logicalHeight"]),
              logicalWidth > 0,
              logicalHeight > 0,
              logicalWidth <= BrowserCaptureImportProtocol.maximumLogicalDimension,
              logicalHeight <= BrowserCaptureImportProtocol.maximumLogicalDimension else {
            throw BrowserCaptureImportStoreError.invalidMetadata
        }

        let filename = Self.sanitizedLabel(payload["filename"] as? String, fallback: "SmartShot")
        let kind = Self.sanitizedKind(payload["kind"] as? String)
        let sourceOrigin = Self.sanitizedOrigin(payload["sourceOrigin"] as? String)
        let metadata = BrowserCaptureImportMetadata(
            requestID: requestID,
            source: source,
            filename: filename,
            kind: kind,
            sourceOrigin: sourceOrigin,
            chunkCount: chunkCount,
            base64Length: base64Length,
            decodedByteLength: decodedByteLength,
            logicalWidth: logicalWidth,
            logicalHeight: logicalHeight,
            pixelWidth: nil,
            pixelHeight: nil,
            createdAt: Date()
        )

        try prepareDirectories()
        cleanupExpiredItems()
        let sessionDirectory = partialSessionURL(requestID: requestID)
        if fileManager.fileExists(atPath: sessionDirectory.path) {
            try fileManager.removeItem(at: sessionDirectory)
        }
        do {
            try fileManager.createDirectory(
                at: sessionDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            try JSONEncoder().encode(metadata).write(
                to: sessionMetadataURL(requestID: requestID),
                options: .atomic
            )
            let usage = try stagedUsage()
            guard usage.bytes <= maximumStagedBytes,
                  usage.sessions <= maximumStagedSessions else {
                throw BrowserCaptureImportStoreError.storageLimitExceeded
            }
        } catch {
            try? fileManager.removeItem(at: sessionDirectory)
            throw error
        }
    }

    private func appendChunk(requestID: String, payload: [String: Any]) throws -> Int {
        let metadata = try sessionMetadata(requestID: requestID)
        guard let index = Self.integer(payload["index"]),
              (0..<metadata.chunkCount).contains(index),
              let chunk = payload["data"] as? String,
              !chunk.isEmpty,
              chunk.utf8.count <= BrowserCaptureImportProtocol.maximumChunkCharacters,
              chunk.unicodeScalars.allSatisfy({ Self.base64Characters.contains($0) }) else {
            throw BrowserCaptureImportStoreError.invalidChunk
        }
        for previousIndex in 0..<index where !fileManager.fileExists(
            atPath: chunkURL(requestID: requestID, index: previousIndex).path
        ) {
            throw BrowserCaptureImportStoreError.invalidChunk
        }
        let chunkURL = self.chunkURL(requestID: requestID, index: index)
        guard !fileManager.fileExists(atPath: chunkURL.path) else {
            throw BrowserCaptureImportStoreError.invalidChunk
        }
        let chunkOffset = index * BrowserCaptureImportProtocol.maximumChunkCharacters
        let expectedLength = min(
            BrowserCaptureImportProtocol.maximumChunkCharacters,
            metadata.base64Length - chunkOffset
        )
        guard expectedLength > 0, chunk.utf8.count == expectedLength else {
            throw BrowserCaptureImportStoreError.invalidChunk
        }
        try Data(chunk.utf8).write(to: chunkURL, options: .atomic)
        return index
    }

    private func finish(requestID: String, payload: [String: Any]) throws {
        let metadata = try sessionMetadata(requestID: requestID)
        guard Self.integer(payload["byteLength"]) == metadata.decodedByteLength,
              Self.integer(payload["chunkCount"]) == metadata.chunkCount else {
            throw BrowserCaptureImportStoreError.invalidMetadata
        }
        var encoded = Data()
        encoded.reserveCapacity(metadata.base64Length)
        for index in 0..<metadata.chunkCount {
            let chunkURL = chunkURL(requestID: requestID, index: index)
            guard fileManager.fileExists(atPath: chunkURL.path) else {
                throw BrowserCaptureImportStoreError.incompleteSession
            }
            let chunk = try Data(contentsOf: chunkURL, options: .mappedIfSafe)
            guard chunk.count <= BrowserCaptureImportProtocol.maximumChunkCharacters,
                  encoded.count <= metadata.base64Length - chunk.count else {
                throw BrowserCaptureImportStoreError.invalidChunk
            }
            encoded.append(chunk)
        }
        guard encoded.count == metadata.base64Length,
              let pngData = Data(base64Encoded: encoded),
              pngData.count == metadata.decodedByteLength,
              pngData.count <= BrowserCaptureImportProtocol.maximumDecodedBytes else {
            throw BrowserCaptureImportStoreError.invalidPNG
        }

        let image = try Self.validatedPNGImage(pngData)
        try Self.validateGeometry(
            image: image,
            logicalWidth: metadata.logicalWidth,
            logicalHeight: metadata.logicalHeight
        )
        let completedMetadata = BrowserCaptureImportMetadata(
            requestID: metadata.requestID,
            source: metadata.source,
            filename: metadata.filename,
            kind: metadata.kind,
            sourceOrigin: metadata.sourceOrigin,
            chunkCount: metadata.chunkCount,
            base64Length: metadata.base64Length,
            decodedByteLength: metadata.decodedByteLength,
            logicalWidth: metadata.logicalWidth,
            logicalHeight: metadata.logicalHeight,
            pixelWidth: image.width,
            pixelHeight: image.height,
            createdAt: metadata.createdAt
        )
        try pngData.write(to: completedPNGURL(requestID: requestID), options: .atomic)
        do {
            try JSONEncoder().encode(completedMetadata).write(
                to: completedMetadataURL(requestID: requestID),
                options: .atomic
            )
        } catch {
            try? fileManager.removeItem(at: completedPNGURL(requestID: requestID))
            throw error
        }
        try fileManager.removeItem(at: partialSessionURL(requestID: requestID))
    }

    private func prepareDirectories() throws {
        for directory in [rootDirectory, partialRootURL, inboxRootURL] {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
    }

    private func discardPartialCaptureAfterRejectedTransfer(
        requestID: String,
        messageType: String?
    ) {
        guard messageType == "capture.import.chunk" || messageType == "capture.import.end",
              let requestID = try? Self.validatedRequestID(requestID) else { return }
        try? fileManager.removeItem(at: partialSessionURL(requestID: requestID))
    }

    private func sessionMetadata(requestID: String) throws -> BrowserCaptureImportMetadata {
        let url = sessionMetadataURL(requestID: requestID)
        guard fileManager.fileExists(atPath: url.path) else {
            throw BrowserCaptureImportStoreError.missingSession
        }
        let metadata = try JSONDecoder().decode(
            BrowserCaptureImportMetadata.self,
            from: Data(contentsOf: url, options: .mappedIfSafe)
        )
        guard metadata.requestID == requestID,
              metadata.source == source,
              metadata.pixelWidth == nil,
              metadata.pixelHeight == nil else {
            throw BrowserCaptureImportStoreError.invalidMetadata
        }
        return metadata
    }

    private func cleanupExpiredItems() {
        let expiration = Date().addingTimeInterval(-3_600)
        for directory in [partialRootURL, inboxRootURL] {
            guard let contents = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for url in contents {
                guard let modified = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate,
                    modified < expiration else { continue }
                try? fileManager.removeItem(at: url)
            }
        }
    }

    private func stagedUsage() throws -> (bytes: Int, sessions: Int) {
        var bytes = 0
        var sessions = 0

        let partialItems = try fileManager.contentsOfDirectory(
            at: partialRootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        for item in partialItems {
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { continue }
            sessions = try adding(sessions, 1)
            let actualBytes = try regularFileBytes(in: item)
            let reservedBytes = values.isDirectory == true ? metadataReservation(in: item) : 0
            bytes = try adding(bytes, max(actualBytes, reservedBytes))
        }

        var completedRequestIDs = Set<String>()
        let inboxItems = try fileManager.contentsOfDirectory(
            at: inboxRootURL,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        for item in inboxItems {
            let values = try item.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true else { continue }
            bytes = try adding(bytes, values.fileSize ?? 0)
            completedRequestIDs.insert(item.deletingPathExtension().lastPathComponent)
        }
        sessions = try adding(sessions, completedRequestIDs.count)
        return (bytes, sessions)
    }

    private func regularFileBytes(in directory: URL) throws -> Int {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var bytes = 0
        for case let item as URL in enumerator {
            let values = try item.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
            )
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            guard values.isRegularFile == true else { continue }
            bytes = try adding(bytes, values.fileSize ?? 0)
        }
        return bytes
    }

    private func metadataReservation(in sessionDirectory: URL) -> Int {
        let metadataURL = sessionDirectory.appendingPathComponent("metadata.json")
        guard let values = try? metadataURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ),
            values.isRegularFile == true,
            values.isSymbolicLink != true,
            let data = try? Data(contentsOf: metadataURL, options: .mappedIfSafe),
            let metadata = try? JSONDecoder().decode(BrowserCaptureImportMetadata.self, from: data),
            metadata.source == source,
            metadata.base64Length > 0,
            metadata.base64Length <= BrowserCaptureImportProtocol.maximumBase64Length else {
            return 0
        }
        return metadata.base64Length
    }

    private func adding(_ left: Int, _ right: Int) throws -> Int {
        let (result, overflow) = left.addingReportingOverflow(right)
        guard !overflow else {
            throw BrowserCaptureImportStoreError.storageLimitExceeded
        }
        return result
    }

    private var partialRootURL: URL {
        rootDirectory.appendingPathComponent("Partial", isDirectory: true)
    }

    private var inboxRootURL: URL {
        rootDirectory.appendingPathComponent("Inbox", isDirectory: true)
    }

    private func partialSessionURL(requestID: String) -> URL {
        partialRootURL.appendingPathComponent(requestID, isDirectory: true)
    }

    private func sessionMetadataURL(requestID: String) -> URL {
        partialSessionURL(requestID: requestID).appendingPathComponent("metadata.json")
    }

    private func chunkURL(requestID: String, index: Int) -> URL {
        partialSessionURL(requestID: requestID)
            .appendingPathComponent(String(format: "chunk-%04d.txt", index))
    }

    private func completedPNGURL(requestID: String) -> URL {
        inboxRootURL.appendingPathComponent(requestID).appendingPathExtension("png")
    }

    private func completedMetadataURL(requestID: String) -> URL {
        inboxRootURL.appendingPathComponent(requestID).appendingPathExtension("json")
    }

    private static let base64Characters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/="
    )

    private static func validatedRequestID(_ value: String) throws -> String {
        guard value.count <= 64, let uuid = UUID(uuidString: value) else {
            throw BrowserCaptureImportStoreError.invalidRequestID
        }
        return uuid.uuidString.lowercased()
    }

    private static func requiredChunkCount(base64Length: Int) -> Int {
        (base64Length + BrowserCaptureImportProtocol.maximumChunkCharacters - 1)
            / BrowserCaptureImportProtocol.maximumChunkCharacters
    }

    private static func integer(_ value: Any?) -> Int? {
        if value is Bool { return nil }
        if let value = value as? Int { return value }
        if let value = value as? NSNumber {
            let number = value.doubleValue
            guard number.isFinite,
                  number.rounded(.towardZero) == number,
                  number >= Double(Int.min),
                  number <= Double(Int.max) else { return nil }
            return Int(number)
        }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        if value is Bool { return nil }
        let number: Double?
        if let value = value as? Double {
            number = value
        } else if let value = value as? NSNumber {
            number = value.doubleValue
        } else {
            number = nil
        }
        guard let number, number.isFinite else { return nil }
        return number
    }

    private static func sanitizedLabel(_ value: String?, fallback: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:")
        let allowed = (value ?? "")
            .unicodeScalars
            .filter {
                !CharacterSet.controlCharacters.contains($0) && !forbidden.contains($0)
            }
        let result = allowed.map(String.init).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String((result.isEmpty ? fallback : result).prefix(120))
    }

    private static func sanitizedKind(_ value: String?) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-:")
        let result = String((value ?? "block").lowercased().filter { allowed.contains($0) })
        return String((result.isEmpty ? "block" : result).prefix(32))
    }

    private static func sanitizedOrigin(_ value: String?) -> String {
        guard let value,
              value.count <= 2_048,
              var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host != nil else { return "" }
        components.user = nil
        components.password = nil
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.string ?? ""
    }

    private static func validatedPNGImage(_ data: Data) throws -> CGImage {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard data.count >= signature.count,
              Array(data.prefix(signature.count)) == signature,
              data.count <= BrowserCaptureImportProtocol.maximumDecodedBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw BrowserCaptureImportStoreError.invalidPNG
        }
        let (pixelCount, overflow) = image.width.multipliedReportingOverflow(by: image.height)
        guard !overflow,
              image.width > 0,
              image.height > 0,
              image.width <= BrowserCaptureImportProtocol.maximumPixelDimension,
              image.height <= BrowserCaptureImportProtocol.maximumPixelDimension,
              pixelCount <= BrowserCaptureImportProtocol.maximumPixelCount else {
            throw BrowserCaptureImportStoreError.imageTooLarge
        }
        return image
    }

    private static func validateGeometry(
        image: CGImage,
        logicalWidth: Double,
        logicalHeight: Double
    ) throws {
        let pixelAspect = Double(image.width) / Double(image.height)
        let logicalAspect = logicalWidth / logicalHeight
        let relativeDifference = abs(pixelAspect - logicalAspect) / max(0.000_001, logicalAspect)
        guard pixelAspect.isFinite,
              logicalAspect.isFinite,
              relativeDifference <= BrowserCaptureImportProtocol.maximumAspectRatioRelativeDifference else {
            throw BrowserCaptureImportStoreError.invalidGeometry
        }
    }

    private static func acknowledgement(
        requestID: String,
        accepted: Bool,
        stage: String? = nil,
        index: Int? = nil,
        errorCode: String? = nil
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "accepted": accepted,
            "handledBy": accepted ? "native" : "browser",
        ]
        if let stage { payload["stage"] = stage }
        if let index { payload["index"] = index }
        if let errorCode { payload["errorCode"] = errorCode }
        return [
            "protocol": BrowserCaptureImportProtocol.name,
            "version": BrowserCaptureImportProtocol.version,
            "type": BrowserCaptureImportProtocol.acknowledgementType,
            "requestId": requestID,
            "payload": payload,
        ]
    }
}
