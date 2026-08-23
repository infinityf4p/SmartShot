import Foundation
import XCTest

final class ChromiumNativeMessagingInstallerTests: XCTestCase {
    func testInstallWritesOnlyDetectedBrowserManifestsAndInspectionVerifiesThem() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try fixture.createBrowser(relativePath: "Google/Chrome")
        try fixture.createBrowser(relativePath: "BraveSoftware/Brave-Browser")

        let before = ChromiumNativeMessagingInstaller.inspect(
            appURL: fixture.appURL,
            requiredApplicationURL: fixture.appURL,
            homeDirectory: fixture.home
        )
        XCTAssertEqual(before.detectedBrowsers, ["Google Chrome", "Brave"])
        XCTAssertEqual(before.configuredBrowsers, [])
        XCTAssertFalse(before.isFullyConfigured)

        let installed = try ChromiumNativeMessagingInstaller.install(
            appURL: fixture.appURL,
            requiredApplicationURL: fixture.appURL,
            homeDirectory: fixture.home
        )
        XCTAssertTrue(installed.isFullyConfigured)
        XCTAssertEqual(installed.configuredBrowsers, ["Google Chrome", "Brave"])

        for relativePath in ["Google/Chrome", "BraveSoftware/Brave-Browser"] {
            let manifestURL = fixture.manifestURL(relativeBrowserPath: relativePath)
            let data = try Data(contentsOf: manifestURL)
            let manifest = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            XCTAssertEqual(manifest["name"] as? String, ChromiumNativeMessagingInstaller.hostName)
            XCTAssertEqual(manifest["path"] as? String, fixture.helperURL.path)
            XCTAssertEqual(
                manifest["allowed_origins"] as? [String],
                ["chrome-extension://\(ChromiumNativeMessagingInstaller.extensionID)/"]
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.manifestURL(relativeBrowserPath: "Microsoft Edge").path
        ))
    }

    func testInstallRejectsNonstandardApplicationLocation() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try fixture.createBrowser(relativePath: "Google/Chrome")

        XCTAssertThrowsError(try ChromiumNativeMessagingInstaller.install(
            appURL: fixture.appURL,
            homeDirectory: fixture.home
        )) { error in
            XCTAssertEqual(
                error as? ChromiumNativeMessagingInstallerError,
                .applicationNotInstalled
            )
        }
    }

    func testInstallRequiresDetectedBrowser() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        XCTAssertThrowsError(try ChromiumNativeMessagingInstaller.install(
            appURL: fixture.appURL,
            requiredApplicationURL: fixture.appURL,
            homeDirectory: fixture.home
        )) { error in
            XCTAssertEqual(
                error as? ChromiumNativeMessagingInstallerError,
                .noSupportedBrowser
            )
        }
    }

    private func makeFixture() throws -> InstallerFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SmartShotChromiumInstallerTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let home = root.appendingPathComponent("Home", isDirectory: true)
        let appURL = root
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent("SmartShot.app", isDirectory: true)
        let helperURL = appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("SmartShotNativeHost")
        try FileManager.default.createDirectory(
            at: helperURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("fixture".utf8).write(to: helperURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: helperURL.path
        )
        return InstallerFixture(root: root, home: home, appURL: appURL, helperURL: helperURL)
    }
}

private struct InstallerFixture {
    let root: URL
    let home: URL
    let appURL: URL
    let helperURL: URL

    func createBrowser(relativePath: String) throws {
        try FileManager.default.createDirectory(
            at: home
                .appendingPathComponent("Library/Application Support", isDirectory: true)
                .appendingPathComponent(relativePath, isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    func manifestURL(relativeBrowserPath: String) -> URL {
        home
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(relativeBrowserPath, isDirectory: true)
            .appendingPathComponent("NativeMessagingHosts", isDirectory: true)
            .appendingPathComponent(ChromiumNativeMessagingInstaller.hostName)
            .appendingPathExtension("json")
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

extension ChromiumNativeMessagingInstallerError: Equatable {
    static func == (
        lhs: ChromiumNativeMessagingInstallerError,
        rhs: ChromiumNativeMessagingInstallerError
    ) -> Bool {
        switch (lhs, rhs) {
        case (.applicationNotInstalled, .applicationNotInstalled),
             (.helperUnavailable, .helperUnavailable),
             (.noSupportedBrowser, .noSupportedBrowser),
             (.manifestEncodingFailed, .manifestEncodingFailed):
            true
        case let (.browserWritesFailed(lhsNames), .browserWritesFailed(rhsNames)):
            lhsNames == rhsNames
        default:
            false
        }
    }
}
