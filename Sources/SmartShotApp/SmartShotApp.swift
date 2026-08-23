import SwiftUI

@main
struct SmartShotApp: App {
    @NSApplicationDelegateAdaptor(SmartShotApplicationDelegate.self)
    private var applicationDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("SmartShot", id: "main") {
            MainView(model: model)
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
            CommandGroup(after: .newItem) {
                Button("Capture") { model.startCapture(origin: .mainWindow) }
                Button("Automatic App Scroll (Experimental)") {
                    model.startScrollingCapture(origin: .mainWindow)
                }
                Button("Record Region") {
                    model.startRegionRecording(origin: .mainWindow)
                }
                .disabled(model.isBusy)
                Button("Record Current Display") {
                    model.startDisplayRecording(origin: .mainWindow)
                }
                .disabled(model.isBusy)
                if model.isScreenRecordingWorkflow {
                    Button("Stop Screen Recording") { model.stopScreenRecording() }
                        .disabled(!model.canStopScreenRecording)
                    Button("Cancel Screen Recording") { model.cancelScreenRecording() }
                }
                Divider()
                Button("Copy Latest Capture") { model.copyLatest() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(model.latestCapture == nil)
                Button("Pin Latest Capture") { model.pinLatest() }
                    .disabled(model.latestCapture == nil)
                Button("Save Latest Capture...") { model.saveLatest() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(model.latestCapture == nil)
                Button("Quick Save Latest Capture") { model.quickSaveLatest() }
                    .keyboardShortcut("s", modifiers: [.command, .option])
                    .disabled(model.latestCapture == nil)
            }
        }

        Settings {
            SettingsView(model: model)
        }

        MenuBarExtra("SmartShot", systemImage: "viewfinder") {
            MenuBarContent(model: model)
        }
    }
}

private struct MenuBarContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Capture", systemImage: "viewfinder") {
            model.startCapture(origin: .menuBar)
        }
        Menu("Record", systemImage: "record.circle") {
            Button("Region", systemImage: "crop") {
                model.startRegionRecording(origin: .menuBar)
            }
            Button("Current Display", systemImage: "display") {
                model.startDisplayRecording(origin: .menuBar)
            }
        }
        .disabled(model.isBusy)
        Button(
            "Automatic App Scroll (Experimental)",
            systemImage: AppSymbol.scrollingCapture
        ) {
            model.startScrollingCapture(origin: .menuBar)
        }
        .disabled(model.isBusy)
        if model.isScreenRecordingWorkflow, model.state == .capturing {
            if model.isFinalizingScreenRecording {
                Text("Finalizing recording...")
                    .font(.caption)
            } else {
                Button("Stop Recording", systemImage: "stop.circle.fill") {
                    model.stopScreenRecording()
                }
                .disabled(!model.canStopScreenRecording)
                Button("Cancel Recording", systemImage: "xmark.circle") {
                    model.cancelScreenRecording()
                }
            }
        }
        if model.isScrollingCapture, model.state == .capturing {
            if model.isManualScrollingCapture {
                Button("Finish Long Capture", systemImage: "checkmark.circle") {
                    model.finishManualScrollingCapture()
                }
                .disabled(!model.canFinishManualScrollingCapture)
            }
            Button("Cancel Scrolling Capture", systemImage: "stop.circle") {
                model.cancelCapture()
            }
        }
        if case let .failed(message) = model.state {
            Text(message)
                .font(.caption)
            Button("Dismiss Error", systemImage: "xmark.circle") {
                model.clearError()
            }
        }
        Button("Copy Latest", systemImage: "doc.on.doc") { model.copyLatest() }
            .disabled(model.latestCapture == nil)
        Button("Pin Latest", systemImage: "pin") { model.pinLatest() }
            .disabled(model.latestCapture == nil)
        Button("Save Latest...", systemImage: "square.and.arrow.down") { model.saveLatest() }
            .disabled(model.latestCapture == nil)
        Button("Quick Save", systemImage: "bolt") { model.quickSaveLatest() }
            .disabled(model.latestCapture == nil)
        if model.latestRecording != nil {
            Button("Reveal Recording", systemImage: "folder") {
                model.revealLatestRecording()
            }
            Button("Export Recording as GIF...", systemImage: "photo.stack") {
                model.exportLatestRecordingAsGIF()
            }
            .disabled(model.isExportingRecordingGIF)
        }
        Divider()
        SettingsLink {
            Label("Settings...", systemImage: "gearshape")
        }
        Button("Open SmartShot", systemImage: "macwindow") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Quit SmartShot", systemImage: "power") { NSApp.terminate(nil) }
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
