import SmartShotCore
import AppKit
import Foundation
import UniformTypeIdentifiers

enum CaptureOutputFormat: String, CaseIterable, Identifiable, Sendable {
    case png
    case jpeg

    var id: String { rawValue }

    var title: String {
        switch self {
        case .png: "PNG"
        case .jpeg: "JPEG"
        }
    }

    var fileExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        }
    }

    var contentType: UTType {
        switch self {
        case .png: .png
        case .jpeg: .jpeg
        }
    }
}

enum CaptureFilenameStyle: String, CaseIterable, Identifiable, Sendable {
    case smartShotTimestamp
    case labelTimestamp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .smartShotTimestamp: L10n.text("SmartShot + time")
        case .labelTimestamp: L10n.text("Content + time")
        }
    }
}

enum CaptureOutputServiceError: LocalizedError {
    case encodingFailed
    case noPicturesDirectory

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            L10n.text("The screenshot could not be encoded in the selected format.")
        case .noPicturesDirectory:
            L10n.text("A default screenshot folder could not be resolved.")
        }
    }
}

enum CaptureOutputService {
    static func encodedData(
        for capture: CapturedImage,
        format: CaptureOutputFormat,
        jpegQuality: Double = 0.9
    ) throws -> Data {
        if format == .png { return capture.pngData }
        let bitmap = NSBitmapImageRep(cgImage: capture.cgImage)
        guard let data = bitmap.representation(
            using: .jpeg,
            properties: [.compressionFactor: min(1, max(0.1, jpegQuality))]
        ) else {
            throw CaptureOutputServiceError.encodingFailed
        }
        return data
    }

    static func filename(
        label: String,
        date: Date,
        format: CaptureOutputFormat,
        style: CaptureFilenameStyle
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let timestamp = formatter.string(from: date)
        let stem: String
        switch style {
        case .smartShotTimestamp:
            stem = "SmartShot \(timestamp)"
        case .labelTimestamp:
            stem = "\(sanitizedFilenameStem(label)) \(timestamp)"
        }
        return "\(stem).\(format.fileExtension)"
    }

    static func defaultDirectory(fileManager: FileManager = .default) throws -> URL {
        guard let pictures = fileManager.urls(
            for: .picturesDirectory,
            in: .userDomainMask
        ).first else {
            throw CaptureOutputServiceError.noPicturesDirectory
        }
        return pictures.appendingPathComponent("SmartShot", isDirectory: true)
    }

    static func availableURL(
        directory: URL,
        preferredFilename: String,
        fileManager: FileManager = .default
    ) -> URL {
        let preferred = directory.appendingPathComponent(preferredFilename)
        guard fileManager.fileExists(atPath: preferred.path) else { return preferred }
        let extensionValue = preferred.pathExtension
        let stem = preferred.deletingPathExtension().lastPathComponent
        for suffix in 2...9_999 {
            let candidate = directory
                .appendingPathComponent("\(stem) \(suffix)")
                .appendingPathExtension(extensionValue)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        return directory
            .appendingPathComponent("\(stem) \(UUID().uuidString.lowercased())")
            .appendingPathExtension(extensionValue)
    }

    private static func sanitizedFilenameStem(_ value: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:")
            .union(.controlCharacters)
        let scalarStrings = value.unicodeScalars
            .filter { !forbidden.contains($0) }
            .map(String.init)
        let result = scalarStrings.joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return String((result.isEmpty ? "Capture" : result).prefix(60))
    }
}
