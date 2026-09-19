import AppKit
import SmartShotCore
import SwiftUI

@main
@MainActor
enum SmartShotMain {
    static func main() {
        AppLanguage.prepareForLaunch()
        SmartShotApp.main()
    }
}

struct SmartShotApp: App {
    @NSApplicationDelegateAdaptor(SmartShotApplicationDelegate.self)
    private var applicationDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("SmartShot", id: "main") {
            MainView(model: model)
                .environment(\.locale, AppLanguage.current.locale)
                .frame(minWidth: 820, minHeight: 560)
                .onAppear {
                    applicationDelegate.installTerminationHandler {
                        model.applicationShouldTerminate()
                    }
                    applicationDelegate.installReopenHandler {
                        model.reopenMainWindow()
                    }
                    model.permissions.refresh()
                    model.startServices()
                    applicationDelegate.installOpenURLHandler(model.handleOpenURL)
                }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(L10n.text("About SmartShot"), action: showAboutPanel)
            }
            CommandGroup(after: .newItem) {
                Button(L10n.text("Capture")) { model.startCapture(origin: .mainWindow) }
                Button(L10n.text("Automatic App Scroll (Experimental)")) {
                    model.startScrollingCapture(origin: .mainWindow)
                }
                Button(L10n.text("Record Region")) {
                    model.startRegionRecording(origin: .mainWindow)
                }
                .disabled(model.isBusy)
                Button(L10n.text("Record Current Display")) {
                    model.startDisplayRecording(origin: .mainWindow)
                }
                .disabled(model.isBusy)
                if model.isScreenRecordingWorkflow {
                    Button(L10n.text("Stop Screen Recording")) { model.stopScreenRecording() }
                        .disabled(!model.canStopScreenRecording)
                    Button(L10n.text("Cancel Screen Recording")) { model.cancelScreenRecording() }
                }
                Divider()
                Button(L10n.text("Copy Latest Capture")) { model.copyLatest() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(model.latestCapture == nil)
                Button(L10n.text("Pin Latest Capture")) { model.pinLatest() }
                    .disabled(model.latestCapture == nil)
                Button(L10n.text("Save Latest Capture...")) { model.saveLatest() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(model.latestCapture == nil)
                Button(L10n.text("Quick Save Latest Capture")) { model.quickSaveLatest() }
                    .keyboardShortcut("s", modifiers: [.command, .option])
                    .disabled(model.latestCapture == nil)
            }
        }

        Settings {
            SettingsView(model: model)
                .environment(\.locale, AppLanguage.current.locale)
        }

        MenuBarExtra("SmartShot", systemImage: "viewfinder") {
            MenuBarContent(model: model)
                .environment(\.locale, AppLanguage.current.locale)
        }
    }

    private func showAboutPanel() {
        let repositoryURL = "https://github.com/infinityf4p/SmartShot"
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        let credits = NSAttributedString(
            string: repositoryURL,
            attributes: [
                .link: repositoryURL,
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .paragraphStyle: paragraphStyle
            ]
        )
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}

private struct MenuBarContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(L10n.text("Capture"), systemImage: "viewfinder") {
            model.startCapture(origin: .menuBar)
        }
        Menu(L10n.text("Record"), systemImage: "record.circle") {
            Button(L10n.text("Region"), systemImage: "crop") {
                model.startRegionRecording(origin: .menuBar)
            }
            Button(L10n.text("Current Display"), systemImage: "display") {
                model.startDisplayRecording(origin: .menuBar)
            }
        }
        .disabled(model.isBusy)
        Button(
            L10n.text("Automatic App Scroll (Experimental)"),
            systemImage: AppSymbol.scrollingCapture
        ) {
            model.startScrollingCapture(origin: .menuBar)
        }
        .disabled(model.isBusy)
        if model.isScreenRecordingWorkflow, model.state == .capturing {
            if model.isFinalizingScreenRecording {
                Text(L10n.text("Finalizing recording..."))
                    .font(.caption)
            } else {
                Button(L10n.text("Stop Recording"), systemImage: "stop.circle.fill") {
                    model.stopScreenRecording()
                }
                .disabled(!model.canStopScreenRecording)
                Button(L10n.text("Cancel Recording"), systemImage: "xmark.circle") {
                    model.cancelScreenRecording()
                }
            }
        }
        if model.isScrollingCapture, model.state == .capturing {
            if model.isManualScrollingCapture {
                Button(L10n.text("Finish Long Capture"), systemImage: "checkmark.circle") {
                    model.finishManualScrollingCapture()
                }
                .disabled(!model.canFinishManualScrollingCapture)
            }
            Button(L10n.text("Cancel Scrolling Capture"), systemImage: "stop.circle") {
                model.cancelCapture()
            }
        }
        if case let .failed(message) = model.state {
            Text(message)
                .font(.caption)
            Button(L10n.text("Dismiss Error"), systemImage: "xmark.circle") {
                model.clearError()
            }
        }
        Button(L10n.text("Copy Latest"), systemImage: "doc.on.doc") { model.copyLatest() }
            .disabled(model.latestCapture == nil)
        Button(L10n.text("Pin Latest"), systemImage: "pin") { model.pinLatest() }
            .disabled(model.latestCapture == nil)
        Button(L10n.text("Save Latest..."), systemImage: "square.and.arrow.down") { model.saveLatest() }
            .disabled(model.latestCapture == nil)
        Button(L10n.text("Quick Save"), systemImage: "bolt") { model.quickSaveLatest() }
            .disabled(model.latestCapture == nil)
        if model.latestRecording != nil {
            Button(L10n.text("Reveal Recording"), systemImage: "folder") {
                model.revealLatestRecording()
            }
            Button(L10n.text("Export Recording as GIF..."), systemImage: "photo.stack") {
                model.exportLatestRecordingAsGIF()
            }
            .disabled(model.isExportingRecordingGIF)
        }
        Divider()
        SettingsLink {
            Label(L10n.text("Settings..."), systemImage: "gearshape")
        }
        Button(L10n.text("Open SmartShot"), systemImage: "macwindow") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button(L10n.text("Quit SmartShot"), systemImage: "power") { NSApp.terminate(nil) }
    }
}

@MainActor
private final class SmartShotApplicationDelegate: NSObject, NSApplicationDelegate {
    private var terminationHandler: (() -> NSApplication.TerminateReply)?
    private var reopenHandler: (() -> Void)?
    private var openURLHandler: ((URL) -> Void)?
    private var pendingURLs: [URL] = []

    func installTerminationHandler(_ handler: @escaping () -> NSApplication.TerminateReply) {
        terminationHandler = handler
    }

    func installReopenHandler(_ handler: @escaping () -> Void) {
        reopenHandler = handler
    }

    func installOpenURLHandler(_ handler: @escaping (URL) -> Void) {
        openURLHandler = handler
        let queuedURLs = pendingURLs
        pendingURLs.removeAll()
        queuedURLs.forEach(handler)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let openURLHandler else {
            pendingURLs.append(contentsOf: urls)
            return
        }
        urls.forEach(openURLHandler)
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        reopenHandler?()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        terminationHandler?() ?? .terminateNow
    }
}
