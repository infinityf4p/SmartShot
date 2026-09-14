import AVFoundation
import CoreVideo
import ImageIO
import XCTest

final class RecordingMediaExportIntegrationTests: XCTestCase {
    func testOfflineMP4AndGIFExport() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SmartShotRecordingMediaExportTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let rawURL = root.appendingPathComponent("source.mov")
        let mp4URL = root.appendingPathComponent("export.mp4")
        let gifURL = root.appendingPathComponent("export.gif")
        try await makeTestVideo(at: rawURL)

        let metadata = try await RecordingMP4Exporter.export(
            rawRecordingURL: rawURL,
            destinationURL: mp4URL
        )
        XCTAssertEqual(metadata.pixelSize, CGSize(width: 64, height: 48))
        XCTAssertGreaterThan(metadata.duration, 0)

        let result = try await GIFExportService.export(
            videoURL: mp4URL,
            destinationURL: gifURL,
            options: GIFExportOptions(maximumDuration: 1, frameRate: 4, maximumLongEdge: 64)
        )
        XCTAssertEqual(result, gifURL)
        guard let source = CGImageSourceCreateWithURL(gifURL as CFURL, nil) else {
            XCTFail("The exported GIF could not be opened.")
            return
        }
        XCTAssertGreaterThan(CGImageSourceGetCount(source), 1)
        XCTAssertLessThanOrEqual(CGImageSourceGetCount(source), 4)
    }

    func testEncodedGIFPreservesDurationAtFractionalFrameDelays() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SmartShotGIFTimingTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let videoURL = root.appendingPathComponent("source.mov")
        try await makeTestVideo(at: videoURL)
        let sourceDuration = try await AVURLAsset(url: videoURL).load(.duration)
        for (frameRate, maximumDuration) in [(15, 1.0), (15, 0.73), (10, 0.71)] {
            let gifURL = root.appendingPathComponent("\(frameRate)-\(maximumDuration).gif")
            _ = try await GIFExportService.export(
                videoURL: videoURL,
                destinationURL: gifURL,
                options: GIFExportOptions(
                    maximumDuration: maximumDuration,
                    frameRate: frameRate,
                    maximumLongEdge: 64
                )
            )
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(gifURL as CFURL, nil))
            var encodedDuration: TimeInterval = 0
            for index in 0..<CGImageSourceGetCount(source) {
                XCTAssertNotNil(CGImageSourceCreateImageAtIndex(source, index, nil))
                let properties = try XCTUnwrap(
                    CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
                )
                let gifProperties = try XCTUnwrap(
                    properties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
                )
                let delay = try XCTUnwrap(
                    gifProperties[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber
                ).doubleValue
                XCTAssertGreaterThanOrEqual(delay, 0.02)
                encodedDuration += delay
            }
            XCTAssertEqual(
                encodedDuration,
                min(CMTimeGetSeconds(sourceDuration), maximumDuration),
                accuracy: 0.005,
                "GIF timing drifted at \(frameRate) fps with a \(maximumDuration)-second limit."
            )
        }
    }

    private func makeTestVideo(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 64,
                AVVideoHeightKey: 48
            ]
        )
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 64,
                kCVPixelBufferHeightKey as String: 48
            ]
        )
        guard writer.canAdd(input) else {
            throw MediaFixtureError.cannotConfigureWriter
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? MediaFixtureError.cannotConfigureWriter
        }
        writer.startSession(atSourceTime: .zero)

        for frameIndex in 0..<8 {
            try await waitUntilReady(input)
            guard let pool = adaptor.pixelBufferPool else {
                throw MediaFixtureError.cannotCreatePixelBuffer
            }
            var optionalBuffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &optionalBuffer) == kCVReturnSuccess,
                  let buffer = optionalBuffer else {
                throw MediaFixtureError.cannotCreatePixelBuffer
            }
            fill(buffer, frameIndex: frameIndex)
            guard adaptor.append(
                buffer,
                withPresentationTime: CMTime(value: CMTimeValue(frameIndex), timescale: 8)
            ) else {
                throw writer.error ?? MediaFixtureError.cannotAppendFrame
            }
        }

        input.markAsFinished()
        let box = MediaFixtureWriterBox(writer)
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            box.writer.finishWriting {
                if box.writer.status == .completed {
                    continuation.resume()
                } else {
                    continuation.resume(
                        throwing: box.writer.error ?? MediaFixtureError.cannotFinishWriter
                    )
                }
            }
        }
    }

    private func waitUntilReady(_ input: AVAssetWriterInput) async throws {
        for _ in 0..<1_000 {
            if input.isReadyForMoreMediaData {
                return
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw MediaFixtureError.encoderBackPressure
    }

    private func fill(_ buffer: CVPixelBuffer, frameIndex: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else { return }

        let pixel = baseAddress.assumingMemoryBound(to: UInt32.self)
        let pixelsPerRow = CVPixelBufferGetBytesPerRow(buffer) / MemoryLayout<UInt32>.size
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let blue = UInt32(frameIndex * 24)
        let color = UInt32(0xFF_40_80_00) | blue
        for row in 0..<height {
            for column in 0..<width {
                pixel[(row * pixelsPerRow) + column] = color
            }
        }
    }
}

private enum MediaFixtureError: Error {
    case cannotConfigureWriter
    case encoderBackPressure
    case cannotCreatePixelBuffer
    case cannotAppendFrame
    case cannotFinishWriter
}

private final class MediaFixtureWriterBox: @unchecked Sendable {
    let writer: AVAssetWriter

    init(_ writer: AVAssetWriter) {
        self.writer = writer
    }
}
