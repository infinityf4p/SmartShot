import SmartShotCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
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
                Text("Keep the second option off to stay in the current app or full-screen Space after a shortcut capture.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Permissions") {
                LabeledContent("Screen Recording") {
                    Button("Open Settings", action: model.permissions.openScreenCaptureSettings)
                }
                LabeledContent("Accessibility") {
                    Button("Open Settings", action: model.permissions.openAccessibilitySettings)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 390)
        .onDisappear {
            model.endShortcutRecording()
        }
    }
}
