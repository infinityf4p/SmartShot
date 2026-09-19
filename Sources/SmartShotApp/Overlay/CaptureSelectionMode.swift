import SmartShotCore
import Foundation

enum CaptureSelectionMode: String, CaseIterable, Equatable, Sendable {
    case smart
    case region
    case long
    case appScroll

    var title: String {
        switch self {
        case .smart: L10n.text("Smart")
        case .region: L10n.text("Region")
        case .long: L10n.text("Long")
        case .appScroll: L10n.text("App Scroll")
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
        case .smart: L10n.text("Select a detected content block or drag a region")
        case .region: L10n.text("Drag a rectangular screenshot region")
        case .long: L10n.text("Drag a fixed region, then scroll its content")
        case .appScroll: L10n.text("Select an app scroll area for automatic capture")
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
