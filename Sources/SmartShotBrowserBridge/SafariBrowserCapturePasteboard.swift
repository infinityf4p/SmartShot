import AppKit
import Foundation

struct SafariBrowserCapturePasteboardPayload: Sendable {
    let pngData: Data
    let metadata: BrowserCaptureImportMetadata
}

struct SafariBrowserCapturePasteboardAcknowledgement: Codable, Equatable, Sendable {
    let requestID: String
    let accepted: Bool
}

enum SafariBrowserCapturePasteboardError: LocalizedError {
    case invalidRequestID
    case writeFailed
    case missingPayload
    case invalidPayload

    var errorDescription: String? {
        switch self {
        case .invalidRequestID:
            "The Safari capture transfer identifier is invalid."
        case .writeFailed:
            "SmartShot could not publish the Safari capture transfer."
        case .missingPayload:
            "The Safari capture transfer is no longer available."
        case .invalidPayload:
            "The Safari capture transfer is invalid."
        }
    }
}

enum SafariBrowserCapturePasteboard {
    private static let captureDataType = NSPasteboard.PasteboardType(
        "com.infinityf4p.smartshot.safari-capture.png"
    )
    private static let metadataType = NSPasteboard.PasteboardType(
        "com.infinityf4p.smartshot.safari-capture.metadata"
    )
    private static let acknowledgementType = NSPasteboard.PasteboardType(
        "com.infinityf4p.smartshot.safari-capture.acknowledgement"
    )

    static func publish(_ artifact: BrowserCaptureImportArtifact) throws {
        let requestID = try normalizedRequestID(artifact.metadata.requestID)
        cleanup(requestID: requestID)

        let item = NSPasteboardItem()
        let metadataData = try JSONEncoder().encode(artifact.metadata)
        guard metadataData.count <= BrowserCaptureImportProtocol.maximumMetadataBytes,
              artifact.pngData.count == artifact.metadata.decodedByteLength,
              artifact.pngData.count <= BrowserCaptureImportProtocol.maximumDecodedBytes,
              item.setData(artifact.pngData, forType: captureDataType),
              item.setData(metadataData, forType: metadataType) else {
            throw SafariBrowserCapturePasteboardError.writeFailed
        }
        let pasteboard = capturePasteboard(requestID: requestID)
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            cleanup(requestID: requestID)
            throw SafariBrowserCapturePasteboardError.writeFailed
        }
    }

    static func payload(requestID: String) throws -> SafariBrowserCapturePasteboardPayload {
        let requestID = try normalizedRequestID(requestID)
        guard let item = capturePasteboard(requestID: requestID).pasteboardItems?.first,
              let metadataData = item.data(forType: metadataType) else {
            throw SafariBrowserCapturePasteboardError.missingPayload
        }
        guard metadataData.count <= BrowserCaptureImportProtocol.maximumMetadataBytes,
              let metadata = try? JSONDecoder().decode(
            BrowserCaptureImportMetadata.self,
            from: metadataData
        ) else {
            throw SafariBrowserCapturePasteboardError.invalidPayload
        }
        do {
            try BrowserCaptureImportStore.validateCompletedMetadata(
                metadata,
                expectedRequestID: requestID,
                expectedSource: "safari"
            )
        } catch {
            throw SafariBrowserCapturePasteboardError.invalidPayload
        }
        guard let pngData = item.data(forType: captureDataType),
              pngData.count == metadata.decodedByteLength,
              pngData.count <= BrowserCaptureImportProtocol.maximumDecodedBytes else {
            throw SafariBrowserCapturePasteboardError.invalidPayload
        }
        return SafariBrowserCapturePasteboardPayload(pngData: pngData, metadata: metadata)
    }

    static func acknowledge(requestID: String, accepted: Bool) throws {
        let requestID = try normalizedRequestID(requestID)
        guard capturePasteboard(requestID: requestID).pasteboardItems?.first?
            .data(forType: metadataType) != nil else {
            throw SafariBrowserCapturePasteboardError.missingPayload
        }
        let acknowledgement = SafariBrowserCapturePasteboardAcknowledgement(
            requestID: requestID,
            accepted: accepted
        )
        let item = NSPasteboardItem()
        let acknowledgementData = try JSONEncoder().encode(acknowledgement)
        guard acknowledgementData.count <= BrowserCaptureImportProtocol.maximumMetadataBytes,
              item.setData(acknowledgementData, forType: acknowledgementType) else {
            throw SafariBrowserCapturePasteboardError.writeFailed
        }
        let pasteboard = acknowledgementPasteboard(requestID: requestID)
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            throw SafariBrowserCapturePasteboardError.writeFailed
        }
        guard capturePasteboard(requestID: requestID).pasteboardItems?.first?
            .data(forType: metadataType) != nil else {
            cleanup(requestID: requestID)
            throw SafariBrowserCapturePasteboardError.missingPayload
        }
    }

    static func acknowledgement(
        requestID: String
    ) throws -> SafariBrowserCapturePasteboardAcknowledgement? {
        let requestID = try normalizedRequestID(requestID)
        guard let data = acknowledgementPasteboard(requestID: requestID)
            .pasteboardItems?.first?.data(forType: acknowledgementType) else {
            return nil
        }
        guard data.count <= BrowserCaptureImportProtocol.maximumMetadataBytes,
              let acknowledgement = try? JSONDecoder().decode(
            SafariBrowserCapturePasteboardAcknowledgement.self,
            from: data
        ),
            acknowledgement.requestID == requestID else {
            throw SafariBrowserCapturePasteboardError.invalidPayload
        }
        return acknowledgement
    }

    static func cleanup(requestID: String) {
        guard let requestID = try? normalizedRequestID(requestID) else { return }
        for pasteboard in [
            capturePasteboard(requestID: requestID),
            acknowledgementPasteboard(requestID: requestID),
        ] {
            pasteboard.clearContents()
            pasteboard.releaseGlobally()
        }
    }

    private static func capturePasteboard(requestID: String) -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name(
            "com.infinityf4p.SmartShot.SafariCapture.\(requestID)"
        ))
    }

    private static func acknowledgementPasteboard(requestID: String) -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name(
            "com.infinityf4p.SmartShot.SafariCaptureAck.\(requestID)"
        ))
    }

    private static func normalizedRequestID(_ value: String) throws -> String {
        guard value.count <= 64, let uuid = UUID(uuidString: value) else {
            throw SafariBrowserCapturePasteboardError.invalidRequestID
        }
        return uuid.uuidString.lowercased()
    }
}
