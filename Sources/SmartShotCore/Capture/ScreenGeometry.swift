import AppKit
import CoreGraphics

public enum ScreenGeometry {
    public static var quartzReferenceTop: CGFloat {
        NSScreen.screens.first?.frame.maxY ?? 0
    }

    public static func cocoaToQuartz(_ point: CGPoint, referenceTop: CGFloat = quartzReferenceTop) -> CGPoint {
        CGPoint(x: point.x, y: referenceTop - point.y)
    }

    public static func quartzToCocoa(_ point: CGPoint, referenceTop: CGFloat = quartzReferenceTop) -> CGPoint {
        CGPoint(x: point.x, y: referenceTop - point.y)
    }

    public static func cocoaToQuartz(_ rect: CGRect, referenceTop: CGFloat = quartzReferenceTop) -> CGRect {
        CGRect(x: rect.minX, y: referenceTop - rect.maxY, width: rect.width, height: rect.height)
    }

    public static func quartzToCocoa(_ rect: CGRect, referenceTop: CGFloat = quartzReferenceTop) -> CGRect {
        CGRect(x: rect.minX, y: referenceTop - rect.maxY, width: rect.width, height: rect.height)
    }
}
