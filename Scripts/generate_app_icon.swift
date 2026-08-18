import AppKit
import Foundation

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let extensionOutputDirectory = CommandLine.arguments.count > 2
    ? URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    : nil
let variants: [(String, Int)] = [
    ("icon_16.png", 16), ("icon_16@2x.png", 32),
    ("icon_32.png", 32), ("icon_32@2x.png", 64),
    ("icon_128.png", 128), ("icon_128@2x.png", 256),
    ("icon_256.png", 256), ("icon_256@2x.png", 512),
    ("icon_512.png", 512), ("icon_512@2x.png", 1024)
]

func render(size: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: size * 4,
        bitsPerPixel: 32
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw CocoaError(.fileWriteUnknown)
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }

    let scale = CGFloat(size) / 1024
    let canvas = NSRect(x: 0, y: 0, width: size, height: size)
    NSColor(red: 0.969, green: 0.980, blue: 0.988, alpha: 1).setFill()
    canvas.fill()

    let tile = NSRect(x: 92 * scale, y: 92 * scale, width: 840 * scale, height: 840 * scale)
    NSColor(red: 0.118, green: 0.227, blue: 0.373, alpha: 1).setFill()
    NSBezierPath(roundedRect: tile, xRadius: 190 * scale, yRadius: 190 * scale).fill()

    let corners = NSBezierPath()
    corners.lineWidth = 62 * scale
    corners.lineCapStyle = .round
    corners.lineJoinStyle = .round

    corners.move(to: NSPoint(x: 432 * scale, y: 708 * scale))
    corners.line(to: NSPoint(x: 390 * scale, y: 708 * scale))
    corners.appendArc(withCenter: NSPoint(x: 390 * scale, y: 650 * scale), radius: 58 * scale, startAngle: 90, endAngle: 180)
    corners.line(to: NSPoint(x: 332 * scale, y: 592 * scale))

    corners.move(to: NSPoint(x: 592 * scale, y: 708 * scale))
    corners.line(to: NSPoint(x: 634 * scale, y: 708 * scale))
    corners.appendArc(withCenter: NSPoint(x: 634 * scale, y: 650 * scale), radius: 58 * scale, startAngle: 90, endAngle: 0, clockwise: true)
    corners.line(to: NSPoint(x: 692 * scale, y: 592 * scale))

    corners.move(to: NSPoint(x: 692 * scale, y: 432 * scale))
    corners.line(to: NSPoint(x: 692 * scale, y: 390 * scale))
    corners.appendArc(withCenter: NSPoint(x: 634 * scale, y: 390 * scale), radius: 58 * scale, startAngle: 0, endAngle: -90, clockwise: true)
    corners.line(to: NSPoint(x: 592 * scale, y: 332 * scale))

    corners.move(to: NSPoint(x: 432 * scale, y: 332 * scale))
    corners.line(to: NSPoint(x: 390 * scale, y: 332 * scale))
    corners.appendArc(withCenter: NSPoint(x: 390 * scale, y: 390 * scale), radius: 58 * scale, startAngle: -90, endAngle: -180, clockwise: true)
    corners.line(to: NSPoint(x: 332 * scale, y: 432 * scale))

    NSColor.white.setStroke()
    corners.stroke()

    NSColor(red: 0.020, green: 0.588, blue: 0.412, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 700 * scale, y: 700 * scale, width: 122 * scale, height: 122 * scale)).fill()

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    return data
}

try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
for (name, size) in variants {
    try render(size: size).write(to: outputDirectory.appendingPathComponent(name), options: .atomic)
}

if let extensionOutputDirectory {
    try FileManager.default.createDirectory(at: extensionOutputDirectory, withIntermediateDirectories: true)
    for size in [16, 32, 128] {
        try render(size: size).write(
            to: extensionOutputDirectory.appendingPathComponent("icon_\(size).png"),
            options: .atomic
        )
    }
}
