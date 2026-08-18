import AppKit
import SmartShotCore
import Foundation

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

    @Published private(set) var state: CaptureState = .idle
    @Published private(set) var latestCapture: CapturedImage?
    @Published private(set) var scrollingCaptureProgress: Double?
    @Published private(set) var manualScrollingCaptureProgress: ManualScrollingCaptureProgress?
    @Published private(set) var shortcutRegistration: GlobalShortcutMonitor.Registration = .inactive
    @Published private(set) var shortcutFeedback: String?
    @Published private(set) var shortcutFeedbackIsError = false
    @Published var automaticallyCopiesCaptures: Bool {
        didSet { defaults.set(automaticallyCopiesCaptures, forKey: PreferenceKey.automaticallyCopiesCaptures) }
    }
    @Published var showsPreviewAfterExternalCapture: Bool {
        didSet { defaults.set(showsPreviewAfterExternalCapture, forKey: PreferenceKey.showsPreviewAfterExternalCapture) }
    }
    @Published var captureDelaySeconds: Int {
        didSet { defaults.set(captureDelaySeconds, forKey: PreferenceKey.captureDelaySeconds) }
    }

    let permissions = PermissionService()
    private let captureService = ScreenCaptureService()
    private let scrollingCaptureService = ScrollingCaptureService()
    private let manualScrollingCaptureService = ManualScrollingCaptureService()
    private let overlayController = SelectionOverlayController()
    private let manualScrollingHUD = ManualScrollingCaptureHUDController()
    private let countdownHUD = CaptureCountdownHUDController()
    private var shortcutMonitor: GlobalShortcutMonitor?
    private var activeCaptureOrigin: CaptureOrigin = .mainWindow
    private var activeCaptureMode: CaptureMode = .standard
    private var captureTask: Task<Void, Never>?
    private var manualScrollingControl: ManualScrollingCaptureControl?
    private var pinnedCaptures: [PinnedCaptureWindowController] = []
    private var terminationTask: Task<Void, Never>?
    private var isTerminationPending = false
    private var openMainWindow: (() -> Void)?
    private let defaults: UserDefaults

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
        overlayController.delegate = self
        manualScrollingHUD.onFinish = { [weak self] in
            self?.finishManualScrollingCapture()
        }
        manualScrollingHUD.onCancel = { [weak self] in
            self?.cancelCapture()
        }
        shortcutMonitor = GlobalShortcutMonitor(defaults: defaults) { [weak self] in
            self?.startCapture(origin: .globalShortcut)
        }
    }

    var isBusy: Bool {
        state == .selecting || state == .capturing
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
    }

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

    func startCapture(origin: CaptureOrigin = .mainWindow) {
        guard !isBusy else { return }
        permissions.refresh()
        guard permissions.hasScreenCaptureAccess else {
            state = .failed("Allow Screen Recording access, then return and try again.")
            bringMainWindowForward()
            permissions.requestScreenCapture()
            return
        }
        activeCaptureOrigin = origin
        activeCaptureMode = .standard
        scrollingCaptureProgress = nil
        manualScrollingCaptureProgress = nil
        state = .selecting
        overlayController.begin(mode: .unified(.smart))
    }

    func startScrollingCapture(origin: CaptureOrigin = .mainWindow) {
        guard !isBusy else { return }
        permissions.refresh()
        guard permissions.hasScreenCaptureAccess else {
            state = .failed("Allow Screen Recording access, then return and try again.")
            bringMainWindowForward()
            permissions.requestScreenCapture()
            return
        }
        guard permissions.hasAccessibilityAccess else {
            state = .failed("Allow Accessibility access to select and control a scroll area.")
            bringMainWindowForward()
            permissions.requestAccessibility()
            return
        }
        activeCaptureOrigin = origin
        activeCaptureMode = .automaticScrolling
        scrollingCaptureProgress = nil
        manualScrollingCaptureProgress = nil
        state = .selecting
        overlayController.begin(mode: .scrollableArea)
    }

    func selectionOverlay(_ controller: SelectionOverlayController, didSelect candidate: CaptureCandidate) {
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
                }
                try Task.checkCancellation()
                completeCapture(capture)
            } catch is CancellationError {
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
        state = .capturing
        scrollingCaptureProgress = 0
        captureTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await waitBeforeCapture(relativeTo: target.captureAppKitFrame)
                try target.validate()
                let capture = try await scrollingCaptureService.capture(target: target) { progress in
                    self.scrollingCaptureProgress = progress
                }
                try Task.checkCancellation()
                completeCapture(capture)
            } catch is CancellationError {
                state = .idle
                resetCaptureContext()
            } catch {
                handleCaptureFailure(error)
            }
            captureTask = nil
        }
    }

    func selectionOverlayDidCancel(_ controller: SelectionOverlayController) {
        state = .idle
        resetCaptureContext()
    }

    func selectionOverlay(_ controller: SelectionOverlayController, didFailWith message: String) {
        state = .failed(message)
        scrollingCaptureProgress = nil
        if activeCaptureOrigin == .mainWindow || showsPreviewAfterExternalCapture {
            bringMainWindowForward()
        }
        activeCaptureMode = .standard
        activeCaptureOrigin = .mainWindow
    }

    func cancelCapture() {
        guard state == .capturing else { return }
        manualScrollingHUD.hide()
        countdownHUD.hide()
        captureTask?.cancel()
    }

    func finishManualScrollingCapture() {
        guard canFinishManualScrollingCapture else { return }
        manualScrollingControl?.finish()
    }

    func applicationShouldTerminate() -> NSApplication.TerminateReply {
        if state == .selecting {
            overlayController.cancel()
            return .terminateNow
        }
        guard let captureTask else { return .terminateNow }
        guard terminationTask == nil else { return .terminateLater }

        isTerminationPending = true
        captureTask.cancel()
        terminationTask = Task { [weak self] in
            await captureTask.value
            self?.terminationTask = nil
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func copyLatest() {
        guard let latestCapture else { return }
        copy(latestCapture)
    }

    func pinLatest() {
        guard let latestCapture else { return }
        let controller = PinnedCaptureWindowController(capture: latestCapture)
        controller.onClose = { [weak self] id in
            self?.pinnedCaptures.removeAll { $0.id == id }
        }
        pinnedCaptures.append(controller)
        controller.show()
    }

    func clearShortcutFeedback() {
        shortcutFeedback = nil
        shortcutFeedbackIsError = false
    }

    private func copy(_ capture: CapturedImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([capture.image])
    }

    func saveLatest() {
        guard let latestCapture else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = defaultFilename()
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try latestCapture.pngData.write(to: url, options: .atomic)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func clearError() {
        if case .failed = state {
            state = .idle
            resetCaptureContext()
        }
    }

    private func completeCapture(_ capture: CapturedImage) {
        latestCapture = capture
        if automaticallyCopiesCaptures {
            copy(capture)
        }
        state = .idle
        scrollingCaptureProgress = nil
        manualScrollingCaptureProgress = nil
        manualScrollingControl = nil
        manualScrollingHUD.hide()
        countdownHUD.hide()
        if activeCaptureOrigin == .mainWindow || showsPreviewAfterExternalCapture {
            bringMainWindowForward()
        }
        activeCaptureMode = .standard
        activeCaptureOrigin = .mainWindow
    }

    private func handleCaptureFailure(_ error: Error) {
        state = .failed(error.localizedDescription)
        scrollingCaptureProgress = nil
        manualScrollingCaptureProgress = nil
        manualScrollingControl = nil
        manualScrollingHUD.hide()
        countdownHUD.hide()
        if !isTerminationPending,
           activeCaptureOrigin == .mainWindow || showsPreviewAfterExternalCapture {
            bringMainWindowForward()
        }
        activeCaptureMode = .standard
        activeCaptureOrigin = .mainWindow
    }

    private func resetCaptureContext() {
        scrollingCaptureProgress = nil
        manualScrollingCaptureProgress = nil
        manualScrollingControl = nil
        manualScrollingHUD.hide()
        countdownHUD.hide()
        activeCaptureMode = .standard
        activeCaptureOrigin = .mainWindow
    }

    private func defaultFilename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "SmartShot \(formatter.string(from: Date())).png"
    }

    private func waitBeforeCapture(relativeTo rect: CGRect) async throws {
        // Give the window server one frame to remove the selection overlays.
        try await Task.sleep(for: .milliseconds(90))
        guard captureDelaySeconds > 0 else { return }

        countdownHUD.show(seconds: captureDelaySeconds, relativeTo: rect)
        defer { countdownHUD.hide() }
        for remaining in stride(from: captureDelaySeconds, through: 1, by: -1) {
            try Task.checkCancellation()
            countdownHUD.update(seconds: remaining)
            try await Task.sleep(for: .seconds(1))
        }
        try Task.checkCancellation()
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
    }
}
