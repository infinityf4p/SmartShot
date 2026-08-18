import CoreGraphics

enum CaptureOcclusionPolicy {
    static func shouldIgnoreSystemWindow(
        ownerName: String?,
        layer: Int,
        frame: CGRect,
        captureFrame: CGRect
    ) -> Bool {
        if ownerName == "Dock", layer == 20, frame.contains(captureFrame) {
            return true
        }
        return ownerName == "Window Server" &&
            layer == Int(CGWindowLevelForKey(.cursorWindow))
    }
}
