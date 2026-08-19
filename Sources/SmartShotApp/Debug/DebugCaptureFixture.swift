#if DEBUG
import AppKit
import CoreGraphics

enum DebugCaptureFixture {
    static func makeEditorCapture() throws -> CapturedImage {
        let width = 1_400
        let height = 900
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw ScreenCaptureError.encodingFailed
        }

        context.setFillColor(CGColor(red: 0.96, green: 0.97, blue: 0.98, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        context.setFillColor(CGColor(red: 0.11, green: 0.13, blue: 0.16, alpha: 1))
        context.fill(CGRect(x: 0, y: 720, width: width, height: 180))

        let colors = [
            CGColor(red: 0.93, green: 0.25, blue: 0.30, alpha: 1),
            CGColor(red: 0.12, green: 0.55, blue: 0.92, alpha: 1),
            CGColor(red: 0.14, green: 0.68, blue: 0.42, alpha: 1),
        ]
        for (index, color) in colors.enumerated() {
            let x = 90 + index * 430
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: x, y: 165, width: 350, height: 450))
            context.setFillColor(color)
            context.fill(CGRect(x: x, y: 500, width: 350, height: 115))

            context.setFillColor(CGColor(gray: 0.82, alpha: 1))
            for row in 0..<5 {
                context.fill(
                    CGRect(
                        x: x + 32,
                        y: 430 - row * 55,
                        width: row.isMultiple(of: 2) ? 285 : 225,
                        height: 18
                    )
                )
            }
        }

        context.setStrokeColor(CGColor(gray: 0.72, alpha: 1))
        context.setLineWidth(3)
        context.stroke(CGRect(x: 45, y: 95, width: 1_310, height: 590))

        guard let image = context.makeImage() else {
            throw ScreenCaptureError.encodingFailed
        }
        return try CapturedImage.encoded(
            cgImage: image,
            logicalRect: CGRect(x: 0, y: 0, width: 700, height: 450),
            label: "Editor fixture"
        )
    }
}
#endif
