import AppKit
import SwiftUI

struct MainView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 224, idealWidth: 240, maxWidth: 272)
            preview
                .frame(minWidth: 460)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.isScrollingCapture, model.state == .capturing {
                    if model.isManualScrollingCapture {
                        Button(action: model.finishManualScrollingCapture) {
                            Label("Done", systemImage: "checkmark.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canFinishManualScrollingCapture)
                        .help("Finish and stitch the long capture")
                    }
                    Button(role: .cancel, action: model.cancelCapture) {
                        Label("Cancel", systemImage: "stop.circle")
                    }
                    .help("Cancel scrolling capture")
                } else {
                    Button {
                        model.startCapture(origin: .mainWindow)
                    } label: {
                        Label("Capture", systemImage: "viewfinder")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy)
                    .help("Choose Smart, Region, or Long capture (\(model.shortcutDisplayName))")

                    Menu {
                        Button {
                            model.startScrollingCapture(origin: .mainWindow)
                        } label: {
                            Label("Automatic App Scroll (Experimental)", systemImage: AppSymbol.scrollingCapture)
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                    .disabled(model.isBusy)
                }
            }
        }
        .alert("SmartShot couldn't complete the capture", isPresented: errorBinding) {
            Button("OK", role: .cancel) { model.clearError() }
        } message: {
            Text(errorMessage)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.permissions.refresh()
        }
        .onAppear {
            model.installMainWindowAction {
                openWindow(id: "main")
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Label("SmartShot", systemImage: "viewfinder")
                    .font(.title2.weight(.semibold))
                Text("Smart, region, and long capture for macOS")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 22)
            .padding(.bottom, 20)

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                Text("ACCESS")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                ShortcutRow(
                    detail: model.shortcutDetail,
                    isReady: model.shortcutIsReady,
                    retry: model.retryShortcutRegistration
                )

                PermissionRow(
                    title: "Screen Recording",
                    detail: "Required to create screenshots",
                    isGranted: model.permissions.hasScreenCaptureAccess,
                    action: model.permissions.hasScreenCaptureAccess
                        ? model.permissions.openScreenCaptureSettings
                        : model.permissions.requestScreenCapture
                )

                PermissionRow(
                    title: "Accessibility",
                    detail: "Improves content block detection",
                    isGranted: model.permissions.hasAccessibilityAccess,
                    action: model.permissions.hasAccessibilityAccess
                        ? model.permissions.openAccessibilitySettings
                        : model.permissions.requestAccessibility
                )
            }
            .padding(20)

            Spacer()

            HStack(spacing: 7) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }

    private var preview: some View {
        VStack(spacing: 0) {
            if let capture = model.latestCapture {
                VStack(spacing: 0) {
                    if let editor = model.captureEditor {
                        CaptureEditorView(editor: editor)
                    } else {
                        GeometryReader { proxy in
                            Image(nsImage: capture.image)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: proxy.size.width, maxHeight: proxy.size.height)
                                .frame(width: proxy.size.width, height: proxy.size.height)
                                .accessibilityLabel("Latest screenshot preview")
                        }
                        .padding(20)
                    }

                    Divider()

                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(capture.label)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                            Text("\(Int(previewSize.width)) x \(Int(previewSize.height)) points")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(action: model.pinLatest) {
                            Label("Pin", systemImage: "pin")
                        }
                        .help("Keep the screenshot above other windows")
                        Button(action: model.copyLatest) {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        .help("Copy the screenshot")
                        Button(action: model.saveLatest) {
                            Label("Save", systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(.borderedProminent)
                        .help("Save as PNG")
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                }
            } else {
                ContentUnavailableView {
                    Label("No Captures", systemImage: "viewfinder")
                } description: {
                    Text("Captured images appear here.")
                } actions: {
                    HStack {
                        Button {
                            model.startCapture(origin: .mainWindow)
                        } label: {
                            Label("Capture", systemImage: "viewfinder")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isBusy)
                    }
                }
            }
        }
    }

    private var previewSize: CGSize {
        model.captureEditor?.previewLogicalSize ?? model.latestCapture?.logicalRect.size ?? .zero
    }

    private var statusText: String {
        switch model.state {
        case .idle: "Ready"
        case .selecting: "Selecting content"
        case .capturing:
            if let progress = model.manualScrollingCaptureProgress {
                switch progress.phase {
                case .preparing:
                    "Preparing long capture"
                case .ready:
                    "Long capture ready"
                case .capturing:
                    "Long capture: \(progress.fragmentCount) sections"
                case .stitching:
                    "Stitching long capture"
                }
            } else if let progress = model.scrollingCaptureProgress {
                "Capturing scroll area \(Int(progress * 100))%"
            } else {
                "Creating screenshot"
            }
        case .failed: "Action needed"
        }
    }

    private var statusColor: Color {
        switch model.state {
        case .idle: .green
        case .selecting, .capturing: .orange
        case .failed: .red
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { if case .failed = model.state { true } else { false } },
            set: { if !$0 { model.clearError() } }
        )
    }

    private var errorMessage: String {
        if case let .failed(message) = model.state { message } else { "" }
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let isGranted: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isGranted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(isGranted ? .green : .orange)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button(isGranted ? "Settings" : "Allow", action: action)
                .controlSize(.small)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(isGranted ? "allowed" : "not allowed")")
    }
}

private struct ShortcutRow: View {
    let detail: String
    let isReady: Bool
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(isReady ? .green : .orange)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Global Shortcut")
                    .font(.subheadline.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if !isReady {
                Button("Retry", action: retry)
                    .controlSize(.small)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Global shortcut, \(detail)")
    }
}
