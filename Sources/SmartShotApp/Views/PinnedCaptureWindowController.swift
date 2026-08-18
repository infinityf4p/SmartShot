import AppKit

@MainActor
final class PinnedCaptureWindowController: NSObject, NSWindowDelegate {
    let id = UUID()
    var onClose: ((UUID) -> Void)?

    private let capture: CapturedImage
    private var panel: NSPanel?

    init(capture: CapturedImage) {
        self.capture = capture
        super.init()
    }

    func show() {
        if let panel {
            panel.orderFrontRegardless()
            return
        }

        let imageSize = capture.image.size
        let viewportWidth = min(max(220, imageSize.width), 560)
        let viewportHeight = min(max(160, imageSize.height), 460)
        let panel = PinnedCapturePanel(
            contentRect: CGRect(x: 0, y: 0, width: viewportWidth, height: viewportHeight),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = capture.label
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.minSize = CGSize(width: 180, height: 120)
        panel.delegate = self
        panel.setAccessibilityLabel("Pinned screenshot")

        let scrollView = NSScrollView(frame: panel.contentView?.bounds ?? .zero)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .black
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let displayWidth = max(viewportWidth, min(imageSize.width, 900))
        let scale = imageSize.width > 0 ? displayWidth / imageSize.width : 1
        let documentSize = CGSize(
            width: max(viewportWidth, imageSize.width * scale),
            height: max(viewportHeight, imageSize.height * scale)
        )
        let imageView = NSImageView(frame: CGRect(origin: .zero, size: documentSize))
        imageView.image = capture.image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.setAccessibilityLabel("Pinned screenshot image")
        scrollView.documentView = imageView
        scrollView.contentView.scroll(
            to: CGPoint(x: 0, y: max(0, documentSize.height - viewportHeight))
        )
        scrollView.reflectScrolledClipView(scrollView.contentView)
        panel.contentView = scrollView

        panel.center()
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func windowWillClose(_ notification: Notification) {
        panel = nil
        onClose?(id)
    }
}

private final class PinnedCapturePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
