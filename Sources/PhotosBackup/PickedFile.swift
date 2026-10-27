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
    static func capturedDate(of url: URL) async -> Date? {
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let stamp = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            return exifDate(stamp, offset: exif[kCGImagePropertyExifOffsetTimeOriginal] as? String)
        }
        let asset = AVURLAsset(url: url)
        guard let item = try? await asset.load(.creationDate) else { return nil }
        return try? await item.load(.dateValue)
    }

    /// EXIF writes "2025:11:29 16:32:36", in local time unless an offset
    /// such as "+05:30" sits beside it.
    static func exifDate(_ stamp: String, offset: String?) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if let offset {
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ssxxx"
            return formatter.date(from: stamp + offset)
        }
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = .current
        return formatter.date(from: stamp)
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
