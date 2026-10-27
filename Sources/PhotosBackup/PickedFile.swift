import CoreTransferable
import Foundation
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

    /// Where picked files wait for their upload; the system clears it too.
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
}
