import AppKit
import SmartShotCore
import SwiftUI

private struct ToolbarItemFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private extension View {
    func toolbarItem(_ id: String) -> some View {
        self.id(id)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: ToolbarItemFramesKey.self,
                        value: [id: geometry.frame(in: .named("editorToolbar"))]
                    )
                }
            }
    }
}

struct CaptureEditorView: View {
    @ObservedObject var editor: CaptureEditorModel
    @State private var zoomScale: CGFloat = 1
    @State private var showsTextRecognition = false
    @State private var toolbarItemFrames: [String: CGRect] = [:]

    var body: some View {
        VStack(spacing: 0) {
            editorToolbar
            Divider()
            editorCanvas
            if let renderingError = editor.renderingError {
                Text(renderingError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private var editorToolbar: some View {
        GeometryReader { geometry in
            let viewportWidth = max(1, geometry.size.width - 64)

            ScrollViewReader { proxy in
                HStack(spacing: 0) {
                    toolbarScrollButton(forward: false, viewportWidth: viewportWidth, proxy: proxy)

                    ScrollView(.horizontal) {
                        toolbarContents
                    }
                    .scrollIndicators(.visible)
                    .coordinateSpace(name: "editorToolbar")
                    .frame(width: viewportWidth)
                    .onPreferenceChange(ToolbarItemFramesKey.self) { toolbarItemFrames = $0 }

                    toolbarScrollButton(forward: true, viewportWidth: viewportWidth, proxy: proxy)
                }
            }
        }
        .frame(height: 56)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func toolbarScrollButton(
        forward: Bool,
        viewportWidth: CGFloat,
        proxy: ScrollViewProxy
    ) -> some View {
        let hiddenItems = toolbarItemFrames.filter {
            forward ? $0.value.maxX > viewportWidth + 1 : $0.value.minX < -1
        }
        let target = hiddenItems.sorted {
            forward ? $0.value.minX < $1.value.minX : $0.value.maxX > $1.value.maxX
        }.first?.key

        return Button {
            guard let target else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(target, anchor: forward ? .leading : .trailing)
            }
        } label: {
            Image(systemName: forward ? "chevron.right" : "chevron.left")
                .frame(width: 32, height: 56)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(target == nil)
        .help(forward ? "Show more tools" : "Show previous tools")
        .accessibilityLabel(forward ? "Show more tools" : "Show previous tools")
    }

    private var toolbarContents: some View {
        HStack(spacing: 6) {
            ForEach(ScreenshotEditingTool.allCases, id: \.rawValue) { tool in
                Button {
                    editor.selectedTool = tool
                } label: {
                    Image(systemName: icon(for: tool))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.bordered)
                .tint(editor.selectedTool == tool ? .accentColor : .secondary)
                .help(label(for: tool))
                .accessibilityLabel(label(for: tool))
                .accessibilityAddTraits(editor.selectedTool == tool ? .isSelected : [])
                .toolbarItem(tool.rawValue)
            }

            Divider()
                .frame(height: 22)
                .padding(.horizontal, 3)

            HStack(spacing: 6) {
                ForEach(colorChoices, id: \.name) { choice in
                    Button {
                        editor.selectedColor = choice.value
                    } label: {
                        Circle()
                            .fill(swiftUIColor(choice.value))
                            .overlay {
                                Circle()
                                    .stroke(
                                        editor.selectedColor == choice.value
                                            ? Color.accentColor
                                            : Color.primary.opacity(0.25),
                                        lineWidth: editor.selectedColor == choice.value ? 3 : 1
                                    )
                                    .padding(editor.selectedColor == choice.value ? -3 : 0)
                            }
                            .frame(width: 16, height: 16)
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.plain)
                    .help(choice.name)
                    .accessibilityLabel(choice.name)
                    .accessibilityAddTraits(editor.selectedColor == choice.value ? .isSelected : [])
                }

                Slider(value: $editor.lineWidthPoints, in: 1...12, step: 1)
                    .frame(width: 86)
                    .help("Line width")
                    .accessibilityLabel("Line width")
            }
            .toolbarItem("appearance")

            if editor.selectedTool == .text {
                TextField("Text", text: $editor.textDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 128)
                    .accessibilityLabel("Annotation text")
                    .toolbarItem("text-entry")
            }

            Divider()
                .frame(height: 22)
                .padding(.horizontal, 3)

            HStack(spacing: 6) {
                Button(action: editor.undo) {
                    Image(systemName: "arrow.uturn.backward")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!editor.canUndo)
                .help("Undo")

                Button(action: editor.redo) {
                    Image(systemName: "arrow.uturn.forward")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!editor.canRedo)
                .help("Redo")

                Button(action: editor.deleteSelected) {
                    Image(systemName: "trash")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(!editor.canDeleteSelection)
                .help("Delete selected annotation")

                if editor.currentCrop != .full {
                    Button(action: editor.resetCrop) {
                        Image(systemName: "crop.rotate")
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.borderless)
                    .help("Restore full image bounds")
                }

                Button {
                    showsTextRecognition = true
                    if editor.recognizedTextBlocks.isEmpty && !editor.isRecognizingText {
                        editor.recognizeText()
                    }
                } label: {
                    Image(systemName: "text.viewfinder")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.borderless)
                .help("Recognize text")
                .popover(isPresented: $showsTextRecognition, arrowEdge: .bottom) {
                    TextRecognitionPanel(editor: editor)
                }

                Button(action: editor.resetAll) {
                    Image(systemName: "arrow.counterclockwise")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.borderless)
                .disabled(!editor.hasEdits)
                .help("Reset all edits")
            }
            .toolbarItem("edit-actions")

            Divider()
                .frame(height: 22)
                .padding(.horizontal, 3)

            HStack(spacing: 6) {
                Button {
                    zoomScale = max(1, zoomScale - 0.5)
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.borderless)
                .disabled(zoomScale <= 1)
                .help("Zoom out")

                Text("\(Int(zoomScale * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 42)

                Button {
                    zoomScale = min(4, zoomScale + 0.5)
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.borderless)
                .disabled(zoomScale >= 4)
                .help("Zoom in")
            }
            .toolbarItem("zoom")
        }
        .fixedSize()
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 16)
    }

    private var editorCanvas: some View {
        GeometryReader { proxy in
            let availableSize = CGSize(
                width: max(1, proxy.size.width - 32),
                height: max(1, proxy.size.height - 32)
            )
            let fittedSize = aspectFit(
                editor.previewLogicalSize,
                inside: availableSize
            )
            let canvasSize = CGSize(
                width: fittedSize.width * zoomScale,
                height: fittedSize.height * zoomScale
            )

            ScrollView([.horizontal, .vertical]) {
                ZStack {
                    EditorImageCanvas(editor: editor)
                        .frame(width: canvasSize.width, height: canvasSize.height)
                        .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
                }
                .frame(
                    width: max(proxy.size.width, canvasSize.width + 32),
                    height: max(proxy.size.height, canvasSize.height + 32)
                )
            }
            .scrollIndicators(.automatic)
        }
    }

    private var colorChoices: [(name: String, value: ScreenshotColor)] {
        [
            ("Red", .red),
            ("Orange", .orange),
            ("Yellow", .yellow),
            ("Green", .green),
            ("Blue", .blue),
            ("White", .white),
            ("Black", .black),
        ]
    }

    private func label(for tool: ScreenshotEditingTool) -> String {
        switch tool {
        case .select: "Select"
        case .crop: "Crop"
        case .freehand: "Freehand"
        case .arrow: "Arrow"
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .text: "Text"
        case .mosaic: "Mosaic"
        case .blur: "Blur"
        case .redaction: "Redact"
        case .spotlight: "Spotlight"
        case .magnifier: "Magnifier"
        case .counter: "Number"
        }
    }

    private func icon(for tool: ScreenshotEditingTool) -> String {
        switch tool {
        case .select: "cursorarrow"
        case .crop: "crop"
        case .freehand: "pencil.tip"
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .text: "character.cursor.ibeam"
        case .mosaic: "square.grid.3x3.fill"
        case .blur: "drop.halffull"
        case .redaction: "rectangle.fill"
        case .spotlight: "scope"
        case .magnifier: "plus.magnifyingglass"
        case .counter: "number.circle"
        }
    }

    private func swiftUIColor(_ color: ScreenshotColor) -> Color {
        Color(
            red: color.red,
            green: color.green,
            blue: color.blue,
            opacity: color.alpha
        )
    }

    private func aspectFit(_ source: CGSize, inside destination: CGSize) -> CGSize {
        guard source.width > 0, source.height > 0 else { return .zero }
        let scale = min(destination.width / source.width, destination.height / source.height)
        return CGSize(width: source.width * scale, height: source.height * scale)
    }
}

private struct TextRecognitionPanel: View {
    @ObservedObject var editor: CaptureEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recognized Text")
                    .font(.headline)
                Spacer()
                Button(action: editor.recognizeText) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(editor.isRecognizingText)
                .help("Recognize again")
            }

            if editor.isRecognizingText {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = editor.textRecognitionError {
                ContentUnavailableView(
                    "Recognition Failed",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
            } else if editor.recognizedText.isEmpty {
                ContentUnavailableView("No Text", systemImage: "text.viewfinder")
            } else {
                ScrollView {
                    Text(editor.recognizedText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 5))

                HStack {
                    Button(action: editor.copyRecognizedText) {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    Button(action: editor.redactSensitiveText) {
                        Label(
                            "Sensitive (\(editor.sensitiveTextBlocks.count))",
                            systemImage: "hand.raised.fill"
                        )
                    }
                    .disabled(editor.sensitiveTextBlocks.isEmpty)
                    Button(action: editor.redactAllRecognizedText) {
                        Label("All", systemImage: "rectangle.fill")
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 380, height: 320)
    }
}

private struct EditorImageCanvas: View {
    @ObservedObject var editor: CaptureEditorModel
    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?
    @State private var dragPoints: [CGPoint] = []

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Image(nsImage: editor.previewImage)
                    .resizable()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .accessibilityLabel("Screenshot editor canvas")

                draftOverlay(in: proxy.size)

                if let bounds = editor.selectedAnnotationBoundsInCrop {
                    let rect = selectionRect(bounds, in: proxy.size)
                    Rectangle()
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                        .frame(width: max(18, rect.width), height: max(18, rect.height))
                        .position(x: rect.midX, y: rect.midY)
                        .allowsHitTesting(false)
                }

                Color.clear
                    .contentShape(Rectangle())
                    .gesture(interactionGesture(in: proxy.size))
            }
            .clipped()
        }
    }

    @ViewBuilder
    private func draftOverlay(in size: CGSize) -> some View {
        if let dragStart, let dragCurrent, drawsDragPreview {
            Canvas { context, _ in
                let color = editor.selectedTool == .crop
                    ? Color.white
                    : Color(
                        red: editor.selectedColor.red,
                        green: editor.selectedColor.green,
                        blue: editor.selectedColor.blue,
                        opacity: editor.selectedColor.alpha
                    )
                switch editor.selectedTool {
                case .crop, .rectangle, .mosaic, .blur, .redaction, .spotlight:
                    let rect = CGRect(
                        x: min(dragStart.x, dragCurrent.x),
                        y: min(dragStart.y, dragCurrent.y),
                        width: abs(dragCurrent.x - dragStart.x),
                        height: abs(dragCurrent.y - dragStart.y)
                    )
                    if [.mosaic, .blur].contains(editor.selectedTool) {
                        context.fill(Path(rect), with: .color(color.opacity(0.18)))
                    } else if editor.selectedTool == .redaction {
                        context.fill(Path(rect), with: .color(Color.black.opacity(0.88)))
                    } else if editor.selectedTool == .spotlight {
                        context.fill(Path(rect), with: .color(Color.white.opacity(0.12)))
                    }
                    context.stroke(
                        Path(rect),
                        with: .color(color),
                        style: StrokeStyle(
                            lineWidth: max(1.5, editor.lineWidthPoints),
                            dash: editor.selectedTool == .crop ? [7, 4] : []
                        )
                    )
                case .ellipse:
                    let rect = CGRect(
                        x: min(dragStart.x, dragCurrent.x),
                        y: min(dragStart.y, dragCurrent.y),
                        width: abs(dragCurrent.x - dragStart.x),
                        height: abs(dragCurrent.y - dragStart.y)
                    )
                    context.stroke(
                        Path(ellipseIn: rect),
                        with: .color(color),
                        style: StrokeStyle(lineWidth: max(1.5, editor.lineWidthPoints))
                    )
                case .arrow, .magnifier:
                    var path = Path()
                    path.move(to: dragStart)
                    path.addLine(to: dragCurrent)
                    if editor.selectedTool == .magnifier {
                        context.stroke(path, with: .color(color.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        context.stroke(
                            Path(ellipseIn: CGRect(x: dragCurrent.x - 28, y: dragCurrent.y - 28, width: 56, height: 56)),
                            with: .color(color),
                            style: StrokeStyle(lineWidth: 2)
                        )
                        return
                    }
                    let angle = atan2(
                        dragCurrent.y - dragStart.y,
                        dragCurrent.x - dragStart.x
                    )
                    let headLength = max(10, editor.lineWidthPoints * 4)
                    path.move(to: dragCurrent)
                    path.addLine(
                        to: CGPoint(
                            x: dragCurrent.x - headLength * cos(angle - CGFloat.pi / 6),
                            y: dragCurrent.y - headLength * sin(angle - CGFloat.pi / 6)
                        )
                    )
                    path.move(to: dragCurrent)
                    path.addLine(
                        to: CGPoint(
                            x: dragCurrent.x - headLength * cos(angle + CGFloat.pi / 6),
                            y: dragCurrent.y - headLength * sin(angle + CGFloat.pi / 6)
                        )
                    )
                    context.stroke(
                        path,
                        with: .color(color),
                        style: StrokeStyle(
                            lineWidth: max(1.5, editor.lineWidthPoints),
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                case .freehand:
                    guard let first = dragPoints.first else { return }
                    var path = Path()
                    path.move(to: first)
                    dragPoints.dropFirst().forEach { path.addLine(to: $0) }
                    context.stroke(
                        path,
                        with: .color(color),
                        style: StrokeStyle(
                            lineWidth: max(1.5, editor.lineWidthPoints),
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                case .select, .text, .counter:
                    break
                }
            }
            .allowsHitTesting(false)
        }
    }

    private var drawsDragPreview: Bool {
        switch editor.selectedTool {
        case .crop, .freehand, .arrow, .rectangle, .ellipse, .mosaic, .blur, .redaction, .spotlight, .magnifier: true
        case .select, .text, .counter: false
        }
    }

    private func interactionGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragStart == nil {
                    dragStart = clamped(value.startLocation, to: size)
                    dragPoints = [dragStart!]
                }
                let current = clamped(value.location, to: size)
                dragCurrent = current
                if editor.selectedTool == .freehand,
                   let last = dragPoints.last,
                   hypot(current.x - last.x, current.y - last.y) >= 2 {
                    dragPoints.append(current)
                }
            }
            .onEnded { value in
                let start = dragStart ?? clamped(value.startLocation, to: size)
                let end = clamped(value.location, to: size)
                if editor.selectedTool == .freehand {
                    if dragPoints.last != end { dragPoints.append(end) }
                    editor.commitFreehand(points: dragPoints.map { normalized($0, in: size) })
                } else if editor.selectedTool == .select {
                    editor.selectOrMove(
                        from: normalized(start, in: size),
                        to: normalized(end, in: size)
                    )
                } else {
                    editor.commitInteraction(
                        from: normalized(start, in: size),
                        to: normalized(end, in: size)
                    )
                }
                dragStart = nil
                dragCurrent = nil
                dragPoints.removeAll(keepingCapacity: true)
            }
    }

    private func normalized(_ point: CGPoint, in size: CGSize) -> NormalizedPoint {
        NormalizedPoint(
            x: size.width > 0 ? point.x / size.width : 0,
            y: size.height > 0 ? point.y / size.height : 0
        )
    }

    private func clamped(_ point: CGPoint, to size: CGSize) -> CGPoint {
        CGPoint(
            x: min(size.width, max(0, point.x)),
            y: min(size.height, max(0, point.y))
        )
    }

    private func selectionRect(_ bounds: NormalizedRect, in size: CGSize) -> CGRect {
        CGRect(
            x: bounds.minX * size.width,
            y: bounds.minY * size.height,
            width: bounds.width * size.width,
            height: bounds.height * size.height
        )
    }
}
