import AppKit
import SmartShotCore
import CoreGraphics
import Foundation
import ScreenCaptureKit

enum ScreenCaptureError: LocalizedError {
    case permissionDenied
    case noDisplay
    case emptySelection
    case captureGeometryChanged
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Screen capture permission is required."
        case .noDisplay:
            "The selected content is not on an available display."
        case .emptySelection:
            "The selected area is empty."
        case .captureGeometryChanged:
            "The selected area changed while it was being captured."
        case .encodingFailed:
            "The screenshot could not be encoded."
        }
    }
}

struct CapturedImage {
    let cgImage: CGImage
    let image: NSImage
    let pngData: Data
    let logicalRect: CGRect
    let label: String

    init(
        cgImage: CGImage,
        image: NSImage,
        pngData: Data,
        logicalRect: CGRect,
        label: String
    ) {
        self.cgImage = cgImage
        self.image = image
        self.pngData = pngData
        self.logicalRect = logicalRect
        self.label = label
    }

    static func encoded(
        cgImage: CGImage,
        logicalRect: CGRect,
        label: String
    ) throws -> CapturedImage {
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw ScreenCaptureError.encodingFailed
        }
        return CapturedImage(
            cgImage: cgImage,
            image: NSImage(cgImage: cgImage, size: logicalRect.size),
            pngData: data,
            logicalRect: logicalRect,
            label: label
        )
    }
}

struct ScreenCaptureFrame: @unchecked Sendable {
    let image: CGImage
    let logicalRect: CGRect
    let scale: CGFloat
}

@MainActor
struct ScreenCaptureService {
    func capture(candidate: CaptureCandidate) async throws -> CapturedImage {
        let preparedCapture = try await prepare(rect: candidate.rect)
        let frame = try await preparedCapture.captureFrame()
        let bitmap = NSBitmapImageRep(cgImage: frame.image)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw ScreenCaptureError.encodingFailed
        }
        let image = NSImage(cgImage: frame.image, size: frame.logicalRect.size)
        return CapturedImage(
            cgImage: frame.image,
            image: image,
            pngData: data,
            logicalRect: frame.logicalRect,
            label: candidate.label
        )
    }

    func prepare(rect: CGRect) async throws -> PreparedScreenCapture {
        guard CGPreflightScreenCaptureAccess() else {
            throw ScreenCaptureError.permissionDenied
        }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        let cocoaRect = rect.standardized
        guard !cocoaRect.isEmpty else { throw ScreenCaptureError.emptySelection }

        let center = CGPoint(x: cocoaRect.midX, y: cocoaRect.midY)
        guard
            let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }),
            let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
            let display = content.displays.first(where: { $0.displayID == displayID })
        else {
            throw ScreenCaptureError.noDisplay
        }

        let clippedCocoaRect = cocoaRect.intersection(screen.frame)
        guard !clippedCocoaRect.isEmpty else { throw ScreenCaptureError.emptySelection }
        let quartzRect = ScreenGeometry.cocoaToQuartz(clippedCocoaRect)
        let sourceRect = CGRect(
            x: quartzRect.minX - display.frame.minX,
            y: quartzRect.minY - display.frame.minY,
            width: quartzRect.width,
            height: quartzRect.height
        )

        let currentApp = content.applications.filter {
            $0.processID == ProcessInfo.processInfo.processIdentifier
        }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: currentApp,
            exceptingWindows: []
        )
        let scale = CGFloat(filter.pointPixelScale)
        guard scale.isFinite, scale > 0 else { throw ScreenCaptureError.captureGeometryChanged }

        let configuration = SCStreamConfiguration()
        configuration.sourceRect = sourceRect
        configuration.width = max(1, Int((sourceRect.width * scale).rounded()))
        configuration.height = max(1, Int((sourceRect.height * scale).rounded()))
        configuration.showsCursor = false
        configuration.capturesAudio = false

        return PreparedScreenCapture(
            filter: filter,
            configuration: configuration,
            logicalRect: clippedCocoaRect
        )
    }
}

@MainActor
final class PreparedScreenCapture {
    private let filter: SCContentFilter
    private let configuration: SCStreamConfiguration
    let logicalRect: CGRect

    init(
        filter: SCContentFilter,
        configuration: SCStreamConfiguration,
        logicalRect: CGRect
    ) {
        self.filter = filter
        self.configuration = configuration
        self.logicalRect = logicalRect
    }

    func captureFrame() async throws -> ScreenCaptureFrame {
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
        guard image.width == configuration.width,
              image.height == configuration.height else {
            throw ScreenCaptureError.captureGeometryChanged
        }
        let scaleX = CGFloat(image.width) / logicalRect.width
        let scaleY = CGFloat(image.height) / logicalRect.height
        let relativeScaleDifference = abs(scaleX - scaleY) / max(scaleX, scaleY)
        guard scaleX.isFinite, scaleY.isFinite,
              relativeScaleDifference <= 0.01 else {
            throw ScreenCaptureError.captureGeometryChanged
        }
        return ScreenCaptureFrame(
            image: image,
            logicalRect: logicalRect,
            scale: (scaleX + scaleY) / 2
        )
    }
}
