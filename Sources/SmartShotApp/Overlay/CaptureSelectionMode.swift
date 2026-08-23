import Foundation

enum CaptureSelectionMode: String, CaseIterable, Equatable, Sendable {
    case smart
    case region
    case long
    case appScroll

    var title: String {
        switch self {
        case .smart: "Smart"
        case .region: "Region"
        case .long: "Long"
        case .appScroll: "App Scroll"
        }
    }

    var systemImage: String {
        switch self {
        case .smart: "viewfinder"
        case .region: "crop"
        case .long: "rectangle.vertical.badge.plus"
        case .appScroll: "rectangle.and.hand.point.up.left"
        }
    }

    var accessibilityHelp: String {
        switch self {
        case .smart: "Select a detected content block or drag a region"
        case .region: "Drag a rectangular screenshot region"
        case .long: "Drag a fixed region, then scroll its content"
        case .appScroll: "Select an app scroll area for automatic capture"
        }
    }
}

extension CaptureSelectionMode {
    init(commandMode: SmartShotCaptureMode) {
        switch commandMode {
        case .smart: self = .smart
        case .region: self = .region
        case .long: self = .long
        case .appScroll: self = .appScroll
        }
    }
}
