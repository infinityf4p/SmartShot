import CoreGraphics
import Foundation

public struct CaptureCandidate: Identifiable, Equatable, Sendable {
    public enum Source: String, Sendable {
        case accessibility
        case webDOM
        case window
        case manual
    }

    public let id: UUID
    public let rect: CGRect
    public let source: Source
    public let label: String
    public let level: Int

    public init(
        id: UUID = UUID(),
        rect: CGRect,
        source: Source,
        label: String,
        level: Int = 0
    ) {
        self.id = id
        self.rect = rect.standardized
        self.source = source
        self.label = label
        self.level = level
    }
}
