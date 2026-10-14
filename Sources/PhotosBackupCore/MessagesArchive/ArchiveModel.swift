import Foundation

/// One message as `messages.json` stores it. Field names are part of the
/// archive's format: add fields, never rename or repurpose one.
public struct ArchivedMessage: Codable, Equatable, Identifiable, Sendable {
    /// The message guid in chat.db.
    public var id: String
    public var rowID: Int64
    public var date: Date?
    public var isFromMe: Bool
    /// The sender's handle (phone number or email); nil for messages from me.
    public var sender: String?
    /// The name shown for the sender: "You", a contact name, or the handle.
    public var senderName: String
    /// iMessage, SMS or RCS.
    public var service: String?
    public var text: String
    public var subject: String?
    public var attachments: [ArchivedAttachment]
    public var reactions: [ArchivedReaction]
    /// The guid of the message this one replies to.
    public var replyTo: String?
    public var edited: Bool
    public var unsent: Bool
    /// A conversation event in words ("Sam named the conversation ..."),
    /// set instead of text for system messages.
    public var event: String?
    /// The iMessage app or rich content kind ("Handwriting", "Apple Pay").
    public var app: String?
    /// The send effect in words ("Slam", "Confetti").
    public var effect: String?

    public init(id: String, rowID: Int64, date: Date?, isFromMe: Bool, sender: String?, senderName: String, service: String?,
                text: String, subject: String? = nil, attachments: [ArchivedAttachment] = [], reactions: [ArchivedReaction] = [],
                replyTo: String? = nil, edited: Bool = false, unsent: Bool = false, event: String? = nil, app: String? = nil,
                effect: String? = nil) {
        self.id = id
        self.rowID = rowID
        self.date = date
        self.isFromMe = isFromMe
        self.sender = sender
        self.senderName = senderName
        self.service = service
        self.text = text
        self.subject = subject
        self.attachments = attachments
        self.reactions = reactions
        self.replyTo = replyTo
        self.edited = edited
        self.unsent = unsent
        self.event = event
        self.app = app
        self.effect = effect
    }

    public var isEvent: Bool { event != nil }
}

public struct ArchivedAttachment: Codable, Equatable, Identifiable, Sendable {
    public enum Status: String, Codable, Sendable {
        /// Copied into the conversation's Attachments folder.
        case archived
        /// Named by chat.db but not on this Mac (iCloud-only or deleted).
        case missing
        /// Not copied because attachments are turned off.
        case skipped
        /// Its path pointed outside the Messages folder.
        case refused
    }

    /// The attachment guid in chat.db.
    public var id: String
    public var name: String
    public var mimeType: String?
    public var uti: String?
    public var bytes: Int64
    public var isSticker: Bool
    /// Relative to the conversation folder; nil unless archived.
    public var file: String?
    public var status: Status

    public init(id: String, name: String, mimeType: String?, uti: String?, bytes: Int64, isSticker: Bool, file: String?, status: Status) {
        self.id = id
        self.name = name
        self.mimeType = mimeType
        self.uti = uti
        self.bytes = bytes
        self.isSticker = isSticker
        self.file = file
        self.status = status
    }

    public enum Kind: Sendable { case image, video, audio, other }

    public var kind: Kind {
        let type = (mimeType ?? "").lowercased()
        if type.hasPrefix("image/") { return .image }
        if type.hasPrefix("video/") { return .video }
        if type.hasPrefix("audio/") { return .audio }
        switch (name as NSString).pathExtension.lowercased() {
        case "heic", "heif", "jpg", "jpeg", "png", "gif", "webp", "tiff": return .image
        case "mov", "mp4", "m4v": return .video
        case "caf", "m4a", "mp3", "aac", "amr", "wav": return .audio
        default: return .other
        }
    }
}

/// A tapback left on a message.
public struct ArchivedReaction: Codable, Equatable, Sendable {
    /// love, like, dislike, laugh, emphasize, question, emoji or sticker.
    public var kind: String
    /// What to draw for it.
    public var emoji: String
    public var sender: String?
    public var senderName: String
    public var isFromMe: Bool
    public var date: Date?

    public init(kind: String, emoji: String, sender: String?, senderName: String, isFromMe: Bool, date: Date?) {
        self.kind = kind
        self.emoji = emoji
        self.sender = sender
        self.senderName = senderName
        self.isFromMe = isFromMe
        self.date = date
    }
}

/// A conversation's `messages.json`.
public struct ConversationTranscript: Codable, Equatable, Sendable {
    public static let formatVersion = 1

    public var version: Int
    public var conversation: ArchivedConversation
    public var messages: [ArchivedMessage]

    public init(conversation: ArchivedConversation, messages: [ArchivedMessage]) {
        version = Self.formatVersion
        self.conversation = conversation
        self.messages = messages
    }

    public static func decode(_ data: Data) throws -> ConversationTranscript {
        try ArchiveJSON.decoder.decode(ConversationTranscript.self, from: data)
    }
}

enum ArchiveJSON {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

public extension ArchivedConversation {
    /// Initials for an avatar; nil when the title is a phone number or an
    /// email, which get a person symbol instead. The pages use the same rule.
    var initials: String? { ArchiveHTML.initials(title) }
}

/// Tapbacks are messages of their own in chat.db, pointing at their target
/// through associated_message_guid. 2000-2007 add one, 3000-3007 remove it.
enum Tapback {
    static func kind(of type: Int64) -> (kind: String, adds: Bool)? {
        let adds: Bool
        switch type {
        case 2000...2007: adds = true
        case 3000...3007: adds = false
        default: return nil
        }
        let kinds = ["love", "like", "dislike", "laugh", "emphasize", "question", "emoji", "sticker"]
        return (kinds[Int(type % 1000)], adds)
    }

    static func emoji(for kind: String, custom: String?) -> String {
        switch kind {
        case "love": "\u{2764}\u{FE0F}"
        case "like": "\u{1F44D}"
        case "dislike": "\u{1F44E}"
        case "laugh": "\u{1F602}"
        case "emphasize": "\u{203C}\u{FE0F}"
        case "question": "\u{2753}"
        case "sticker": custom ?? "\u{2B50}"
        default: custom ?? "\u{2B50}"
        }
    }

    /// "p:0/GUID" (a part of the message) and "bp:GUID" (a balloon) both
    /// point at GUID.
    static func targetGUID(_ associated: String) -> String {
        if let slash = associated.firstIndex(of: "/") { return String(associated[associated.index(after: slash)...]) }
        if associated.hasPrefix("bp:") { return String(associated.dropFirst(3)) }
        return associated
    }
}
