import Foundation
import SafariServices

final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    private enum ProtocolValue {
        static let name = "com.infinityf4p.smartshot"
        static let version = 1
        static let responseType = "capture.response"
    }

    func beginRequest(with context: NSExtensionContext) {
        let request = context.inputItems.first as? NSExtensionItem
        let message = request?.userInfo?[SFExtensionMessageKey] as? [String: Any]
        let requestID = message?["requestId"] as? String ?? UUID().uuidString

        // v0.1 keeps pixel capture in the WebExtension. Returning an explicit
        // decline lets background.js continue with captureVisibleTab safely.
        let responseMessage: [String: Any] = [
            "protocol": ProtocolValue.name,
            "version": ProtocolValue.version,
            "type": ProtocolValue.responseType,
            "requestId": requestID,
            "payload": [
                "accepted": false,
                "handledBy": "browser"
            ]
        ]

        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: responseMessage]
        context.completeRequest(returningItems: [response])
    }
}
