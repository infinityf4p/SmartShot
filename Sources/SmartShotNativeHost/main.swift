import AppKit
import Foundation

private let maximumNativeMessageBytes = 512 * 1_024
private let applicationAcknowledgementTimeout: TimeInterval = 10
private let acknowledgementPollInterval: TimeInterval = 0.05

private func readExactly(_ count: Int, from handle: FileHandle) throws -> Data? {
    var result = Data()
    result.reserveCapacity(count)
    while result.count < count {
        guard let chunk = try handle.read(upToCount: count - result.count), !chunk.isEmpty else {
            return result.isEmpty ? nil : result
        }
        result.append(chunk)
    }
    return result
}

private func readMessage(from handle: FileHandle) throws -> [String: Any]? {
    guard let lengthData = try readExactly(4, from: handle) else { return nil }
    guard lengthData.count == 4 else { throw BrowserCaptureImportStoreError.invalidEnvelope }
    let length = lengthData.withUnsafeBytes {
        $0.loadUnaligned(as: UInt32.self).littleEndian
    }
    guard length > 0, length <= maximumNativeMessageBytes else {
        throw BrowserCaptureImportStoreError.invalidEnvelope
    }
    guard let body = try readExactly(Int(length), from: handle), body.count == Int(length),
          let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
        throw BrowserCaptureImportStoreError.invalidEnvelope
    }
    return object
}

private func writeMessage(_ message: [String: Any], to handle: FileHandle) throws {
    let body = try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])
    var length = UInt32(body.count).littleEndian
    let prefix = withUnsafeBytes(of: &length) { Data($0) }
    try handle.write(contentsOf: prefix)
    try handle.write(contentsOf: body)
}

private func rejectedResponse(requestID: String, code: String) -> [String: Any] {
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

private func importURL(requestID: String) -> URL? {
    var components = URLComponents()
    components.scheme = "smartshot"
    components.host = "import"
    components.queryItems = [
        URLQueryItem(name: "requestId", value: requestID),
        URLQueryItem(name: "source", value: "chromium"),
    ]
    return components.url
}

private func waitForApplicationConsumption(
    requestID: String,
    store: BrowserCaptureImportStore
) -> Bool {
    let deadline = Date().addingTimeInterval(applicationAcknowledgementTimeout)
    while store.completedCaptureExists(requestID: requestID), Date() < deadline {
        Thread.sleep(forTimeInterval: acknowledgementPollInterval)
    }
    return !store.completedCaptureExists(requestID: requestID)
}

let input = FileHandle.standardInput
let output = FileHandle.standardOutput
let rootDirectory = try BrowserCaptureImportStore.applicationSupportRoot()
let store = BrowserCaptureImportStore(rootDirectory: rootDirectory, source: "chromium")

while true {
    do {
        guard let message = try readMessage(from: input) else { break }
        var result = store.handle(message)
        if let requestID = result.completedRequestID {
            let opened = importURL(requestID: requestID).map(NSWorkspace.shared.open) ?? false
            if !opened || !waitForApplicationConsumption(requestID: requestID, store: store) {
                store.discardCompletedCapture(requestID: requestID)
                result = BrowserCaptureImportHandlingResult(
                    response: rejectedResponse(
                        requestID: requestID,
                        code: opened ? "app_timeout" : "app_unavailable"
                    ),
                    completedRequestID: nil
                )
            }
        }
        try writeMessage(result.response, to: output)
    } catch {
        try? writeMessage(rejectedResponse(requestID: "", code: "invalid_message"), to: output)
        break
    }
}
