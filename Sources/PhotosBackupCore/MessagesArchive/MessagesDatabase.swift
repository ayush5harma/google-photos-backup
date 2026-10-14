import Foundation

public enum MessagesArchiveError: Error, Equatable, Sendable {
    /// chat.db or its folder refused to open: the app has no Full Disk Access.
    case needsFullDiskAccess
    case databaseMissing
    case snapshotFailed
    case unreadableDatabase
    /// The archive folder could not be created or written.
    case folderUnavailable(String)

    public var description: String {
        switch self {
        case .needsFullDiskAccess: "needs Full Disk Access to read Messages"
        case .databaseMissing: "Messages has no conversations on this Mac"
        case .snapshotFailed: "could not copy the Messages database"
        case .unreadableDatabase: "could not read the Messages database"
        case let .folderUnavailable(reason): "could not write the archive folder (\(reason))"
        }
    }

    /// TCC answers EPERM (or EACCES) for a protected file, wrapped by
    /// FileManager in a Cocoa no-permission error.
    static func isPermissionDenied(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain, [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(error.code) { return true }
        if error.domain == NSPOSIXErrorDomain, [Int(EPERM), Int(EACCES)].contains(error.code) { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? Error { return isPermissionDenied(underlying) }
        return false
    }
}

/// A private copy of chat.db and its WAL sidecars. The live database is
/// never opened: Messages writes to it all the time, and a reader holding
/// it could stall or see a torn page.
struct MessagesSnapshot {
    let directory: URL
    let database: URL

    init(of source: URL, in temporaryDirectory: URL) throws {
        let files = FileManager.default
        guard files.fileExists(atPath: source.path) else {
            // Without Full Disk Access the file is invisible rather than
            // unreadable; listing its folder tells the two cases apart.
            do { _ = try files.contentsOfDirectory(atPath: source.deletingLastPathComponent().path) }
            catch let error where MessagesArchiveError.isPermissionDenied(error) { throw MessagesArchiveError.needsFullDiskAccess }
            catch {}
            throw MessagesArchiveError.databaseMissing
        }
        directory = temporaryDirectory.appendingPathComponent("photos-backup-archive-\(UUID().uuidString)", isDirectory: true)
        database = directory.appendingPathComponent("chat.db")
        do { try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { throw MessagesArchiveError.snapshotFailed }
        do {
            try files.copyItem(at: source, to: database)
            for suffix in ["-wal", "-shm"] {
                let sidecar = URL(fileURLWithPath: source.path + suffix)
                if files.fileExists(atPath: sidecar.path) { try files.copyItem(at: sidecar, to: URL(fileURLWithPath: database.path + suffix)) }
            }
        } catch {
            try? files.removeItem(at: directory)
            throw MessagesArchiveError.isPermissionDenied(error) ? MessagesArchiveError.needsFullDiskAccess : MessagesArchiveError.snapshotFailed
        }
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

struct ChatRow: Equatable, Sendable {
    var rowID: Int64
    var guid: String
    var identifier: String
    var displayName: String?
    var service: String?
    /// 43 is a group, 45 a one-to-one conversation.
    var style: Int64

    var isGroup: Bool { style == 43 || (style != 45 && guid.contains(";+;")) }
}

/// What tells whether a conversation changed since the last archive: new
/// rows, deleted rows, and edits or unsends of old ones.
struct ChatStats: Equatable, Sendable {
    var maxRowID: Int64
    var count: Int
    var lastEdit: Int64
    var lastDate: Int64
}

struct MessageRow: Equatable, Sendable {
    var rowID: Int64
    var guid: String
    var text: String?
    var attributedBody: Data?
    var date: Int64
    var isFromMe: Bool
    var handleID: Int64
    var service: String?
    var subject: String?
    var associatedGUID: String?
    var associatedType: Int64
    var associatedEmoji: String?
    var threadOriginator: String?
    var dateEdited: Int64
    var dateRetracted: Int64
    var itemType: Int64
    var groupActionType: Int64
    var groupTitle: String?
    var otherHandle: Int64
    var balloonBundle: String?
    var effect: String?
}

struct AttachmentRow: Equatable, Sendable {
    var messageID: Int64
    var rowID: Int64
    var guid: String
    var filename: String?
    var transferName: String?
    var mimeType: String?
    var uti: String?
    var totalBytes: Int64
    var isSticker: Bool
}

/// Queries over a snapshot. Columns that an older (or newer) macOS lacks
/// read as NULL instead of failing the whole archive.
final class MessagesDatabase {
    private let sqlite: SQLiteDatabase
    private var columns: [String: Set<String>] = [:]

    init(snapshot: MessagesSnapshot) throws {
        do {
            sqlite = try SQLiteDatabase(readOnly: snapshot.database)
            for table in ["chat", "message", "attachment", "handle"] { columns[table] = try sqlite.columns(of: table) }
        } catch { throw MessagesArchiveError.unreadableDatabase }
        guard columns["message"]?.contains("guid") == true, columns["chat"]?.contains("guid") == true else {
            throw MessagesArchiveError.unreadableDatabase
        }
    }

    private func column(_ alias: String, _ table: String, _ name: String) -> String {
        columns[table]?.contains(name) == true ? "\(alias).\(name)" : "NULL"
    }

    private func run(_ sql: String, _ bindings: [SQLiteDatabase.Value] = [], _ body: (SQLiteDatabase.Row) throws -> Void) throws {
        do { try sqlite.query(sql, bindings, body) }
        catch let error as CancellationError { throw error }
        catch { throw MessagesArchiveError.unreadableDatabase }
    }

    func chats() throws -> [ChatRow] {
        var rows: [ChatRow] = []
        let c = { self.column("c", "chat", $0) }
        try run("SELECT c.ROWID, c.guid, \(c("chat_identifier")), \(c("display_name")), \(c("service_name")), \(c("style")) FROM chat c ORDER BY c.ROWID") { row in
            guard let guid = row.string(1) else { return }
            rows.append(ChatRow(rowID: row.int(0), guid: guid, identifier: row.string(2) ?? guid, displayName: row.string(3),
                                service: row.string(4), style: row.int(5)))
        }
        return rows
    }

    func handles() throws -> [Int64: String] {
        var handles: [Int64: String] = [:]
        try run("SELECT ROWID, id FROM handle") { row in
            if let id = row.string(1) { handles[row.int(0)] = id }
        }
        return handles
    }

    /// Participants by chat ROWID, as handle ROWIDs.
    func participants() throws -> [Int64: [Int64]] {
        var participants: [Int64: [Int64]] = [:]
        try run("SELECT chat_id, handle_id FROM chat_handle_join ORDER BY chat_id, handle_id") { row in
            participants[row.int(0), default: []].append(row.int(1))
        }
        return participants
    }

    func stats() throws -> [Int64: ChatStats] {
        var stats: [Int64: ChatStats] = [:]
        let m = { self.column("m", "message", $0) }
        let sql = """
        SELECT j.chat_id, max(m.ROWID), count(*), max(max(coalesce(\(m("date_edited")), 0), coalesce(\(m("date_retracted")), 0))), max(m.date)
        FROM chat_message_join j JOIN message m ON m.ROWID = j.message_id GROUP BY j.chat_id
        """
        try run(sql) { row in
            stats[row.int(0)] = ChatStats(maxRowID: row.int(1), count: Int(row.int(2)), lastEdit: row.int(3), lastDate: row.int(4))
        }
        return stats
    }

    func maxMessageRowID() throws -> Int64 {
        var value: Int64 = 0
        try run("SELECT coalesce(max(ROWID), 0) FROM message") { value = $0.int(0) }
        return value
    }

    func messages(chat: Int64) throws -> [MessageRow] {
        let m = { self.column("m", "message", $0) }
        let sql = """
        SELECT m.ROWID, m.guid, \(m("text")), \(m("attributedBody")), coalesce(m.date, 0), coalesce(\(m("is_from_me")), 0),
               coalesce(\(m("handle_id")), 0), \(m("service")), \(m("subject")), \(m("associated_message_guid")),
               coalesce(\(m("associated_message_type")), 0), \(m("associated_message_emoji")), \(m("thread_originator_guid")),
               coalesce(\(m("date_edited")), 0), coalesce(\(m("date_retracted")), 0), coalesce(\(m("item_type")), 0),
               coalesce(\(m("group_action_type")), 0), \(m("group_title")), coalesce(\(m("other_handle")), 0),
               \(m("balloon_bundle_id")), \(m("expressive_send_style_id"))
        FROM chat_message_join j JOIN message m ON m.ROWID = j.message_id
        WHERE j.chat_id = ? ORDER BY m.date, m.ROWID
        """
        var rows: [MessageRow] = []
        try run(sql, [.int(chat)]) { row in
            guard let guid = row.string(1) else { return }
            rows.append(MessageRow(rowID: row.int(0), guid: guid, text: row.string(2), attributedBody: row.data(3), date: row.int(4),
                                   isFromMe: row.int(5) != 0, handleID: row.int(6), service: row.string(7), subject: row.string(8),
                                   associatedGUID: row.string(9), associatedType: row.int(10), associatedEmoji: row.string(11),
                                   threadOriginator: row.string(12), dateEdited: row.int(13), dateRetracted: row.int(14),
                                   itemType: row.int(15), groupActionType: row.int(16), groupTitle: row.string(17),
                                   otherHandle: row.int(18), balloonBundle: row.string(19), effect: row.string(20)))
        }
        return rows
    }

    /// Attachments of a chat's messages, by message ROWID.
    func attachments(chat: Int64) throws -> [Int64: [AttachmentRow]] {
        let a = { self.column("a", "attachment", $0) }
        let sql = """
        SELECT ma.message_id, a.ROWID, \(a("guid")), \(a("filename")), \(a("transfer_name")), \(a("mime_type")), \(a("uti")),
               coalesce(\(a("total_bytes")), 0), coalesce(\(a("is_sticker")), 0)
        FROM chat_message_join j JOIN message_attachment_join ma ON ma.message_id = j.message_id
        JOIN attachment a ON a.ROWID = ma.attachment_id
        WHERE j.chat_id = ? AND coalesce(\(a("hide_attachment")), 0) = 0 ORDER BY ma.message_id, a.ROWID
        """
        var rows: [Int64: [AttachmentRow]] = [:]
        try run(sql, [.int(chat)]) { row in
            let attachment = AttachmentRow(messageID: row.int(0), rowID: row.int(1), guid: row.string(2) ?? "attachment-\(row.int(1))",
                                           filename: row.string(3), transferName: row.string(4), mimeType: row.string(5),
                                           uti: row.string(6), totalBytes: row.int(7), isSticker: row.int(8) != 0)
            rows[attachment.messageID, default: []].append(attachment)
        }
        return rows
    }

    /// A consistent single-file copy (WAL folded in) for the dated copies.
    func backup(to destination: URL) throws {
        let copy = try SQLiteDatabase(creating: destination)
        try sqlite.backup(to: copy)
    }
}
