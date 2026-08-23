import Foundation
import XCTest

final class RecordingOutputServiceTests: XCTestCase {
    func testWorkingFilesAreIsolatedBySessionAndUseExpectedExtensions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SmartShotRecordingOutputTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let first = try RecordingOutputService.prepareWorkingFiles(
            sessionID: UUID(),
            rootDirectory: root
        )
        let second = try RecordingOutputService.prepareWorkingFiles(
            sessionID: UUID(),
            rootDirectory: root
        )

        XCTAssertNotEqual(first.workingDirectory, second.workingDirectory)
        XCTAssertEqual(first.rawRecordingURL.pathExtension, "mov")
        XCTAssertEqual(first.completedRecordingURL.pathExtension, "mp4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.workingDirectory.path))
        let attributes = try FileManager.default.attributesOfItem(
            atPath: first.workingDirectory.path
        )
        XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, NSNumber(value: 0o700))
    }

    func testCleanupCanPreserveACompletedRecording() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SmartShotRecordingOutputTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = try RecordingOutputService.prepareWorkingFiles(
            sessionID: UUID(),
            rootDirectory: root
        )
        try Data([1, 2, 3]).write(to: files.completedRecordingURL)

        RecordingOutputService.removeWorkingFiles(
            files,
            includeCompletedFile: false
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: files.workingDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: files.completedRecordingURL.path))
    }

    func testCopyReplacingDestinationKeepsSourceAndAtomicallyReplacesExistingFile() throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let source = root.appendingPathComponent("source.mp4")
        let destination = root.appendingPathComponent("destination.mp4")
        let sourceData = Data([1, 2, 3, 4])
        try sourceData.write(to: source)
        try Data([9, 8, 7]).write(to: destination)

        try RecordingDestinationInstaller.copyReplacingDestination(
            sourceURL: source,
            destinationURL: destination
        )

        XCTAssertEqual(try Data(contentsOf: source), sourceData)
        XCTAssertEqual(try Data(contentsOf: destination), sourceData)
    }

    func testStagingURLUsesDestinationDirectoryWithoutRepeatingLongFilename() {
        let directory = makeTemporaryRoot()
        let destination = directory
            .appendingPathComponent(String(repeating: "a", count: 200))
            .appendingPathExtension("gif")

        let staging = RecordingDestinationInstaller.stagingURL(for: destination)

        XCTAssertEqual(staging.deletingLastPathComponent(), directory)
        XCTAssertEqual(staging.pathExtension, "gif")
        XCTAssertLessThan(staging.lastPathComponent.utf8.count, 64)
    }

    func testCopyFailureDoesNotRemoveExistingDestination() throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let missingSource = root.appendingPathComponent("missing.mp4")
        let destination = root.appendingPathComponent("destination.mp4")
        let originalData = Data([9, 8, 7])
        try originalData.write(to: destination)

        XCTAssertThrowsError(
            try RecordingDestinationInstaller.copyReplacingDestination(
                sourceURL: missingSource,
                destinationURL: destination
            )
        )
        XCTAssertEqual(try Data(contentsOf: destination), originalData)
    }

    func testInstallerRejectsStagingFileOutsideDestinationDirectory() throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let stagingDirectory = root.appendingPathComponent("staging", isDirectory: true)
        let destinationDirectory = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true
        )
        let staging = stagingDirectory.appendingPathComponent("recording.gif")
        let destination = destinationDirectory.appendingPathComponent("recording.gif")
        try Data([1, 2, 3]).write(to: staging)

        XCTAssertThrowsError(
            try RecordingDestinationInstaller.installStagedFile(
                at: staging,
                destinationURL: destination
            )
        ) { error in
            XCTAssertEqual(
                error as? RecordingDestinationInstallerError,
                .stagingFileOutsideDestinationDirectory
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testStaleTemporaryCleanupIsBoundedByAgeAndRecordingNames() throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let working = root.appendingPathComponent("Working", isDirectory: true)
        let completed = root.appendingPathComponent("Completed", isDirectory: true)
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: completed, withIntermediateDirectories: true)

        let staleWorking = working.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let recentWorking = working.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let unknownWorking = working.appendingPathComponent("keep-me", isDirectory: true)
        try FileManager.default.createDirectory(at: staleWorking, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: recentWorking, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unknownWorking, withIntermediateDirectories: true)

        let staleCompleted = completed
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        let recentCompleted = completed
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        let unknownCompleted = completed.appendingPathComponent("keep-me.mp4")
        try Data([1]).write(to: staleCompleted)
        try Data([2]).write(to: recentCompleted)
        try Data([3]).write(to: unknownCompleted)

        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let staleDate = now.addingTimeInterval(-200)
        let recentDate = now.addingTimeInterval(-50)
        for url in [staleWorking, unknownWorking, staleCompleted, unknownCompleted] {
            try FileManager.default.setAttributes(
                [.modificationDate: staleDate],
                ofItemAtPath: url.path
            )
        }
        for url in [recentWorking, recentCompleted] {
            try FileManager.default.setAttributes(
                [.modificationDate: recentDate],
                ofItemAtPath: url.path
            )
        }

        let result = RecordingOutputService.removeStaleTemporaryFiles(
            rootDirectory: root,
            now: now,
            workingRetention: 100,
            completedRetention: 100
        )

        XCTAssertEqual(
            result,
            RecordingTemporaryCleanupResult(
                removedWorkingDirectories: 1,
                removedCompletedRecordings: 1
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleWorking.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleCompleted.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recentWorking.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recentCompleted.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unknownWorking.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unknownCompleted.path))
    }

    func testRecordingServiceInitializationPrunesOldTemporaryResidue() throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let working = root
            .appendingPathComponent("Working", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let completed = root
            .appendingPathComponent("Completed", isDirectory: true)
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: completed.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([1]).write(to: completed)
        let oldDate = Date().addingTimeInterval(-8 * 24 * 60 * 60)
        for url in [working, completed] {
            try FileManager.default.setAttributes(
                [.modificationDate: oldDate],
                ofItemAtPath: url.path
            )
        }

        _ = ScreenRecordingService(workingRootDirectory: root)

        XCTAssertFalse(FileManager.default.fileExists(atPath: working.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: completed.path))
    }

    private func makeTemporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SmartShotRecordingOutputTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
