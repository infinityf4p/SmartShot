import AppKit
import SmartShotCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @AppStorage(AppLanguage.preferenceKey) private var language = AppLanguage.english
    @StateObject private var launchAtLogin = LaunchAtLoginService()
    @State private var confirmsHistoryDeletion = false

    var body: some View {
        Form {
            Section(L10n.text("General")) {
                Picker(L10n.text("Language"), selection: $language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.title).tag(language)
                    }
                }
                .accessibilityLabel(L10n.text("Interface language"))
                .onChange(of: language) { _, selection in selection.save() }

                if language != AppLanguage.current {
                    Text(L10n.text("Restart SmartShot to apply the new language."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle(
                    L10n.text("Launch SmartShot at login"),
                    isOn: Binding(
                        get: { launchAtLogin.isEnabled },
                        set: { launchAtLogin.setEnabled($0) }
                    )
                )
                Text(L10n.text("Automatically start SmartShot when you log in to your Mac."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if launchAtLogin.requiresApproval {
                    Text(L10n.text("Allow SmartShot in System Settings > General > Login Items to enable launch at login."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(L10n.text("Open Login Items"), action: launchAtLogin.openSystemSettings)
                }

                if let errorMessage = launchAtLogin.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section(L10n.text("Capture Shortcut")) {
                LabeledContent(L10n.text("Global shortcut")) {
                    HStack(spacing: 8) {
                        ShortcutRecorder(
                            shortcut: model.configuredShortcut,
                            onBeginRecording: model.beginShortcutRecording,
                            onEndRecording: model.endShortcutRecording,
                            onCommit: model.applyShortcut
                        )
                        .frame(width: 150)

                        Button(L10n.text("Restore Default"), action: model.restoreDefaultShortcut)
                    }
                    .accessibilityElement(children: .contain)
                }

                Text(L10n.text("Click the shortcut field, then press a key with at least two modifiers."))
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

            Section(L10n.text("After Capture")) {
                Picker(L10n.text("Capture delay"), selection: $model.captureDelaySeconds) {
                    Text(L10n.text("Off")).tag(0)
                    Text(L10n.text("3 seconds")).tag(3)
                    Text(L10n.text("5 seconds")).tag(5)
                }
                .pickerStyle(.segmented)

                Toggle(L10n.text("Copy screenshot to the clipboard"), isOn: $model.automaticallyCopiesCaptures)
                Toggle(L10n.text("Show SmartShot after captures started elsewhere"), isOn: $model.showsPreviewAfterExternalCapture)
                Toggle(L10n.text("Private captures skip history and automatic copy"), isOn: $model.usesPrivateCaptureMode)
                Text(L10n.text("Keep preview off to stay in the current app or full-screen Space after a shortcut capture."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.text("History")) {
                Toggle(L10n.text("Save captures to local history"), isOn: $model.savesCaptureHistory)
                Toggle(
                    L10n.text("Index text recognized with OCR"),
                    isOn: $model.indexesRecognizedTextInHistory
                )
                Text(L10n.text("Off by default. Text is indexed only after you run OCR. Turning this off removes stored OCR indexes. Private captures are never indexed."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker(L10n.text("Keep"), selection: $model.captureHistoryLimit) {
                    Text(L10n.text("10 captures")).tag(10)
                    Text(L10n.text("25 captures")).tag(25)
                    Text(L10n.text("50 captures")).tag(50)
                    Text(L10n.text("100 captures")).tag(100)
                    Text(L10n.text("250 captures")).tag(250)
                }
                Button(L10n.text("Clear History..."), role: .destructive) {
                    confirmsHistoryDeletion = true
                }
                .disabled(!model.hasCaptureHistory)
            }

            Section(L10n.text("Output")) {
                Picker(L10n.text("Format"), selection: $model.outputFormat) {
                    ForEach(CaptureOutputFormat.allCases) { format in
                        Text(format.title).tag(format)
                    }
                }
                .pickerStyle(.segmented)

                Picker(L10n.text("Filename"), selection: $model.filenameStyle) {
                    ForEach(CaptureFilenameStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }

                LabeledContent(L10n.text("Quick Save folder")) {
                    HStack(spacing: 8) {
                        Text(model.defaultSaveDirectoryDisplayName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 240, alignment: .trailing)
                        Button(L10n.text("Choose..."), action: model.chooseDefaultSaveDirectory)
                    }
                }
            }

            Section(L10n.text("Screen Recording")) {
                Toggle(L10n.text("Capture system audio"), isOn: $model.recordingCapturesSystemAudio)
                Toggle(L10n.text("Capture microphone"), isOn: $model.recordingCapturesMicrophone)
                Toggle(L10n.text("Show pointer"), isOn: $model.recordingShowsCursor)

                Picker(L10n.text("Frame rate"), selection: $model.recordingFrameRate) {
                    Text(L10n.text("15 fps")).tag(15)
                    Text(L10n.text("30 fps")).tag(30)
                    Text(L10n.text("60 fps")).tag(60)
                }
                .pickerStyle(.segmented)

                Picker(L10n.text("Maximum edge"), selection: $model.recordingMaximumLongEdge) {
                    Text(L10n.text("1920 px")).tag(1_920)
                    Text(L10n.text("2560 px")).tag(2_560)
                    Text(L10n.text("3840 px")).tag(3_840)
                }
                .pickerStyle(.segmented)

                Text(L10n.text("Recordings are saved as H.264/AAC MP4 files in the Quick Save folder. GIF export is limited to 30 seconds, 15 fps, and 1280 px."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.text("Browser Integration")) {
                LabeledContent(L10n.text("Safari extension")) {
                    HStack(spacing: 8) {
                        Button(
                            L10n.text("Open Safari Settings"),
                            action: model.openSafariExtensionPreferences
                        )
                        .accessibilityLabel(L10n.text("Open SmartShot Safari extension settings"))
                        .disabled(model.safariExtensionIsBusy)
                        Button(action: model.refreshSafariExtensionStatus) {
                            Label(L10n.text("Refresh"), systemImage: "arrow.clockwise")
                        }
                        .accessibilityLabel(L10n.text("Refresh Safari extension status"))
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

                LabeledContent(L10n.text("Chromium connector")) {
                    HStack(spacing: 8) {
                        Button(L10n.text("Install"), action: model.installChromiumIntegration)
                            .accessibilityLabel(L10n.text("Install Chromium connector"))
                            .disabled(model.chromiumIntegrationIsBusy || model.chromiumIntegrationIsReady)
                        Button(L10n.text("Reveal Extension"), action: model.revealChromiumExtension)
                            .accessibilityLabel(L10n.text("Reveal SmartShot browser extension"))
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

            Section(L10n.text("Permissions")) {
                LabeledContent(L10n.text("Screen Recording")) {
                    Button(L10n.text("Open Settings"), action: model.permissions.openScreenCaptureSettings)
                }
                LabeledContent(L10n.text("Accessibility")) {
                    Button(L10n.text("Open Settings"), action: model.permissions.openAccessibilitySettings)
                }
                LabeledContent(L10n.text("Microphone")) {
                    HStack(spacing: 8) {
                        Label(
                            model.permissions.hasMicrophoneAccess ? L10n.text("Allowed") : L10n.text("Not allowed"),
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
            L10n.text("Delete all screenshot history?"),
            isPresented: $confirmsHistoryDeletion
        ) {
            Button(L10n.text("Delete All History"), role: .destructive, action: model.clearCaptureHistory)
        } message: {
            Text(L10n.text("This removes SmartShot's local history files. This cannot be undone."))
        }
    }
}
