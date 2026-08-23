import CoreGraphics
import Foundation
import ScreenCaptureKit

actor ScreenRecordingService {
    private var stateMachine = RecordingSessionStateMachine()
    private var activeSession: ActiveRecordingSession?
    private var stopTask: Task<RecordingArtifact, Error>?
    private var terminalCleanup: TerminalRecordingCleanup?
    private var lastArtifact: RecordingArtifact?
    private let workingRootDirectory: URL?
    private let fileManagerBox: RecordingFileManagerBox

    init(
        workingRootDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.workingRootDirectory = workingRootDirectory
        fileManagerBox = RecordingFileManagerBox(fileManager)
        RecordingOutputService.removeStaleTemporaryFiles(
            rootDirectory: workingRootDirectory,
            fileManager: fileManager
        )
    }

    var state: RecordingSessionState { stateMachine.state }

    var activeSessionID: UUID? {
        stateMachine.state.isActive ? stateMachine.state.sessionID : nil
    }

    @discardableResult
    func start(
        source: RecordingSource,
        options: RecordingOptions = RecordingOptions()
    ) async throws -> UUID {
        if let terminalCleanup {
            await completeTerminalCleanup(terminalCleanup)
        }
        guard CGPreflightScreenCaptureAccess() else {
            throw ScreenRecordingError.screenCapturePermissionDenied
        }

        let sessionID = UUID()
        try stateMachine.begin(sessionID: sessionID)
        lastArtifact = nil

        var context: ActiveRecordingSession?
        var orphanedWorkingFiles: RecordingWorkingFiles?
        do {
            let resolvedSource = try await RecordingSourceResolver().resolve(source)
            let videoPlan = try RecordingVideoPlanner.plan(
                sourceSize: resolvedSource.sourceSize,
                pointPixelScale: resolvedSource.pointPixelScale,
                options: options
            )
            let workingFiles = try RecordingOutputService.prepareWorkingFiles(
                sessionID: sessionID,
                rootDirectory: workingRootDirectory,
                fileManager: fileManagerBox.value
            )
            orphanedWorkingFiles = workingFiles
            let writer = try RecordingAssetWriter(
                outputURL: workingFiles.rawRecordingURL,
                videoPlan: videoPlan,
                capturesSystemAudio: options.capturesSystemAudio,
                capturesMicrophone: options.capturesMicrophone
            ) { [weak self] error in
                Task { await self?.handleRuntimeFailure(sessionID: sessionID, error: error) }
            }
            let router = RecordingSampleRouter(
                sessionID: sessionID,
                writer: writer
            ) { [weak self] failedSessionID, error in
                Task {
                    await self?.handleRuntimeFailure(
                        sessionID: failedSessionID,
                        error: error
                    )
                }
            }
            let configuration = RecordingStreamConfigurationFactory.make(
                resolvedSource: resolvedSource,
                videoPlan: videoPlan,
                options: options
            )
            let stream = SCStream(
                filter: resolvedSource.filter,
                configuration: configuration,
                delegate: router
            )
            let microphone = options.capturesMicrophone
                ? MicrophoneCaptureService()
                : nil
            let createdContext = ActiveRecordingSession(
                id: sessionID,
                source: source,
                options: options,
                videoPlan: videoPlan,
                workingFiles: workingFiles,
                writer: writer,
                router: router,
                stream: stream,
                microphone: microphone
            )
            context = createdContext
            orphanedWorkingFiles = nil
            activeSession = createdContext

            try stream.addStreamOutput(
                router,
                type: .screen,
                sampleHandlerQueue: router.sampleQueue
            )
            if options.capturesSystemAudio {
                try stream.addStreamOutput(
                    router,
                    type: .audio,
                    sampleHandlerQueue: router.sampleQueue
                )
            }

            if let microphone {
                try await microphone.start(router: router)
                try ensurePreparingSession(sessionID)
            }
            try await stream.startCapture()
            try ensurePreparingSession(sessionID)
            try stateMachine.didStart(sessionID: sessionID)
            return sessionID
        } catch {
            let existingCleanup = terminalCleanup.flatMap {
                $0.sessionID == sessionID ? $0 : nil
            }
            let outwardError: Error
            if let runtimeError = existingCleanup?.runtimeError {
                outwardError = runtimeError
            } else if stateMachine.state == .cancelled(sessionID) {
                outwardError = CancellationError()
            } else {
                outwardError = error
            }

            var cleanup = existingCleanup
            if activeSession?.id == sessionID {
                activeSession = nil
                if let context {
                    cleanup = beginTerminalCleanup(for: context)
                }
            }
            switch stateMachine.state {
            case .preparing(sessionID), .recording(sessionID):
                stateMachine.fail(sessionID: sessionID, error: outwardError)
            default:
                break
            }
            if let cleanup {
                await completeTerminalCleanup(cleanup)
            } else if let orphanedWorkingFiles {
                RecordingOutputService.removeWorkingFiles(
                    orphanedWorkingFiles,
                    includeCompletedFile: true,
                    fileManager: fileManagerBox.value
                )
            }
            throw outwardError
        }
    }

    func stop(sessionID requestedSessionID: UUID? = nil) async throws -> RecordingArtifact {
        if let lastArtifact,
           requestedSessionID == nil || requestedSessionID == lastArtifact.sessionID,
           stateMachine.state == .finished(lastArtifact.sessionID) {
            return lastArtifact
        }
        if let stopTask {
            guard requestedSessionID == nil || requestedSessionID == stateMachine.state.sessionID else {
                throw ScreenRecordingError.sessionNotActive
            }
            return try await stopTask.value
        }
        if let terminalCleanup,
           requestedSessionID == nil || requestedSessionID == terminalCleanup.sessionID {
            await completeTerminalCleanup(terminalCleanup)
            if let runtimeError = terminalCleanup.runtimeError {
                throw runtimeError
            }
            throw ScreenRecordingError.sessionNotActive
        }
        guard let context = activeSession,
              requestedSessionID == nil || requestedSessionID == context.id else {
            throw ScreenRecordingError.sessionNotActive
        }

        _ = try stateMachine.requestStop(sessionID: context.id)
        let fileManagerBox = self.fileManagerBox
        let finalizationTask = Task {
            try await Self.finish(context, fileManagerBox: fileManagerBox)
        }
        stopTask = finalizationTask

        do {
            let artifact = try await finalizationTask.value
            if activeSession?.id == context.id {
                activeSession = nil
            }
            stopTask = nil
            try stateMachine.finish(sessionID: context.id)
            lastArtifact = artifact
            return artifact
        } catch {
            if activeSession?.id == context.id {
                activeSession = nil
            }
            stopTask = nil
            stateMachine.fail(sessionID: context.id, error: error)
            await Self.cancelAndRemove(context, fileManagerBox: fileManagerBox)
            throw error
        }
    }

    func cancel(sessionID requestedSessionID: UUID? = nil) async {
        if let terminalCleanup,
           requestedSessionID == nil || requestedSessionID == terminalCleanup.sessionID {
            await completeTerminalCleanup(terminalCleanup)
            return
        }
        guard stopTask == nil,
              let context = activeSession,
              requestedSessionID == nil || requestedSessionID == context.id else {
            return
        }
        activeSession = nil
        stateMachine.cancel(sessionID: context.id)
        let cleanup = beginTerminalCleanup(for: context)
        await completeTerminalCleanup(cleanup)
    }

    func waitForPendingTerminalCleanup() async {
        while let cleanup = terminalCleanup {
            await completeTerminalCleanup(cleanup)
        }
    }

    private func ensurePreparingSession(_ sessionID: UUID) throws {
        guard activeSession?.id == sessionID,
              stateMachine.state == .preparing(sessionID) else {
            throw ScreenRecordingError.invalidSessionTransition
        }
    }

    private func handleRuntimeFailure(sessionID: UUID, error: Error) {
        guard stopTask == nil,
              let context = activeSession,
              context.id == sessionID else {
            return
        }
        activeSession = nil
        let runtimeError = Self.normalizedRuntimeError(error)
        stateMachine.fail(sessionID: sessionID, error: runtimeError)
        _ = beginTerminalCleanup(for: context, runtimeError: runtimeError)
    }

    private func beginTerminalCleanup(
        for context: ActiveRecordingSession,
        runtimeError: ScreenRecordingError? = nil
    ) -> TerminalRecordingCleanup {
        let fileManagerBox = self.fileManagerBox
        let cleanup = TerminalRecordingCleanup(
            sessionID: context.id,
            runtimeError: runtimeError,
            task: Task {
                await Self.cancelAndRemove(context, fileManagerBox: fileManagerBox)
            }
        )
        terminalCleanup = cleanup
        return cleanup
    }

    private func completeTerminalCleanup(_ cleanup: TerminalRecordingCleanup) async {
        await cleanup.task.value
        if terminalCleanup?.sessionID == cleanup.sessionID {
            terminalCleanup = nil
        }
    }

    private static func normalizedRuntimeError(_ error: Error) -> ScreenRecordingError {
        if let recordingError = error as? ScreenRecordingError {
            return recordingError
        }
        return .streamStopped(error.localizedDescription)
    }

    private static func finish(
        _ context: ActiveRecordingSession,
        fileManagerBox: RecordingFileManagerBox
    ) async throws -> RecordingArtifact {
        do {
            try? await context.stream.stopCapture()
            await context.microphone?.stop()
            _ = try await context.writer.finish()
            let metadata = try await RecordingMP4Exporter.export(
                rawRecordingURL: context.workingFiles.rawRecordingURL,
                destinationURL: context.workingFiles.completedRecordingURL,
                fileManager: fileManagerBox.value
            )
            RecordingOutputService.removeWorkingFiles(
                context.workingFiles,
                includeCompletedFile: false,
                fileManager: fileManagerBox.value
            )
            return RecordingArtifact(
                sessionID: context.id,
                fileURL: context.workingFiles.completedRecordingURL,
                duration: metadata.duration,
                pixelSize: metadata.pixelSize,
                capturesSystemAudio: context.options.capturesSystemAudio,
                capturesMicrophone: context.options.capturesMicrophone
            )
        } catch {
            await context.writer.cancel()
            throw error
        }
    }

    private static func cancelAndRemove(
        _ context: ActiveRecordingSession,
        fileManagerBox: RecordingFileManagerBox
    ) async {
        try? await context.stream.stopCapture()
        await context.microphone?.stop()
        await context.writer.cancel()
        RecordingOutputService.removeWorkingFiles(
            context.workingFiles,
            includeCompletedFile: true,
            fileManager: fileManagerBox.value
        )
    }
}

private struct TerminalRecordingCleanup {
    let sessionID: UUID
    let runtimeError: ScreenRecordingError?
    let task: Task<Void, Never>
}

private final class RecordingFileManagerBox: @unchecked Sendable {
    let value: FileManager

    init(_ value: FileManager) {
        self.value = value
    }
}

private final class ActiveRecordingSession: @unchecked Sendable {
    let id: UUID
    let source: RecordingSource
    let options: RecordingOptions
    let videoPlan: RecordingVideoPlan
    let workingFiles: RecordingWorkingFiles
    let writer: RecordingAssetWriter
    let router: RecordingSampleRouter
    let stream: SCStream
    let microphone: MicrophoneCaptureService?

    init(
        id: UUID,
        source: RecordingSource,
        options: RecordingOptions,
        videoPlan: RecordingVideoPlan,
        workingFiles: RecordingWorkingFiles,
        writer: RecordingAssetWriter,
        router: RecordingSampleRouter,
        stream: SCStream,
        microphone: MicrophoneCaptureService?
    ) {
        self.id = id
        self.source = source
        self.options = options
        self.videoPlan = videoPlan
        self.workingFiles = workingFiles
        self.writer = writer
        self.router = router
        self.stream = stream
        self.microphone = microphone
    }
}
