import AppKit
import Combine
import SmartShotCore
import Foundation
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject, SelectionOverlayControllerDelegate {
    enum CaptureOrigin {
        case globalShortcut
        case menuBar
        case mainWindow
    }

    enum CaptureState: Equatable {
        case idle
        case selecting
        case capturing
        case failed(String)
    }

    private enum CaptureMode {
        case standard
        case manualScrolling
        case automaticScrolling
    }

    private enum ActiveOperation {
        case screenshot
        case recording
    }

    @Published private(set) var state: CaptureState = .idle
    @Published private(set) var latestCapture: CapturedImage?
    @Published private(set) var latestRecording: RecordingArtifact?
    @Published private(set) var captureEditor: CaptureEditorModel? {
        didSet { observeCaptureEditor() }
    }
    @Published private(set) var scrollingCaptureProgress: Double?
    @Published private(set) var manualScrollingCaptureProgress: ManualScrollingCaptureProgress?
    @Published private(set) var shortcutRegistration: GlobalShortcutMonitor.Registration = .inactive
    @Published private(set) var shortcutFeedback: String?
    @Published private(set) var shortcutFeedbackIsError = false
    @Published private(set) var chromiumIntegrationStatus = "Checking browser integration..."
    @Published private(set) var chromiumIntegrationIsReady = false
    @Published private(set) var chromiumIntegrationIsBusy = false
    @Published private(set) var chromiumIntegrationHasError = false
    @Published private(set) var safariExtensionStatus: SafariExtensionIntegrationStatus = .checking
    @Published private(set) var safariExtensionIsBusy = false
    @Published private(set) var captureHistoryItems: [CaptureHistoryItem] = []
    @Published private(set) var selectedHistoryID: UUID?
    @Published private(set) var captureHistoryError: String?
    @Published private(set) var lastOutputStatus: String?
    @Published private(set) var recordingState: RecordingSessionState = .idle
    @Published private(set) var isExportingRecordingGIF = false
    @Published var captureHistoryQuery = "" {
        didSet { refreshCaptureHistoryDisplay() }
    }
    @Published var automaticallyCopiesCaptures: Bool {
        didSet { defaults.set(automaticallyCopiesCaptures, forKey: PreferenceKey.automaticallyCopiesCaptures) }
    }
    @Published var showsPreviewAfterExternalCapture: Bool {
        didSet { defaults.set(showsPreviewAfterExternalCapture, forKey: PreferenceKey.showsPreviewAfterExternalCapture) }
    }
    @Published var captureDelaySeconds: Int {
        didSet { defaults.set(captureDelaySeconds, forKey: PreferenceKey.captureDelaySeconds) }
    }
    @Published var savesCaptureHistory: Bool {
        didSet { defaults.set(savesCaptureHistory, forKey: PreferenceKey.savesCaptureHistory) }
    }
    @Published var usesPrivateCaptureMode: Bool {
        didSet { defaults.set(usesPrivateCaptureMode, forKey: PreferenceKey.usesPrivateCaptureMode) }
    }
    @Published var indexesRecognizedTextInHistory: Bool {
        didSet {
            defaults.set(
                indexesRecognizedTextInHistory,
                forKey: PreferenceKey.indexesRecognizedTextInHistory
            )
            if indexesRecognizedTextInHistory {
                let recognizedText = captureEditor?.recognizedText ?? ""
                if recognizedText.isEmpty {
                    refreshCaptureHistoryDisplay()
                } else {
                    indexRecognizedTextForCurrentCapture(recognizedText)
                }
            } else {
                disableHistoryOCRIndexing()
            }
        }
    }
    @Published var captureHistoryLimit: Int {
        didSet {
            let normalized = Self.normalizedHistoryLimit(captureHistoryLimit)
            if captureHistoryLimit != normalized {
                captureHistoryLimit = normalized
                return
            }
            defaults.set(captureHistoryLimit, forKey: PreferenceKey.captureHistoryLimit)
            enforceCaptureHistoryLimit()
        }
    }
    @Published var outputFormat: CaptureOutputFormat {
        didSet { defaults.set(outputFormat.rawValue, forKey: PreferenceKey.outputFormat) }
    }
    @Published var filenameStyle: CaptureFilenameStyle {
        didSet { defaults.set(filenameStyle.rawValue, forKey: PreferenceKey.filenameStyle) }
    }
    @Published var recordingCapturesSystemAudio: Bool {
        didSet {
            defaults.set(
                recordingCapturesSystemAudio,
                forKey: PreferenceKey.recordingCapturesSystemAudio
            )
        }
    }
    @Published var recordingCapturesMicrophone: Bool {
        didSet {
            defaults.set(
                recordingCapturesMicrophone,
                forKey: PreferenceKey.recordingCapturesMicrophone
            )
            if recordingCapturesMicrophone, !permissions.hasMicrophoneAccess {
                permissions.requestMicrophone()
            }
        }
    }
    @Published var recordingShowsCursor: Bool {
        didSet { defaults.set(recordingShowsCursor, forKey: PreferenceKey.recordingShowsCursor) }
    }
    @Published var recordingFrameRate: Int {
        didSet {
            let normalized = [15, 30, 60].min {
                abs($0 - recordingFrameRate) < abs($1 - recordingFrameRate)
            } ?? 30
            if recordingFrameRate != normalized {
                recordingFrameRate = normalized
                return
            }
            defaults.set(recordingFrameRate, forKey: PreferenceKey.recordingFrameRate)
        }
    }
    @Published var recordingMaximumLongEdge: Int {
        didSet {
            let normalized = [1_920, 2_560, 3_840].min {
                abs($0 - recordingMaximumLongEdge) < abs($1 - recordingMaximumLongEdge)
            } ?? 3_840
            if recordingMaximumLongEdge != normalized {
                recordingMaximumLongEdge = normalized
                return
            }
            defaults.set(
                recordingMaximumLongEdge,
                forKey: PreferenceKey.recordingMaximumLongEdge
            )
        }
    }
    @Published private(set) var defaultSaveDirectoryPath: String {
        didSet {
            defaults.set(defaultSaveDirectoryPath, forKey: PreferenceKey.defaultSaveDirectoryPath)
        }
    }

    let permissions = PermissionService()
    private let captureService = ScreenCaptureService()
    private let scrollingCaptureService = ScrollingCaptureService()
    private let manualScrollingCaptureService = ManualScrollingCaptureService()
    private let overlayController = SelectionOverlayController()
    private let manualScrollingHUD = ManualScrollingCaptureHUDController()
    private let countdownHUD = CaptureCountdownHUDController()
    private let screenRecordingHUD = ScreenRecordingHUDController()
    private let screenRecordingService = ScreenRecordingService()
    private var shortcutMonitor: GlobalShortcutMonitor?
    private var captureEscapeHotKeyMonitor: TransientEscapeHotKeyMonitor?
    private var activeCaptureOrigin: CaptureOrigin = .mainWindow
    private var activeCaptureMode: CaptureMode = .standard
    private var activeOperation: ActiveOperation = .screenshot
    private var captureTask: Task<Void, Never>?
    private var recordingStopTask: Task<Void, Never>?
    private var recordingMonitorTask: Task<Void, Never>?
    private var recordingGIFExportTask: Task<Void, Never>?
    private var recordingSessionID: UUID?
    private var activeRecordingRect: CGRect?
    private var manualScrollingControl: ManualScrollingCaptureControl?
    private var pinnedCaptures: [PinnedCaptureWindowController] = []
    private var captureEditorChanges: AnyCancellable?
    private var terminationTask: Task<Void, Never>?
    private var isTerminationPending = false
    private var openMainWindow: (() -> Void)?
    private var browserImportQueue = BrowserCaptureImportQueue()
    private var browserImportTask: Task<Void, Never>?
    private var chromiumIntegrationTask: Task<Void, Never>?
    private var safariExtensionTask: Task<Void, Never>?
    private let captureHistoryStore = CaptureHistoryStore()
    private var captureHistoryTask: Task<Void, Never>?
    private var captureHistoryTaskID: UUID?
    private var captureHistorySelectionTask: Task<Void, Never>?
    private var captureHistorySelectionTaskID: UUID?
    private var captureHistorySearchTask: Task<Void, Never>?
    private var captureHistorySearchTaskID: UUID?
    private var captureHistoryAllItems: [CaptureHistoryItem] = []
    private var currentCaptureHistoryID: UUID?
    private var currentCaptureCreatedAt: Date?
    private var currentCaptureHistorySearchIndex: CaptureHistorySearchIndex = .none
    private var latestSmartShotPasteboardChangeCount: Int?
    private var didLoadCaptureHistory = false
    private let browserCaptureImportService = BrowserCaptureImportService()
    private let defaults: UserDefaults
#if DEBUG
    private var didScheduleDebugCapture = false
    private var didAutoFinishDebugManualCapture = false
    private var debugManualScrollSessionGate = DebugCaptureSessionGate()
    private var debugManualScrollTask: Task<Void, Never>?
    private var debugManualScrollTarget: AccessibilityScrollCaptureTarget?
#endif

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        automaticallyCopiesCaptures = defaults.object(
            forKey: PreferenceKey.automaticallyCopiesCaptures
        ) as? Bool ?? true
        showsPreviewAfterExternalCapture = defaults.object(
            forKey: PreferenceKey.showsPreviewAfterExternalCapture
        ) as? Bool ?? false
        let storedDelay = defaults.object(forKey: PreferenceKey.captureDelaySeconds) as? Int ?? 0
        captureDelaySeconds = [0, 3, 5].contains(storedDelay) ? storedDelay : 0
        savesCaptureHistory = defaults.object(
            forKey: PreferenceKey.savesCaptureHistory
        ) as? Bool ?? true
        usesPrivateCaptureMode = defaults.object(
            forKey: PreferenceKey.usesPrivateCaptureMode
        ) as? Bool ?? false
        indexesRecognizedTextInHistory = defaults.object(
            forKey: PreferenceKey.indexesRecognizedTextInHistory
        ) as? Bool ?? false
        captureHistoryLimit = Self.normalizedHistoryLimit(
            defaults.object(forKey: PreferenceKey.captureHistoryLimit) as? Int ?? 50
        )
        outputFormat = CaptureOutputFormat(
            rawValue: defaults.string(forKey: PreferenceKey.outputFormat) ?? ""
        ) ?? .png
        filenameStyle = CaptureFilenameStyle(
            rawValue: defaults.string(forKey: PreferenceKey.filenameStyle) ?? ""
        ) ?? .smartShotTimestamp
        recordingCapturesSystemAudio = defaults.object(
            forKey: PreferenceKey.recordingCapturesSystemAudio
        ) as? Bool ?? true
        recordingCapturesMicrophone = defaults.object(
            forKey: PreferenceKey.recordingCapturesMicrophone
        ) as? Bool ?? false
        recordingShowsCursor = defaults.object(
            forKey: PreferenceKey.recordingShowsCursor
        ) as? Bool ?? true
        let storedRecordingFrameRate = defaults.object(
            forKey: PreferenceKey.recordingFrameRate
        ) as? Int ?? 30
        recordingFrameRate = [15, 30, 60].contains(storedRecordingFrameRate)
            ? storedRecordingFrameRate
            : 30
        let storedMaximumLongEdge = defaults.object(
            forKey: PreferenceKey.recordingMaximumLongEdge
        ) as? Int ?? 3_840
        recordingMaximumLongEdge = [1_920, 2_560, 3_840].contains(storedMaximumLongEdge)
            ? storedMaximumLongEdge
            : 3_840
        defaultSaveDirectoryPath = defaults.string(
            forKey: PreferenceKey.defaultSaveDirectoryPath
        ) ?? ((try? CaptureOutputService.defaultDirectory().path) ?? "")
        overlayController.delegate = self
        manualScrollingHUD.onFinish = { [weak self] in
            self?.finishManualScrollingCapture()
        }
        manualScrollingHUD.onCancel = { [weak self] in
            self?.cancelCapture()
        }
        screenRecordingHUD.onStop = { [weak self] in
            self?.stopScreenRecording()
        }
        screenRecordingHUD.onCancel = { [weak self] in
            self?.cancelScreenRecording()
        }
        shortcutMonitor = GlobalShortcutMonitor(defaults: defaults) { [weak self] in
            self?.startCapture(origin: .globalShortcut)
        }
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--editor-fixture"),
           let fixture = try? DebugCaptureFixture.makeEditorCapture() {
            latestCapture = fixture
            captureEditor = makeCaptureEditor(for: fixture)
        }
        scheduleDebugCaptureIfRequested()
#endif
        observeCaptureEditor()
    }

    var isBusy: Bool {
        state == .selecting || state == .capturing || isExportingRecordingGIF
    }

    var isScreenRecordingWorkflow: Bool {
        activeOperation == .recording && isBusy
    }

    var canStopScreenRecording: Bool {
        if case .recording = recordingState { true } else { false }
    }

    var isFinalizingScreenRecording: Bool {
        if case .stopping = recordingState { true } else { false }
    }

    var recordingStatusText: String? {
        switch recordingState {
        case .idle, .finished, .cancelled:
            nil
        case .preparing:
            "Preparing screen recording"
        case .recording:
            "Recording screen"
        case .stopping:
            "Finalizing MP4"
        case let .failed(_, message):
            message
        }
    }

    var defaultSaveDirectoryDisplayName: String {
        guard !defaultSaveDirectoryPath.isEmpty else { return "Not set" }
        return (defaultSaveDirectoryPath as NSString).abbreviatingWithTildeInPath
    }

    var hasCaptureHistory: Bool {
        !captureHistoryAllItems.isEmpty
    }

    var isScrollingCapture: Bool {
        switch activeCaptureMode {
        case .manualScrolling, .automaticScrolling:
            isBusy
        case .standard:
            false
        }
    }

    var isManualScrollingCapture: Bool {
        activeCaptureMode == .manualScrolling && state == .capturing
    }

    var canFinishManualScrollingCapture: Bool {
        guard isManualScrollingCapture,
              let progress = manualScrollingCaptureProgress else { return false }
        return progress.fragmentCount > 1 && progress.phase != .stitching
    }

    var shortcutIsReady: Bool {
        if case .registered = shortcutRegistration { true } else { false }
    }

    var shortcutDisplayName: String {
        if case let .registered(shortcut) = shortcutRegistration {
            shortcut.displayName
        } else {
            configuredShortcut.displayName
        }
    }

    var configuredShortcut: KeyboardShortcutValue {
        shortcutMonitor?.configuredShortcut ?? .defaultCapture
    }

    var shortcutDetail: String {
        switch shortcutRegistration {
        case .inactive:
            "Starting..."
        case let .registered(shortcut):
            shortcut == .fallbackCapture
                ? "Using \(shortcut.displayName) because the default was busy"
                : shortcut.displayName
        case let .conflict(shortcut):
            "\(shortcut.displayName) is currently in use"
        case let .failed(_, status):
            "Registration failed (error \(status))"
        }
    }

    func startServices() {
        shortcutRegistration = shortcutMonitor?.start() ?? .failed(nil, OSStatus(paramErr))
        refreshChromiumIntegrationStatus()
        refreshSafariExtensionStatus()
        loadCaptureHistoryIfNeeded()
    }

#if DEBUG
    private func scheduleDebugCaptureIfRequested() {
        guard !didScheduleDebugCapture else { return }

        let arguments = ProcessInfo.processInfo.arguments
        guard let modeArgument = arguments.first(where: { $0.hasPrefix("--debug-capture=") }) else {
            return
        }
        let mode = String(modeArgument.dropFirst("--debug-capture=".count))
        guard ["standard", "manual", "scroll"].contains(mode) else { return }

        let delay = arguments
            .first(where: { $0.hasPrefix("--debug-capture-delay=") })
            .flatMap { Double($0.dropFirst("--debug-capture-delay=".count)) }
            .map { min(max($0, 0.5), 30) }
            ?? 3

        didScheduleDebugCapture = true
        clearDebugCaptureReport()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            if arguments.contains("--debug-hide-main-window") {
                NSApp.windows
                    .filter { $0.identifier?.rawValue == "main" }
                    .forEach { $0.orderOut(nil) }
            }
            if let bundleIdentifier = arguments
                .first(where: { $0.hasPrefix("--debug-activate-target=") })
                .map({ String($0.dropFirst("--debug-activate-target=".count)) }),
               !(await activateDebugTarget(bundleIdentifier: bundleIdentifier)) {
                writeDebugCaptureReport(
                    status: "failed",
                    error: AccessibilityScrollTargetError.unavailable
                )
                return
            }
            switch mode {
            case "manual":
                guard let rect = debugCaptureRect(arguments: arguments) else {
                    writeDebugCaptureReport(
                        status: "failed",
                        error: ScreenCaptureError.emptySelection
                    )
                    return
                }
                let manualScrollTarget: AccessibilityScrollCaptureTarget?
                if let bundleIdentifier = arguments
                    .first(where: { $0.hasPrefix("--debug-manual-scroll-target=") })
                    .map({ String($0.dropFirst("--debug-manual-scroll-target=".count)) }) {
                    let result = await AccessibilityScrollCaptureTarget
                        .resolveFirstScrollableTargetForDebug(
                            bundleIdentifier: bundleIdentifier
                        )
                    switch result {
                    case let .success(target):
                        do {
                            try target.setValue(target.minimumValue)
                            try await Task.sleep(for: .milliseconds(800))
                            manualScrollTarget = target
                        } catch {
                            writeDebugCaptureReport(status: "failed", error: error)
                            return
                        }
                    case let .failure(error):
                        writeDebugCaptureReport(status: "failed", error: error)
                        return
                    }
                } else {
                    manualScrollTarget = nil
                }
                activeCaptureOrigin = .menuBar
                selectionOverlay(
                    overlayController,
                    didSelectManualScrollingRect: rect
                )
                if let manualScrollTarget {
                    scheduleDebugManualScrollSequence(target: manualScrollTarget)
                }
            case "scroll":
                if let bundleIdentifier = arguments
                    .first(where: { $0.hasPrefix("--debug-scroll-target=") })
                    .map({ String($0.dropFirst("--debug-scroll-target=".count)) }) {
                    activeCaptureOrigin = .menuBar
                    activeCaptureMode = .automaticScrolling
                    scrollingCaptureProgress = 0
                    let result = await AccessibilityScrollCaptureTarget
                        .resolveFirstScrollableTargetForDebug(
                            bundleIdentifier: bundleIdentifier
                        )
                    switch result {
                    case let .success(target):
                        selectionOverlay(
                            overlayController,
                            didSelectScrollingTarget: target
                        )
                    case let .failure(error):
                        writeDebugCaptureReport(status: "failed", error: error)
                    }
                } else {
                    startScrollingCapture(origin: .menuBar)
                }
            default:
                startCapture(origin: .menuBar)
            }
        }
    }

    private func debugCaptureRect(arguments: [String]) -> CGRect? {
        guard let rawValue = arguments
            .first(where: { $0.hasPrefix("--debug-capture-rect=") })
            .map({ String($0.dropFirst("--debug-capture-rect=".count)) }) else { return nil }
        let values = rawValue.split(separator: ",").compactMap { Double($0) }
        guard values.count == 4, values[2] > 0, values[3] > 0 else { return nil }
        return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
    }

    private func scheduleDebugManualScrollSequence(
        target: AccessibilityScrollCaptureTarget
    ) {
        invalidateDebugManualScrollSession()
        let sessionID = debugManualScrollSessionGate.begin()
        debugManualScrollTarget = target
        debugManualScrollTask = Task { @MainActor [weak self] in
            defer { self?.finishDebugManualScrollSession(sessionID) }
            do {
                try await Task.sleep(for: .milliseconds(1_500))
                try Task.checkCancellation()
                guard let self, self.debugManualScrollSessionGate.contains(sessionID) else { return }
                let span = target.maximumValue - target.minimumValue
                try target.setValue(target.minimumValue + span * 0.04)
                try await Task.sleep(for: .milliseconds(2_500))
                try Task.checkCancellation()
                guard self.debugManualScrollSessionGate.contains(sessionID) else { return }
                try target.setValue(target.minimumValue + span * 0.08)
                for _ in 0..<100 {
                    try Task.checkCancellation()
                    guard self.debugManualScrollSessionGate.contains(sessionID),
                          self.state == .capturing else { return }
                    try await Task.sleep(for: .milliseconds(100))
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.debugManualScrollSessionGate.contains(sessionID) else { return }
                self.captureTask?.cancel()
                self.writeDebugCaptureReport(status: "failed", error: error)
            }
        }
    }

    private func finishDebugManualScrollSession(_ sessionID: UUID) {
        guard debugManualScrollSessionGate.contains(sessionID) else { return }
        let target = debugManualScrollTarget
        debugManualScrollSessionGate.invalidate()
        debugManualScrollTask = nil
        debugManualScrollTarget = nil
        if let target { try? target.setValue(target.originalValue) }
    }

    private func invalidateDebugManualScrollSession() {
        let target = debugManualScrollTarget
        debugManualScrollSessionGate.invalidate()
        debugManualScrollTask?.cancel()
        debugManualScrollTask = nil
        debugManualScrollTarget = nil
        if let target { try? target.setValue(target.originalValue) }
    }

    private func activateDebugTarget(bundleIdentifier: String) async -> Bool {
        guard var application = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ).first else { return false }
        application.unhide()
        if !application.activate(options: [.activateAllWindows]) {
            guard let bundleURL = application.bundleURL else { return false }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.addsToRecentItems = false
            guard let reopenedApplication = try? await NSWorkspace.shared.openApplication(
                at: bundleURL,
                configuration: configuration
            ) else { return false }
            application = reopenedApplication
        }
        for _ in 0..<50 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier,
               AccessibilityScrollCaptureTarget.hasVisibleWindowForDebug(
                    processIdentifier: application.processIdentifier
               ) {
                try? await Task.sleep(for: .milliseconds(250))
                return true
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    private func finishDebugManualCaptureIfNeeded(_ progress: ManualScrollingCaptureProgress) {
        guard !didAutoFinishDebugManualCapture,
              progress.phase == .capturing,
              let threshold = ProcessInfo.processInfo.arguments
                .first(where: { $0.hasPrefix("--debug-manual-auto-finish=") })
                .flatMap({ Int($0.dropFirst("--debug-manual-auto-finish=".count)) }),
              (2...24).contains(threshold),
              progress.fragmentCount >= threshold else { return }
        didAutoFinishDebugManualCapture = true
        manualScrollingControl?.finish()
    }

    private func clearDebugCaptureReport() {
        guard let reportURL = debugCaptureReportURL() else { return }
        try? FileManager.default.removeItem(at: reportURL)
        try? FileManager.default.removeItem(at: reportURL.deletingPathExtension().appendingPathExtension("png"))
    }

    private func writeDebugCaptureReport(
        status: String,
        capture: CapturedImage? = nil,
        error: Error? = nil
    ) {
        guard let reportURL = debugCaptureReportURL() else { return }
        var report: [String: Any] = ["status": status]
        if let capture {
            let pngURL = reportURL.deletingPathExtension().appendingPathExtension("png")
            do {
                try capture.pngData.write(to: pngURL, options: .atomic)
                report.merge([
                    "label": capture.label,
                    "logicalWidth": capture.logicalRect.width,
                    "logicalHeight": capture.logicalRect.height,
                    "pixelWidth": capture.cgImage.width,
                    "pixelHeight": capture.cgImage.height,
                    "pngPath": pngURL.path,
                ]) { _, new in new }
            } catch {
                report["artifactError"] = error.localizedDescription
            }
        }
        if let error {
            report["error"] = error.localizedDescription
        }
        if let scrollingCaptureProgress {
            report["scrollingProgress"] = scrollingCaptureProgress
        }
        if let manualScrollingCaptureProgress {
            report["manualFragmentCount"] = manualScrollingCaptureProgress.fragmentCount
            report["manualLogicalHeight"] = manualScrollingCaptureProgress.logicalHeight
            report["manualPhase"] = String(describing: manualScrollingCaptureProgress.phase)
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: report,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? data.write(to: reportURL, options: .atomic)
    }

    private func debugCaptureReportURL() -> URL? {
        ProcessInfo.processInfo.arguments
            .first(where: { $0.hasPrefix("--debug-capture-report=") })
            .map { URL(fileURLWithPath: String($0.dropFirst("--debug-capture-report=".count))) }
    }
#endif

    func retryShortcutRegistration() {
        shortcutMonitor?.stop()
        startServices()
    }

    func applyShortcut(_ shortcut: KeyboardShortcutValue) {
        guard let shortcutMonitor else { return }
        switch shortcutMonitor.update(to: shortcut) {
        case let .updated(value):
            shortcutRegistration = shortcutMonitor.registration
            setShortcutFeedback("Capture shortcut changed to \(value.displayName).", isError: false)
        case let .unchanged(value):
            shortcutRegistration = shortcutMonitor.registration
            setShortcutFeedback("\(value.displayName) is already the capture shortcut.", isError: false)
        case let .conflict(value):
            setShortcutFeedback("\(value.displayName) is already registered. The current shortcut is unchanged.", isError: true)
        case let .invalid(error):
            setShortcutFeedback(error.localizedDescription, isError: true)
        case let .failed(_, status):
            setShortcutFeedback("The shortcut could not be registered (error \(status)). The current shortcut is unchanged.", isError: true)
        case .persistenceFailed:
            setShortcutFeedback("The shortcut could not be saved. The current shortcut is unchanged.", isError: true)
        }
    }

    func restoreDefaultShortcut() {
        applyShortcut(.defaultCapture)
    }

    func beginShortcutRecording(onActiveShortcut: @escaping (KeyboardShortcutValue) -> Void) {
        shortcutMonitor?.beginRecording(onActiveShortcut: onActiveShortcut)
    }

    func endShortcutRecording() {
        shortcutMonitor?.endRecording()
    }

    func installMainWindowAction(_ action: @escaping () -> Void) {
        openMainWindow = action
    }

    func reopenMainWindow() {
        bringMainWindowForward()
    }

    func handleOpenURL(_ url: URL) {
        if browserCaptureImportService.canHandle(url) {
            guard let request = try? browserCaptureImportService.request(from: url) else { return }
            guard !isTerminationPending else {
                browserCaptureImportService.finalize(request, accepted: false)
                return
            }
            switch browserImportQueue.enqueue(request) {
            case .enqueued:
                startNextBrowserImportIfNeeded()
            case .duplicate:
                break
            case .alreadyCompleted:
                browserCaptureImportService.finalize(request, accepted: true)
            case .full:
                browserCaptureImportService.finalize(request, accepted: false)
            }
            return
        }
        guard let command = SmartShotExternalCommand(url: url) else { return }
        switch command {
        case .capture(.appScroll):
            startScrollingCapture(origin: .menuBar)
        case let .capture(mode):
            startCapture(
                origin: .menuBar,
                initialSelectionMode: CaptureSelectionMode(commandMode: mode)
            )
        case .quickSave:
            quickSaveLatest()
        case .show:
            bringMainWindowForward()
        }
    }

    func refreshChromiumIntegrationStatus() {
        let status = ChromiumNativeMessagingInstaller.inspect()
        applyChromiumIntegrationStatus(status)
    }

    func refreshSafariExtensionStatus() {
        guard safariExtensionTask == nil else { return }
        safariExtensionIsBusy = true
        safariExtensionStatus = .checking
        safariExtensionTask = Task { @MainActor [weak self] in
            let status = await SafariExtensionService.currentStatus()
            guard let self else { return }
            defer {
                safariExtensionIsBusy = false
                safariExtensionTask = nil
            }
            guard !Task.isCancelled else { return }
            safariExtensionStatus = status
        }
    }

    func openSafariExtensionPreferences() {
        guard safariExtensionTask == nil else { return }
        safariExtensionIsBusy = true
        safariExtensionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                safariExtensionIsBusy = false
                safariExtensionTask = nil
            }
            do {
                try await SafariExtensionService.openPreferences()
                try Task.checkCancellation()
                safariExtensionStatus = .preferencesOpened
            } catch is CancellationError {
                return
            } catch {
                safariExtensionStatus = .unavailable(
                    "Could not open Safari extension settings: \(error.localizedDescription)"
                )
            }
        }
    }

    func installChromiumIntegration() {
        guard chromiumIntegrationTask == nil else { return }
        chromiumIntegrationIsBusy = true
        chromiumIntegrationHasError = false
        chromiumIntegrationStatus = "Installing browser connector..."
        let appURL = Bundle.main.bundleURL
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        chromiumIntegrationTask = Task { @MainActor [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                do {
                    let status = try ChromiumNativeMessagingInstaller.install(
                            appURL: appURL,
                            homeDirectory: homeDirectory
                        )
                    return (
                        status: Optional(status),
                        errorMessage: nil as String?
                    )
                } catch {
                    return (
                        status: nil as ChromiumNativeMessagingStatus?,
                        errorMessage: error.localizedDescription
                    )
                }
            }.value
            guard let self else { return }
            if let status = outcome.status {
                applyChromiumIntegrationStatus(status)
            } else {
                chromiumIntegrationStatus = outcome.errorMessage
                    ?? "The browser connector could not be installed."
                chromiumIntegrationIsReady = false
                chromiumIntegrationHasError = true
            }
            chromiumIntegrationIsBusy = false
            chromiumIntegrationTask = nil
        }
    }

    func revealChromiumExtension() {
        guard let pluginsURL = Bundle.main.builtInPlugInsURL else {
            chromiumIntegrationStatus = "The embedded browser extension could not be found."
            chromiumIntegrationHasError = true
            return
        }
        let manifestURL = pluginsURL
            .appendingPathComponent("SmartShot Safari Extension.appex", isDirectory: true)
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            chromiumIntegrationStatus = "The embedded browser extension could not be found."
            chromiumIntegrationHasError = true
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([manifestURL])
    }

    func openHistoryItem(_ item: CaptureHistoryItem) {
        guard !isBusy else { return }
        cancelPendingHistorySelection()
        selectedHistoryID = item.id
        let taskID = UUID()
        captureHistorySelectionTaskID = taskID
        let store = captureHistoryStore
        captureHistorySelectionTask = Task { @MainActor [weak self] in
            do {
                let artifact = try await store.loadArtifact(id: item.id)
                try Task.checkCancellation()
                let capture = try CapturedImage.decoded(
                    pngData: artifact.pngData,
                    logicalRect: artifact.item.logicalRect,
                    label: artifact.item.label
                )
                guard capture.cgImage.width == artifact.item.pixelWidth,
                      capture.cgImage.height == artifact.item.pixelHeight else {
                    throw CaptureHistoryStoreError.invalidCapture
                }
                guard let self,
                      captureHistorySelectionTaskID == taskID,
                      selectedHistoryID == item.id else { return }
                latestCapture = capture
                latestRecording = nil
                captureEditor = makeCaptureEditor(for: capture)
                currentCaptureHistoryID = item.id
                currentCaptureCreatedAt = item.createdAt
                currentCaptureHistorySearchIndex = artifact.searchIndex
                latestSmartShotPasteboardChangeCount = nil
                lastOutputStatus = nil
                captureHistoryError = nil
                state = .idle
                captureHistorySelectionTask = nil
                captureHistorySelectionTaskID = nil
                bringMainWindowForward()
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      captureHistorySelectionTaskID == taskID,
                      selectedHistoryID == item.id else { return }
                captureHistoryError = error.localizedDescription
                selectedHistoryID = nil
                captureHistorySelectionTask = nil
                captureHistorySelectionTaskID = nil
            }
        }
    }

    func deleteHistoryItem(_ item: CaptureHistoryItem) {
        if selectedHistoryID == item.id {
            cancelPendingHistorySelection()
            selectedHistoryID = nil
        }
        if currentCaptureHistoryID == item.id {
            currentCaptureHistoryID = nil
            currentCaptureCreatedAt = nil
            currentCaptureHistorySearchIndex = .none
        }
        queueCaptureHistoryOperation { store in
            try await store.delete(id: item.id)
        }
    }

    func clearCaptureHistory() {
        cancelPendingHistorySelection()
        captureHistorySearchTask?.cancel()
        captureHistorySearchTask = nil
        captureHistorySearchTaskID = nil
        selectedHistoryID = nil
        currentCaptureHistoryID = nil
        currentCaptureCreatedAt = nil
        currentCaptureHistorySearchIndex = .none
        captureHistoryAllItems = []
        captureHistoryItems = []
        captureHistoryError = nil
        queueCaptureHistoryOperation { store in
            try await store.deleteAll()
        }
    }

    private func loadCaptureHistoryIfNeeded() {
        guard !didLoadCaptureHistory else { return }
        didLoadCaptureHistory = true
        let includesOCRText = indexesRecognizedTextInHistory
        queueCaptureHistoryOperation { store in
            if includesOCRText {
                try await store.loadItems()
            } else {
                try await store.removeAllOCRTextIndexes()
            }
        }
    }

    private func recordCaptureInHistory(
        _ capture: CapturedImage,
        id: UUID,
        createdAt: Date,
        searchIndex: CaptureHistorySearchIndex? = nil
    ) {
        let payload = CaptureHistoryPayload(
            id: id,
            createdAt: createdAt,
            label: capture.label,
            logicalRect: capture.logicalRect,
            pixelWidth: capture.cgImage.width,
            pixelHeight: capture.cgImage.height,
            pngData: capture.pngData,
            searchIndex: searchIndex ?? currentCaptureHistorySearchIndex
        )
        let limit = captureHistoryLimit
        queueCaptureHistoryOperation { store in
            try await store.save(payload, limit: limit)
        }
    }

    private func enforceCaptureHistoryLimit() {
        guard didLoadCaptureHistory else { return }
        let limit = captureHistoryLimit
        queueCaptureHistoryOperation { store in
            try await store.enforceLimit(limit)
        }
    }

    private func queueCaptureHistoryOperation(
        _ operation: @escaping @Sendable (CaptureHistoryStore) async throws -> [CaptureHistoryItem]
    ) {
        let previousTask = captureHistoryTask
        let taskID = UUID()
        captureHistoryTaskID = taskID
        let store = captureHistoryStore
        captureHistoryTask = Task { @MainActor [weak self] in
            await previousTask?.value
            guard !Task.isCancelled else { return }
            do {
                let items = try await operation(store)
                guard let self, captureHistoryTaskID == taskID else { return }
                captureHistoryAllItems = items
                refreshCaptureHistoryDisplay()
                captureHistoryError = nil
            } catch {
                guard let self, captureHistoryTaskID == taskID else { return }
                captureHistoryError = error.localizedDescription
            }
            guard let self, captureHistoryTaskID == taskID else { return }
            captureHistoryTask = nil
            captureHistoryTaskID = nil
        }
    }

    private func refreshCaptureHistoryDisplay() {
        captureHistorySearchTask?.cancel()
        captureHistorySearchTaskID = nil
        let query = captureHistoryQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            captureHistoryItems = captureHistoryAllItems
            captureHistorySearchTask = nil
            return
        }

        let store = captureHistoryStore
        let includesOCRText = indexesRecognizedTextInHistory
        let taskID = UUID()
        captureHistorySearchTaskID = taskID
        captureHistorySearchTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(140))
                try Task.checkCancellation()
                let items = try await store.searchItems(
                    matching: query,
                    options: CaptureHistorySearchOptions(
                        includesOCRText: includesOCRText,
                        maximumResults: 500
                    )
                )
                try Task.checkCancellation()
                guard let self,
                      captureHistorySearchTaskID == taskID,
                      captureHistoryQuery.trimmingCharacters(in: .whitespacesAndNewlines) == query,
                      indexesRecognizedTextInHistory == includesOCRText else { return }
                captureHistoryItems = items
                captureHistoryError = nil
                captureHistorySearchTask = nil
                captureHistorySearchTaskID = nil
            } catch is CancellationError {
                return
            } catch {
                guard let self, captureHistorySearchTaskID == taskID else { return }
                captureHistoryError = error.localizedDescription
                captureHistorySearchTask = nil
                captureHistorySearchTaskID = nil
            }
        }
    }

    private func observeCaptureEditor() {
        captureEditorChanges = captureEditor?.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    private func makeCaptureEditor(for capture: CapturedImage) -> CaptureEditorModel {
        let editor = CaptureEditorModel(capture: capture)
        editor.onRecognizedTextChanged = { [weak self, weak editor] text in
            guard let self, let editor, captureEditor === editor else { return }
            indexRecognizedTextForCurrentCapture(text)
        }
        return editor
    }

    private func disableHistoryOCRIndexing() {
        currentCaptureHistorySearchIndex = currentCaptureHistorySearchIndex.removingOCRText
        refreshCaptureHistoryDisplay()
        guard didLoadCaptureHistory else { return }
        queueCaptureHistoryOperation { store in
            try await store.removeAllOCRTextIndexes()
        }
    }

    private func cancelPendingHistorySelection() {
        captureHistorySelectionTask?.cancel()
        captureHistorySelectionTask = nil
        captureHistorySelectionTaskID = nil
    }

    private func indexRecognizedTextForCurrentCapture(_ text: String) {
        guard indexesRecognizedTextInHistory,
              !usesPrivateCaptureMode,
              let id = currentCaptureHistoryID,
              let createdAt = currentCaptureCreatedAt,
              let capture = latestCapture else { return }
        currentCaptureHistorySearchIndex = CaptureHistorySearchIndex(
            filename: currentCaptureHistorySearchIndex.filename,
            ocrText: text,
            ocrIndexingPolicy: .enabled
        )
        recordCaptureInHistory(
            capture,
            id: id,
            createdAt: createdAt,
            searchIndex: currentCaptureHistorySearchIndex
        )
    }

    private func indexCurrentHistoryFilename(_ filename: String) {
        guard let id = currentCaptureHistoryID,
              let createdAt = currentCaptureCreatedAt,
              let capture = latestCapture else { return }
        currentCaptureHistorySearchIndex = CaptureHistorySearchIndex(
            filename: filename,
            ocrText: currentCaptureHistorySearchIndex.ocrText,
            ocrIndexingPolicy: currentCaptureHistorySearchIndex.ocrIndexingPolicy
        )
        recordCaptureInHistory(
            capture,
            id: id,
            createdAt: createdAt,
            searchIndex: currentCaptureHistorySearchIndex
        )
    }

    private func applyChromiumIntegrationStatus(_ status: ChromiumNativeMessagingStatus) {
        chromiumIntegrationIsReady = status.isFullyConfigured
        chromiumIntegrationHasError = false
        if !status.isInstalledApplication {
            chromiumIntegrationStatus = "Install SmartShot in /Applications to enable the Chromium connector."
        } else if !status.isHelperAvailable {
            chromiumIntegrationStatus = "The browser connector is missing from this SmartShot build."
            chromiumIntegrationHasError = true
        } else if status.detectedBrowsers.isEmpty {
            chromiumIntegrationStatus = "No supported Chromium browser was detected."
        } else if status.isFullyConfigured {
            chromiumIntegrationStatus = "Connected: \(status.configuredBrowsers.joined(separator: ", "))."
        } else {
            let pending = status.detectedBrowsers.filter {
                !status.configuredBrowsers.contains($0)
            }
            chromiumIntegrationStatus = "Connector available for: \(pending.joined(separator: ", "))."
        }
    }

    private func startNextBrowserImportIfNeeded() {
        guard !isTerminationPending,
              browserImportTask == nil,
              let request = browserImportQueue.startNext() else { return }
        browserImportTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var completedSuccessfully = false
            do {
                try Task.checkCancellation()
                guard !isBusy, !isTerminationPending else { throw CancellationError() }
                let capture = try await browserCaptureImportService.importCapture(request)
                try Task.checkCancellation()
                guard !isBusy, !isTerminationPending else { throw CancellationError() }
                activeCaptureOrigin = .mainWindow
                completeCapture(capture)
                browserCaptureImportService.finalize(request, accepted: true)
                completedSuccessfully = true
            } catch is CancellationError {
                browserCaptureImportService.finalize(request, accepted: false)
            } catch {
                browserCaptureImportService.finalize(request, accepted: false)
                if !isTerminationPending, !isBusy {
                    state = .failed(error.localizedDescription)
                    bringMainWindowForward()
                }
            }
            browserImportQueue.finishActive(
                request,
                completedSuccessfully: completedSuccessfully
            )
            browserImportTask = nil
            startNextBrowserImportIfNeeded()
        }
    }

    func startCapture(
        origin: CaptureOrigin = .mainWindow,
        initialSelectionMode: CaptureSelectionMode = .smart
    ) {
        guard !isBusy else { return }
        permissions.refresh()
        guard permissions.hasScreenCaptureAccess else {
            state = .failed("Allow Screen Recording access, then return and try again.")
            bringMainWindowForward()
            permissions.requestScreenCaptureIfNeeded()
            return
        }
        cancelPendingHistorySelection()
        activeCaptureOrigin = origin
        activeCaptureMode = .standard
        activeOperation = .screenshot
        scrollingCaptureProgress = nil
        manualScrollingCaptureProgress = nil
        state = .selecting
        overlayController.begin(mode: .unified(initialSelectionMode))
    }

    func startScrollingCapture(origin: CaptureOrigin = .mainWindow) {
        guard !isBusy else { return }
        permissions.refresh()
        guard permissions.hasScreenCaptureAccess else {
            state = .failed("Allow Screen Recording access, then return and try again.")
            bringMainWindowForward()
            permissions.requestScreenCaptureIfNeeded()
            return
        }
        guard permissions.hasAccessibilityAccess else {
            state = .failed("Allow Accessibility access to select and control a scroll area.")
            bringMainWindowForward()
            permissions.requestAccessibilityIfNeeded()
            return
        }
        cancelPendingHistorySelection()
        activeCaptureOrigin = origin
        activeCaptureMode = .automaticScrolling
        activeOperation = .screenshot
        scrollingCaptureProgress = nil
        manualScrollingCaptureProgress = nil
        state = .selecting
        overlayController.begin(mode: .scrollableArea)
    }

    func startRegionRecording(origin: CaptureOrigin = .mainWindow) {
        guard prepareForScreenRecording(origin: origin) else { return }
        state = .selecting
        overlayController.begin(mode: .recordingRegion)
    }

    func startDisplayRecording(origin: CaptureOrigin = .mainWindow) {
        guard prepareForScreenRecording(origin: origin) else { return }
        do {
            let mapped = try RecordingSourceMapper.display(containing: NSEvent.mouseLocation)
            beginScreenRecording(mapped)
        } catch {
            handleScreenRecordingFailure(error)
        }
    }

    private func prepareForScreenRecording(origin: CaptureOrigin) -> Bool {
        guard !isBusy else { return false }
        permissions.refresh()
        guard permissions.hasScreenCaptureAccess else {
            state = .failed("Allow Screen Recording access, then return and try again.")
            bringMainWindowForward()
            permissions.requestScreenCaptureIfNeeded()
            return false
        }
        guard !recordingCapturesMicrophone || permissions.hasMicrophoneAccess else {
            state = .failed("Allow Microphone access, then return and start the recording again.")
            bringMainWindowForward()
            permissions.requestMicrophoneIfNeeded()
            return false
        }
        cancelPendingHistorySelection()
        activeCaptureOrigin = origin
        activeCaptureMode = .standard
        activeOperation = .recording
        scrollingCaptureProgress = nil
        manualScrollingCaptureProgress = nil
        recordingState = .idle
        lastOutputStatus = nil
        return true
    }

    private func beginScreenRecording(_ mapped: MappedRecordingSource) {
        state = .capturing
        activeRecordingRect = mapped.appKitRect
        let options = RecordingOptions(
            capturesSystemAudio: recordingCapturesSystemAudio,
            capturesMicrophone: recordingCapturesMicrophone,
            showsCursor: recordingShowsCursor,
            frameRate: recordingFrameRate,
            maximumLongEdge: recordingMaximumLongEdge
        )
        recordingState = .preparing(UUID())
        let service = screenRecordingService
        captureTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await waitBeforeCapture(relativeTo: mapped.appKitRect)
                let sessionID = try await service.start(source: mapped.source, options: options)
                recordingSessionID = sessionID
                try Task.checkCancellation()
                let serviceState = await service.state
                recordingState = serviceState
                if case let .failed(_, message) = serviceState {
                    handleScreenRecordingFailure(message: message)
                    captureTask = nil
                    return
                }
                guard serviceState == .recording(sessionID) else {
                    throw ScreenRecordingError.invalidSessionTransition
                }
                screenRecordingHUD.show(relativeTo: mapped.appKitRect)
                monitorScreenRecording(sessionID: sessionID)
            } catch is CancellationError {
                let activeSessionID = await service.activeSessionID
                await service.cancel(sessionID: activeSessionID)
                finishCancelledScreenRecording(sessionID: activeSessionID)
            } catch {
                handleScreenRecordingFailure(error)
            }
            captureTask = nil
        }
    }

    private func monitorScreenRecording(sessionID: UUID) {
        recordingMonitorTask?.cancel()
        let service = screenRecordingService
        recordingMonitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self else { return }
                let serviceState = await service.state
                guard serviceState.sessionID == sessionID else { return }
                recordingState = serviceState
                if case let .failed(_, message) = serviceState {
                    handleScreenRecordingFailure(message: message)
                    return
                }
                if !serviceState.isActive { return }
            }
        }
    }

    func selectionOverlay(_ controller: SelectionOverlayController, didSelect candidate: CaptureCandidate) {
        if activeOperation == .recording {
            do {
                beginScreenRecording(try RecordingSourceMapper.region(from: candidate.rect))
            } catch {
                handleScreenRecordingFailure(error)
            }
            return
        }
        state = .capturing
        scrollingCaptureProgress = nil
        captureTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await waitBeforeCapture(relativeTo: candidate.rect)
                let capture = try await captureService.capture(candidate: candidate)
                try Task.checkCancellation()
                completeCapture(capture)
            } catch is CancellationError {
#if DEBUG
                writeDebugCaptureReport(status: "cancelled")
#endif
                state = .idle
                resetCaptureContext()
            } catch {
                handleCaptureFailure(error)
            }
            captureTask = nil
        }
    }

    func selectionOverlay(
        _ controller: SelectionOverlayController,
        didSelectManualScrollingRect rect: CGRect
    ) {
#if DEBUG
        didAutoFinishDebugManualCapture = false
#endif
        activeCaptureMode = .manualScrolling
        state = .capturing
        scrollingCaptureProgress = nil
        manualScrollingCaptureProgress = .init(phase: .preparing, fragmentCount: 0, logicalHeight: 0)
        let control = ManualScrollingCaptureControl()
        manualScrollingControl = control
        captureTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await waitBeforeCapture(relativeTo: rect)
                manualScrollingHUD.show(relativeTo: rect)
                let capture = try await manualScrollingCaptureService.capture(
                    rect: rect,
                    control: control
                ) { progress in
                    self.manualScrollingCaptureProgress = progress
                    self.manualScrollingHUD.update(progress)
#if DEBUG
                    self.finishDebugManualCaptureIfNeeded(progress)
#endif
                }
                try Task.checkCancellation()
                completeCapture(capture)
            } catch is CancellationError {
#if DEBUG
                writeDebugCaptureReport(status: "cancelled")
#endif
                state = .idle
                resetCaptureContext()
            } catch {
                handleCaptureFailure(error)
            }
            captureTask = nil
        }
    }

    func selectionOverlay(
        _ controller: SelectionOverlayController,
        didSelectScrollingTarget target: AccessibilityScrollCaptureTarget
    ) {
        activeCaptureMode = .automaticScrolling
        state = .capturing
        scrollingCaptureProgress = 0
        captureTask = Task { [weak self] in
            guard let self else { return }
            installCaptureEscapeHotKey()
            defer { removeCaptureEscapeHotKey() }
            do {
                try await waitBeforeCapture(
                    relativeTo: target.captureAppKitFrame,
                    installsEscapeHotKey: false
                )
                try target.validate()
                let capture = try await scrollingCaptureService.capture(target: target) { progress in
                    self.scrollingCaptureProgress = progress
                }
                try Task.checkCancellation()
                completeCapture(capture)
            } catch is CancellationError {
#if DEBUG
                writeDebugCaptureReport(status: "cancelled")
#endif
                state = .idle
                resetCaptureContext()
            } catch {
                handleCaptureFailure(error)
            }
            captureTask = nil
        }
    }

    func selectionOverlayDidCancel(_ controller: SelectionOverlayController) {
#if DEBUG
        writeDebugCaptureReport(status: "cancelled")
#endif
        state = .idle
        resetCaptureContext()
    }

    func selectionOverlay(_ controller: SelectionOverlayController, didFailWith message: String) {
        state = .failed(message)
        scrollingCaptureProgress = nil
        if !isTerminationPending,
           activeCaptureOrigin == .mainWindow || showsPreviewAfterExternalCapture {
            bringMainWindowForward()
        }
        activeCaptureMode = .standard
        activeOperation = .screenshot
        activeCaptureOrigin = .mainWindow
    }

    func cancelCapture() {
        guard state == .capturing else { return }
        removeCaptureEscapeHotKey()
        countdownHUD.hide()
        if activeOperation == .recording {
            cancelScreenRecording()
            return
        }
#if DEBUG
        invalidateDebugManualScrollSession()
#endif
        manualScrollingHUD.hide()
        captureTask?.cancel()
    }

    func stopScreenRecording() {
        guard activeOperation == .recording,
              let sessionID = recordingSessionID,
              canStopScreenRecording,
              recordingStopTask == nil else { return }
        screenRecordingHUD.hide()
        recordingMonitorTask?.cancel()
        recordingMonitorTask = nil
        recordingState = .stopping(sessionID)
        let service = screenRecordingService
        recordingStopTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let temporaryArtifact = try await service.stop(sessionID: sessionID)
                recordingState = await service.state
                latestRecording = temporaryArtifact
                do {
                    let artifact = try persistRecording(temporaryArtifact)
                    completeScreenRecording(artifact)
                } catch {
                    handleScreenRecordingFailure(error)
                    lastOutputStatus = "Recording remains in temporary storage. Use Save As to keep it."
                }
            } catch {
                handleScreenRecordingFailure(error)
            }
            recordingStopTask = nil
        }
    }

    func cancelScreenRecording() {
        guard activeOperation == .recording, recordingStopTask == nil else { return }
        screenRecordingHUD.hide()
        recordingMonitorTask?.cancel()
        recordingMonitorTask = nil
        if captureTask != nil {
            captureTask?.cancel()
            return
        }
        let sessionID = recordingSessionID
        if let sessionID {
            recordingState = .cancelled(sessionID)
        }
        let service = screenRecordingService
        captureTask = Task { @MainActor [weak self] in
            await service.cancel(sessionID: sessionID)
            guard let self else { return }
            finishCancelledScreenRecording(sessionID: sessionID)
            captureTask = nil
        }
    }

    private func completeScreenRecording(_ artifact: RecordingArtifact) {
        latestRecording = artifact
        latestCapture = nil
        captureEditor = nil
        recordingState = .finished(artifact.sessionID)
        recordingSessionID = nil
        activeRecordingRect = nil
        state = .idle
        countdownHUD.hide()
        lastOutputStatus = "Saved \(artifact.fileURL.lastPathComponent)"
        if !isTerminationPending,
           activeCaptureOrigin == .mainWindow || showsPreviewAfterExternalCapture {
            bringMainWindowForward()
        }
        activeOperation = .screenshot
        activeCaptureOrigin = .mainWindow
    }

    private func finishCancelledScreenRecording(sessionID: UUID?) {
        screenRecordingHUD.hide()
        recordingMonitorTask?.cancel()
        recordingMonitorTask = nil
        if let sessionID {
            recordingState = .cancelled(sessionID)
        } else {
            recordingState = .idle
        }
        recordingSessionID = nil
        activeRecordingRect = nil
        state = .idle
        countdownHUD.hide()
        activeOperation = .screenshot
        activeCaptureOrigin = .mainWindow
    }

    private func handleScreenRecordingFailure(_ error: Error) {
        handleScreenRecordingFailure(message: error.localizedDescription)
    }

    private func handleScreenRecordingFailure(message: String) {
        screenRecordingHUD.hide()
        recordingMonitorTask?.cancel()
        recordingMonitorTask = nil
        let sessionID = recordingSessionID ?? recordingState.sessionID ?? UUID()
        recordingState = .failed(sessionID, message)
        recordingSessionID = nil
        activeRecordingRect = nil
        state = .failed(message)
        countdownHUD.hide()
        if !isTerminationPending,
           activeCaptureOrigin == .mainWindow || showsPreviewAfterExternalCapture {
            bringMainWindowForward()
        }
        activeOperation = .screenshot
        activeCaptureOrigin = .mainWindow
    }

    private func persistRecording(_ artifact: RecordingArtifact) throws -> RecordingArtifact {
        let directory = try resolvedDefaultSaveDirectory()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let filename = "SmartShot Recording \(formatter.string(from: Date())).mp4"
        let destination = CaptureOutputService.availableURL(
            directory: directory,
            preferredFilename: filename
        )
        try FileManager.default.moveItem(at: artifact.fileURL, to: destination)
        return RecordingArtifact(
            sessionID: artifact.sessionID,
            fileURL: destination,
            duration: artifact.duration,
            pixelSize: artifact.pixelSize,
            capturesSystemAudio: artifact.capturesSystemAudio,
            capturesMicrophone: artifact.capturesMicrophone
        )
    }

    func finishManualScrollingCapture() {
        guard canFinishManualScrollingCapture else { return }
        manualScrollingControl?.finish()
    }

    func applicationShouldTerminate() -> NSApplication.TerminateReply {
        chromiumIntegrationTask?.cancel()
        chromiumIntegrationTask = nil
        safariExtensionTask?.cancel()
        safariExtensionTask = nil
        let pendingBrowserImportTask = browserImportTask
        for request in browserImportQueue.removePending() {
            browserCaptureImportService.finalize(request, accepted: false)
        }
        pendingBrowserImportTask?.cancel()
        captureHistorySelectionTask?.cancel()
        captureHistorySelectionTask = nil
        captureHistorySelectionTaskID = nil
        captureHistorySearchTask?.cancel()
        captureHistorySearchTask = nil
        captureHistorySearchTaskID = nil
        recordingMonitorTask?.cancel()
        recordingMonitorTask = nil
        recordingGIFExportTask?.cancel()
        removeCaptureEscapeHotKey()
        countdownHUD.hide()
        screenRecordingHUD.hide()
        if state == .selecting {
            overlayController.cancel()
        }
        let pendingCaptureTask = captureTask
        let pendingHistoryTask = captureHistoryTask
        let pendingRecordingStopTask = recordingStopTask
        let pendingGIFExportTask = recordingGIFExportTask
        let service = screenRecordingService
        let shouldWaitForTerminalRecordingCleanup: Bool
        if case .failed = recordingState {
            shouldWaitForTerminalRecordingCleanup = true
        } else {
            shouldWaitForTerminalRecordingCleanup = false
        }
        let pendingRecordingCleanupTask: Task<Void, Never>?
        if let activeRecordingSessionID = recordingSessionID,
           pendingRecordingStopTask == nil,
           pendingCaptureTask == nil {
            pendingRecordingCleanupTask = Task {
                await service.cancel(sessionID: activeRecordingSessionID)
                await service.waitForPendingTerminalCleanup()
            }
        } else if shouldWaitForTerminalRecordingCleanup,
                  pendingRecordingStopTask == nil,
                  pendingCaptureTask == nil {
            pendingRecordingCleanupTask = Task {
                await service.waitForPendingTerminalCleanup()
            }
        } else {
            pendingRecordingCleanupTask = nil
        }
        guard pendingCaptureTask != nil || pendingHistoryTask != nil ||
                pendingBrowserImportTask != nil ||
                pendingRecordingStopTask != nil || pendingGIFExportTask != nil ||
                pendingRecordingCleanupTask != nil else {
            return .terminateNow
        }
        guard terminationTask == nil else { return .terminateLater }

        isTerminationPending = true
#if DEBUG
        invalidateDebugManualScrollSession()
#endif
        pendingCaptureTask?.cancel()
        terminationTask = Task { [weak self] in
            await pendingCaptureTask?.value
            await pendingBrowserImportTask?.value
            await pendingHistoryTask?.value
            await self?.captureHistoryTask?.value
            await pendingRecordingStopTask?.value
            await pendingGIFExportTask?.value
            await pendingRecordingCleanupTask?.value
            self?.terminationTask = nil
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func copyLatest() {
        do {
            guard let capture = try captureForOutput() else { return }
            latestSmartShotPasteboardChangeCount = copy(capture)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func chooseDefaultSaveDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if !defaultSaveDirectoryPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: defaultSaveDirectoryPath)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        defaultSaveDirectoryPath = url.standardizedFileURL.path
        lastOutputStatus = nil
    }

    func quickSaveLatest() {
        do {
            guard let capture = try captureForOutput() else {
                state = .failed("There is no screenshot to save.")
                bringMainWindowForward()
                return
            }
            let directory = try resolvedDefaultSaveDirectory()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let filename = CaptureOutputService.filename(
                label: capture.label,
                date: Date(),
                format: outputFormat,
                style: filenameStyle
            )
            let url = CaptureOutputService.availableURL(
                directory: directory,
                preferredFilename: filename
            )
            let data = try CaptureOutputService.encodedData(
                for: capture,
                format: outputFormat
            )
            try data.write(to: url, options: .atomic)
            lastOutputStatus = "Saved \(url.lastPathComponent)"
            indexCurrentHistoryFilename(url.lastPathComponent)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func pinLatest() {
        do {
            guard let capture = try captureForOutput() else { return }
            let controller = PinnedCaptureWindowController(capture: capture)
            controller.onClose = { [weak self] id in
                self?.pinnedCaptures.removeAll { $0.id == id }
            }
            pinnedCaptures.append(controller)
            controller.show()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func clearShortcutFeedback() {
        shortcutFeedback = nil
        shortcutFeedbackIsError = false
    }

    @discardableResult
    private func copy(_ capture: CapturedImage) -> Int {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([capture.image])
        return pasteboard.changeCount
    }

    func flattenLatestEdits() {
        do {
            guard let editor = captureEditor, editor.hasEdits else { return }
            let flattened = try editor.renderedCapture()
            latestCapture = flattened
            captureEditor = makeCaptureEditor(for: flattened)
            currentCaptureHistorySearchIndex = currentCaptureHistorySearchIndex.removingOCRText

            if let changeCount = latestSmartShotPasteboardChangeCount,
               NSPasteboard.general.changeCount == changeCount {
                latestSmartShotPasteboardChangeCount = copy(flattened)
            }

            if let id = currentCaptureHistoryID,
               let createdAt = currentCaptureCreatedAt {
                recordCaptureInHistory(
                    flattened,
                    id: id,
                    createdAt: createdAt,
                    searchIndex: currentCaptureHistorySearchIndex
                )
                selectedHistoryID = id
            }
            lastOutputStatus = "Edits flattened"
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func saveLatest() {
        guard latestCapture != nil else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [outputFormat.contentType]
        let suggestedLabel = (try? captureForOutput())?.label
            ?? latestCapture?.label
            ?? "Capture"
        panel.nameFieldStringValue = CaptureOutputService.filename(
            label: suggestedLabel,
            date: Date(),
            format: outputFormat,
            style: filenameStyle
        )
        panel.canCreateDirectories = true
        if !defaultSaveDirectoryPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: defaultSaveDirectoryPath)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard let capture = try captureForOutput() else { return }
            let data = try CaptureOutputService.encodedData(
                for: capture,
                format: outputFormat
            )
            try data.write(to: url, options: .atomic)
            lastOutputStatus = "Saved \(url.lastPathComponent)"
            indexCurrentHistoryFilename(url.lastPathComponent)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func playLatestRecording() {
        guard let url = latestRecording?.fileURL else { return }
        NSWorkspace.shared.open(url)
    }

    func revealLatestRecording() {
        guard let url = latestRecording?.fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func copyLatestRecordingFile() {
        guard let url = latestRecording?.fileURL else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if pasteboard.writeObjects([url as NSURL]) {
            lastOutputStatus = "Copied recording file"
        }
    }

    func saveLatestRecordingAs() {
        guard let artifact = latestRecording, !isExportingRecordingGIF else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = artifact.fileURL.lastPathComponent
        panel.directoryURL = artifact.fileURL.deletingLastPathComponent()
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            let source = artifact.fileURL.standardizedFileURL
            let target = destination.standardizedFileURL
            try RecordingDestinationInstaller.copyReplacingDestination(
                sourceURL: source,
                destinationURL: target
            )
            lastOutputStatus = "Saved \(target.lastPathComponent)"
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func exportLatestRecordingAsGIF() {
        guard let artifact = latestRecording, recordingGIFExportTask == nil else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.gif]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = artifact.fileURL
            .deletingPathExtension()
            .lastPathComponent + ".gif"
        panel.directoryURL = artifact.fileURL.deletingLastPathComponent()
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let target = destination.standardizedFileURL
        let stagingURL = RecordingDestinationInstaller.stagingURL(for: target)
        isExportingRecordingGIF = true
        recordingGIFExportTask = Task { @MainActor [weak self] in
            defer {
                try? FileManager.default.removeItem(at: stagingURL)
                self?.isExportingRecordingGIF = false
                self?.recordingGIFExportTask = nil
            }
            do {
                _ = try await GIFExportService.export(
                    videoURL: artifact.fileURL,
                    destinationURL: stagingURL
                )
                try Task.checkCancellation()
                try RecordingDestinationInstaller.installStagedFile(
                    at: stagingURL,
                    destinationURL: target
                )
                guard let self else { return }
                lastOutputStatus = "Saved \(target.lastPathComponent)"
            } catch is CancellationError {
                // The staging file is removed by this task's defer block.
            } catch {
                guard let self else { return }
                state = .failed(error.localizedDescription)
            }
        }
    }

    func cancelRecordingGIFExport() {
        recordingGIFExportTask?.cancel()
    }

    func clearError() {
        if case .failed = state {
            state = .idle
            resetCaptureContext()
        }
    }

    private func completeCapture(_ capture: CapturedImage) {
#if DEBUG
        invalidateDebugManualScrollSession()
        writeDebugCaptureReport(status: "succeeded", capture: capture)
#endif
        cancelPendingHistorySelection()
        latestCapture = capture
        latestRecording = nil
        captureEditor = makeCaptureEditor(for: capture)
        selectedHistoryID = nil
        currentCaptureHistoryID = nil
        currentCaptureCreatedAt = nil
        currentCaptureHistorySearchIndex = .none
        latestSmartShotPasteboardChangeCount = nil
        lastOutputStatus = nil
        let policy = CapturePostProcessingPolicy(
            isPrivateCapture: usesPrivateCaptureMode,
            historyEnabled: savesCaptureHistory,
            automaticCopyEnabled: automaticallyCopiesCaptures
        )
        if policy.shouldSaveHistory {
            let id = UUID()
            let createdAt = Date()
            currentCaptureHistoryID = id
            currentCaptureCreatedAt = createdAt
            recordCaptureInHistory(
                capture,
                id: id,
                createdAt: createdAt,
                searchIndex: CaptureHistorySearchIndex.none
            )
        }
        if policy.shouldAutomaticallyCopy {
            latestSmartShotPasteboardChangeCount = copy(capture)
        }
        state = .idle
        scrollingCaptureProgress = nil
        manualScrollingCaptureProgress = nil
        manualScrollingControl = nil
        manualScrollingHUD.hide()
        countdownHUD.hide()
        removeCaptureEscapeHotKey()
        if activeCaptureOrigin == .mainWindow || showsPreviewAfterExternalCapture {
            bringMainWindowForward()
        }
        activeCaptureMode = .standard
        activeOperation = .screenshot
        activeCaptureOrigin = .mainWindow
    }

    private func captureForOutput() throws -> CapturedImage? {
        if let captureEditor {
            return try captureEditor.renderedCapture()
        }
        return latestCapture
    }

    private func handleCaptureFailure(_ error: Error) {
#if DEBUG
        invalidateDebugManualScrollSession()
        writeDebugCaptureReport(status: "failed", error: error)
#endif
        state = .failed(error.localizedDescription)
        scrollingCaptureProgress = nil
        manualScrollingCaptureProgress = nil
        manualScrollingControl = nil
        manualScrollingHUD.hide()
        countdownHUD.hide()
        removeCaptureEscapeHotKey()
        if !isTerminationPending,
           activeCaptureOrigin == .mainWindow || showsPreviewAfterExternalCapture {
            bringMainWindowForward()
        }
        activeCaptureMode = .standard
        activeOperation = .screenshot
        activeCaptureOrigin = .mainWindow
    }

    private func resetCaptureContext() {
#if DEBUG
        invalidateDebugManualScrollSession()
#endif
        scrollingCaptureProgress = nil
        manualScrollingCaptureProgress = nil
        manualScrollingControl = nil
        manualScrollingHUD.hide()
        screenRecordingHUD.hide()
        recordingMonitorTask?.cancel()
        recordingMonitorTask = nil
        countdownHUD.hide()
        removeCaptureEscapeHotKey()
        activeCaptureMode = .standard
        activeOperation = .screenshot
        activeCaptureOrigin = .mainWindow
    }

    private func resolvedDefaultSaveDirectory() throws -> URL {
        if !defaultSaveDirectoryPath.isEmpty {
            return URL(fileURLWithPath: defaultSaveDirectoryPath, isDirectory: true)
        }
        return try CaptureOutputService.defaultDirectory()
    }

    private func waitBeforeCapture(
        relativeTo rect: CGRect,
        installsEscapeHotKey: Bool = true
    ) async throws {
        let delaySeconds = captureDelaySeconds
        let shouldInstallEscapeHotKey = installsEscapeHotKey && delaySeconds > 0
        if shouldInstallEscapeHotKey {
            installCaptureEscapeHotKey()
        }
        defer {
            if shouldInstallEscapeHotKey {
                removeCaptureEscapeHotKey()
            }
        }

        // Give the window server one frame to remove the selection overlays.
        try await Task.sleep(for: .milliseconds(90))
        guard delaySeconds > 0 else { return }

        countdownHUD.show(seconds: delaySeconds, relativeTo: rect)
        defer { countdownHUD.hide() }
        for remaining in stride(from: delaySeconds, through: 1, by: -1) {
            try Task.checkCancellation()
            countdownHUD.update(seconds: remaining)
            try await Task.sleep(for: .seconds(1))
        }
        try Task.checkCancellation()
    }

    private func installCaptureEscapeHotKey() {
        removeCaptureEscapeHotKey()
        let monitor = TransientEscapeHotKeyMonitor { [weak self] in
            self?.cancelCapture()
        }
        guard monitor.start() == .registered else { return }
        captureEscapeHotKeyMonitor = monitor
    }

    private func removeCaptureEscapeHotKey() {
        captureEscapeHotKeyMonitor?.stop()
        captureEscapeHotKeyMonitor = nil
    }

    private func bringMainWindowForward() {
        if let mainWindow = mainWindow() {
            NSApp.activate(ignoringOtherApps: true)
            mainWindow.makeKeyAndOrderFront(nil)
            return
        }

        guard let openMainWindow else { return }
        openMainWindow()
        Task { @MainActor in
            await Task.yield()
            guard let mainWindow = self.mainWindow() else { return }
            NSApp.activate(ignoringOtherApps: true)
            mainWindow.makeKeyAndOrderFront(nil)
        }
    }

    private func mainWindow() -> NSWindow? {
        NSApp.windows.first {
            $0.identifier?.rawValue == "main" || ($0.title == "SmartShot" && $0.canBecomeKey)
        }
    }

    private func setShortcutFeedback(_ message: String, isError: Bool) {
        shortcutFeedback = message
        shortcutFeedbackIsError = isError
    }

    private enum PreferenceKey {
        static let automaticallyCopiesCaptures = "automaticallyCopiesCaptures"
        static let showsPreviewAfterExternalCapture = "showsPreviewAfterExternalCapture"
        static let captureDelaySeconds = "captureDelaySeconds"
        static let savesCaptureHistory = "savesCaptureHistory"
        static let usesPrivateCaptureMode = "usesPrivateCaptureMode"
        static let indexesRecognizedTextInHistory = "indexesRecognizedTextInHistory"
        static let captureHistoryLimit = "captureHistoryLimit"
        static let outputFormat = "outputFormat"
        static let filenameStyle = "filenameStyle"
        static let defaultSaveDirectoryPath = "defaultSaveDirectoryPath"
        static let recordingCapturesSystemAudio = "recordingCapturesSystemAudio"
        static let recordingCapturesMicrophone = "recordingCapturesMicrophone"
        static let recordingShowsCursor = "recordingShowsCursor"
        static let recordingFrameRate = "recordingFrameRate"
        static let recordingMaximumLongEdge = "recordingMaximumLongEdge"
    }

    private static func normalizedHistoryLimit(_ value: Int) -> Int {
        [10, 25, 50, 100, 250].min { abs($0 - value) < abs($1 - value) } ?? 50
    }
}
