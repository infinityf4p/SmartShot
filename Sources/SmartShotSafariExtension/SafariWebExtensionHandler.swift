import Foundation
import SafariServices

private final class SafariApplicationOpenState: @unchecked Sendable {
    let context: NSExtensionContext
    let requestID: String
    let acceptedResponse: [String: Any]
    let deadline: ContinuousClock.Instant

    private let lock = NSLock()
    private var openResult: Bool?
    private var completed = false

    init(
        context: NSExtensionContext,
        requestID: String,
        acceptedResponse: [String: Any],
        deadline: ContinuousClock.Instant
    ) {
        self.context = context
        self.requestID = requestID
        self.acceptedResponse = acceptedResponse
        self.deadline = deadline
    }

    func recordOpenResult(_ opened: Bool) {
        lock.lock()
        if !completed { openResult = opened }
        lock.unlock()
    }

    func snapshot() -> (openResult: Bool?, completed: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (openResult, completed)
    }

    func complete(with message: [String: Any]) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        lock.unlock()

        SafariBrowserCapturePasteboard.cleanup(requestID: requestID)
        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: message]
        context.completeRequest(returningItems: [response])
    }
}

final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    private static let applicationAcknowledgementTimeout: Duration = .seconds(10)
    private static let acknowledgementPollInterval: TimeInterval = 0.05

    private lazy var importStore: BrowserCaptureImportStore? = {
        guard let rootDirectory = try? BrowserCaptureImportStore.applicationSupportRoot() else {
            return nil
        }
        return BrowserCaptureImportStore(rootDirectory: rootDirectory, source: "safari")
    }()

    func beginRequest(with context: NSExtensionContext) {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.applicationAcknowledgementTimeout)
        let request = context.inputItems.first as? NSExtensionItem
        let message = request?.userInfo?[SFExtensionMessageKey] as? [String: Any]
        let requestID = message?["requestId"] as? String ?? ""
        guard let message, let importStore else {
            Self.complete(
                context,
                with: Self.rejectedResponse(requestID: requestID, code: "store_unavailable")
            )
            return
        }

        let result = importStore.handle(message)
        guard let completedRequestID = result.completedRequestID else {
            Self.complete(context, with: result.response)
            return
        }
        let artifact: BrowserCaptureImportArtifact
        do {
            artifact = try importStore.consumeCompletedCapture(requestID: completedRequestID)
            try SafariBrowserCapturePasteboard.publish(artifact)
        } catch {
            importStore.discardCompletedCapture(requestID: completedRequestID)
            SafariBrowserCapturePasteboard.cleanup(requestID: completedRequestID)
            Self.complete(
                context,
                with: Self.rejectedResponse(
                    requestID: completedRequestID,
                    code: "transfer_unavailable"
                )
            )
            return
        }
        guard let url = Self.importURL(requestID: completedRequestID) else {
            SafariBrowserCapturePasteboard.cleanup(requestID: completedRequestID)
            Self.complete(
                context,
                with: Self.rejectedResponse(
                    requestID: completedRequestID,
                    code: "invalid_import_url"
                )
            )
            return
        }

        let openState = SafariApplicationOpenState(
            context: context,
            requestID: completedRequestID,
            acceptedResponse: result.response,
            deadline: deadline
        )
        DispatchQueue.global(qos: .userInitiated).async { [openState] in
            Self.waitForApplicationAcknowledgement(openState)
        }
        context.open(url) { [openState] opened in
            openState.recordOpenResult(opened)
        }
    }

    private static func waitForApplicationAcknowledgement(
        _ state: SafariApplicationOpenState
    ) {
        let clock = ContinuousClock()
        while clock.now < state.deadline {
            let snapshot = state.snapshot()
            if snapshot.completed { return }
            if let opened = snapshot.openResult {
                guard opened else {
                    state.complete(with: rejectedResponse(
                        requestID: state.requestID,
                        code: "app_unavailable"
                    ))
                    return
                }
                do {
                    if let acknowledgement = try SafariBrowserCapturePasteboard.acknowledgement(
                        requestID: state.requestID
                    ) {
                        state.complete(
                            with: acknowledgement.accepted
                                ? state.acceptedResponse
                                : rejectedResponse(
                                    requestID: state.requestID,
                                    code: "app_rejected"
                                )
                        )
                        return
                    }
                } catch {
                    state.complete(with: rejectedResponse(
                        requestID: state.requestID,
                        code: "invalid_app_ack"
                    ))
                    return
                }
            }
            Thread.sleep(forTimeInterval: acknowledgementPollInterval)
        }
        state.complete(with: rejectedResponse(
            requestID: state.requestID,
            code: "app_timeout"
        ))
    }

    private static func complete(_ context: NSExtensionContext, with message: [String: Any]) {
        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: message]
        context.completeRequest(returningItems: [response])
    }

    private static func rejectedResponse(requestID: String, code: String) -> [String: Any] {
        [
            "protocol": BrowserCaptureImportProtocol.name,
            "version": BrowserCaptureImportProtocol.version,
            "type": BrowserCaptureImportProtocol.acknowledgementType,
            "requestId": requestID,
            "payload": [
                "accepted": false,
                "handledBy": "browser",
                "errorCode": code,
            ],
        ]
    }

    private static func importURL(requestID: String) -> URL? {
        var components = URLComponents()
        components.scheme = "smartshot"
        components.host = "import"
        components.queryItems = [
            URLQueryItem(name: "requestId", value: requestID),
            URLQueryItem(name: "source", value: "safari"),
        ]
        return components.url
    }
}
