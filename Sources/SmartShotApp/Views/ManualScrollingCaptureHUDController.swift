import AppKit

@MainActor
final class ManualScrollingCaptureHUDController: NSObject {
    var onFinish: (() -> Void)?
    var onCancel: (() -> Void)?

    private var panel: ManualScrollingCapturePanel?
    private weak var titleLabel: NSTextField?
    private weak var detailLabel: NSTextField?
    private weak var activityIndicator: NSProgressIndicator?
    private weak var doneButton: NSButton?

    func show(relativeTo captureRect: CGRect) {
        hide()

        let panel = ManualScrollingCapturePanel(
            contentRect: CGRect(x: 0, y: 0, width: 360, height: 104),
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
            .ignoresCycle
        ]
        panel.isMovableByWindowBackground = true
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.setAccessibilityLabel("Manual long capture controls")

        let visualEffect = NSVisualEffectView(frame: panel.contentView?.bounds ?? .zero)
        visualEffect.autoresizingMask = [.width, .height]
        visualEffect.material = .hudWindow
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 8
        visualEffect.layer?.masksToBounds = true
        panel.contentView = visualEffect

        let indicator = NSProgressIndicator()
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.style = .spinning
        indicator.controlSize = .small
        indicator.startAnimation(nil)
        visualEffect.addSubview(indicator)

        let title = NSTextField(labelWithString: "Preparing long capture")
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        visualEffect.addSubview(title)

        let detail = NSTextField(labelWithString: "Hold the region still")
        detail.translatesAutoresizingMaskIntoConstraints = false
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        visualEffect.addSubview(detail)

        let done = NSButton(title: "Done", target: self, action: #selector(finishCapture))
        done.translatesAutoresizingMaskIntoConstraints = false
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        done.isEnabled = false
        done.setAccessibilityHelp("Finish and stitch the captured sections")
        visualEffect.addSubview(done)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelCapture))
        cancel.translatesAutoresizingMaskIntoConstraints = false
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        cancel.setAccessibilityHelp("Cancel manual long capture")
        visualEffect.addSubview(cancel)

        NSLayoutConstraint.activate([
            indicator.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor, constant: 16),
            indicator.topAnchor.constraint(equalTo: visualEffect.topAnchor, constant: 18),
            title.leadingAnchor.constraint(equalTo: indicator.trailingAnchor, constant: 10),
            title.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor, constant: -16),
            title.centerYAnchor.constraint(equalTo: indicator.centerYAnchor),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3),
            cancel.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor, constant: -12),
            cancel.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor, constant: -11),
            cancel.widthAnchor.constraint(equalToConstant: 74),
            done.trailingAnchor.constraint(equalTo: cancel.leadingAnchor, constant: -8),
            done.bottomAnchor.constraint(equalTo: cancel.bottomAnchor),
            done.widthAnchor.constraint(equalToConstant: 74)
        ])

        panel.setFrameOrigin(origin(for: panel.frame.size, relativeTo: captureRect))
        panel.orderFrontRegardless()

        self.panel = panel
        titleLabel = title
        detailLabel = detail
        activityIndicator = indicator
        doneButton = done
    }

    func update(_ progress: ManualScrollingCaptureProgress) {
        switch progress.phase {
        case .preparing:
            titleLabel?.stringValue = "Preparing long capture"
            detailLabel?.stringValue = detail("Hold the region still", progress: progress)
            activityIndicator?.startAnimation(nil)
            doneButton?.isEnabled = false
        case .ready:
            titleLabel?.stringValue = "Long capture ready"
            detailLabel?.stringValue = detail("Scroll down and pause", progress: progress)
            activityIndicator?.stopAnimation(nil)
            doneButton?.isEnabled = false
        case .capturing:
            titleLabel?.stringValue = "\(progress.fragmentCount) sections captured"
            detailLabel?.stringValue = detail(
                "\(Int(progress.logicalHeight)) points - continue or finish",
                progress: progress
            )
            activityIndicator?.stopAnimation(nil)
            doneButton?.isEnabled = progress.fragmentCount > 1
        case .stitching:
            titleLabel?.stringValue = "Stitching \(progress.fragmentCount) sections"
            detailLabel?.stringValue = "Checking the final image"
            activityIndicator?.startAnimation(nil)
            doneButton?.isEnabled = false
        }
        panel?.setAccessibilityValue(titleLabel?.stringValue)
    }

    private func detail(
        _ message: String,
        progress: ManualScrollingCaptureProgress
    ) -> String {
        guard let remaining = progress.remainingTimeText else { return message }
        if let seconds = progress.secondsRemaining, seconds <= 30 {
            return "Finish soon - \(remaining)"
        }
        return "\(message) - \(remaining)"
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        titleLabel = nil
        detailLabel = nil
        activityIndicator = nil
        doneButton = nil
    }

    @objc private func finishCapture() {
        doneButton?.isEnabled = false
        activityIndicator?.startAnimation(nil)
        detailLabel?.stringValue = "Finishing the current section"
        onFinish?()
    }

    @objc private func cancelCapture() {
        onCancel?()
    }

    private func origin(for panelSize: CGSize, relativeTo captureRect: CGRect) -> CGPoint {
        let center = CGPoint(x: captureRect.midX, y: captureRect.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSScreen.screens.map(\.visibleFrame).reduce(.zero) { $0.union($1) }
        let margin: CGFloat = 12
        let proposedX = captureRect.midX - panelSize.width / 2
        let x = min(max(visible.minX + margin, proposedX), visible.maxX - panelSize.width - margin)

        if captureRect.minY - panelSize.height - margin >= visible.minY {
            return CGPoint(x: x, y: captureRect.minY - panelSize.height - margin)
        }
        if captureRect.maxY + panelSize.height + margin <= visible.maxY {
            return CGPoint(x: x, y: captureRect.maxY + margin)
        }
        return CGPoint(
            x: visible.maxX - panelSize.width - margin,
            y: visible.maxY - panelSize.height - margin
        )
    }
}

private final class ManualScrollingCapturePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
