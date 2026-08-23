import AppKit
import SmartShotCore

@MainActor
final class CaptureEditorModel: ObservableObject {
    var onRecognizedTextChanged: ((String) -> Void)?

    @Published private(set) var history = ScreenshotEditHistory()
    @Published private(set) var previewImage: NSImage
    @Published private(set) var previewLogicalSize: CGSize
    @Published private(set) var renderingError: String?
    @Published var selectedTool: ScreenshotEditingTool = .arrow {
        didSet {
            if selectedTool != .select { selectedAnnotationID = nil }
        }
    }
    @Published private(set) var selectedAnnotationID: UUID?
    @Published var selectedColor: ScreenshotColor = .red
    @Published var lineWidthPoints = 3.0
    @Published var textDraft = "Label"
    @Published private(set) var recognizedTextBlocks: [RecognizedTextBlock] = []
    @Published private(set) var isRecognizingText = false
    @Published private(set) var textRecognitionError: String?

    let originalCapture: CapturedImage
    private var cachedOutput: CapturedImage?
    private var previewRenderTask: Task<Void, Never>?
    private var textRecognitionTask: Task<Void, Never>?
    private var previewRevision = 0

    init(capture: CapturedImage) {
        originalCapture = capture
        previewImage = capture.image
        previewLogicalSize = capture.logicalRect.size
    }

    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }
    var hasEdits: Bool { history.document != ScreenshotEditDocument() }
    var currentCrop: NormalizedRect { history.document.crop }
    var canDeleteSelection: Bool { selectedAnnotationID != nil }
    var recognizedText: String { visibleTextBlocks.map(\.text).joined(separator: "\n") }
    var sensitiveTextBlocks: [RecognizedTextBlock] {
        visibleTextBlocks.filter { !SensitiveTextDetector.matches(in: $0.text).isEmpty }
    }

    var selectedAnnotationBoundsInCrop: NormalizedRect? {
        guard let annotation = selectedAnnotation else { return nil }
        let bounds = annotation.bounds
        let crop = history.document.crop
        guard crop.width > 0, crop.height > 0 else { return nil }
        return NormalizedRect(
            minX: (bounds.minX - crop.minX) / crop.width,
            minY: (bounds.minY - crop.minY) / crop.height,
            maxX: (bounds.maxX - crop.minX) / crop.width,
            maxY: (bounds.maxY - crop.minY) / crop.height
        )
    }

    func commitInteraction(from start: NormalizedPoint, to end: NormalizedPoint) {
        let localRect = NormalizedRect(start: start, end: end)
        var document = history.document

        switch selectedTool {
        case .crop:
            guard localRect.width >= 0.015, localRect.height >= 0.015 else { return }
            document.crop = document.crop.rectInOriginal(fromLocal: localRect)
        case .arrow, .rectangle, .ellipse, .mosaic, .blur, .redaction, .spotlight, .magnifier:
            guard squaredDistance(start, end) >= 0.000_1 else { return }
            document.annotations.append(
                ScreenshotAnnotation(
                    kind: annotationKind(for: selectedTool),
                    start: document.crop.pointInOriginal(fromLocal: start),
                    end: document.crop.pointInOriginal(fromLocal: end),
                    color: selectedColor,
                    lineWidthPoints: lineWidthPoints
                )
            )
        case .text:
            let text = textDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            let point = document.crop.pointInOriginal(fromLocal: end)
            document.annotations.append(
                ScreenshotAnnotation(
                    kind: .text,
                    start: point,
                    end: point,
                    color: selectedColor,
                    lineWidthPoints: lineWidthPoints,
                    text: text
                )
            )
        case .counter:
            let point = document.crop.pointInOriginal(fromLocal: end)
            document.annotations.append(
                ScreenshotAnnotation(
                    kind: .counter,
                    start: point,
                    end: point,
                    color: selectedColor,
                    lineWidthPoints: lineWidthPoints,
                    counterValue: document.nextCounterValue
                )
            )
        case .select, .freehand:
            return
        }

        if history.commit(document) {
            didChangeDocument()
        }
    }

    func commitFreehand(points: [NormalizedPoint]) {
        guard points.count > 1 else { return }
        let documentCrop = history.document.crop
        let mapped = decimated(points).map(documentCrop.pointInOriginal(fromLocal:))
        guard let first = mapped.first, let last = mapped.last else { return }
        var document = history.document
        document.annotations.append(
            ScreenshotAnnotation(
                kind: .freehand,
                start: first,
                end: last,
                color: selectedColor,
                lineWidthPoints: lineWidthPoints,
                points: mapped
            )
        )
        if history.commit(document) { didChangeDocument() }
    }

    func selectOrMove(from start: NormalizedPoint, to end: NormalizedPoint) {
        let crop = history.document.crop
        let originalStart = crop.pointInOriginal(fromLocal: start)
        let originalEnd = crop.pointInOriginal(fromLocal: end)
        let movement = squaredDistance(start, end)
        let hit = hitTest(at: originalStart)
        guard let hit else {
            selectedAnnotationID = nil
            return
        }
        selectedAnnotationID = hit.id
        guard movement >= 0.000_025,
              let index = history.document.annotations.firstIndex(where: { $0.id == hit.id }) else {
            return
        }
        var document = history.document
        document.annotations[index] = hit.translated(
            x: originalEnd.x - originalStart.x,
            y: originalEnd.y - originalStart.y
        )
        if history.commit(document) { didChangeDocument() }
    }

    func deleteSelected() {
        guard let selectedAnnotationID else { return }
        var document = history.document
        document.annotations.removeAll { $0.id == selectedAnnotationID }
        guard history.commit(document) else { return }
        self.selectedAnnotationID = nil
        didChangeDocument()
    }

    func addRedactions(_ rects: [NormalizedRect]) {
        let valid = rects.filter { $0.width >= 0.001 && $0.height >= 0.001 }
        guard !valid.isEmpty else { return }
        var document = history.document
        document.annotations.append(contentsOf: valid.map { rect in
            ScreenshotAnnotation(
                kind: .redaction,
                start: NormalizedPoint(x: rect.minX, y: rect.minY),
                end: NormalizedPoint(x: rect.maxX, y: rect.maxY),
                color: .black,
                lineWidthPoints: 3
            )
        })
        if history.commit(document) { didChangeDocument() }
    }

    func recognizeText() {
        textRecognitionTask?.cancel()
        isRecognizingText = true
        textRecognitionError = nil
        let image = originalCapture.cgImage
        textRecognitionTask = Task { [weak self] in
            do {
                let blocks = try await TextRecognitionService().recognizeText(in: image)
                try Task.checkCancellation()
                guard let self else { return }
                recognizedTextBlocks = blocks
                onRecognizedTextChanged?(blocks.map(\.text).joined(separator: "\n"))
                isRecognizingText = false
                textRecognitionTask = nil
            } catch is CancellationError {
                guard let self else { return }
                isRecognizingText = false
                textRecognitionTask = nil
            } catch {
                guard let self else { return }
                textRecognitionError = error.localizedDescription
                isRecognizingText = false
                textRecognitionTask = nil
            }
        }
    }

    func copyRecognizedText() {
        guard !recognizedText.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(recognizedText, forType: .string)
    }

    func redactSensitiveText() {
        addRedactions(sensitiveTextBlocks.map(redactionRect(for:)))
    }

    func redactAllRecognizedText() {
        addRedactions(visibleTextBlocks.map(redactionRect(for:)))
    }

    func undo() {
        if history.undo() {
            selectedAnnotationID = nil
            didChangeDocument()
        }
    }

    func redo() {
        if history.redo() {
            selectedAnnotationID = nil
            didChangeDocument()
        }
    }

    func resetAll() {
        if history.reset() {
            selectedAnnotationID = nil
            didChangeDocument()
        }
    }

    func resetCrop() {
        var document = history.document
        guard document.crop != .full else { return }
        document.crop = .full
        if history.commit(document) { didChangeDocument() }
    }

    func renderedCapture() throws -> CapturedImage {
        if let cachedOutput { return cachedOutput }
        guard hasEdits else { return originalCapture }
        let result = try ScreenshotRenderer.render(
            original: originalCapture.cgImage,
            logicalSize: originalCapture.logicalRect.size,
            document: history.document,
            maximumPixelCount: 50_000_000
        )
        let rect = CGRect(origin: originalCapture.logicalRect.origin, size: result.logicalSize)
        let capture = try CapturedImage.encoded(
            cgImage: result.image,
            logicalRect: rect,
            label: originalCapture.label
        )
        cachedOutput = capture
        return capture
    }

    private func didChangeDocument() {
        cachedOutput = nil
        refreshPreview()
    }

    private func refreshPreview() {
        previewRevision += 1
        let revision = previewRevision
        let input = PreviewRenderInput(
            image: originalCapture.cgImage,
            logicalSize: originalCapture.logicalRect.size,
            document: history.document
        )
        previewRenderTask?.cancel()
        previewRenderTask = Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                guard !Task.isCancelled else { return PreviewRenderOutcome.cancelled }
                do {
                    let result = try ScreenshotRenderer.render(
                        original: input.image,
                        logicalSize: input.logicalSize,
                        document: input.document,
                        maximumDimensionPixels: 2_400,
                        maximumPixelCount: 8_000_000
                    )
                    return .success(result.image, result.logicalSize)
                } catch {
                    return .failure(error.localizedDescription)
                }
            }.value
            guard let self, !Task.isCancelled, previewRevision == revision else { return }
            switch outcome {
            case let .success(image, logicalSize):
                previewImage = NSImage(cgImage: image, size: logicalSize)
                previewLogicalSize = logicalSize
                renderingError = nil
            case let .failure(message):
                renderingError = message
            case .cancelled:
                break
            }
        }
    }

    private func annotationKind(for tool: ScreenshotEditingTool) -> ScreenshotAnnotationKind {
        switch tool {
        case .freehand: .freehand
        case .arrow: .arrow
        case .rectangle: .rectangle
        case .ellipse: .ellipse
        case .mosaic: .mosaic
        case .blur: .blur
        case .redaction: .redaction
        case .spotlight: .spotlight
        case .magnifier: .magnifier
        case .text: .text
        case .counter: .counter
        case .select, .crop: .rectangle
        }
    }

    private var selectedAnnotation: ScreenshotAnnotation? {
        guard let selectedAnnotationID else { return nil }
        return history.document.annotations.first { $0.id == selectedAnnotationID }
    }

    private var visibleTextBlocks: [RecognizedTextBlock] {
        let crop = history.document.crop
        return recognizedTextBlocks.filter { block in
            let bounds = block.normalizedBounds
            return bounds.maxX > crop.minX && bounds.minX < crop.maxX
                && bounds.maxY > crop.minY && bounds.minY < crop.maxY
        }
    }

    private func redactionRect(for block: RecognizedTextBlock) -> NormalizedRect {
        let padding = 0.003
        return NormalizedRect(
            minX: block.normalizedBounds.minX - padding,
            minY: block.normalizedBounds.minY - padding,
            maxX: block.normalizedBounds.maxX + padding,
            maxY: block.normalizedBounds.maxY + padding
        )
    }

    private func hitTest(at point: NormalizedPoint) -> ScreenshotAnnotation? {
        let tolerance = max(history.document.crop.width, history.document.crop.height) * 0.025
        return history.document.annotations.reversed().first { annotation in
            switch annotation.kind {
            case .arrow:
                return distance(point, toSegmentFrom: annotation.start, to: annotation.end) <= tolerance
            case .freehand:
                return zip(annotation.points, annotation.points.dropFirst()).contains {
                    distance(point, toSegmentFrom: $0.0, to: $0.1) <= tolerance
                }
            case .text, .counter:
                return sqrt(squaredDistance(point, annotation.start)) <= tolerance * 2
            case .magnifier:
                return sqrt(squaredDistance(point, annotation.end)) <= tolerance * 3
            case .rectangle, .ellipse, .mosaic, .blur, .redaction, .spotlight:
                let bounds = annotation.bounds
                return point.x >= bounds.minX - tolerance
                    && point.x <= bounds.maxX + tolerance
                    && point.y >= bounds.minY - tolerance
                    && point.y <= bounds.maxY + tolerance
            }
        }
    }

    private func distance(
        _ point: NormalizedPoint,
        toSegmentFrom start: NormalizedPoint,
        to end: NormalizedPoint
    ) -> Double {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return sqrt(squaredDistance(point, start)) }
        let projection = min(1, max(0, ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared))
        let closest = NormalizedPoint(x: start.x + projection * dx, y: start.y + projection * dy)
        return sqrt(squaredDistance(point, closest))
    }

    private func decimated(_ points: [NormalizedPoint]) -> [NormalizedPoint] {
        guard points.count > 2 else { return points }
        var result = [points[0]]
        for point in points.dropFirst().dropLast()
        where squaredDistance(result.last!, point) >= 0.000_004 {
            result.append(point)
        }
        if let last = points.last, result.last != last { result.append(last) }
        return Array(result.prefix(4_096))
    }

    private func squaredDistance(_ first: NormalizedPoint, _ second: NormalizedPoint) -> Double {
        let dx = second.x - first.x
        let dy = second.y - first.y
        return dx * dx + dy * dy
    }
}

private struct PreviewRenderInput: @unchecked Sendable {
    let image: CGImage
    let logicalSize: CGSize
    let document: ScreenshotEditDocument
}

private enum PreviewRenderOutcome: @unchecked Sendable {
    case success(CGImage, CGSize)
    case failure(String)
    case cancelled
}
