import AppKit
import SmartShotCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @StateObject private var launchAtLogin = LaunchAtLoginService()
    @State private var confirmsHistoryDeletion = false

    var body: some View {
        Form {
            Section("General") {
                Toggle(
                    "Launch SmartShot at login",
                    isOn: Binding(
                        get: { launchAtLogin.isEnabled },
                        set: { launchAtLogin.setEnabled($0) }
                    )
                )
                Text("Automatically start SmartShot when you log in to your Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if launchAtLogin.requiresApproval {
                    Text("Allow SmartShot in System Settings > General > Login Items to enable launch at login.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Login Items", action: launchAtLogin.openSystemSettings)
                }

                if launchAtLogin.isUnavailable {
                    Text("Launch at login is unavailable. Move SmartShot to Applications and reopen it, then try again.")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let errorMessage = launchAtLogin.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Capture Shortcut") {
                LabeledContent("Global shortcut") {
                    HStack(spacing: 8) {
                        ShortcutRecorder(
                            shortcut: model.configuredShortcut,
                            onBeginRecording: model.beginShortcutRecording,
                            onEndRecording: model.endShortcutRecording,
                            onCommit: model.applyShortcut
                        )
                        .frame(width: 150)

                        Button("Restore Default", action: model.restoreDefaultShortcut)
                    }
                    .accessibilityElement(children: .contain)
                }

                Text("Click the shortcut field, then press a key with at least two modifiers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let feedback = model.shortcutFeedback {
                    Label(
                        feedback,
                        systemImage: model.shortcutFeedbackIsError
                            ? "exclamationmark.triangle.fill"
                            : "checkmark.circle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(model.shortcutFeedbackIsError ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("After Capture") {
                Picker("Capture delay", selection: $model.captureDelaySeconds) {
                    Text("Off").tag(0)
                    Text("3 seconds").tag(3)
                    Text("5 seconds").tag(5)
                }
                .pickerStyle(.segmented)

                Toggle("Copy screenshot to the clipboard", isOn: $model.automaticallyCopiesCaptures)
                Toggle("Show SmartShot after captures started elsewhere", isOn: $model.showsPreviewAfterExternalCapture)
                Toggle("Private captures skip history and automatic copy", isOn: $model.usesPrivateCaptureMode)
                Text("Keep preview off to stay in the current app or full-screen Space after a shortcut capture.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("History") {
                Toggle("Save captures to local history", isOn: $model.savesCaptureHistory)
                Toggle(
                    "Index text recognized with OCR",
                    isOn: $model.indexesRecognizedTextInHistory
                )
                Text("Off by default. Text is indexed only after you run OCR. Turning this off removes stored OCR indexes. Private captures are never indexed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Keep", selection: $model.captureHistoryLimit) {
                    Text("10 captures").tag(10)
                    Text("25 captures").tag(25)
                    Text("50 captures").tag(50)
                    Text("100 captures").tag(100)
                    Text("250 captures").tag(250)
                }
                Button("Clear History...", role: .destructive) {
                    confirmsHistoryDeletion = true
                }
                .disabled(!model.hasCaptureHistory)
            }

            Section("Output") {
                Picker("Format", selection: $model.outputFormat) {
                    ForEach(CaptureOutputFormat.allCases) { format in
                        Text(format.title).tag(format)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Filename", selection: $model.filenameStyle) {
                    ForEach(CaptureFilenameStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }

                LabeledContent("Quick Save folder") {
                    HStack(spacing: 8) {
                        Text(model.defaultSaveDirectoryDisplayName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 240, alignment: .trailing)
                        Button("Choose...", action: model.chooseDefaultSaveDirectory)
                    }
                }
            }

            Section("Screen Recording") {
                Toggle("Capture system audio", isOn: $model.recordingCapturesSystemAudio)
                Toggle("Capture microphone", isOn: $model.recordingCapturesMicrophone)
                Toggle("Show pointer", isOn: $model.recordingShowsCursor)

                Picker("Frame rate", selection: $model.recordingFrameRate) {
                    Text("15 fps").tag(15)
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                .pickerStyle(.segmented)

                Picker("Maximum edge", selection: $model.recordingMaximumLongEdge) {
                    Text("1920 px").tag(1_920)
                    Text("2560 px").tag(2_560)
                    Text("3840 px").tag(3_840)
                }
                .pickerStyle(.segmented)

                Text("Recordings are saved as H.264/AAC MP4 files in the Quick Save folder. GIF export is limited to 30 seconds, 15 fps, and 1280 px.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Browser Integration") {
                LabeledContent("Safari extension") {
                    HStack(spacing: 8) {
                        Button(
                            "Open Safari Settings",
                            action: model.openSafariExtensionPreferences
                        )
                        .accessibilityLabel("Open SmartShot Safari extension settings")
                        .disabled(model.safariExtensionIsBusy)
                        Button(action: model.refreshSafariExtensionStatus) {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .accessibilityLabel("Refresh Safari extension status")
                        .disabled(model.safariExtensionIsBusy)
                    }
                    .accessibilityElement(children: .contain)
                }
                Label(
                    model.safariExtensionStatus.message,
                    systemImage: model.safariExtensionStatus.isEnabled
                        ? "checkmark.circle.fill"
                        : model.safariExtensionStatus.hasError
                            ? "exclamationmark.triangle.fill"
                            : "info.circle"
                )
                .font(.caption)
                .foregroundStyle(
                    model.safariExtensionStatus.hasError ? .red : .secondary
                )
                .fixedSize(horizontal: false, vertical: true)

                LabeledContent("Chromium connector") {
                    HStack(spacing: 8) {
                        Button("Install", action: model.installChromiumIntegration)
                            .accessibilityLabel("Install Chromium connector")
                            .disabled(model.chromiumIntegrationIsBusy || model.chromiumIntegrationIsReady)
                        Button("Reveal Extension", action: model.revealChromiumExtension)
                            .accessibilityLabel("Reveal SmartShot browser extension")
                    }
                    .accessibilityElement(children: .contain)
                }
                Label(
                    model.chromiumIntegrationStatus,
                    systemImage: model.chromiumIntegrationIsReady
                        ? "checkmark.circle.fill"
                        : model.chromiumIntegrationHasError
                            ? "exclamationmark.triangle.fill"
                            : "info.circle"
                )
                .font(.caption)
                .foregroundStyle(
                    model.chromiumIntegrationHasError ? .red : .secondary
                )
                .fixedSize(horizontal: false, vertical: true)
            }

            Section("Permissions") {
                LabeledContent("Screen Recording") {
                    Button("Open Settings", action: model.permissions.openScreenCaptureSettings)
                }
                LabeledContent("Accessibility") {
                    Button("Open Settings", action: model.permissions.openAccessibilitySettings)
                }
                LabeledContent("Microphone") {
                    HStack(spacing: 8) {
                        Label(
                            model.permissions.hasMicrophoneAccess ? "Allowed" : "Not allowed",
                            systemImage: model.permissions.hasMicrophoneAccess
                                ? "checkmark.circle.fill"
                                : "circle"
                        )
                        .foregroundStyle(.secondary)
                        Button(model.permissions.microphoneActionTitle) {
                            model.permissions.requestMicrophone()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 600, height: 820)
        .onAppear {
            launchAtLogin.refreshStatus()
            model.refreshSafariExtensionStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchAtLogin.refreshStatus()
        }
        .onDisappear {
            model.endShortcutRecording()
        }
        .confirmationDialog(
            "Delete all screenshot history?",
            isPresented: $confirmsHistoryDeletion
        ) {
            Button("Delete All History", role: .destructive, action: model.clearCaptureHistory)
        } message: {
            Text("This removes SmartShot's local history files. This cannot be undone.")
        }
    }
}
