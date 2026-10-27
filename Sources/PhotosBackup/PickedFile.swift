import AVFoundation
import CoreTransferable
import Foundation
import ImageIO
import PhotosBackupCore
import UniformTypeIdentifiers

/// A picked photo or video, copied out of the system picker. Measured
/// 2026-10-28 on macOS 27.2: with the Hidden album locked, PhotoKit hands an
/// app none of the library's 62 hidden photos, even with full access and
/// includeHiddenAssets (a fetch for isHidden == YES counted 0), while the
/// picker shows them once the owner unlocks the album and hands over the
/// files of those picked. So a pick PhotoKit cannot see goes up from here.
struct PickedFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { try PickedFile(copying: $0.file) }
        FileRepresentation(importedContentType: .image) { try PickedFile(copying: $0.file) }
    }

    /// Where picked files wait for their upload. Only this launch's engine
    /// knows them, so the app clears the folder at launch: these are hidden
    /// photos, and a copy must not outlive the run that needed it.
    static let root = FileManager.default.temporaryDirectory.appendingPathComponent("PickedFiles", isDirectory: true)

    /// The picker removes its file once the import returns, so it is copied
    /// out, one folder per pick so two files with one name cannot collide.
    init(copying file: URL) throws {
        let folder = Self.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        url = folder.appendingPathComponent(file.lastPathComponent)
        try FileManager.default.copyItem(at: file, to: url)
    }

    static func discard(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// When the photo or video was taken, from the file itself: PhotoKit
    /// cannot say for a pick it cannot see, and gpmc sends the file's mtime,
    /// which Google Photos uses when the file carries no date of its own.
    /// Measured 2026-10-28: the first hidden pick, a PNG screenshot taken
    /// 2018-11-13, came out of the picker with no EXIF and an mtime of its
    /// import into Photos (2026-10-09), so the name is the last resort.
    static func capturedDate(of url: URL) async -> Date? {
        if let date = metadataDate(of: url) { return date }
        let asset = AVURLAsset(url: url)
        if let item = try? await asset.load(.creationDate), let date = try? await item.load(.dateValue) { return date }
        return dateInName(url.lastPathComponent)
    }

    /// EXIF capture or digitising time, then TIFF and PNG dates.
    static func metadataDate(of url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        if let stamp = exif[kCGImagePropertyExifDateTimeOriginal] as? String,
           let date = exifDate(stamp, offset: exif[kCGImagePropertyExifOffsetTimeOriginal] as? String) { return date }
        if let stamp = exif[kCGImagePropertyExifDateTimeDigitized] as? String,
           let date = exifDate(stamp, offset: exif[kCGImagePropertyExifOffsetTimeDigitized] as? String) { return date }
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        if let stamp = tiff[kCGImagePropertyTIFFDateTime] as? String,
           let date = exifDate(stamp, offset: exif[kCGImagePropertyExifOffsetTime] as? String) { return date }
        let png = properties[kCGImagePropertyPNGDictionary] as? [CFString: Any] ?? [:]
        if let stamp = png[kCGImagePropertyPNGCreationTime] as? String { return exifDate(stamp, offset: nil) ?? isoDate(stamp) }
        return nil
    }

    /// EXIF writes "2025:11:29 16:32:36", in local time unless an offset
    /// such as "+05:30" sits beside it; an offset that will not parse is
    /// dropped rather than the date.
    static func exifDate(_ stamp: String, offset: String?) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if let offset, !offset.isEmpty {
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ssxxx"
            if let date = formatter.date(from: stamp + offset) { return date }
        }
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = .current
        return formatter.date(from: stamp)
    }

    private static func isoDate(_ stamp: String) -> Date? {
        ISO8601DateFormatter().date(from: stamp)
    }

    /// A capture time written into the file name by the camera or phone, in
    /// local time: "Screenshot_2018-11-13-17-37-06", "2025-11-29_16-32-36",
    /// "PXL_20230324_015637359", "IMG_20230101_123456".
    static func dateInName(_ name: String) -> Date? {
        let patterns = [#"(\d{4})-(\d{2})-(\d{2})[-_ ](\d{2})[-_.:](\d{2})[-_.:](\d{2})"#,
                        #"(?<!\d)(\d{4})(\d{2})(\d{2})[-_](\d{2})(\d{2})(\d{2})"#]
        for pattern in patterns {
            guard let match = try? NSRegularExpression(pattern: pattern).firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) else { continue }
            let parts = (1...6).compactMap { Range(match.range(at: $0), in: name).flatMap { Int(name[$0]) } }
            guard parts.count == 6, (1990...2100).contains(parts[0]) else { continue }
            var components = DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: parts[3], minute: parts[4], second: parts[5])
            components.timeZone = .current
            guard components.isValidDate(in: Calendar(identifier: .gregorian)),
                  let date = Calendar(identifier: .gregorian).date(from: components) else { continue }
            return date
        }
        return nil
    }

    /// The name Google Photos shows. The picker's own file name is used when
    /// it reads like a photo's; an edited rendition ("FullSizeRender") or a
    /// generated name ("version=1&uuid=...") gives way to the capture time,
    /// the way this library already names its imports (2025-11-29_16-32-36).
    static func uploadName(_ name: String, captured: Date?) -> String {
        let clean = ExportNaming.sanitized(name)
        let stem = (clean as NSString).deletingPathExtension
        let ext = (clean as NSString).pathExtension
        guard stem.hasPrefix("FullSizeRender") || stem.contains("=") || stem.contains("&") else { return clean }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let base = captured.map(formatter.string(from:)) ?? "Photo"
        return ext.isEmpty ? base : "\(base).\(ext)"
    }
}
