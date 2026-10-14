import Foundation

/// One conversation as the archive recorded it.
public struct ArchivedConversation: Codable, Equatable, Identifiable, Sendable {
    /// The chat's guid in chat.db.
    public let id: String
    public var title: String
    public var participants: [String]
    public var isGroup: Bool
    /// iMessage, SMS or RCS.
    public var service: String
    public var messageCount: Int
    public var attachmentCount: Int
    public var lastMessageDate: Date?
    /// The conversation's folder, relative to the archive folder.
    public var relativePath: String

    public init(id: String, title: String, participants: [String], isGroup: Bool, service: String,
                messageCount: Int, attachmentCount: Int, lastMessageDate: Date?, relativePath: String) {
        self.id = id
        self.title = title
        self.participants = participants
        self.isGroup = isGroup
        self.service = service
        self.messageCount = messageCount
        self.attachmentCount = attachmentCount
        self.lastMessageDate = lastMessageDate
        self.relativePath = relativePath
    }
}

/// What a Messages archive holds, for the Messages section, the menu bar and
/// Settings. Read back from the archive's manifest, so it survives relaunch.
public struct MessagesArchiveOverview: Codable, Equatable, Sendable {
    public var conversations: [ArchivedConversation]
    public var messageCount: Int
    public var attachmentCount: Int
    /// Attachments chat.db names that were not on this Mac (iCloud-only,
    /// deleted) when the archive last ran.
    public var missingAttachmentCount: Int
    public var archiveBytes: Int64
    public var lastArchived: Date?
    /// Dated copies of chat.db kept beside the readable archive.
    public var databaseSnapshots: Int
    /// Why today's dated copy of chat.db could not be made; the readable
    /// archive itself was still written.
    public var snapshotProblem: String?
    /// Conversations whose messages.json could not be read, left untouched
    /// rather than rewritten without the messages they keep.
    public var unreadableConversations: Int

    public init(conversations: [ArchivedConversation] = [], messageCount: Int = 0, attachmentCount: Int = 0,
                missingAttachmentCount: Int = 0, archiveBytes: Int64 = 0, lastArchived: Date? = nil, databaseSnapshots: Int = 0,
                snapshotProblem: String? = nil, unreadableConversations: Int = 0) {
        self.snapshotProblem = snapshotProblem
        self.unreadableConversations = unreadableConversations
        self.conversations = conversations
        self.messageCount = messageCount
        self.attachmentCount = attachmentCount
        self.missingAttachmentCount = missingAttachmentCount
        self.archiveBytes = archiveBytes
        self.lastArchived = lastArchived
        self.databaseSnapshots = databaseSnapshots
    }
}

/// Fields read with defaults, so an archive written by an older or newer
/// version of the app still loads.
extension ArchivedConversation {
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decodeIfPresent(String.self, forKey: .title) ?? id
        participants = try values.decodeIfPresent([String].self, forKey: .participants) ?? []
        isGroup = try values.decodeIfPresent(Bool.self, forKey: .isGroup) ?? false
        service = try values.decodeIfPresent(String.self, forKey: .service) ?? "iMessage"
        messageCount = try values.decodeIfPresent(Int.self, forKey: .messageCount) ?? 0
        attachmentCount = try values.decodeIfPresent(Int.self, forKey: .attachmentCount) ?? 0
        lastMessageDate = try values.decodeIfPresent(Date.self, forKey: .lastMessageDate)
        relativePath = try values.decode(String.self, forKey: .relativePath)
    }
}

extension MessagesArchiveOverview {
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        conversations = try values.decodeIfPresent([ArchivedConversation].self, forKey: .conversations) ?? []
        messageCount = try values.decodeIfPresent(Int.self, forKey: .messageCount) ?? 0
        attachmentCount = try values.decodeIfPresent(Int.self, forKey: .attachmentCount) ?? 0
        missingAttachmentCount = try values.decodeIfPresent(Int.self, forKey: .missingAttachmentCount) ?? 0
        archiveBytes = try values.decodeIfPresent(Int64.self, forKey: .archiveBytes) ?? 0
        lastArchived = try values.decodeIfPresent(Date.self, forKey: .lastArchived)
        databaseSnapshots = try values.decodeIfPresent(Int.self, forKey: .databaseSnapshots) ?? 0
        snapshotProblem = try values.decodeIfPresent(String.self, forKey: .snapshotProblem)
        unreadableConversations = try values.decodeIfPresent(Int.self, forKey: .unreadableConversations) ?? 0
    }
}
