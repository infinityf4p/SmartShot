import AppKit
import AVKit
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
                if model.isScreenRecordingWorkflow, model.state == .capturing {
                    if model.isFinalizingScreenRecording {
                        ProgressView()
                            .controlSize(.small)
                        Text("Finalizing")
                            .foregroundStyle(.secondary)
                    } else {
                        Button(action: model.stopScreenRecording) {
                            Label("Stop", systemImage: "stop.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canStopScreenRecording)
                        Button(role: .cancel, action: model.cancelScreenRecording) {
                            Label("Cancel", systemImage: "xmark.circle")
                        }
                    }
                } else if model.isScrollingCapture, model.state == .capturing {
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
                    .help("Choose Smart, Region, Long, or App Scroll (\(model.shortcutDisplayName))")

                    Menu {
                        Button {
                            model.startRegionRecording(origin: .mainWindow)
                        } label: {
                            Label("Record Region", systemImage: "record.circle")
                        }
                        Button {
                            model.startDisplayRecording(origin: .mainWindow)
                        } label: {
                            Label("Record Current Display", systemImage: "display")
                        }
                        Divider()
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
        .alert("SmartShot couldn't complete the action", isPresented: errorBinding) {
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
                Text("Smart capture, long capture, and recording")
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
                    actionTitle: model.permissions.screenCaptureActionTitle,
                    action: model.permissions.hasScreenCaptureAccess
                        ? model.permissions.openScreenCaptureSettings
                        : model.permissions.requestScreenCapture
                )

                PermissionRow(
                    title: "Accessibility",
                    detail: "Improves content block detection",
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
                    Text("HISTORY")
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

                TextField("Search history", text: $model.captureHistoryQuery)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search screenshot history")

                if !model.hasCaptureHistory {
                    ContentUnavailableView(
                        "No History",
                        systemImage: "clock.arrow.circlepath"
                    )
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.captureHistoryItems.isEmpty {
                    ContentUnavailableView(
                        "No Results",
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
                            if let status = model.lastOutputStatus {
                                Text(status)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        if let editor = model.captureEditor, editor.hasEdits {
                            Button(action: model.flattenLatestEdits) {
                                Label("Flatten", systemImage: "square.stack.3d.down.forward")
                            }
                            .help("Replace the original and history copy with the rendered edits")
                        }
                        Button(action: model.pinLatest) {
                            Label("Pin", systemImage: "pin")
                        }
                        .help("Keep the screenshot above other windows")
                        Button(action: model.copyLatest) {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        .help("Copy the screenshot")
                        Button(action: model.quickSaveLatest) {
                            Image(systemName: "bolt")
                        }
                        .help("Quick Save")
                        Button(action: model.saveLatest) {
                            Label("Save", systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(.borderedProminent)
                        .help("Save with options")
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
                    HStack(spacing: 8) {
                        Button {
                            model.startCapture(origin: .mainWindow)
                        } label: {
                            Label("Capture", systemImage: "viewfinder")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isBusy)
                        Button {
                            model.startRegionRecording(origin: .mainWindow)
                        } label: {
                            Label("Record", systemImage: "record.circle")
                        }
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
            if model.isScreenRecordingWorkflow {
                model.recordingStatusText ?? "Recording screen"
            } else if let progress = model.manualScrollingCaptureProgress {
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

private struct RecordingResultView: View {
    let artifact: RecordingArtifact
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                RecordingPlayerView(url: artifact.fileURL)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .background(Color.black)
                    .accessibilityLabel("Latest screen recording preview")
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
                .help("Reveal recording in Finder")
                Button(action: model.copyLatestRecordingFile) {
                    Image(systemName: "doc.on.doc")
                }
                .help("Copy recording file")
                if model.isExportingRecordingGIF {
                    ProgressView()
                        .controlSize(.small)
                    Button(role: .cancel, action: model.cancelRecordingGIFExport) {
                        Image(systemName: "xmark")
                    }
                    .help("Cancel GIF export")
                } else {
                    Button(action: model.exportLatestRecordingAsGIF) {
                        Label("GIF", systemImage: "photo.stack")
                    }
                    .help("Export up to 30 seconds as GIF")
                }
                Button(action: model.saveLatestRecordingAs) {
                    Label("Save As", systemImage: "square.and.arrow.down")
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
        if artifact.capturesSystemAudio { audio.append("system audio") }
        if artifact.capturesMicrophone { audio.append("microphone") }
        return "\(duration) | \(size) px | \(audio.isEmpty ? "video only" : audio.joined(separator: " + "))"
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
            .help("Delete history item")
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
