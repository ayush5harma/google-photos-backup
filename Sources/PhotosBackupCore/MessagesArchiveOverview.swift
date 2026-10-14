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

    public init(conversations: [ArchivedConversation] = [], messageCount: Int = 0, attachmentCount: Int = 0,
                missingAttachmentCount: Int = 0, archiveBytes: Int64 = 0, lastArchived: Date? = nil, databaseSnapshots: Int = 0) {
        self.conversations = conversations
        self.messageCount = messageCount
        self.attachmentCount = attachmentCount
        self.missingAttachmentCount = missingAttachmentCount
        self.archiveBytes = archiveBytes
        self.lastArchived = lastArchived
        self.databaseSnapshots = databaseSnapshots
    }
}
