import Foundation

enum CaptureSelectionMode: String, CaseIterable, Equatable, Sendable {
    case smart
    case region
    case long

    var title: String {
        switch self {
        case .smart: "Smart"
        case .region: "Region"
        case .long: "Long"
        }
    }

    var systemImage: String {
        switch self {
        case .smart: "viewfinder"
        case .region: "crop"
        case .long: "rectangle.vertical.badge.plus"
        }
    }

    var accessibilityHelp: String {
        switch self {
        case .smart: "Select a detected content block or drag a region"
        case .region: "Drag a rectangular screenshot region"
        case .long: "Drag a fixed region, then scroll its content"
        }
    }
}
