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
        /// means nothing to do. Empty forces a rewrite.
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

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.value(.version, default: Self.formatVersion)
        lastArchived = try values.decodeIfPresent(Date.self, forKey: .lastArchived)
        maxRowID = try values.value(.maxRowID, default: 0)
        chats = try values.value(.chats, default: [:])
        snapshots = try values.value(.snapshots, default: [])
    }

    enum Loaded: Equatable {
        case absent
        case loaded(ArchiveManifest)
        /// There, but not readable as a manifest.
        case unreadable
    }

    static func load(from folder: URL) -> Loaded {
        let url = folder.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        // 2026-10-15: Defaults aid older manifests, but an unrelated or
        // damaged `{}` must trigger reconstruction from conversation files.
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["chats"] is [String: Any],
              let manifest = try? ArchiveJSON.decoder.decode(ArchiveManifest.self, from: data) else {
            return .unreadable
        }
        return .loaded(manifest)
    }

    /// The manifest as the conversation folders describe it, for an
    /// archive.json that is gone or damaged: without it, conversations no
    /// longer in Messages would drop out of the index. Empty signatures make
    /// the next run rewrite each conversation (merging, so nothing is lost).
    static func rebuilt(from folder: URL) -> ArchiveManifest {
        var manifest = ArchiveManifest()
        let conversations = folder.appendingPathComponent(MessagesArchiver.conversationsFolder, isDirectory: true)
        let slugs = (try? FileManager.default.contentsOfDirectory(atPath: conversations.path)) ?? []
        for slug in slugs where !slug.hasPrefix(".") {
            let json = conversations.appendingPathComponent(slug).appendingPathComponent("messages.json")
            guard case let .loaded(transcript) = TranscriptFile.load(json) else { continue }
            var conversation = transcript.conversation
            conversation.relativePath = "\(MessagesArchiver.conversationsFolder)/\(slug)"
            let attachments = transcript.messages.flatMap(\.attachments)
            manifest.chats[conversation.id] = Entry(
                conversation: conversation, lastRowID: transcript.messages.map(\.rowID).max() ?? 0, signature: "",
                missingAttachments: attachments.filter { $0.status == .missing || $0.status == .refused }.count, decodeFailures: 0)
        }
        return manifest
    }

    func save(to folder: URL) throws {
        try ArchiveFiles.write(ArchiveJSON.encoder.encode(self), to: folder.appendingPathComponent(Self.fileName))
    }
}

/// A conversation's messages.json, told apart: absent (write a new one),
/// readable, or there but unreadable (never write over it).
enum TranscriptFile: Equatable {
    case absent
    case loaded(ConversationTranscript)
    case unreadable

    static func load(_ url: URL) -> TranscriptFile {
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        guard let data = try? Data(contentsOf: url), let transcript = try? ConversationTranscript.decode(data),
              // A newer app's format is kept as it is, not downgraded.
              transcript.version <= ConversationTranscript.formatVersion else { return .unreadable }
        return .loaded(transcript)
    }
}
