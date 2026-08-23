import AppKit
import Foundation

private func writeStandardError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

private final class WorkspaceOpenResult: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private var error: Error?

    func complete(error: Error?) {
        self.error = error
        semaphore.signal()
    }

    func wait() -> Error? {
        semaphore.wait()
        return error
    }
}

private func open(_ command: SmartShotExternalCommand) throws {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = command.activatesApplication

    let result = WorkspaceOpenResult()
    NSWorkspace.shared.open(command.url, configuration: configuration) { _, error in
        result.complete(error: error)
    }
    if let error = result.wait() {
        throw error
    }
}

do {
    switch try SmartShotCLIParser.parse(arguments: Array(CommandLine.arguments.dropFirst())) {
    case .help:
        print(SmartShotCLIParser.usage)
    case let .command(command):
        try open(command)
    }
} catch {
    if !(error is SmartShotCLIParserError) {
        writeStandardError("SmartShot could not be opened. Install SmartShot.app and try again.")
    }
    writeStandardError(error.localizedDescription)
    if error is SmartShotCLIParserError {
        writeStandardError(SmartShotCLIParser.usage)
    }
    exit(EXIT_FAILURE)
}
