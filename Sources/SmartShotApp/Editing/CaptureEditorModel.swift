import AppKit
import SmartShotCore

@MainActor
final class CaptureEditorModel: ObservableObject {
    @Published private(set) var history = ScreenshotEditHistory()
    @Published private(set) var previewImage: NSImage
    @Published private(set) var previewLogicalSize: CGSize
    @Published private(set) var renderingError: String?
    @Published var selectedTool: ScreenshotEditingTool = .arrow
    @Published var selectedColor: ScreenshotColor = .red
    @Published var lineWidthPoints = 3.0
    @Published var textDraft = "Label"

    let originalCapture: CapturedImage
    private var cachedOutput: CapturedImage?

    init(capture: CapturedImage) {
        originalCapture = capture
        previewImage = capture.image
        previewLogicalSize = capture.logicalRect.size
    }

    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }
    var hasEdits: Bool { history.document != ScreenshotEditDocument() }
    var currentCrop: NormalizedRect { history.document.crop }

    func commitInteraction(from start: NormalizedPoint, to end: NormalizedPoint) {
        let localRect = NormalizedRect(start: start, end: end)
        var document = history.document

        switch selectedTool {
        case .crop:
            guard localRect.width >= 0.015, localRect.height >= 0.015 else { return }
            document.crop = document.crop.rectInOriginal(fromLocal: localRect)
        case .arrow, .rectangle, .mosaic:
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
        }

        if history.commit(document) {
            didChangeDocument()
        }
    }

    func undo() {
        if history.undo() { didChangeDocument() }
    }

    func redo() {
        if history.redo() { didChangeDocument() }
    }

    func resetAll() {
        if history.reset() { didChangeDocument() }
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
        do {
            let result = try ScreenshotRenderer.render(
                original: originalCapture.cgImage,
                logicalSize: originalCapture.logicalRect.size,
                document: history.document,
                maximumDimensionPixels: 2_400,
                maximumPixelCount: 8_000_000
            )
            previewImage = NSImage(cgImage: result.image, size: result.logicalSize)
            previewLogicalSize = result.logicalSize
            renderingError = nil
        } catch {
            renderingError = error.localizedDescription
        }
    }

    private func annotationKind(for tool: ScreenshotEditingTool) -> ScreenshotAnnotationKind {
        switch tool {
        case .arrow: .arrow
        case .rectangle: .rectangle
        case .mosaic: .mosaic
        case .text: .text
        case .counter: .counter
        case .crop: .rectangle
        }
    }

    private func squaredDistance(_ first: NormalizedPoint, _ second: NormalizedPoint) -> Double {
        let dx = second.x - first.x
        let dy = second.y - first.y
        return dx * dx + dy * dy
    }
}
