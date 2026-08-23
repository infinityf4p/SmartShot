import AppKit
import SmartShotCore
import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit

enum ScreenCaptureError: LocalizedError {
    case permissionDenied
    case noDisplay
    case selectionMustFitSingleDisplay
    case emptySelection
    case captureGeometryChanged
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Screen capture permission is required."
        case .noDisplay:
            "The selected content is not on an available display."
        case .selectionMustFitSingleDisplay:
            "The selected area must fit entirely on one available display."
        case .emptySelection:
            "The selected area is empty."
        case .captureGeometryChanged:
            "The selected area changed while it was being captured."
        case .encodingFailed:
            "The screenshot could not be encoded."
        }
    }
}

struct ScreenCaptureDisplayMatch: Equatable, Sendable {
    let displayIndex: Int
    let captureRect: CGRect
}

enum ScreenCaptureDisplayGeometry {
    static let defaultBoundaryTolerance: CGFloat = 0.5

    static func match(
        rect: CGRect,
        displayFrames: [CGRect],
        boundaryTolerance: CGFloat = defaultBoundaryTolerance
    ) -> ScreenCaptureDisplayMatch? {
        let rect = rect.standardized
        guard isFinitePositive(rect) else { return nil }
        let tolerance = boundaryTolerance.isFinite ? max(0, boundaryTolerance) : 0

        for (index, rawFrame) in displayFrames.enumerated() {
            let frame = rawFrame.standardized
            guard isFinitePositive(frame),
                  rect.minX >= frame.minX - tolerance,
                  rect.minY >= frame.minY - tolerance,
                  rect.maxX <= frame.maxX + tolerance,
                  rect.maxY <= frame.maxY + tolerance else {
                continue
            }

            // Absorb only sub-point coordinate rounding at a display edge.
            let captureRect = rect.intersection(frame)
            guard isFinitePositive(captureRect) else { continue }
            return ScreenCaptureDisplayMatch(
                displayIndex: index,
                captureRect: captureRect
            )
        }
        return nil
    }

    private static func isFinitePositive(_ rect: CGRect) -> Bool {
        [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite) &&
            rect.width > 0 && rect.height > 0 && !rect.isNull && !rect.isInfinite
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

    static func decoded(
        pngData: Data,
        logicalRect: CGRect,
        label: String
    ) throws -> CapturedImage {
        guard pngData.count >= 8,
              Array(pngData.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
              logicalRect.width.isFinite,
              logicalRect.height.isFinite,
              logicalRect.width > 0,
              logicalRect.height > 0,
              let source = CGImageSourceCreateWithData(pngData as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ScreenCaptureError.encodingFailed
        }
        return CapturedImage(
            cgImage: image,
            image: NSImage(cgImage: image, size: logicalRect.size),
            pngData: pngData,
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

        let capturableDisplays: [(screen: NSScreen, display: SCDisplay)] = NSScreen.screens.compactMap { screen in
            guard let displayID = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? CGDirectDisplayID,
                  let display = content.displays.first(where: { $0.displayID == displayID }) else {
                return nil
            }
            return (screen, display)
        }
        guard !capturableDisplays.isEmpty else { throw ScreenCaptureError.noDisplay }
        guard let displayMatch = ScreenCaptureDisplayGeometry.match(
            rect: cocoaRect,
            displayFrames: capturableDisplays.map { $0.screen.frame }
        ) else {
            throw ScreenCaptureError.selectionMustFitSingleDisplay
        }

        let display = capturableDisplays[displayMatch.displayIndex].display
        let captureRect = displayMatch.captureRect
        let quartzRect = ScreenGeometry.cocoaToQuartz(captureRect)
        let sourceRect = CGRect(
            x: quartzRect.minX - display.frame.minX,
            y: quartzRect.minY - display.frame.minY,
            width: quartzRect.width,
            height: quartzRect.height
        )

        var excludedApplications = content.applications.filter {
            $0.processID == ProcessInfo.processInfo.processIdentifier
        }
        excludedApplications.append(contentsOf: content.applications.filter {
            CaptureOcclusionPolicy.shouldIgnoreDebugTestHost(
                applicationName: $0.applicationName,
                bundleIdentifier: $0.bundleIdentifier
            )
        })
        let filter = SCContentFilter(
            display: display,
            excludingApplications: excludedApplications,
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
            logicalRect: captureRect
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
