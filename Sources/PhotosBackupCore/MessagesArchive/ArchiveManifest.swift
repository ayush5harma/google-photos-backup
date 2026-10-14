import Foundation

/// `archive.json` at the archive root: what was archived, so the next run
/// can skip every conversation that did not change.
struct ArchiveManifest: Codable, Equatable {
    static let fileName = "archive.json"
    static let formatVersion = 1

    struct Entry: Codable, Equatable {
        var conversation: ArchivedConversation
        /// The highest message ROWID archived for this chat.
        var lastRowID: Int64
        /// Hash of what the conversation's pages were rendered from; equal
        /// means nothing to do.
        var signature: String
        var missingAttachments: Int
        var decodeFailures: Int
    }

    var version = formatVersion
    var lastArchived: Date?
    /// The highest message ROWID chat.db had at the last run. A lower one
    /// later means the database was replaced (a restored Mac).
    var maxRowID: Int64 = 0
    /// By chat guid. Conversations deleted from Messages stay here.
    var chats: [String: Entry] = [:]
    /// File names under Database/, oldest first.
    var snapshots: [String] = []

    static func load(from folder: URL) -> ArchiveManifest? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(fileName)) else { return nil }
        return try? ArchiveJSON.decoder.decode(ArchiveManifest.self, from: data)
    }

    func save(to folder: URL) throws {
        try ArchiveFiles.write(ArchiveJSON.encoder.encode(self), to: folder.appendingPathComponent(Self.fileName))
    }
}
