import AppKit
import SmartShotCore
import CoreGraphics

struct MappedRecordingSource: Equatable, Sendable {
    let source: RecordingSource
    let appKitRect: CGRect
}

enum RecordingSourceMapper {
    @MainActor
    static func region(from appKitRect: CGRect) throws -> MappedRecordingSource {
        let standardized = appKitRect.standardized
        let center = CGPoint(x: standardized.midX, y: standardized.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }),
              let displayNumber = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
              ] as? NSNumber else {
            throw ScreenRecordingError.displayUnavailable
        }
        return try mapRegion(
            appKitRect: standardized,
            screenFrame: screen.frame,
            displayID: CGDirectDisplayID(displayNumber.uint32Value),
            quartzReferenceTop: ScreenGeometry.quartzReferenceTop
        )
    }

    @MainActor
    static func display(containing appKitPoint: CGPoint) throws -> MappedRecordingSource {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(appKitPoint) }),
              let displayNumber = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
              ] as? NSNumber else {
            throw ScreenRecordingError.displayUnavailable
        }
        return MappedRecordingSource(
            source: .display(displayID: CGDirectDisplayID(displayNumber.uint32Value)),
            appKitRect: screen.frame
        )
    }

    static func mapRegion(
        appKitRect: CGRect,
        screenFrame: CGRect,
        displayID: CGDirectDisplayID,
        quartzReferenceTop: CGFloat
    ) throws -> MappedRecordingSource {
        let selection = appKitRect.standardized
        let displayFrame = screenFrame.standardized
        guard selection.minX.isFinite,
              selection.minY.isFinite,
              selection.width.isFinite,
              selection.height.isFinite,
              selection.width >= 2,
              selection.height >= 2,
              displayFrame.minX.isFinite,
              displayFrame.minY.isFinite,
              displayFrame.width.isFinite,
              displayFrame.height.isFinite,
              displayFrame.width >= 2,
              displayFrame.height >= 2,
              displayFrame.contains(selection) else {
            throw ScreenRecordingError.invalidSourceGeometry
        }

        let quartzRect = ScreenGeometry.cocoaToQuartz(
            selection,
            referenceTop: quartzReferenceTop
        )
        let displayQuartzRect = ScreenGeometry.cocoaToQuartz(
            displayFrame,
            referenceTop: quartzReferenceTop
        )
        let localRect = CGRect(
            x: quartzRect.minX - displayQuartzRect.minX,
            y: quartzRect.minY - displayQuartzRect.minY,
            width: quartzRect.width,
            height: quartzRect.height
        )
        let validated = try RecordingRegionValidator.validated(
            localRect,
            within: displayFrame.size
        )
        return MappedRecordingSource(
            source: .region(displayID: displayID, displayLocalRect: validated),
            appKitRect: selection
        )
    }
}
