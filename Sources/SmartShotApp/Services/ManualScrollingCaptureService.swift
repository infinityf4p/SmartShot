import AppKit
import SmartShotCore
import CoreGraphics
import Foundation

enum ManualScrollingCaptureError: LocalizedError {
    case timedOut
    case frameLimitReached
    case outputTooLarge
    case contentDidNotMove
    case unreliableOverlap

    var errorDescription: String? {
        switch self {
        case .timedOut:
            "Manual long capture reached the 5-minute session limit. Finish sooner or start a new capture."
        case .frameLimitReached:
            "This long capture needs more than 24 sections. Try a shorter region."
        case .outputTooLarge:
            "The completed long image would exceed SmartShot's safe size limit."
        case .contentDidNotMove:
            "Scroll the selected content down at least once before finishing."
        case .unreliableOverlap:
            "SmartShot could not verify a clean overlap. Scroll downward in smaller steps and pause after each step."
        }
    }
}

struct ManualScrollingCaptureConfiguration: Sendable {
    var maximumFragments = 24
    var maximumDuration: Duration = .seconds(300)
    var maximumLogicalHeight: CGFloat = 20_000
    var maximumOutputDimensionPixels = 16_384
    var maximumPixelCount = 32_000_000
    var stableFrameDelay: Duration = .milliseconds(160)
    var idlePollDelay: Duration = .milliseconds(260)
    var maximumIdleMeanAbsoluteDifference = 0.008
}

struct ManualScrollingCaptureProgress: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case preparing
        case ready
        case capturing
        case stitching
    }

    let phase: Phase
    let fragmentCount: Int
    let logicalHeight: CGFloat
    let secondsRemaining: Int?

    init(
        phase: Phase,
        fragmentCount: Int,
        logicalHeight: CGFloat,
        secondsRemaining: Int? = nil
    ) {
        self.phase = phase
        self.fragmentCount = fragmentCount
        self.logicalHeight = logicalHeight
        self.secondsRemaining = secondsRemaining
    }

    var remainingTimeText: String? {
        guard let secondsRemaining else { return nil }
        let clamped = max(0, secondsRemaining)
        return String(format: "%d:%02d left", clamped / 60, clamped % 60)
    }
}

@MainActor
final class ManualScrollingCaptureControl {
    private(set) var finishRequested = false
    private(set) var scrollAttemptCount = 0
    private var scrollTracker: ManualScrollAttemptTracker?
    private var scrollMonitor: Any?

    func finish() {
        finishRequested = true
    }

    func beginMonitoringScrollAttempts(in captureRect: CGRect) {
        endMonitoringScrollAttempts()
        finishRequested = false
        scrollAttemptCount = 0
        scrollTracker = ManualScrollAttemptTracker(captureRect: captureRect)
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let phase = event.phase
            let sample = ManualScrollEventSample(
                location: NSEvent.mouseLocation,
                verticalDelta: event.scrollingDeltaY,
                horizontalDelta: event.scrollingDeltaX,
                phaseBegan: phase.contains(.began),
                phaseChanged: phase.contains(.changed),
                phaseEnded: phase.contains(.ended) || phase.contains(.cancelled),
                hasMomentum: !event.momentumPhase.isEmpty,
                timestamp: event.timestamp
            )
            Task { @MainActor [weak self] in
                self?.recordScrollAttempt(sample)
            }
        }
    }

    func endMonitoringScrollAttempts() {
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
        }
        scrollMonitor = nil
        scrollTracker = nil
    }

    private func recordScrollAttempt(_ sample: ManualScrollEventSample) {
        guard var scrollTracker else { return }
        if scrollTracker.observe(sample) {
            scrollAttemptCount = scrollTracker.attemptCount
        }
        self.scrollTracker = scrollTracker
    }
}

@MainActor
struct ManualScrollingCaptureService {
    let configuration: ManualScrollingCaptureConfiguration
    private let screenCaptureService = ScreenCaptureService()

    init(configuration: ManualScrollingCaptureConfiguration = ManualScrollingCaptureConfiguration()) {
        self.configuration = configuration
    }

    func capture(
        rect: CGRect,
        control: ManualScrollingCaptureControl,
        progress: @escaping @MainActor (ManualScrollingCaptureProgress) -> Void
    ) async throws -> CapturedImage {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: configuration.maximumDuration)
        control.beginMonitoringScrollAttempts(in: rect)
        defer { control.endMonitoringScrollAttempts() }
        progress(
            makeProgress(
                phase: .preparing,
                fragmentCount: 0,
                logicalHeight: 0,
                deadline: deadline,
                clock: clock
            )
        )

        let preparedCapture = try await screenCaptureService.prepare(rect: rect)
        let firstFrame = try await nextStableFrame(
            preparedCapture: preparedCapture,
            deadline: deadline
        )
        try validateOutput(
            width: firstFrame.image.width,
            height: firstFrame.image.height,
            scale: firstFrame.scale
        )

        var previousFrame = firstFrame
        var fragments = [
            VerticalCaptureFragment(
                image: firstFrame.image,
                verticalOffset: 0,
                scale: firstFrame.scale
            ),
        ]
        var cumulativeScrollPixels = 0
        var fixedTopHeightPixels: Int?
        var acceptedScrollAttemptCount = control.scrollAttemptCount
        var stitchedPixelHeight = firstFrame.image.height
        progress(
            makeProgress(
                phase: .ready,
                fragmentCount: fragments.count,
                logicalHeight: CGFloat(stitchedPixelHeight) / firstFrame.scale,
                deadline: deadline,
                clock: clock
            )
        )

        while true {
            try Task.checkCancellation()
            guard clock.now < deadline else { throw ManualScrollingCaptureError.timedOut }

            let currentFrame = try await nextStableFrame(
                preparedCapture: preparedCapture,
                deadline: deadline
            )
            guard approximatelyEqual(currentFrame.scale, previousFrame.scale) else {
                throw ScreenCaptureError.captureGeometryChanged
            }

            let estimate: VerticalOverlapEstimate?
            var reachedBottom = false
            if try await framesAreVisuallyEquivalent(
                previousFrame.image,
                currentFrame.image
            ) {
                estimate = nil
                reachedBottom = ManualLongCaptureCompletionPolicy.shouldAutomaticallyFinish(
                    framesAreEquivalent: true,
                    fragmentCount: fragments.count,
                    acceptedScrollAttemptCount: acceptedScrollAttemptCount,
                    currentScrollAttemptCount: control.scrollAttemptCount
                )
            } else {
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
                } catch VerticalOverlapEstimationError.identicalImages {
                    estimate = nil
                } catch VerticalOverlapEstimationError.noReliableOverlap {
                    if control.finishRequested {
                        throw ManualScrollingCaptureError.unreliableOverlap
                    }
                    progress(
                        makeProgress(
                            phase: fragments.count > 1 ? .capturing : .ready,
                            fragmentCount: fragments.count,
                            logicalHeight: CGFloat(stitchedPixelHeight) / currentFrame.scale,
                            deadline: deadline,
                            clock: clock
                        )
                    )
                    try await Task.sleep(for: configuration.idlePollDelay)
                    continue
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw ManualScrollingCaptureError.unreliableOverlap
                }
            }

            if let estimate {
                guard fragments.count < configuration.maximumFragments else {
                    throw ManualScrollingCaptureError.frameLimitReached
                }
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
                previousFrame = currentFrame
                acceptedScrollAttemptCount = control.scrollAttemptCount
                progress(
                    makeProgress(
                        phase: .capturing,
                        fragmentCount: fragments.count,
                        logicalHeight: CGFloat(stitchedPixelHeight) / currentFrame.scale,
                        deadline: deadline,
                        clock: clock
                    )
                )
            } else {
                progress(
                    makeProgress(
                        phase: fragments.count > 1 ? .capturing : .ready,
                        fragmentCount: fragments.count,
                        logicalHeight: CGFloat(stitchedPixelHeight) / currentFrame.scale,
                        deadline: deadline,
                        clock: clock
                    )
                )
            }

            if control.finishRequested || reachedBottom {
                break
            }
            try await Task.sleep(for: configuration.idlePollDelay)
        }

        guard fragments.count > 1 else { throw ManualScrollingCaptureError.contentDidNotMove }
        try Task.checkCancellation()
        progress(
            .init(
                phase: .stitching,
                fragmentCount: fragments.count,
                logicalHeight: CGFloat(stitchedPixelHeight) / firstFrame.scale,
                secondsRemaining: nil
            )
        )

        let stitchingFragments = fragments
        let maximumPixelCount = configuration.maximumPixelCount
        let stitchingTask = Task.detached(priority: .userInitiated) {
            try VerticalImageStitcher.stitch(
                stitchingFragments,
                limits: VerticalImageStitchingLimits(maximumPixelCount: maximumPixelCount)
            )
        }
        let stitched = try await withTaskCancellationHandler {
            try await stitchingTask.value
        } onCancel: {
            stitchingTask.cancel()
        }
        try Task.checkCancellation()

        let logicalSize = stitched.layout.logicalSize
        return CapturedImage(
            cgImage: stitched.image,
            image: NSImage(cgImage: stitched.image, size: logicalSize),
            pngData: stitched.pngData,
            logicalRect: CGRect(origin: preparedCapture.logicalRect.origin, size: logicalSize),
            label: "Manual long capture"
        )
    }

    private func nextStableFrame(
        preparedCapture: PreparedScreenCapture,
        deadline: ContinuousClock.Instant
    ) async throws -> ScreenCaptureFrame {
        let clock = ContinuousClock()
        var previous = try await preparedCapture.captureFrame()
        while clock.now < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: configuration.stableFrameDelay)
            let current = try await preparedCapture.captureFrame()
            guard approximatelyEqual(previous.scale, current.scale) else {
                throw ScreenCaptureError.captureGeometryChanged
            }
            if try await framesAreVisuallyEquivalent(previous.image, current.image) {
                return current
            }
            previous = current
        }
        throw ManualScrollingCaptureError.timedOut
    }

    private func framesAreVisuallyEquivalent(
        _ first: CGImage,
        _ second: CGImage
    ) async throws -> Bool {
        let firstImage = ManualSendableCGImage(first)
        let secondImage = ManualSendableCGImage(second)
        let maximumPixelCount = configuration.maximumPixelCount
        let comparisonTask = Task.detached(priority: .userInitiated) {
            try VerticalOverlapEstimator.meanAbsoluteDifferenceAtSamePosition(
                first: firstImage.value,
                second: secondImage.value,
                horizontalInsetFraction: 0.10,
                maximumSampleRows: 64,
                maximumSampleColumns: 72,
                maximumInputPixelCount: maximumPixelCount
            )
        }
        let difference = try await withTaskCancellationHandler {
            try await comparisonTask.value
        } onCancel: {
            comparisonTask.cancel()
        }
        return difference <= configuration.maximumIdleMeanAbsoluteDifference
    }

    private func estimateOverlap(
        previous: CGImage,
        current: CGImage,
        fixedTopHeightPixels: Int
    ) async throws -> VerticalOverlapEstimate {
        let previousImage = ManualSendableCGImage(previous)
        let currentImage = ManualSendableCGImage(current)
        let bodyHeight = max(1, previous.height - fixedTopHeightPixels)
        let minimumOverlapHeight = max(24, Int(ceil(Double(bodyHeight) * 0.68)))
        let estimationTask = Task.detached(priority: .userInitiated) {
            try VerticalOverlapEstimator.estimate(
                previous: previousImage.value,
                current: currentImage.value,
                configuration: VerticalOverlapEstimatorConfiguration(
                    minimumOverlapHeightPixels: minimumOverlapHeight,
                    maximumOverlapFraction: 0.999_999,
                    horizontalInsetFraction: 0.10,
                    fixedTopHeightPixels: fixedTopHeightPixels,
                    maximumMeanAbsoluteDifference: 0.075,
                    minimumConfidence: 0.48,
                    maximumSampleRows: 160,
                    maximumSampleColumns: 128,
                    maximumInputPixelCount: 32_000_000,
                    overlapPreferenceWeight: 0.012
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
        let previousImage = ManualSendableCGImage(previous)
        let currentImage = ManualSendableCGImage(current)
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

    private func validateOutput(width: Int, height: Int, scale: CGFloat) throws {
        guard width > 0, height > 0,
              width <= configuration.maximumOutputDimensionPixels,
              height <= configuration.maximumOutputDimensionPixels,
              CGFloat(height) / scale <= configuration.maximumLogicalHeight else {
            throw ManualScrollingCaptureError.outputTooLarge
        }
        let (pixelCount, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixelCount <= configuration.maximumPixelCount else {
            throw ManualScrollingCaptureError.outputTooLarge
        }
    }

    private func makeProgress(
        phase: ManualScrollingCaptureProgress.Phase,
        fragmentCount: Int,
        logicalHeight: CGFloat,
        deadline: ContinuousClock.Instant,
        clock: ContinuousClock
    ) -> ManualScrollingCaptureProgress {
        let components = clock.now.duration(to: deadline).components
        let roundedSeconds = components.seconds + (components.attoseconds > 0 ? 1 : 0)
        return .init(
            phase: phase,
            fragmentCount: fragmentCount,
            logicalHeight: logicalHeight,
            secondsRemaining: max(0, Int(clamping: roundedSeconds))
        )
    }

    private func approximatelyEqual(_ lhs: CGFloat, _ rhs: CGFloat) -> Bool {
        abs(lhs - rhs) / max(lhs, rhs) <= 0.01
    }
}

private struct ManualSendableCGImage: @unchecked Sendable {
    let value: CGImage

    init(_ value: CGImage) {
        self.value = value
    }
}
