import AppKit
import SmartShotCore

enum SelectionOverlayStatus: Equatable {
    case regionSelection
    case manualLongSelection
    case searchingForScrollArea
    case scrollAreaReady
    case checkingScrollArea
    case unsupportedScrollArea

    var message: String {
        switch self {
        case .regionSelection:
            "Region capture"
        case .manualLongSelection:
            "Long capture region"
        case .searchingForScrollArea:
            "Looking for a supported scroll area..."
        case .scrollAreaReady:
            "Click the highlighted scroll area"
        case .checkingScrollArea:
            "Checking the scroll area..."
        case .unsupportedScrollArea:
            "No app scroll area here. Web pages use the SmartShot extension."
        }
    }

    var cursor: NSCursor {
        switch self {
        case .regionSelection, .manualLongSelection:
            .crosshair
        case .scrollAreaReady:
            .pointingHand
        case .unsupportedScrollArea:
            .operationNotAllowed
        case .searchingForScrollArea, .checkingScrollArea:
            .crosshair
        }
    }
}

@MainActor
protocol SelectionOverlayViewDelegate: AnyObject {
    func overlay(_ overlay: SelectionOverlayView, pointerMovedTo globalPoint: CGPoint)
    func overlay(_ overlay: SelectionOverlayView, didFinishAt globalPoint: CGPoint, manualRect: CGRect?)
    func overlayDidCancel(_ overlay: SelectionOverlayView)
    func overlay(_ overlay: SelectionOverlayView, cycleBy delta: Int)
    func overlay(_ overlay: SelectionOverlayView, didChoose mode: CaptureSelectionMode)
}

@MainActor
final class SelectionOverlayView: NSView {
    weak var delegate: SelectionOverlayViewDelegate?
    var candidate: CaptureCandidate? { didSet { needsDisplay = true } }
    var manualRect: CGRect? { didSet { needsDisplay = true } }
    var screenFrame: CGRect = .zero
    var allowsManualSelection = true
    var captureMode: CaptureSelectionMode = .smart {
        didSet { updateModeButtons() }
    }
    var showsModeToolbar = true {
        didSet { modeToolbar.isHidden = !showsModeToolbar }
    }
    var status: SelectionOverlayStatus? {
        didSet {
            needsDisplay = true
            setAccessibilityValue(status?.message)
            window?.invalidateCursorRects(for: self)
        }
    }

    private var mouseDownPoint: CGPoint?
    private var trackingAreaReference: NSTrackingArea?
    private let modeToolbar = NSVisualEffectView()
    private var modeButtons: [NSButton] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureModeToolbar()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureModeToolbar()
    }

    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: status?.cursor ?? .crosshair)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingAreaReference = area
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.black.withAlphaComponent(0.34).setFill()
        bounds.fill()

        if let selection = localSelectionRect, !selection.isEmpty {
            NSGraphicsContext.current?.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .clear
            selection.fill()
            NSGraphicsContext.current?.restoreGraphicsState()

            let outline = NSBezierPath(
                roundedRect: selection.insetBy(dx: 1, dy: 1),
                xRadius: 5,
                yRadius: 5
            )
            outline.lineWidth = 2
            NSColor.controlAccentColor.setStroke()
            outline.stroke()

            drawBadge(for: selection)
        }

        if let status { drawStatus(status) }
    }

    private func configureModeToolbar() {
        modeToolbar.translatesAutoresizingMaskIntoConstraints = false
        modeToolbar.material = .hudWindow
        modeToolbar.blendingMode = .withinWindow
        modeToolbar.state = .active
        modeToolbar.wantsLayer = true
        modeToolbar.layer?.cornerRadius = 7
        modeToolbar.layer?.masksToBounds = true
        addSubview(modeToolbar)

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.distribution = .fillEqually
        modeToolbar.addSubview(stack)

        modeButtons = CaptureSelectionMode.allCases.map { mode in
            let button = NSButton(
                title: mode.title,
                image: NSImage(systemSymbolName: mode.systemImage, accessibilityDescription: nil) ?? NSImage(),
                target: self,
                action: #selector(chooseMode(_:))
            )
            button.tag = CaptureSelectionMode.allCases.firstIndex(of: mode) ?? 0
            button.bezelStyle = .texturedRounded
            button.setButtonType(.toggle)
            button.imagePosition = .imageLeading
            button.font = .systemFont(ofSize: 12, weight: .medium)
            button.focusRingType = .none
            button.toolTip = mode.accessibilityHelp
            button.setAccessibilityLabel("\(mode.title) capture")
            button.setAccessibilityHelp(mode.accessibilityHelp)
            stack.addArrangedSubview(button)
            return button
        }

        NSLayoutConstraint.activate([
            modeToolbar.centerXAnchor.constraint(equalTo: centerXAnchor),
            modeToolbar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -22),
            modeToolbar.widthAnchor.constraint(equalToConstant: 336),
            modeToolbar.heightAnchor.constraint(equalToConstant: 50),
            stack.leadingAnchor.constraint(equalTo: modeToolbar.leadingAnchor, constant: 7),
            stack.trailingAnchor.constraint(equalTo: modeToolbar.trailingAnchor, constant: -7),
            stack.topAnchor.constraint(equalTo: modeToolbar.topAnchor, constant: 7),
            stack.bottomAnchor.constraint(equalTo: modeToolbar.bottomAnchor, constant: -7)
        ])
        updateModeButtons()
    }

    @objc private func chooseMode(_ sender: NSButton) {
        guard CaptureSelectionMode.allCases.indices.contains(sender.tag) else { return }
        delegate?.overlay(self, didChoose: CaptureSelectionMode.allCases[sender.tag])
    }

    private func updateModeButtons() {
        for (index, button) in modeButtons.enumerated() {
            guard CaptureSelectionMode.allCases.indices.contains(index) else { continue }
            let isSelected = CaptureSelectionMode.allCases[index] == captureMode
            button.state = isSelected ? .on : .off
            button.contentTintColor = isSelected ? .controlAccentColor : .labelColor
        }
        setAccessibilityValue("\(captureMode.title) capture")
    }

    override func mouseMoved(with event: NSEvent) {
        delegate?.overlay(self, pointerMovedTo: globalPoint(for: event))
    }

    override func mouseDown(with event: NSEvent) {
        guard allowsManualSelection else { return }
        let point = globalPoint(for: event)
        mouseDownPoint = point
        manualRect = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard allowsManualSelection else { return }
        guard let start = mouseDownPoint else { return }
        let current = globalPoint(for: event)
        let dragRect = CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(start.x - current.x),
            height: abs(start.y - current.y)
        )
        manualRect = dragRect.intersection(screenFrame)
    }

    override func mouseUp(with event: NSEvent) {
        let point = globalPoint(for: event)
        let manual = allowsManualSelection
            ? manualRect.flatMap { $0.width >= 6 && $0.height >= 6 ? $0 : nil }
            : nil
        delegate?.overlay(self, didFinishAt: point, manualRect: manual)
        mouseDownPoint = nil
        manualRect = nil
    }

    override func scrollWheel(with event: NSEvent) {
        delegate?.overlay(self, cycleBy: event.scrollingDeltaY < 0 ? 1 : -1)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:
            delegate?.overlayDidCancel(self)
        case 36, 76:
            delegate?.overlay(self, didFinishAt: NSEvent.mouseLocation, manualRect: nil)
        case 123, 125:
            delegate?.overlay(self, cycleBy: -1)
        case 124, 126:
            delegate?.overlay(self, cycleBy: 1)
        default:
            super.keyDown(with: event)
        }
    }

    private var localSelectionRect: CGRect? {
        let global = manualRect ?? candidate?.rect
        guard let global else { return nil }
        let clipped = global.intersection(screenFrame)
        guard !clipped.isNull else { return nil }
        return clipped.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
    }

    private func globalPoint(for event: NSEvent) -> CGPoint {
        window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
    }

    private func drawBadge(for selection: CGRect) {
        let label = manualRect == nil ? (candidate?.label ?? "Selection") : "Manual"
        let sizeText = "\(Int(selection.width)) x \(Int(selection.height))"
        let text = "\(label)  \(sizeText)" as NSString
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraphStyle
        ]
        let textSize = text.size(withAttributes: attributes)
        let badgeWidth = min(textSize.width + 16, max(80, bounds.width - 8))
        let badgeSize = CGSize(width: badgeWidth, height: 24)
        let originY = selection.minY >= 30 ? selection.minY - 28 : selection.maxY + 4
        let originX = min(max(4, selection.minX), max(4, bounds.maxX - badgeSize.width - 4))
        let badge = CGRect(origin: CGPoint(x: originX, y: originY), size: badgeSize)
        NSColor.black.withAlphaComponent(0.82).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 4, yRadius: 4).fill()
        text.draw(
            in: CGRect(x: badge.minX + 8, y: badge.minY + 5, width: badge.width - 16, height: 14),
            withAttributes: attributes
        )
    }

    private func drawStatus(_ status: SelectionOverlayStatus) {
        let text = status.message as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let textSize = text.size(withAttributes: attributes)
        let width = min(max(260, textSize.width + 28), max(120, bounds.width - 32))
        let frame = CGRect(
            x: max(16, (bounds.width - width) / 2),
            y: max(16, bounds.maxY - 58),
            width: width,
            height: 38
        )
        NSColor.black.withAlphaComponent(0.86).setFill()
        NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6).fill()
        text.draw(
            in: CGRect(x: frame.minX + 14, y: frame.minY + 11, width: frame.width - 28, height: 18),
            withAttributes: attributes
        )
    }
}
