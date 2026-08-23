import Foundation

public enum ScreenshotEditingTool: String, CaseIterable, Equatable, Sendable {
    case select
    case crop
    case freehand
    case arrow
    case rectangle
    case ellipse
    case text
    case mosaic
    case blur
    case redaction
    case spotlight
    case magnifier
    case counter
}

public struct ScreenshotColor: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = min(1, max(0, red))
        self.green = min(1, max(0, green))
        self.blue = min(1, max(0, blue))
        self.alpha = min(1, max(0, alpha))
    }

    public static let red = ScreenshotColor(red: 0.95, green: 0.16, blue: 0.24)
    public static let orange = ScreenshotColor(red: 1, green: 0.48, blue: 0.08)
    public static let yellow = ScreenshotColor(red: 1, green: 0.78, blue: 0.08)
    public static let green = ScreenshotColor(red: 0.12, green: 0.72, blue: 0.36)
    public static let blue = ScreenshotColor(red: 0.08, green: 0.48, blue: 0.95)
    public static let white = ScreenshotColor(red: 1, green: 1, blue: 1)
    public static let black = ScreenshotColor(red: 0.06, green: 0.06, blue: 0.07)
}

public struct NormalizedPoint: Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = min(1, max(0, x))
        self.y = min(1, max(0, y))
    }
}

public struct NormalizedRect: Equatable, Sendable {
    public let minX: Double
    public let minY: Double
    public let maxX: Double
    public let maxY: Double

    public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        let lowerX = min(minX, maxX)
        let upperX = max(minX, maxX)
        let lowerY = min(minY, maxY)
        let upperY = max(minY, maxY)
        self.minX = min(1, max(0, lowerX))
        self.minY = min(1, max(0, lowerY))
        self.maxX = min(1, max(0, upperX))
        self.maxY = min(1, max(0, upperY))
    }

    public init(start: NormalizedPoint, end: NormalizedPoint) {
        self.init(minX: start.x, minY: start.y, maxX: end.x, maxY: end.y)
    }

    public static let full = NormalizedRect(minX: 0, minY: 0, maxX: 1, maxY: 1)

    public var width: Double { maxX - minX }
    public var height: Double { maxY - minY }
    public var isEmpty: Bool { width <= 0 || height <= 0 }

    public func pointInOriginal(fromLocal point: NormalizedPoint) -> NormalizedPoint {
        NormalizedPoint(
            x: minX + point.x * width,
            y: minY + point.y * height
        )
    }

    public func rectInOriginal(fromLocal rect: NormalizedRect) -> NormalizedRect {
        NormalizedRect(
            minX: minX + rect.minX * width,
            minY: minY + rect.minY * height,
            maxX: minX + rect.maxX * width,
            maxY: minY + rect.maxY * height
        )
    }
}

public enum ScreenshotAnnotationKind: String, Equatable, Sendable {
    case freehand
    case arrow
    case rectangle
    case ellipse
    case text
    case mosaic
    case blur
    case redaction
    case spotlight
    case magnifier
    case counter
}

public struct ScreenshotAnnotation: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let kind: ScreenshotAnnotationKind
    public let start: NormalizedPoint
    public let end: NormalizedPoint
    public let color: ScreenshotColor
    public let lineWidthPoints: Double
    public let text: String?
    public let counterValue: Int?
    public let points: [NormalizedPoint]
    public let magnification: Double

    public init(
        id: UUID = UUID(),
        kind: ScreenshotAnnotationKind,
        start: NormalizedPoint,
        end: NormalizedPoint,
        color: ScreenshotColor = .red,
        lineWidthPoints: Double = 3,
        text: String? = nil,
        counterValue: Int? = nil,
        points: [NormalizedPoint] = [],
        magnification: Double = 2
    ) {
        self.id = id
        self.kind = kind
        self.start = start
        self.end = end
        self.color = color
        self.lineWidthPoints = max(1, min(24, lineWidthPoints))
        self.text = text
        self.counterValue = counterValue
        self.points = Array(points.prefix(4_096))
        self.magnification = max(1.25, min(4, magnification))
    }

    public var bounds: NormalizedRect {
        let allPoints = points.isEmpty ? [start, end] : points + [start, end]
        return NormalizedRect(
            minX: allPoints.map(\.x).min() ?? start.x,
            minY: allPoints.map(\.y).min() ?? start.y,
            maxX: allPoints.map(\.x).max() ?? end.x,
            maxY: allPoints.map(\.y).max() ?? end.y
        )
    }

    public func translated(x deltaX: Double, y deltaY: Double) -> ScreenshotAnnotation {
        let bounds = bounds
        let safeX = min(1 - bounds.maxX, max(-bounds.minX, deltaX))
        let safeY = min(1 - bounds.maxY, max(-bounds.minY, deltaY))
        func moved(_ point: NormalizedPoint) -> NormalizedPoint {
            NormalizedPoint(x: point.x + safeX, y: point.y + safeY)
        }
        return ScreenshotAnnotation(
            id: id,
            kind: kind,
            start: moved(start),
            end: moved(end),
            color: color,
            lineWidthPoints: lineWidthPoints,
            text: text,
            counterValue: counterValue,
            points: points.map(moved),
            magnification: magnification
        )
    }
}

public struct ScreenshotEditDocument: Equatable, Sendable {
    public var crop: NormalizedRect
    public var annotations: [ScreenshotAnnotation]

    public init(
        crop: NormalizedRect = .full,
        annotations: [ScreenshotAnnotation] = []
    ) {
        self.crop = crop.isEmpty ? .full : crop
        self.annotations = annotations
    }

    public var nextCounterValue: Int {
        (annotations.compactMap(\.counterValue).max() ?? 0) + 1
    }
}

public struct ScreenshotEditHistory: Equatable, Sendable {
    public private(set) var document: ScreenshotEditDocument
    public private(set) var canUndo = false
    public private(set) var canRedo = false

    private let initialDocument: ScreenshotEditDocument
    private var undoStack: [ScreenshotEditDocument] = []
    private var redoStack: [ScreenshotEditDocument] = []
    private let maximumDepth: Int

    public init(
        document: ScreenshotEditDocument = ScreenshotEditDocument(),
        maximumDepth: Int = 100
    ) {
        self.document = document
        initialDocument = document
        self.maximumDepth = max(1, maximumDepth)
    }

    @discardableResult
    public mutating func commit(_ next: ScreenshotEditDocument) -> Bool {
        guard next != document else { return false }
        undoStack.append(document)
        if undoStack.count > maximumDepth {
            undoStack.removeFirst(undoStack.count - maximumDepth)
        }
        document = next
        redoStack.removeAll(keepingCapacity: true)
        refreshAvailability()
        return true
    }

    @discardableResult
    public mutating func undo() -> Bool {
        guard let previous = undoStack.popLast() else { return false }
        redoStack.append(document)
        document = previous
        refreshAvailability()
        return true
    }

    @discardableResult
    public mutating func redo() -> Bool {
        guard let next = redoStack.popLast() else { return false }
        undoStack.append(document)
        document = next
        refreshAvailability()
        return true
    }

    @discardableResult
    public mutating func reset() -> Bool {
        commit(initialDocument)
    }

    private mutating func refreshAvailability() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }
}
