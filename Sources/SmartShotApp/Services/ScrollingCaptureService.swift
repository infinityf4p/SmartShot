import AppKit
import SmartShotCore
import CoreGraphics
import Foundation

enum ScrollingCaptureError: LocalizedError {
    case timedOut
    case frameLimitReached
    case outputTooLarge
    case contentDidNotMove
    case contentChanged
    case unreliableOverlap
    case couldNotReachEnd
    case restoreFailed

    var errorDescription: String? {
        switch self {
        case .timedOut:
            "Scrolling capture took too long. The original scroll position was restored."
        case .frameLimitReached:
            "This scroll area needs more than 24 images. Try a shorter area."
        case .outputTooLarge:
            "The completed image would exceed SmartShot's safe size limit."
        case .contentDidNotMove:
            "This application did not expose reliable scrolling progress."
        case .contentChanged:
            "The content changed while it was being captured. Try again after it becomes still."
        case .unreliableOverlap:
            "SmartShot could not verify a clean overlap between two sections."
        case .couldNotReachEnd:
            "SmartShot could not verify the end of this scroll area."
        case .restoreFailed:
            "The screenshot stopped, but the application's original scroll position could not be restored."
        }
    }
}

struct ScrollingCaptureConfiguration: Sendable {
    var maximumFragments = 24
    var maximumDuration: Duration = .seconds(75)
    var maximumLogicalHeight: CGFloat = 20_000
    var maximumOutputDimensionPixels = 16_384
    var maximumPixelCount = 32_000_000
    var initialStepFraction = 0.08
    var targetScrollFraction = 0.72
    var settleDelay: Duration = .milliseconds(180)
    var maximumIdleMeanAbsoluteDifference = 0.008
}

@MainActor
struct ScrollingCaptureService {
    let configuration: ScrollingCaptureConfiguration
    private let screenCaptureService = ScreenCaptureService()

    init(configuration: ScrollingCaptureConfiguration = ScrollingCaptureConfiguration()) {
        self.configuration = configuration
    }

    func capture(
        target: AccessibilityScrollCaptureTarget,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> CapturedImage {
        do {
            let capture = try await performCapture(target: target, progress: progress)
            try await restore(target)
            try Task.checkCancellation()
            progress(1)
            return capture
        } catch {
            let captureError = error
            do {
                try await restore(target)
            } catch {
                throw ScrollingCaptureError.restoreFailed
            }
            throw captureError
        }
    }

    private func performCapture(
        target: AccessibilityScrollCaptureTarget,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> CapturedImage {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: configuration.maximumDuration)
        let range = target.maximumValue - target.minimumValue
        let valueTolerance = max(0.000_001, range * 0.000_1)
        let minimumStep = max(range / 4096, valueTolerance * 4)

        try Task.checkCancellation()
        try target.validate()
        let firstValue = try await setAndSettle(target, value: target.minimumValue)
        guard abs(firstValue - target.minimumValue) <= valueTolerance * 4 else {
            throw ScrollingCaptureError.contentDidNotMove
        }

        try target.validate()
        let preparedCapture = try await screenCaptureService.prepare(rect: target.captureAppKitFrame)
        var previousFrame = try await preparedCapture.captureFrame()
        try await pause(configuration.settleDelay / 2)
        try target.validate()
        let stabilityFrame = try await preparedCapture.captureFrame()
        try await requireVisuallyEquivalent(previousFrame.image, stabilityFrame.image)
        previousFrame = stabilityFrame

        guard previousFrame.image.width <= configuration.maximumOutputDimensionPixels,
              previousFrame.image.height <= configuration.maximumOutputDimensionPixels else {
            throw ScrollingCaptureError.outputTooLarge
        }

        var fragments = [
            VerticalCaptureFragment(
                image: previousFrame.image,
                verticalOffset: 0,
                scale: previousFrame.scale
            ),
        ]
        var stitchedPixelHeight = previousFrame.image.height
        try validateOutput(width: previousFrame.image.width, height: stitchedPixelHeight, scale: previousFrame.scale)

        var previousValue = firstValue
        var step = max(minimumStep, range * configuration.initialStepFraction)
        var cumulativeScrollPixels = 0
        var fixedTopHeightPixels: Int?
        var overlapRetries = 0
        progress(0.04)

        while true {
            try Task.checkCancellation()
            guard clock.now < deadline else { throw ScrollingCaptureError.timedOut }
            try target.validate()

            if abs(previousValue - target.maximumValue) <= valueTolerance {
                try await verifyEnd(
                    target: target,
                    preparedCapture: preparedCapture,
                    previousImage: previousFrame.image
                )
                break
            }
            guard fragments.count < configuration.maximumFragments else {
                throw ScrollingCaptureError.frameLimitReached
            }

            let requestedValue = min(target.maximumValue, previousValue + step)
            let settledValue = try await setAndSettle(target, value: requestedValue)
            guard settledValue > previousValue + valueTolerance else {
                throw ScrollingCaptureError.contentDidNotMove
            }
            guard abs(settledValue - requestedValue) <= max(valueTolerance * 8, step * 0.15) else {
                throw AccessibilityScrollTargetError.targetChanged
            }

            try target.validate()
            let currentFrame = try await preparedCapture.captureFrame()
            guard let valueAfterCapture = target.currentValue(),
                  abs(valueAfterCapture - settledValue) <= valueTolerance * 4 else {
                throw AccessibilityScrollTargetError.targetChanged
            }
            let estimate: VerticalOverlapEstimate
            do {
                if fixedTopHeightPixels == nil {
                    fixedTopHeightPixels = try await detectFixedTop(
                        previous: previousFrame.image,
                        current: currentFrame.image
                    )
                }
                let fixedTop = fixedTopHeightPixels ?? 0
                do {
                    estimate = try await estimateOverlap(
                        previous: previousFrame.image,
                        current: currentFrame.image,
                        fixedTopHeightPixels: fixedTop
                    )
                } catch VerticalOverlapEstimationError.noReliableOverlap where fixedTop > 0 {
                    fixedTopHeightPixels = 0
                    estimate = try await estimateOverlap(
                        previous: previousFrame.image,
                        current: currentFrame.image,
                        fixedTopHeightPixels: 0
                    )
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch VerticalOverlapEstimationError.identicalImages {
                throw ScrollingCaptureError.contentDidNotMove
            } catch VerticalOverlapEstimationError.noReliableOverlap {
                try await rollback(target, value: previousValue)
                step /= 2
                overlapRetries += 1
                guard step >= minimumStep, overlapRetries <= 7 else {
                    throw ScrollingCaptureError.unreliableOverlap
                }
                continue
            } catch {
                throw ScrollingCaptureError.unreliableOverlap
            }

            overlapRetries = 0
            cumulativeScrollPixels += estimate.scrollDeltaPixels
            stitchedPixelHeight += estimate.addedHeightPixels
            try validateOutput(
                width: currentFrame.image.width,
                height: stitchedPixelHeight,
                scale: currentFrame.scale
            )
            fragments.append(
                VerticalCaptureFragment(
                    image: currentFrame.image,
                    verticalOffset: CGFloat(
                        (fixedTopHeightPixels ?? 0) + cumulativeScrollPixels
                    ) / currentFrame.scale,
                    scale: currentFrame.scale,
                    sourceTopInsetPixels: estimate.currentSourceTopInsetPixels
                )
            )

            let targetScrollPixels = Double(currentFrame.image.height) * configuration.targetScrollFraction
            let adjustment = min(2, max(0.5, targetScrollPixels / Double(estimate.scrollDeltaPixels)))
            step = min(range * 0.35, max(minimumStep, step * adjustment))
            previousFrame = currentFrame
            previousValue = settledValue
            progress(min(0.94, max(0.05, (settledValue - target.minimumValue) / range)))
        }

        guard fragments.count > 1 else { throw ScrollingCaptureError.contentDidNotMove }
        try Task.checkCancellation()
        let fragmentsForStitching = fragments
        let pixelLimit = configuration.maximumPixelCount
        let stitchTask = Task.detached(priority: .userInitiated) {
            try VerticalImageStitcher.stitch(
                fragmentsForStitching,
                limits: VerticalImageStitchingLimits(maximumPixelCount: pixelLimit)
            )
        }
        let stitched = try await withTaskCancellationHandler {
            try await stitchTask.value
        } onCancel: {
            stitchTask.cancel()
        }
        try Task.checkCancellation()
        let logicalSize = stitched.layout.logicalSize
        return CapturedImage(
            cgImage: stitched.image,
            image: NSImage(cgImage: stitched.image, size: logicalSize),
            pngData: stitched.pngData,
            logicalRect: CGRect(origin: target.captureAppKitFrame.origin, size: logicalSize),
            label: "Scrolling capture"
        )
    }

    private func setAndSettle(
        _ target: AccessibilityScrollCaptureTarget,
        value: Double
    ) async throws -> Double {
        try target.setValue(value)
        let range = target.maximumValue - target.minimumValue
        let tolerance = max(0.000_001, range * 0.000_1)
        var previous: Double?
        var stableReadCount = 0

        for _ in 0..<24 {
            try Task.checkCancellation()
            try await pause(.milliseconds(25))
            guard let current = target.currentValue(), current.isFinite else {
                throw AccessibilityScrollTargetError.targetChanged
            }
            if let previous, abs(previous - current) <= tolerance {
                stableReadCount += 1
                if stableReadCount >= 2 {
                    try await pause(configuration.settleDelay)
                    return current
                }
            } else {
                stableReadCount = 0
            }
            previous = current
        }
        throw AccessibilityScrollTargetError.targetChanged
    }

    private func rollback(_ target: AccessibilityScrollCaptureTarget, value: Double) async throws {
        _ = try await setAndSettle(target, value: value)
        try target.validate()
    }

    private func verifyEnd(
        target: AccessibilityScrollCaptureTarget,
        preparedCapture: PreparedScreenCapture,
        previousImage: CGImage
    ) async throws {
        let finalValue = try await setAndSettle(target, value: target.maximumValue)
        let tolerance = max(
            0.000_001,
            (target.maximumValue - target.minimumValue) * 0.000_1
        )
        guard abs(finalValue - target.maximumValue) <= tolerance * 4 else {
            throw ScrollingCaptureError.couldNotReachEnd
        }
        try target.validate()
        let confirmation = try await preparedCapture.captureFrame()
        do {
            try await requireVisuallyEquivalent(previousImage, confirmation.image)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ScrollingCaptureError.contentChanged
        }
    }

    private func restore(_ target: AccessibilityScrollCaptureTarget) async throws {
        try target.setValue(target.originalValue)
        await pauseIgnoringCancellation(.milliseconds(100))
        guard let restoredValue = target.currentValue() else {
            throw ScrollingCaptureError.restoreFailed
        }
        let tolerance = max(
            0.000_001,
            (target.maximumValue - target.minimumValue) * 0.001
        )
        guard abs(restoredValue - target.originalValue) <= tolerance else {
            throw ScrollingCaptureError.restoreFailed
        }
    }

    private func validateOutput(width: Int, height: Int, scale: CGFloat) throws {
        guard width > 0, height > 0,
              width <= configuration.maximumOutputDimensionPixels,
              height <= configuration.maximumOutputDimensionPixels,
              CGFloat(height) / scale <= configuration.maximumLogicalHeight else {
            throw ScrollingCaptureError.outputTooLarge
        }
        let (pixelCount, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixelCount <= configuration.maximumPixelCount else {
            throw ScrollingCaptureError.outputTooLarge
        }
    }

    private func estimateOverlap(
        previous: CGImage,
        current: CGImage,
        fixedTopHeightPixels: Int = 0
    ) async throws -> VerticalOverlapEstimate {
        let previousImage = SendableCGImage(previous)
        let currentImage = SendableCGImage(current)
        let estimationTask = Task.detached(priority: .userInitiated) {
            try VerticalOverlapEstimator.estimate(
                previous: previousImage.value,
                current: currentImage.value,
                configuration: VerticalOverlapEstimatorConfiguration(
                    minimumOverlapHeightPixels: 24,
                    maximumOverlapFraction: 0.999_999,
                    horizontalInsetFraction: 0.10,
                    fixedTopHeightPixels: fixedTopHeightPixels,
                    maximumMeanAbsoluteDifference: 0.025,
                    minimumConfidence: 0.84,
                    minimumUniqueness: 0.08,
                    maximumSampleRows: 64,
                    maximumSampleColumns: 72,
                    maximumInputPixelCount: 32_000_000
                )
            )
        }
        return try await withTaskCancellationHandler {
            try await estimationTask.value
        } onCancel: {
            estimationTask.cancel()
        }
    }

    private func detectFixedTop(previous: CGImage, current: CGImage) async throws -> Int {
        let previousImage = SendableCGImage(previous)
        let currentImage = SendableCGImage(current)
        let detectionTask = Task.detached(priority: .userInitiated) {
            try VerticalFixedTopDetector.detect(
                previous: previousImage.value,
                current: currentImage.value
            )
        }
        return try await withTaskCancellationHandler {
            try await detectionTask.value
        } onCancel: {
            detectionTask.cancel()
        }
    }

    private func requireVisuallyEquivalent(_ first: CGImage, _ second: CGImage) async throws {
        let firstImage = SendableCGImage(first)
        let secondImage = SendableCGImage(second)
        let pixelLimit = configuration.maximumPixelCount
        let comparisonTask = Task.detached(priority: .userInitiated) {
            try VerticalOverlapEstimator.meanAbsoluteDifferenceAtSamePosition(
                first: firstImage.value,
                second: secondImage.value,
                horizontalInsetFraction: 0.10,
                maximumSampleRows: 64,
                maximumSampleColumns: 72,
                maximumInputPixelCount: pixelLimit
            )
        }
        do {
            let difference = try await withTaskCancellationHandler {
                try await comparisonTask.value
            } onCancel: {
                comparisonTask.cancel()
            }
            guard difference <= configuration.maximumIdleMeanAbsoluteDifference else {
                throw ScrollingCaptureError.contentChanged
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ScrollingCaptureError {
            throw error
        } catch {
            throw ScrollingCaptureError.contentChanged
        }
    }

    private func pause(_ duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }

    private func pauseIgnoringCancellation(_ duration: Duration) async {
        await Task.detached {
            try? await Task.sleep(for: duration)
        }.value
    }

}

private struct SendableCGImage: @unchecked Sendable {
    let value: CGImage

    init(_ value: CGImage) {
        self.value = value
    }
}
