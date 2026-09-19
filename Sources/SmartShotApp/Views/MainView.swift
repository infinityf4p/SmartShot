import SmartShotCore
import AppKit
import AVKit
import SwiftUI

struct MainView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var capturePendingClose: CaptureEditorModel?

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 224, idealWidth: 240, maxWidth: 272, maxHeight: .infinity)
            preview
                .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.isScreenRecordingWorkflow, model.state == .capturing {
                    if model.isFinalizingScreenRecording {
                        ProgressView()
                            .controlSize(.small)
                        Text(L10n.text("Finalizing"))
                            .foregroundStyle(.secondary)
                    } else {
                        Button(action: model.stopScreenRecording) {
                            Label(L10n.text("Stop"), systemImage: "stop.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canStopScreenRecording)
                        Button(role: .cancel, action: model.cancelScreenRecording) {
                            Label(L10n.text("Cancel"), systemImage: "xmark.circle")
                        }
                    }
                } else if model.isScrollingCapture, model.state == .capturing {
                    if model.isManualScrollingCapture {
                        Button(action: model.finishManualScrollingCapture) {
                            Label(L10n.text("Done"), systemImage: "checkmark.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canFinishManualScrollingCapture)
                        .help(L10n.text("Finish and stitch the long capture"))
                    }
                    Button(role: .cancel, action: model.cancelCapture) {
                        Label(L10n.text("Cancel"), systemImage: "stop.circle")
                    }
                    .help(L10n.text("Cancel scrolling capture"))
                } else {
                    Button {
                        model.startCapture(origin: .mainWindow)
                    } label: {
                        Label(L10n.text("Capture"), systemImage: "viewfinder")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy)
                    .help(L10n.format("Choose Smart, Region, Long, or App Scroll (%@)", String(describing: model.shortcutDisplayName)))

                    Menu {
                        Button {
                            model.startRegionRecording(origin: .mainWindow)
                        } label: {
                            Label(L10n.text("Record Region"), systemImage: "record.circle")
                        }
                        Button {
                            model.startDisplayRecording(origin: .mainWindow)
                        } label: {
                            Label(L10n.text("Record Current Display"), systemImage: "display")
                        }
                    } label: {
                        Label(L10n.text("Record"), systemImage: "record.circle")
                    }
                    .disabled(model.isBusy)
                    .help(L10n.text("Record a region or the current display"))

                    Menu {
                        Button {
                            model.startScrollingCapture(origin: .mainWindow)
                        } label: {
                            Label(L10n.text("Automatic App Scroll (Experimental)"), systemImage: AppSymbol.scrollingCapture)
                        }
                    } label: {
                        Label(L10n.text("More"), systemImage: "ellipsis.circle")
                    }
                    .disabled(model.isBusy)
                    .help(L10n.text("Automatic App Scroll (Experimental)"))
                }
            }
        }
        .alert(L10n.text("SmartShot couldn't complete the action"), isPresented: errorBinding) {
            Button(L10n.text("OK"), role: .cancel) { model.clearError() }
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
            Label("SmartShot", systemImage: "viewfinder")
                .font(.title2.weight(.semibold))
                .padding(.horizontal, 20)
                .padding(.top, 22)
                .padding(.bottom, 20)

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                Text(L10n.text("ACCESS"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                ShortcutRow(
                    detail: model.shortcutDetail,
                    isReady: model.shortcutIsReady,
                    retry: model.retryShortcutRegistration
                )

                PermissionRow(
                    title: L10n.text("Screen Recording"),
                    detail: L10n.text("Required to create screenshots"),
                    isGranted: model.permissions.hasScreenCaptureAccess,
                    actionTitle: model.permissions.screenCaptureActionTitle,
                    action: model.permissions.hasScreenCaptureAccess
                        ? model.permissions.openScreenCaptureSettings
                        : model.permissions.requestScreenCapture
                )

                PermissionRow(
                    title: L10n.text("Accessibility"),
                    detail: L10n.text("Improves content block detection"),
                    isGranted: model.permissions.hasAccessibilityAccess,
                    actionTitle: model.permissions.accessibilityActionTitle,
                    action: model.permissions.hasAccessibilityAccess
                        ? model.permissions.openAccessibilitySettings
                        : model.permissions.requestAccessibility
                )
            }
            .padding(20)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L10n.text("HISTORY"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let error = model.captureHistoryError {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .help(error)
                            .accessibilityLabel(error)
                    }
                }

                TextField(L10n.text("Search history"), text: $model.captureHistoryQuery)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(L10n.text("Search screenshot history"))

                if !model.hasCaptureHistory {
                    ContentUnavailableView(
                        L10n.text("No History"),
                        systemImage: "clock.arrow.circlepath"
                    )
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.captureHistoryItems.isEmpty {
                    ContentUnavailableView(
                        L10n.text("No Results"),
                        systemImage: "magnifyingglass"
                    )
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(model.captureHistoryItems) { item in
                                CaptureHistoryRow(
                                    item: item,
                                    isSelected: model.selectedHistoryID == item.id,
                                    open: { model.openHistoryItem(item) },
                                    delete: { model.deleteHistoryItem(item) }
                                )
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .frame(maxHeight: .infinity)

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
            if let recording = model.latestRecording {
                RecordingResultView(artifact: recording, model: model)
                    .id(recording.sessionID)
            } else if let capture = model.latestCapture {
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
                                .accessibilityLabel(L10n.text("Latest screenshot preview"))
                        }
                        .padding(20)
                    }

                    Divider()

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) {
                            captureDetails(capture)
                            Spacer(minLength: 10)
                            flattenCaptureButton
                            captureOutputButtons
                            closeCaptureButton
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 10) {
                                captureDetails(capture)
                                Spacer(minLength: 10)
                                flattenCaptureButton
                                closeCaptureButton
                            }
                            captureOutputButtons
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                }
            } else {
                ContentUnavailableView {
                    Label(L10n.text("No Captures"), systemImage: "viewfinder")
                } description: {
                    Text(L10n.text("Captured images appear here."))
                } actions: {
                    HStack(spacing: 8) {
                        Button {
                            model.startCapture(origin: .mainWindow)
                        } label: {
                            Label(L10n.text("Capture"), systemImage: "viewfinder")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isBusy)
                        Button {
                            model.startRegionRecording(origin: .mainWindow)
                        } label: {
                            Label(L10n.text("Record"), systemImage: "record.circle")
                        }
                        .disabled(model.isBusy)
                    }
                }
            }
        }
    }

    private func captureDetails(_ capture: CapturedImage) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(capture.label)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            Text(L10n.format("%@ x %@ points", String(describing: Int(previewSize.width)), String(describing: Int(previewSize.height))))
                .font(.caption)
                .foregroundStyle(.secondary)
            if let status = model.lastOutputStatus {
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var flattenCaptureButton: some View {
        if let editor = model.captureEditor, editor.hasEdits {
            Button(action: model.flattenLatestEdits) {
                Label(L10n.text("Flatten"), systemImage: "square.stack.3d.down.forward")
            }
            .fixedSize()
            .help(L10n.text("Replace the original and history copy with the rendered edits"))
        }
    }

    private var captureOutputButtons: some View {
        HStack(spacing: 10) {
            Button(action: model.pinLatest) {
                Label(L10n.text("Pin"), systemImage: "pin")
            }
            .help(L10n.text("Keep the screenshot above other windows"))
            Button(action: model.copyLatest) {
                Label(L10n.text("Copy"), systemImage: "doc.on.doc")
            }
            .help(L10n.text("Copy the screenshot"))
            ControlGroup {
                Button(action: model.quickSaveLatest) {
                    Label(L10n.text("Save"), systemImage: "square.and.arrow.down")
                        .labelStyle(.titleAndIcon)
                }
                .help(L10n.text("Quick Save: Save immediately to the Quick Save folder"))
                Button(action: model.saveLatest) {
                    Image(systemName: "chevron.down")
                        .frame(width: 12)
                }
                .help(L10n.text("Save with options: Choose a filename and location"))
                .accessibilityLabel(L10n.text("Save with options"))
            }
            .controlGroupStyle(.navigation)
            .buttonStyle(.borderedProminent)
        }
        .fixedSize()
    }

    private var closeCaptureButton: some View {
        Button {
            if let editor = model.captureEditor, editor.hasEdits {
                capturePendingClose = editor
            } else {
                model.closeLatestCapture()
            }
        } label: {
            Image(systemName: "xmark")
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.borderless)
        .disabled(model.isBusy)
        .help(L10n.text("Close screenshot"))
        .accessibilityLabel(L10n.text("Close screenshot"))
        .confirmationDialog(
            L10n.text("Close screenshot?"),
            isPresented: Binding(
                get: { capturePendingClose != nil },
                set: { if !$0 { capturePendingClose = nil } }
            ),
            titleVisibility: .visible,
            presenting: capturePendingClose
        ) { editor in
            Button(L10n.text("Close Screenshot"), role: .destructive) {
                guard model.captureEditor === editor else { return }
                model.closeLatestCapture()
            }
        } message: { _ in
            Text(L10n.text("Edits in this preview will be discarded. Saved files and history will be kept."))
        }
    }

    private var previewSize: CGSize {
        model.captureEditor?.previewLogicalSize ?? model.latestCapture?.logicalRect.size ?? .zero
    }

    private var statusText: String {
        switch model.state {
        case .idle: L10n.text("Ready")
        case .selecting: L10n.text("Selecting content")
        case .capturing:
            if model.isScreenRecordingWorkflow {
                model.recordingStatusText ?? L10n.text("Recording screen")
            } else if let progress = model.manualScrollingCaptureProgress {
                switch progress.phase {
                case .preparing:
                    L10n.text("Preparing long capture")
                case .ready:
                    L10n.text("Long capture ready")
                case .capturing:
                    L10n.format("Long capture: %@ sections", String(describing: progress.fragmentCount))
                case .stitching:
                    L10n.text("Stitching long capture")
                }
            } else if let progress = model.scrollingCaptureProgress {
                L10n.format("Capturing scroll area %@%%", String(describing: Int(progress * 100)))
            } else {
                L10n.text("Creating screenshot")
            }
        case .failed: L10n.text("Action needed")
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

private struct RecordingResultView: View {
    let artifact: RecordingArtifact
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                RecordingPlayerView(url: artifact.fileURL)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .background(Color.black)
                    .accessibilityLabel(L10n.text("Latest screen recording preview"))
            }
            .padding(20)

            Divider()

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(artifact.fileURL.lastPathComponent)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text(metadataText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let status = model.lastOutputStatus {
                        Text(status)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Button(action: model.revealLatestRecording) {
                    Image(systemName: "folder")
                }
                .help(L10n.text("Reveal recording in Finder"))
                Button(action: model.copyLatestRecordingFile) {
                    Image(systemName: "doc.on.doc")
                }
                .help(L10n.text("Copy recording file"))
                if model.isExportingRecordingGIF {
                    ProgressView()
                        .controlSize(.small)
                    Button(role: .cancel, action: model.cancelRecordingGIFExport) {
                        Image(systemName: "xmark")
                    }
                    .help(L10n.text("Cancel GIF export"))
                } else {
                    Button(action: model.exportLatestRecordingAsGIF) {
                        Label("GIF", systemImage: "photo.stack")
                    }
                    .help(L10n.text("Export up to 30 seconds as GIF"))
                }
                Button(action: model.saveLatestRecordingAs) {
                    Label(L10n.text("Save As"), systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isExportingRecordingGIF)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
    }

    private var metadataText: String {
        let totalSeconds = max(0, Int(artifact.duration.rounded()))
        let duration = String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
        let size = "\(Int(artifact.pixelSize.width)) x \(Int(artifact.pixelSize.height))"
        var audio: [String] = []
        if artifact.capturesSystemAudio { audio.append(L10n.text("system audio")) }
        if artifact.capturesMicrophone { audio.append(L10n.text("microphone")) }
        return L10n.format("%@ | %@ px | %@", String(describing: duration), String(describing: size), String(describing: audio.isEmpty ? L10n.text("video only") : audio.joined(separator: " + ")))
    }
}

private struct RecordingPlayerView: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.player = context.coordinator.player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        context.coordinator.update(url: url)
        if view.player !== context.coordinator.player {
            view.player = context.coordinator.player
        }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) {
        coordinator.player.pause()
        view.player = nil
    }

    final class Coordinator {
        private(set) var url: URL
        private(set) var player: AVPlayer

        init(url: URL) {
            self.url = url
            player = AVPlayer(url: url)
        }

        func update(url: URL) {
            guard self.url != url else { return }
            player.pause()
            self.url = url
            player = AVPlayer(url: url)
        }
    }
}

private struct CaptureHistoryRow: View {
    let item: CaptureHistoryItem
    let isSelected: Bool
    let open: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: open) {
                HStack(spacing: 8) {
                    Group {
                        if let image = NSImage(data: item.thumbnailData) {
                            Image(nsImage: image)
                                .resizable()
                                .scaledToFill()
                        } else {
                            Image(systemName: "photo")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 52, height: 36)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.label)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                        Text(item.createdAt, style: .time)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(role: .destructive, action: delete) {
                Image(systemName: "trash")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(L10n.text("Delete history item"))
        }
        .padding(6)
        .background(
            isSelected
                ? Color.accentColor.opacity(0.16)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 5)
        )
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let isGranted: Bool
    let actionTitle: String
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
            Button(actionTitle, action: action)
                .controlSize(.small)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(isGranted ? L10n.text("allowed") : L10n.text("not allowed"))")
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
                Text(L10n.text("Global Shortcut"))
                    .font(.subheadline.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if !isReady {
                Button(L10n.text("Retry"), action: retry)
                    .controlSize(.small)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.format("Global shortcut, %@", String(describing: detail)))
    }
}
