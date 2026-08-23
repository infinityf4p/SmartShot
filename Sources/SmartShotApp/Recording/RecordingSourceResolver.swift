import AppKit
import CoreGraphics
import CoreVideo
import Foundation
import ScreenCaptureKit

struct ResolvedRecordingSource: @unchecked Sendable {
    let filter: SCContentFilter
    let sourceSize: CGSize
    let sourceRect: CGRect?
    let pointPixelScale: CGFloat
}

enum RecordingRegionValidator {
    static func validated(
        _ rect: CGRect,
        within displaySize: CGSize
    ) throws -> CGRect {
        let standardized = rect.standardized
        guard standardized.minX.isFinite,
              standardized.minY.isFinite,
              standardized.width.isFinite,
              standardized.height.isFinite,
              standardized.width > 0,
              standardized.height > 0,
              displaySize.width.isFinite,
              displaySize.height.isFinite,
              displaySize.width > 0,
              displaySize.height > 0 else {
            throw ScreenRecordingError.invalidSourceGeometry
        }

        let displayBounds = CGRect(origin: .zero, size: displaySize)
        guard displayBounds.contains(standardized) else {
            throw ScreenRecordingError.invalidSourceGeometry
        }
        return standardized
    }
}

@MainActor
struct RecordingSourceResolver {
    func resolve(_ source: RecordingSource) async throws -> ResolvedRecordingSource {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let display = content.displays.first(where: { $0.displayID == source.displayID }) else {
            throw ScreenRecordingError.displayUnavailable
        }

        let excludedApplications = content.applications.filter {
            $0.processID == ProcessInfo.processInfo.processIdentifier
        }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: excludedApplications,
            exceptingWindows: []
        )
        let scale = CGFloat(filter.pointPixelScale)
        guard scale.isFinite, scale > 0 else {
            throw ScreenRecordingError.invalidSourceGeometry
        }

        switch source {
        case .display:
            guard display.frame.width.isFinite,
                  display.frame.height.isFinite,
                  display.frame.width > 0,
                  display.frame.height > 0 else {
                throw ScreenRecordingError.invalidSourceGeometry
            }
            return ResolvedRecordingSource(
                filter: filter,
                sourceSize: display.frame.size,
                sourceRect: nil,
                pointPixelScale: scale
            )

        case let .region(_, displayLocalRect):
            let rect = try RecordingRegionValidator.validated(
                displayLocalRect,
                within: display.frame.size
            )
            return ResolvedRecordingSource(
                filter: filter,
                sourceSize: rect.size,
                sourceRect: rect,
                pointPixelScale: scale
            )
        }
    }
}

enum RecordingStreamConfigurationFactory {
    static func make(
        resolvedSource: ResolvedRecordingSource,
        videoPlan: RecordingVideoPlan,
        options: RecordingOptions
    ) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = videoPlan.width
        configuration.height = videoPlan.height
        configuration.minimumFrameInterval = videoPlan.minimumFrameInterval
        configuration.queueDepth = 5
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.showsCursor = options.showsCursor
        configuration.capturesAudio = options.capturesSystemAudio
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = true
        configuration.captureResolution = .best
        configuration.streamName = "SmartShot Recording"
        if let sourceRect = resolvedSource.sourceRect {
            configuration.sourceRect = sourceRect
        }
        return configuration
    }
}
