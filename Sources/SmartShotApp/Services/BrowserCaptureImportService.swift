import SmartShotCore
import AppKit
import CoreGraphics
import Foundation

enum BrowserCaptureImportServiceError: LocalizedError {
    case invalidURL
    case unsupportedSource
    case invalidGeometry

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            L10n.text("SmartShot received an invalid browser import URL.")
        case .unsupportedSource:
            L10n.text("SmartShot does not recognize this browser import source.")
        case .invalidGeometry:
            L10n.text("The browser capture dimensions are inconsistent.")
        }
    }
}

enum BrowserCaptureImportSource: String, Hashable, Sendable {
    case chromium
    case safari
}

struct BrowserCaptureImportRequest: Hashable, Sendable {
    let requestID: String
    let source: BrowserCaptureImportSource

    init(url: URL) throws {
        guard Self.canHandle(url),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.path.isEmpty,
              components.fragment == nil,
              let queryItems = components.queryItems,
              queryItems.count == 2 else {
            throw BrowserCaptureImportServiceError.invalidURL
        }

        var values: [String: String] = [:]
        for item in queryItems {
            guard (item.name == "requestId" || item.name == "source"),
                  let value = item.value,
                  values.updateValue(value, forKey: item.name) == nil else {
                throw BrowserCaptureImportServiceError.invalidURL
            }
        }
        guard let requestIDValue = values["requestId"],
              requestIDValue.count <= 64,
              let requestUUID = UUID(uuidString: requestIDValue),
              let sourceValue = values["source"]?.lowercased(),
              let source = BrowserCaptureImportSource(rawValue: sourceValue) else {
            throw BrowserCaptureImportServiceError.unsupportedSource
        }
        requestID = requestUUID.uuidString.lowercased()
        self.source = source
    }

    static func canHandle(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "smartshot" && url.host?.lowercased() == "import"
    }
}

enum BrowserCaptureImportEnqueueResult: Equatable {
    case enqueued
    case duplicate
    case alreadyCompleted
    case full
}

struct BrowserCaptureImportQueue {
    private(set) var pending: [BrowserCaptureImportRequest] = []
    private(set) var active: BrowserCaptureImportRequest?
    private(set) var completed: [BrowserCaptureImportRequest] = []
    let maximumOutstanding: Int
    let maximumCompleted: Int

    init(
        maximumOutstanding: Int = 1,
        maximumCompleted: Int = 32
    ) {
        precondition(maximumOutstanding > 0)
        precondition(maximumCompleted > 0)
        self.maximumOutstanding = maximumOutstanding
        self.maximumCompleted = maximumCompleted
    }

    mutating func enqueue(_ request: BrowserCaptureImportRequest) -> BrowserCaptureImportEnqueueResult {
        if completed.contains(request) { return .alreadyCompleted }
        if active == request || pending.contains(request) { return .duplicate }
        let outstanding = pending.count + (active == nil ? 0 : 1)
        guard outstanding < maximumOutstanding else { return .full }
        pending.append(request)
        return .enqueued
    }

    mutating func startNext() -> BrowserCaptureImportRequest? {
        guard active == nil, !pending.isEmpty else { return nil }
        let request = pending.removeFirst()
        active = request
        return request
    }

    mutating func finishActive(
        _ request: BrowserCaptureImportRequest,
        completedSuccessfully: Bool
    ) {
        guard active == request else { return }
        active = nil
        guard completedSuccessfully else { return }
        completed.append(request)
        if completed.count > maximumCompleted {
            completed.removeFirst(completed.count - maximumCompleted)
        }
    }

    mutating func removePending() -> [BrowserCaptureImportRequest] {
        defer { pending.removeAll() }
        return pending
    }
}

@MainActor
struct BrowserCaptureImportService {
    func canHandle(_ url: URL) -> Bool {
        BrowserCaptureImportRequest.canHandle(url)
    }

    func request(from url: URL) throws -> BrowserCaptureImportRequest {
        try BrowserCaptureImportRequest(url: url)
    }

    func importCapture(_ request: BrowserCaptureImportRequest) async throws -> CapturedImage {
        let artifact: BrowserCaptureImportArtifact
        switch request.source {
        case .chromium:
            artifact = try await Task.detached(priority: .userInitiated) {
                let store = try Self.chromiumStore()
                return try store.loadCompletedCapture(requestID: request.requestID)
            }.value
        case .safari:
            let payload = try SafariBrowserCapturePasteboard.payload(
                requestID: request.requestID
            )
            artifact = try await Task.detached(priority: .userInitiated) {
                try BrowserCaptureImportStore.validatedArtifact(
                    pngData: payload.pngData,
                    metadata: payload.metadata,
                    expectedRequestID: request.requestID,
                    expectedSource: BrowserCaptureImportSource.safari.rawValue
                )
            }.value
        }

        let logicalSize = CGSize(
            width: artifact.metadata.logicalWidth,
            height: artifact.metadata.logicalHeight
        )
        guard logicalSize.width.isFinite,
              logicalSize.height.isFinite,
              logicalSize.width > 0,
              logicalSize.height > 0 else {
            throw BrowserCaptureImportServiceError.invalidGeometry
        }
        let pixelAspect = Double(artifact.image.width) / Double(artifact.image.height)
        let logicalAspect = logicalSize.width / logicalSize.height
        guard abs(pixelAspect - logicalAspect) / max(0.000_001, logicalAspect) <= 0.08 else {
            throw BrowserCaptureImportServiceError.invalidGeometry
        }

        let label = artifact.metadata.kind == "x-post"
            ? "X post"
            : "Web \(artifact.metadata.kind)"
        return CapturedImage(
            cgImage: artifact.image,
            image: NSImage(cgImage: artifact.image, size: logicalSize),
            pngData: artifact.pngData,
            logicalRect: CGRect(origin: .zero, size: logicalSize),
            label: label
        )
    }

    func finalize(_ request: BrowserCaptureImportRequest, accepted: Bool) {
        switch request.source {
        case .chromium:
            guard accepted, let store = try? Self.chromiumStore() else { return }
            store.discardCompletedCapture(requestID: request.requestID)
        case .safari:
            try? SafariBrowserCapturePasteboard.acknowledge(
                requestID: request.requestID,
                accepted: accepted
            )
        }
    }

    private nonisolated static func chromiumStore(
        fileManager: FileManager = .default
    ) throws -> BrowserCaptureImportStore {
        let root = try BrowserCaptureImportStore.applicationSupportRoot(fileManager: fileManager)
        return BrowserCaptureImportStore(
            rootDirectory: root,
            source: BrowserCaptureImportSource.chromium.rawValue,
            fileManager: fileManager
        )
    }
}
