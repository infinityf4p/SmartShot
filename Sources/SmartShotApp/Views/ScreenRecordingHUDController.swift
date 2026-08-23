import AppKit

@MainActor
final class ScreenRecordingHUDController {
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?

    private var panel: NSPanel?
    private weak var durationLabel: NSTextField?
    private var timer: Timer?
    private var startedAt: Date?

    func show(relativeTo recordingRect: CGRect) {
        hide()

        let size = CGSize(width: 188, height: 46)
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .canJoinAllApplications,
            .fullScreenAuxiliary,
            .transient,
            .ignoresCycle,
        ]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.setAccessibilityLabel("Screen recording controls")

        let effect = NSVisualEffectView(frame: CGRect(origin: .zero, size: size))
        effect.autoresizingMask = [.width, .height]
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 7
        effect.layer?.masksToBounds = true
        panel.contentView = effect

        let indicator = NSView()
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.wantsLayer = true
        indicator.layer?.backgroundColor = NSColor.systemRed.cgColor
        indicator.layer?.cornerRadius = 4
        indicator.setAccessibilityElement(false)

        let duration = NSTextField(labelWithString: "00:00")
        duration.translatesAutoresizingMaskIntoConstraints = false
        duration.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        duration.alignment = .left
        duration.setAccessibilityLabel("Recording duration")
        duration.setAccessibilityValue("0 seconds")

        let stop = symbolButton(
            symbol: "stop.fill",
            accessibilityLabel: "Stop recording",
            toolTip: "Stop and save recording",
            action: #selector(stopRecording)
        )
        let cancel = symbolButton(
            symbol: "xmark",
            accessibilityLabel: "Cancel recording",
            toolTip: "Cancel and discard recording",
            action: #selector(cancelRecording)
        )

        let controls = NSStackView(views: [indicator, duration, stop, cancel])
        controls.translatesAutoresizingMaskIntoConstraints = false
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 10
        controls.setCustomSpacing(14, after: duration)
        effect.addSubview(controls)

        NSLayoutConstraint.activate([
            indicator.widthAnchor.constraint(equalToConstant: 8),
            indicator.heightAnchor.constraint(equalToConstant: 8),
            duration.widthAnchor.constraint(equalToConstant: 48),
            stop.widthAnchor.constraint(equalToConstant: 30),
            stop.heightAnchor.constraint(equalToConstant: 28),
            cancel.widthAnchor.constraint(equalToConstant: 30),
            cancel.heightAnchor.constraint(equalToConstant: 28),
            controls.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 14),
            controls.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -10),
            controls.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
        ])

        let screen = NSScreen.screens.first { $0.frame.contains(recordingRect.center) }
        let visibleFrame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let desiredOrigin = CGPoint(
            x: min(max(recordingRect.midX - size.width / 2, visibleFrame.minX + 8),
                   visibleFrame.maxX - size.width - 8),
            y: min(recordingRect.maxY + 12, visibleFrame.maxY - size.height - 8)
        )
        panel.setFrameOrigin(desiredOrigin)
        panel.orderFrontRegardless()

        self.panel = panel
        durationLabel = duration
        startedAt = Date()
        updateDuration()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateDuration() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        startedAt = nil
        panel?.orderOut(nil)
        panel = nil
        durationLabel = nil
    }

    private func symbolButton(
        symbol: String,
        accessibilityLabel: String,
        toolTip: String,
        action: Selector
    ) -> NSButton {
        let image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: accessibilityLabel
        ) ?? NSImage()
        let button = NSButton(image: image, target: self, action: action)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .texturedRounded
        button.imagePosition = .imageOnly
        button.toolTip = toolTip
        button.setAccessibilityLabel(accessibilityLabel)
        return button
    }

    private func updateDuration() {
        guard let startedAt else { return }
        let elapsed = max(0, Int(Date().timeIntervalSince(startedAt)))
        let minutes = elapsed / 60
        let seconds = elapsed % 60
        durationLabel?.stringValue = String(format: "%02d:%02d", minutes, seconds)
        durationLabel?.setAccessibilityValue("\(elapsed) seconds")
    }

    @objc private func stopRecording() {
        onStop?()
    }

    @objc private func cancelRecording() {
        onCancel?()
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
