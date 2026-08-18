import AppKit

@MainActor
final class CaptureCountdownHUDController {
    private var panel: NSPanel?
    private weak var valueLabel: NSTextField?

    func show(seconds: Int, relativeTo captureRect: CGRect) {
        hide()
        let size = CGSize(width: 88, height: 88)
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .canJoinAllApplications,
            .fullScreenAuxiliary,
            .transient,
            .ignoresCycle
        ]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false

        let effect = NSVisualEffectView(frame: CGRect(origin: .zero, size: size))
        effect.autoresizingMask = [.width, .height]
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 8
        effect.layer?.masksToBounds = true
        panel.contentView = effect

        let label = NSTextField(labelWithString: "\(seconds)")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedDigitSystemFont(ofSize: 42, weight: .semibold)
        label.textColor = .labelColor
        label.alignment = .center
        label.setAccessibilityLabel("Capture countdown")
        label.setAccessibilityValue("\(seconds) seconds")
        effect.addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: effect.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: effect.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(lessThanOrEqualTo: effect.trailingAnchor, constant: -8)
        ])

        let screen = screen(containing: captureRect)
        let visible = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        panel.setFrameOrigin(
            CGPoint(
                x: visible.midX - size.width / 2,
                y: visible.maxY - size.height - 32
            )
        )
        panel.orderFrontRegardless()
        self.panel = panel
        valueLabel = label
    }

    func update(seconds: Int) {
        valueLabel?.stringValue = "\(seconds)"
        valueLabel?.setAccessibilityValue("\(seconds) seconds")
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        valueLabel = nil
    }

    private func screen(containing rect: CGRect) -> NSScreen? {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        return NSScreen.screens.first { $0.frame.contains(center) }
    }
}
