import Foundation

struct ChromiumNativeMessagingStatus: Equatable, Sendable {
    let isInstalledApplication: Bool
    let isHelperAvailable: Bool
    let detectedBrowsers: [String]
    let configuredBrowsers: [String]

    var isFullyConfigured: Bool {
        isInstalledApplication &&
            isHelperAvailable &&
            !detectedBrowsers.isEmpty &&
            detectedBrowsers == configuredBrowsers
    }
}

enum ChromiumNativeMessagingInstallerError: LocalizedError {
    case applicationNotInstalled
    case helperUnavailable
    case noSupportedBrowser
    case manifestEncodingFailed
    case browserWritesFailed([String])

    var errorDescription: String? {
        switch self {
        case .applicationNotInstalled:
            "Move SmartShot to /Applications before installing the browser connector."
        case .helperUnavailable:
            "The SmartShot browser connector is missing from the app bundle."
        case .noSupportedBrowser:
            "No supported Chromium browser was detected."
        case .manifestEncodingFailed:
            "SmartShot could not prepare the browser connector manifest."
        case let .browserWritesFailed(names):
            "The connector could not be installed for: \(names.joined(separator: ", "))."
        }
    }
}

enum ChromiumNativeMessagingInstaller {
    static let extensionID = "fihllldonobikbajacoflinfomigonhd"
    static let hostName = "com.infinityf4p.smartshot"

    private struct Browser: Sendable {
        let name: String
        let relativeSupportPath: String
    }

    private static let browsers = [
        Browser(name: "Google Chrome", relativeSupportPath: "Google/Chrome"),
        Browser(name: "Chromium", relativeSupportPath: "Chromium"),
        Browser(name: "Microsoft Edge", relativeSupportPath: "Microsoft Edge"),
        Browser(name: "Brave", relativeSupportPath: "BraveSoftware/Brave-Browser"),
    ]

    static func inspect(
        appURL: URL = Bundle.main.bundleURL,
        requiredApplicationURL: URL = URL(fileURLWithPath: "/Applications/SmartShot.app"),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> ChromiumNativeMessagingStatus {
        let appURL = appURL.standardizedFileURL
        let installed = appURL.path == requiredApplicationURL.standardizedFileURL.path
        let helperURL = helperURL(appURL: appURL)
        let detected = detectedBrowsers(
            homeDirectory: homeDirectory,
            fileManager: fileManager
        )
        let configured = detected.filter { browser in
            manifestIsCurrent(
                at: manifestURL(browser: browser, homeDirectory: homeDirectory),
                helperURL: helperURL,
                fileManager: fileManager
            )
        }
        return ChromiumNativeMessagingStatus(
            isInstalledApplication: installed,
            isHelperAvailable: fileManager.isExecutableFile(atPath: helperURL.path),
            detectedBrowsers: detected.map(\.name),
            configuredBrowsers: configured.map(\.name)
        )
    }

    @discardableResult
    static func install(
        appURL: URL = Bundle.main.bundleURL,
        requiredApplicationURL: URL = URL(fileURLWithPath: "/Applications/SmartShot.app"),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) throws -> ChromiumNativeMessagingStatus {
        let appURL = appURL.standardizedFileURL
        guard appURL.path == requiredApplicationURL.standardizedFileURL.path else {
            throw ChromiumNativeMessagingInstallerError.applicationNotInstalled
        }
        let helperURL = helperURL(appURL: appURL)
        guard fileManager.isExecutableFile(atPath: helperURL.path) else {
            throw ChromiumNativeMessagingInstallerError.helperUnavailable
        }
        let detected = detectedBrowsers(
            homeDirectory: homeDirectory,
            fileManager: fileManager
        )
        guard !detected.isEmpty else {
            throw ChromiumNativeMessagingInstallerError.noSupportedBrowser
        }
        guard let manifestData = try? JSONSerialization.data(
            withJSONObject: manifest(helperURL: helperURL),
            options: [.prettyPrinted, .sortedKeys]
        ) else {
            throw ChromiumNativeMessagingInstallerError.manifestEncodingFailed
        }

        var failedBrowsers: [String] = []
        for browser in detected {
            let manifestURL = manifestURL(browser: browser, homeDirectory: homeDirectory)
            do {
                try fileManager.createDirectory(
                    at: manifestURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                try manifestData.write(to: manifestURL, options: .atomic)
                try fileManager.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: manifestURL.path
                )
            } catch {
                failedBrowsers.append(browser.name)
            }
        }
        guard failedBrowsers.isEmpty else {
            throw ChromiumNativeMessagingInstallerError.browserWritesFailed(failedBrowsers)
        }
        return inspect(
            appURL: appURL,
            requiredApplicationURL: requiredApplicationURL,
            homeDirectory: homeDirectory,
            fileManager: fileManager
        )
    }

    private static func helperURL(appURL: URL) -> URL {
        appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("SmartShotNativeHost")
    }

    private static func applicationSupportURL(homeDirectory: URL) -> URL {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
    }

    private static func detectedBrowsers(
        homeDirectory: URL,
        fileManager: FileManager
    ) -> [Browser] {
        let support = applicationSupportURL(homeDirectory: homeDirectory)
        return browsers.filter { browser in
            fileManager.fileExists(
                atPath: support.appendingPathComponent(
                    browser.relativeSupportPath,
                    isDirectory: true
                ).path
            )
        }
    }

    private static func manifestURL(browser: Browser, homeDirectory: URL) -> URL {
        applicationSupportURL(homeDirectory: homeDirectory)
            .appendingPathComponent(browser.relativeSupportPath, isDirectory: true)
            .appendingPathComponent("NativeMessagingHosts", isDirectory: true)
            .appendingPathComponent(hostName)
            .appendingPathExtension("json")
    }

    private static func manifest(helperURL: URL) -> [String: Any] {
        [
            "name": hostName,
            "description": "Import browser captures into SmartShot",
            "path": helperURL.path,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://\(extensionID)/"],
        ]
    }

    private static func manifestIsCurrent(
        at url: URL,
        helperURL: URL,
        fileManager: FileManager
    ) -> Bool {
        guard let data = fileManager.contents(atPath: url.path),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              value["name"] as? String == hostName,
              value["path"] as? String == helperURL.path,
              value["type"] as? String == "stdio",
              let origins = value["allowed_origins"] as? [String],
              origins == ["chrome-extension://\(extensionID)/"] else {
            return false
        }
        return true
    }
}
