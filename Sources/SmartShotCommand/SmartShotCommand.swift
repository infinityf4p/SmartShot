import Foundation

enum SmartShotCaptureMode: String, CaseIterable, Equatable, Sendable {
    case smart
    case region
    case long
    case appScroll = "app-scroll"
}

enum SmartShotExternalCommand: Equatable, Sendable {
    case capture(SmartShotCaptureMode)
    case quickSave
    case show

    var activatesApplication: Bool {
        switch self {
        case .capture, .quickSave:
            false
        case .show:
            true
        }
    }

    var url: URL {
        var components = URLComponents()
        components.scheme = "smartshot"
        switch self {
        case let .capture(mode):
            components.host = "capture"
            components.queryItems = [URLQueryItem(name: "mode", value: mode.rawValue)]
        case .quickSave:
            components.host = "quick-save"
        case .show:
            components.host = "show"
        }
        return components.url!
    }

    init?(url: URL) {
        guard url.scheme?.lowercased() == "smartshot",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let route = components.host?.lowercased()
            ?? components.path.split(separator: "/").first.map { String($0).lowercased() }
        switch route {
        case "capture":
            let rawMode = components.queryItems?
                .first(where: { $0.name == "mode" })?
                .value?
                .lowercased() ?? SmartShotCaptureMode.smart.rawValue
            guard let mode = SmartShotCaptureMode(rawValue: rawMode) else { return nil }
            self = .capture(mode)
        case "quick-save":
            self = .quickSave
        case "show":
            self = .show
        default:
            return nil
        }
    }
}

enum SmartShotCLIRequest: Equatable, Sendable {
    case command(SmartShotExternalCommand)
    case help
}

enum SmartShotCLIParserError: LocalizedError, Equatable {
    case unexpectedArguments([String])
    case missingMode
    case unsupportedMode(String)
    case unsupportedCommand(String)

    var errorDescription: String? {
        switch self {
        case let .unexpectedArguments(arguments):
            "Unexpected arguments: \(arguments.joined(separator: " "))"
        case .missingMode:
            "--mode requires smart, region, long, or app-scroll."
        case let .unsupportedMode(mode):
            "Unsupported capture mode: \(mode)"
        case let .unsupportedCommand(command):
            "Unsupported command: \(command)"
        }
    }
}

enum SmartShotCLIParser {
    static let usage = """
    Usage:
      smartshot capture [--mode smart|region|long|app-scroll]
      smartshot quick-save
      smartshot show
      smartshot --help
    """

    static func parse(arguments: [String]) throws -> SmartShotCLIRequest {
        guard let command = arguments.first else {
            return .command(.capture(.smart))
        }
        switch command.lowercased() {
        case "-h", "--help", "help":
            guard arguments.count == 1 else {
                throw SmartShotCLIParserError.unexpectedArguments(Array(arguments.dropFirst()))
            }
            return .help
        case "capture":
            return try parseCapture(arguments: Array(arguments.dropFirst()))
        case "quick-save":
            guard arguments.count == 1 else {
                throw SmartShotCLIParserError.unexpectedArguments(Array(arguments.dropFirst()))
            }
            return .command(.quickSave)
        case "show":
            guard arguments.count == 1 else {
                throw SmartShotCLIParserError.unexpectedArguments(Array(arguments.dropFirst()))
            }
            return .command(.show)
        default:
            throw SmartShotCLIParserError.unsupportedCommand(command)
        }
    }

    private static func parseCapture(arguments: [String]) throws -> SmartShotCLIRequest {
        guard !arguments.isEmpty else { return .command(.capture(.smart)) }
        guard arguments.first == "--mode" else {
            throw SmartShotCLIParserError.unexpectedArguments(arguments)
        }
        guard arguments.count >= 2 else { throw SmartShotCLIParserError.missingMode }
        guard arguments.count == 2 else {
            throw SmartShotCLIParserError.unexpectedArguments(Array(arguments.dropFirst(2)))
        }
        let rawMode = arguments[1].lowercased()
        guard let mode = SmartShotCaptureMode(rawValue: rawMode) else {
            throw SmartShotCLIParserError.unsupportedMode(rawMode)
        }
        return .command(.capture(mode))
    }
}
