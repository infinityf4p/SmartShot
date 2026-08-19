import AppKit
import SmartShotCore
import SwiftUI

struct CaptureEditorView: View {
    @ObservedObject var editor: CaptureEditorModel
    @State private var zoomScale: CGFloat = 1

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
        ScrollView(.horizontal, showsIndicators: false) {
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
                }

                Divider()
                    .frame(height: 22)
                    .padding(.horizontal, 3)

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

                if editor.selectedTool == .text {
                    TextField("Text", text: $editor.textDraft)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 128)
                        .accessibilityLabel("Annotation text")
                }

                Divider()
                    .frame(height: 22)
                    .padding(.horizontal, 3)

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

                if editor.currentCrop != .full {
                    Button(action: editor.resetCrop) {
                        Image(systemName: "crop.rotate")
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.borderless)
                    .help("Restore full image bounds")
                }

                Button(action: editor.resetAll) {
                    Image(systemName: "arrow.counterclockwise")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.borderless)
                .disabled(!editor.hasEdits)
                .help("Reset all edits")

                Divider()
                    .frame(height: 22)
                    .padding(.horizontal, 3)

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
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color(nsColor: .controlBackgroundColor))
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
        case .crop: "Crop"
        case .arrow: "Arrow"
        case .rectangle: "Rectangle"
        case .text: "Text"
        case .mosaic: "Mosaic"
        case .counter: "Number"
        }
    }

    private func icon(for tool: ScreenshotEditingTool) -> String {
        switch tool {
        case .crop: "crop"
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .text: "character.cursor.ibeam"
        case .mosaic: "square.grid.3x3.fill"
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

private struct EditorImageCanvas: View {
    @ObservedObject var editor: CaptureEditorModel
    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Image(nsImage: editor.previewImage)
                    .resizable()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .accessibilityLabel("Screenshot editor canvas")

                draftOverlay(in: proxy.size)

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
                case .crop, .rectangle, .mosaic:
                    let rect = CGRect(
                        x: min(dragStart.x, dragCurrent.x),
                        y: min(dragStart.y, dragCurrent.y),
                        width: abs(dragCurrent.x - dragStart.x),
                        height: abs(dragCurrent.y - dragStart.y)
                    )
                    if editor.selectedTool == .mosaic {
                        context.fill(Path(rect), with: .color(color.opacity(0.18)))
                    }
                    context.stroke(
                        Path(rect),
                        with: .color(color),
                        style: StrokeStyle(
                            lineWidth: max(1.5, editor.lineWidthPoints),
                            dash: editor.selectedTool == .crop ? [7, 4] : []
                        )
                    )
                case .arrow:
                    var path = Path()
                    path.move(to: dragStart)
                    path.addLine(to: dragCurrent)
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
                case .text, .counter:
                    break
                }
            }
            .allowsHitTesting(false)
        }
    }

    private var drawsDragPreview: Bool {
        switch editor.selectedTool {
        case .crop, .arrow, .rectangle, .mosaic: true
        case .text, .counter: false
        }
    }

    private func interactionGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragStart == nil {
                    dragStart = clamped(value.startLocation, to: size)
                }
                dragCurrent = clamped(value.location, to: size)
            }
            .onEnded { value in
                let start = dragStart ?? clamped(value.startLocation, to: size)
                let end = clamped(value.location, to: size)
                editor.commitInteraction(
                    from: normalized(start, in: size),
                    to: normalized(end, in: size)
                )
                dragStart = nil
                dragCurrent = nil
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
}
