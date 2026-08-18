import AppKit
import ApplicationServices
import SmartShotCore
import Foundation

@MainActor
protocol SelectionOverlayControllerDelegate: AnyObject {
    func selectionOverlay(_ controller: SelectionOverlayController, didSelect candidate: CaptureCandidate)
    func selectionOverlay(
        _ controller: SelectionOverlayController,
        didSelectManualScrollingRect rect: CGRect
    )
    func selectionOverlay(
        _ controller: SelectionOverlayController,
        didSelectScrollingTarget target: AccessibilityScrollCaptureTarget
    )
    func selectionOverlayDidCancel(_ controller: SelectionOverlayController)
    func selectionOverlay(_ controller: SelectionOverlayController, didFailWith message: String)
}

@MainActor
final class SelectionOverlayController: NSObject, SelectionOverlayViewDelegate {
    enum Mode: Equatable, Sendable {
        case unified(CaptureSelectionMode)
        case scrollableArea
    }

    weak var delegate: SelectionOverlayControllerDelegate?

    private var windows: [NSPanel] = []
    private var views: [SelectionOverlayView] = []
    private var candidates: [CaptureCandidate] = []
    private var candidateIndex = 0
    private var debounceTask: Task<Void, Never>?
    private var detectionTask: Task<Void, Never>?
    private var resolutionTask: Task<Void, Never>?
    private var pendingRequest: CandidateRequest?
    private var appliedRequest: AppliedCandidateRequest?
    private var pendingScrollingCommitPoint: CGPoint?
    private var candidateRequestID = 0
    private var resolutionRequestID: Int?
    private var mode: Mode = .unified(.smart)

    private struct CandidateRequest: Sendable {
        let id: Int
        let point: CGPoint
        let mode: Mode
        let screenLayout: AXScreenLayout
        let desktopBounds: CGRect
    }

    private struct CandidateDetection: Sendable {
        let candidates: [CaptureCandidate]
        let targetIdentity: AccessibilityScrollTargetIdentity?
    }

    private struct AppliedCandidateRequest: Sendable {
        let request: CandidateRequest
        let targetIdentity: AccessibilityScrollTargetIdentity?
    }

    func begin(mode: Mode = .unified(.smart)) {
        guard windows.isEmpty else { return }
        self.mode = mode
        candidates = []
        candidateIndex = 0
        appliedRequest = nil
        pendingScrollingCommitPoint = nil

        for screen in NSScreen.screens {
            let window = SelectionOverlayPanel(screen: screen)

            let view = SelectionOverlayView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.setAccessibilityElement(true)
            view.setAccessibilityRole(.group)
            view.setAccessibilityLabel("SmartShot selection overlay")
            view.delegate = self
            view.screenFrame = screen.frame
            configure(view, for: mode)
            window.contentView = view
            windows.append(window)
            views.append(view)
            window.orderFrontRegardless()
        }

        if let active = window(at: NSEvent.mouseLocation), let view = active.contentView as? SelectionOverlayView {
            active.makeKey()
            active.makeFirstResponder(view)
        } else if let first = windows.first, let view = views.first {
            first.makeKey()
            first.makeFirstResponder(view)
        }

        if mode.requiresCandidateDetection {
            let initialPoint = NSEvent.mouseLocation
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, !self.windows.isEmpty else { return }
                self.scheduleCandidateUpdate(at: initialPoint, delay: nil)
            }
        }
    }

    func cancel() {
        tearDown()
        delegate?.selectionOverlayDidCancel(self)
    }

    func overlay(_ overlay: SelectionOverlayView, pointerMovedTo globalPoint: CGPoint) {
        guard resolutionTask == nil else { return }
        guard mode.requiresCandidateDetection else { return }
        pendingScrollingCommitPoint = nil
        if mode == .scrollableArea {
            renderStatus(.searchingForScrollArea)
        }
        if let window = overlay.window, !window.isKeyWindow {
            window.makeKey()
            window.makeFirstResponder(overlay)
        }
        scheduleCandidateUpdate(at: globalPoint, delay: .milliseconds(70))
    }

    func overlay(_ overlay: SelectionOverlayView, didFinishAt globalPoint: CGPoint, manualRect: CGRect?) {
        if mode == .scrollableArea {
            switch scrollingSelectionDecision(at: globalPoint) {
            case let .resolve(selection):
                beginScrollingTargetResolution(selection)
            case .refresh:
                pendingScrollingCommitPoint = globalPoint
                renderStatus(.searchingForScrollArea)
                scheduleCandidateUpdate(at: globalPoint, delay: nil)
            case .unsupported:
                failUnsupportedScrollingSelection()
            }
            return
        }

        switch mode {
        case .unified(.smart):
            let selected = manualRect.map {
                CaptureCandidate(rect: $0, source: .manual, label: "Region")
            } ?? currentCandidate
            guard let selected else { return }
            tearDown()
            delegate?.selectionOverlay(self, didSelect: selected)
        case .unified(.region):
            guard let manualRect else { return }
            let selected = CaptureCandidate(rect: manualRect, source: .manual, label: "Region")
            tearDown()
            delegate?.selectionOverlay(self, didSelect: selected)
        case .unified(.long):
            guard let manualRect else { return }
            tearDown()
            delegate?.selectionOverlay(self, didSelectManualScrollingRect: manualRect)
        case .scrollableArea:
            break
        }
    }

    func overlayDidCancel(_ overlay: SelectionOverlayView) {
        cancel()
    }

    func overlay(_ overlay: SelectionOverlayView, cycleBy delta: Int) {
        guard resolutionTask == nil else { return }
        guard !candidates.isEmpty else { return }
        candidateIndex = min(max(0, candidateIndex + delta), candidates.count - 1)
        renderCandidate()
    }

    func overlay(_ overlay: SelectionOverlayView, didChoose selectionMode: CaptureSelectionMode) {
        guard case .unified = mode, resolutionTask == nil else { return }
        mode = .unified(selectionMode)
        cancelCandidateWork()
        candidates = []
        candidateIndex = 0
        appliedRequest = nil
        pendingScrollingCommitPoint = nil
        candidateRequestID &+= 1
        for view in views {
            view.candidate = nil
            view.manualRect = nil
            configure(view, for: mode)
        }
        if mode.requiresCandidateDetection {
            scheduleCandidateUpdate(at: NSEvent.mouseLocation, delay: nil)
        }
    }

    private var currentCandidate: CaptureCandidate? {
        candidates.indices.contains(candidateIndex) ? candidates[candidateIndex] : nil
    }

    private func scheduleCandidateUpdate(at point: CGPoint, delay: Duration?) {
        debounceTask?.cancel()
        candidateRequestID &+= 1
        let requestID = candidateRequestID
        pendingRequest = CandidateRequest(
            id: requestID,
            point: point,
            mode: mode,
            screenLayout: .current(),
            desktopBounds: NSScreen.screens.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        )

        debounceTask = Task { [weak self] in
            if let delay {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            self?.startPendingDetectionIfNeeded()
        }
    }

    private func startPendingDetectionIfNeeded() {
        guard detectionTask == nil, let request = pendingRequest else { return }
        pendingRequest = nil
        detectionTask = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                Self.detectCandidates(
                    at: request.point,
                    mode: request.mode,
                    screenLayout: request.screenLayout,
                    desktopBounds: request.desktopBounds
                )
            }
            let detection = await worker.value
            guard let self else { return }
            self.detectionTask = nil
            if request.id == self.candidateRequestID, !self.windows.isEmpty {
                self.applyCandidates(detection, for: request)
            }
            self.startPendingDetectionIfNeeded()
        }
    }

    nonisolated private static func detectCandidates(
        at point: CGPoint,
        mode: Mode,
        screenLayout: AXScreenLayout,
        desktopBounds: CGRect
    ) -> CandidateDetection {
        var next: [CaptureCandidate] = []
        let identityBefore: AccessibilityScrollTargetIdentity?
        if case .scrollableArea = mode {
            identityBefore = AccessibilityScrollCaptureTarget.identity(at: point)
        } else {
            identityBefore = nil
        }

        if AXIsProcessTrusted() {
            do {
                let detector = AccessibilityBlockDetector(
                    provider: SystemAccessibilityHierarchyProvider()
                )
                let result = try detector.detect(
                    at: point,
                    in: .appKit,
                    screenLayout: screenLayout
                )
                switch mode {
                case .unified(.smart):
                    next.append(contentsOf: result.captureCandidates())
                case .unified(.region), .unified(.long):
                    break
                case .scrollableArea:
                    next.append(contentsOf: result.candidates.compactMap(scrollCandidate))
                }
            } catch {
                // Partial or slow Accessibility trees must not block pointer input.
            }
        }

        if case .unified(.smart) = mode {
            next.append(contentsOf: WindowCandidateProvider().candidates(at: point))
        }
        switch mode {
        case .unified(.smart):
            return CandidateDetection(
                candidates: CandidateFilter.normalized(next, within: desktopBounds),
                targetIdentity: nil
            )
        case .unified(.region), .unified(.long):
            return CandidateDetection(candidates: [], targetIdentity: nil)
        case .scrollableArea:
            let identityAfter = AccessibilityScrollCaptureTarget.identity(at: point)
            guard let identityBefore, identityBefore == identityAfter else {
                return CandidateDetection(candidates: [], targetIdentity: nil)
            }
            // A clipped AX frame cannot be matched back to the live element reliably.
            let candidates = next
                .filter { candidate in
                    let rect = candidate.rect
                    return !rect.isNull && !rect.isInfinite &&
                        rect.width >= 24 && rect.height >= 18 &&
                        rect.intersects(desktopBounds)
                }
                .sorted { lhs, rhs in
                    lhs.rect.width * lhs.rect.height < rhs.rect.width * rhs.rect.height
                }
            return CandidateDetection(
                candidates: candidates,
                targetIdentity: identityBefore
            )
        }
    }

    private func applyCandidates(_ detection: CandidateDetection, for request: CandidateRequest) {
        let previousCandidate = currentCandidate
        candidates = detection.candidates
        appliedRequest = AppliedCandidateRequest(
            request: request,
            targetIdentity: detection.targetIdentity
        )
        candidateIndex = previousCandidate.flatMap { previous in
            candidates.firstIndex { candidate in
                candidate.source == previous.source &&
                    candidate.level == previous.level &&
                    approximatelyEqual(candidate.rect, previous.rect)
            }
        } ?? 0
        renderCandidate()
        if mode == .scrollableArea {
            renderStatus(candidates.isEmpty ? .unsupportedScrollArea : .scrollAreaReady)
        }

        if mode == .scrollableArea,
           let commitPoint = pendingScrollingCommitPoint,
           request.id == candidateRequestID,
           request.point == commitPoint {
            pendingScrollingCommitPoint = nil
            switch scrollingSelectionDecision(at: commitPoint) {
            case let .resolve(selection):
                beginScrollingTargetResolution(selection)
            case .unsupported:
                failUnsupportedScrollingSelection()
            case .refresh:
                pendingScrollingCommitPoint = commitPoint
                scheduleCandidateUpdate(at: commitPoint, delay: nil)
            }
        }
    }

    private func renderCandidate() {
        let candidate = currentCandidate
        for view in views { view.candidate = candidate }
    }

    private func renderStatus(_ status: SelectionOverlayStatus) {
        for view in views { view.status = status }
    }

    private func tearDown() {
        debounceTask?.cancel()
        debounceTask = nil
        resolutionTask?.cancel()
        resolutionTask = nil
        resolutionRequestID = nil
        pendingRequest = nil
        appliedRequest = nil
        pendingScrollingCommitPoint = nil
        candidateRequestID &+= 1
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        views.removeAll()
        candidates.removeAll()
        mode = .unified(.smart)
    }

    private func scrollingSelectionDecision(at clickPoint: CGPoint) -> ScrollingSelectionDecision {
        ScrollingSelectionDecision.decide(
            appliedRequestID: appliedRequest?.request.id,
            currentRequestID: candidateRequestID,
            appliedHitPoint: appliedRequest?.request.point,
            clickPoint: clickPoint,
            candidate: currentCandidate,
            targetIdentity: appliedRequest?.targetIdentity
        )
    }

    private func beginScrollingTargetResolution(_ selection: ScrollingSelectionCommit) {
        guard resolutionTask == nil else { return }

        debounceTask?.cancel()
        debounceTask = nil
        pendingRequest = nil
        resolutionRequestID = selection.requestID
        renderStatus(.checkingScrollArea)
        resolutionTask = Task { [weak self] in
            let result = await AccessibilityScrollCaptureTarget.resolveInBackground(
                at: selection.hitPoint,
                matching: selection.expectedFrame,
                expectedIdentity: selection.targetIdentity
            )
            guard let self,
                  !Task.isCancelled,
                  self.resolutionRequestID == selection.requestID,
                  !self.windows.isEmpty else { return }

            self.resolutionTask = nil
            self.resolutionRequestID = nil
            switch result {
            case let .success(target):
                self.tearDown()
                self.delegate?.selectionOverlay(self, didSelectScrollingTarget: target)
            case let .failure(error):
                self.tearDown()
                self.delegate?.selectionOverlay(self, didFailWith: error.localizedDescription)
            }
        }
    }

    private func failUnsupportedScrollingSelection() {
        tearDown()
        delegate?.selectionOverlay(
            self,
            didFailWith: "No controllable app scroll area was found here. For X and other webpages, use the SmartShot browser extension from the browser toolbar."
        )
    }

    private func configure(_ view: SelectionOverlayView, for mode: Mode) {
        switch mode {
        case let .unified(selectionMode):
            view.captureMode = selectionMode
            view.showsModeToolbar = true
            view.allowsManualSelection = true
            switch selectionMode {
            case .smart:
                view.status = nil
            case .region:
                view.status = .regionSelection
            case .long:
                view.status = .manualLongSelection
            }
        case .scrollableArea:
            view.showsModeToolbar = false
            view.allowsManualSelection = false
            view.status = .searchingForScrollArea
        }
    }

    private func cancelCandidateWork() {
        debounceTask?.cancel()
        debounceTask = nil
        detectionTask?.cancel()
        pendingRequest = nil
    }

    private func window(at point: CGPoint) -> NSPanel? {
        windows.first { $0.frame.contains(point) }
    }

    private func approximatelyEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= 1 &&
            abs(lhs.minY - rhs.minY) <= 1 &&
            abs(lhs.width - rhs.width) <= 1 &&
            abs(lhs.height - rhs.height) <= 1
    }

    nonisolated private static func scrollCandidate(
        _ candidate: AccessibilityBlockCandidate
    ) -> CaptureCandidate? {
        guard candidate.element.role == kAXScrollAreaRole as String else { return nil }
        return CaptureCandidate(
            rect: candidate.appKitFrame,
            source: .accessibility,
            label: "Scroll Area",
            level: candidate.element.hierarchyLevel
        )
    }
}

private extension SelectionOverlayController.Mode {
    var requiresCandidateDetection: Bool {
        switch self {
        case .unified(.smart), .scrollableArea:
            true
        case .unified(.region), .unified(.long):
            false
        }
    }
}

private final class SelectionOverlayPanel: NSPanel {
    convenience init(screen: NSScreen) {
        self.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        level = .screenSaver
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
        hidesOnDeactivate = false
        animationBehavior = .none
        collectionBehavior = [
            .canJoinAllSpaces,
            .canJoinAllApplications,
            .fullScreenAuxiliary,
            .transient,
            .ignoresCycle,
            .fullScreenDisallowsTiling
        ]
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = false
        isReleasedWhenClosed = false
        setAccessibilityElement(true)
        setAccessibilityRole(.window)
        setAccessibilityLabel("SmartShot selection overlay")
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
