import Foundation
@testable import PhotosBackupCore

/// A home folder with a synthetic Messages library: chat.db with the real
/// table and column names (macOS 27), and an Attachments folder.
final class MessagesArchiveFixture {
    let root: URL
    let home: URL
    let attachments: URL
    let database: URL
    let archive: URL
    let temporary: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("archive-tests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        home = root.appendingPathComponent("home", isDirectory: true)
        attachments = home.appendingPathComponent("Library/Messages/Attachments", isDirectory: true)
        database = home.appendingPathComponent("Library/Messages/chat.db")
        archive = root.appendingPathComponent("Messages Archive", isDirectory: true)
        temporary = root.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        try createSchema()
    }

    func remove() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: database.path)
        try? FileManager.default.removeItem(at: root)
    }

    func sql(_ statement: String) throws {
        let connection = try SQLiteDatabase(creating: database)
        try connection.query(statement) { _ in }
    }

    func createSchema() throws {
        try sql("""
        CREATE TABLE chat (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT UNIQUE NOT NULL, style INTEGER, state INTEGER,
            chat_identifier TEXT, service_name TEXT, room_name TEXT, display_name TEXT, group_id TEXT, is_archived INTEGER DEFAULT 0)
        """)
        try sql("CREATE TABLE handle (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL, service TEXT, uncanonicalized_id TEXT)")
        try sql("""
        CREATE TABLE message (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT UNIQUE NOT NULL, text TEXT, handle_id INTEGER DEFAULT 0,
            subject TEXT, attributedBody BLOB, service TEXT, date INTEGER, date_read INTEGER, date_delivered INTEGER,
            is_from_me INTEGER DEFAULT 0, item_type INTEGER DEFAULT 0, other_handle INTEGER DEFAULT 0, group_title TEXT,
            group_action_type INTEGER DEFAULT 0, associated_message_guid TEXT, associated_message_type INTEGER DEFAULT 0,
            balloon_bundle_id TEXT, expressive_send_style_id TEXT, thread_originator_guid TEXT, thread_originator_part TEXT,
            date_retracted INTEGER DEFAULT 0, date_edited INTEGER DEFAULT 0, part_count INTEGER, associated_message_emoji TEXT,
            cache_has_attachments INTEGER DEFAULT 0, is_audio_message INTEGER DEFAULT 0, is_system_message INTEGER DEFAULT 0)
        """)
        try sql("""
        CREATE TABLE attachment (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT UNIQUE NOT NULL, created_date INTEGER DEFAULT 0,
            filename TEXT, uti TEXT, mime_type TEXT, transfer_state INTEGER DEFAULT 0, is_outgoing INTEGER DEFAULT 0, transfer_name TEXT,
            total_bytes INTEGER DEFAULT 0, is_sticker INTEGER DEFAULT 0, hide_attachment INTEGER DEFAULT 0)
        """)
        try sql("CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER, message_date INTEGER DEFAULT 0, PRIMARY KEY (chat_id, message_id))")
        try sql("CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER, UNIQUE (chat_id, handle_id))")
        try sql("CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER, UNIQUE (message_id, attachment_id))")
    }

    static func quoted(_ text: String?) -> String {
        guard let text else { return "NULL" }
        return "'" + text.replacingOccurrences(of: "'", with: "''") + "'"
    }

    func addHandle(_ rowID: Int64, _ id: String) throws {
        try sql("INSERT INTO handle (ROWID, id, service) VALUES (\(rowID), \(Self.quoted(id)), 'iMessage')")
    }

    /// style 45 is one-to-one, 43 a group.
    func addChat(_ rowID: Int64, guid: String, identifier: String, name: String? = nil, service: String = "iMessage",
                 group: Bool = false, handles: [Int64]) throws {
        try sql("""
        INSERT INTO chat (ROWID, guid, style, chat_identifier, service_name, display_name)
        VALUES (\(rowID), \(Self.quoted(guid)), \(group ? 43 : 45), \(Self.quoted(identifier)), \(Self.quoted(service)), \(Self.quoted(name)))
        """)
        for handle in handles { try sql("INSERT INTO chat_handle_join VALUES (\(rowID), \(handle))") }
    }

    struct Message {
        var rowID: Int64
        var chat: Int64
        var text: String?
        var body: Data?
        /// Nanoseconds since 2001 unless the test says otherwise.
        var date: Int64
        var fromMe = false
        var handle: Int64 = 0
        var service = "iMessage"
        var associatedGUID: String?
        var associatedType: Int64 = 0
        var emoji: String?
        var replyTo: String?
        var edited: Int64 = 0
        var retracted: Int64 = 0
        var itemType: Int64 = 0
        var groupAction: Int64 = 0
        var groupTitle: String?
        var otherHandle: Int64 = 0
        var effect: String?
        var guid: String { "guid-\(rowID)" }
    }

    func add(_ message: Message) throws {
        let body = message.body.map { "X'" + $0.map { String(format: "%02X", $0) }.joined() + "'" } ?? "NULL"
        try sql("""
        INSERT INTO message (ROWID, guid, text, attributedBody, date, is_from_me, handle_id, service, associated_message_guid,
            associated_message_type, associated_message_emoji, thread_originator_guid, date_edited, date_retracted, item_type,
            group_action_type, group_title, other_handle, expressive_send_style_id)
        VALUES (\(message.rowID), \(Self.quoted(message.guid)), \(Self.quoted(message.text)), \(body), \(message.date),
            \(message.fromMe ? 1 : 0), \(message.handle), \(Self.quoted(message.service)), \(Self.quoted(message.associatedGUID)),
            \(message.associatedType), \(Self.quoted(message.emoji)), \(Self.quoted(message.replyTo)), \(message.edited),
            \(message.retracted), \(message.itemType), \(message.groupAction), \(Self.quoted(message.groupTitle)),
            \(message.otherHandle), \(Self.quoted(message.effect)))
        """)
        try sql("INSERT INTO chat_message_join VALUES (\(message.chat), \(message.rowID), \(message.date))")
    }

    func addAttachment(_ rowID: Int64, message: Int64, filename: String?, name: String, mime: String = "image/jpeg",
                       sticker: Bool = false) throws {
        try sql("""
        INSERT INTO attachment (ROWID, guid, filename, mime_type, transfer_name, total_bytes, is_sticker)
        VALUES (\(rowID), 'att-\(rowID)', \(Self.quoted(filename)), \(Self.quoted(mime)), \(Self.quoted(name)), 0, \(sticker ? 1 : 0))
        """)
        try sql("INSERT INTO message_attachment_join VALUES (\(message), \(rowID))")
    }

    /// Writes a file under Attachments and returns its chat.db path ("~/...").
    @discardableResult
    func writeAttachment(_ relative: String, bytes: String = "pixels") throws -> String {
        let file = attachments.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes.utf8).write(to: file)
        return "~/Library/Messages/Attachments/\(relative)"
    }

    /// 2026-10-14 09:00 UTC plus `minutes`, in chat.db nanoseconds.
    static func time(_ minutes: Int) -> Int64 { (813_661_200 + Int64(minutes) * 60) * 1_000_000_000 }

    static let utc = TimeZone(identifier: "UTC")!
    static let day = Date(timeIntervalSinceReferenceDate: 813_661_200 + 86_400)

    func archiver(attachments: Bool = true, keep: Int = 7, now: Date = day, names: HandleNames = HandleNames()) -> MessagesArchiver {
        MessagesArchiver(configuration: .init(folder: archive, database: database, homeDirectory: home, temporaryDirectory: temporary,
                                              archiveAttachments: attachments, snapshotsToKeep: keep, names: names, timeZone: Self.utc,
                                              locale: Locale(identifier: "en_US_POSIX"), now: now))
    }

    func transcript(_ conversation: ArchivedConversation) throws -> ConversationTranscript {
        try ConversationTranscript.decode(Data(contentsOf: archive.appendingPathComponent(conversation.relativePath).appendingPathComponent("messages.json")))
    }

    func page(_ conversation: ArchivedConversation) throws -> String {
        try String(contentsOf: archive.appendingPathComponent(conversation.relativePath).appendingPathComponent("index.html"), encoding: .utf8)
    }

    /// Every file under the archive with its modification date.
    func modificationDates() throws -> [String: Date] {
        var dates: [String: Date] = [:]
        // resolvingSymlinksInPath drops /private from /private/var, the
        // enumerator does not; compare both resolved.
        let prefix = archive.resolvingSymlinksInPath().path.count
        let walker = FileManager.default.enumerator(at: archive, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey])
        while let url = walker?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            dates[String(url.resolvingSymlinksInPath().path.dropFirst(prefix))] = values.contentModificationDate
        }
        return dates
    }
}
