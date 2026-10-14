import Foundation
import SQLite3

/// The few SQLite calls the archive needs, over the system library. The
/// Messages scanner shells out to /usr/bin/sqlite3, which is fine for one
/// column of paths but not for blobs (attributedBody) or 100k-row reads.
final class SQLiteDatabase {
    enum Failure: Error, Equatable {
        /// The SQLite result code and the system errno behind it (EPERM is
        /// how a missing Full Disk Access shows up).
        case open(Int32, errno: Int32)
        case prepare(String)
        case step(String)
        case backup(String, errno: Int32)

        var systemErrno: Int32 {
            switch self {
            case let .open(_, errno), let .backup(_, errno): errno
            default: 0
            }
        }
    }

    /// Messages holds its write lock for milliseconds at a time; a reader
    /// waits this long before calling the database busy.
    static let busyTimeoutMilliseconds: Int32 = 2_000
    static let busyRetries = 50

    private var handle: OpaquePointer?

    /// Read-only, no mutex (one connection, one thread), and no URI parsing
    /// so a path with "?" or "#" is taken literally.
    init(readOnly url: URL) throws {
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        let status = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard status == SQLITE_OK else {
            let code = sqlite3_system_errno(handle)
            sqlite3_close(handle)
            throw Failure.open(status, errno: code)
        }
        sqlite3_busy_timeout(handle, Self.busyTimeoutMilliseconds)
    }

    init(creating url: URL) throws {
        let status = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil)
        guard status == SQLITE_OK else {
            let code = sqlite3_system_errno(handle)
            sqlite3_close(handle)
            throw Failure.open(status, errno: code)
        }
    }

    deinit { sqlite3_close(handle) }

    private var lastError: String { String(cString: sqlite3_errmsg(handle)) }

    /// Column names of a table; empty when the table does not exist.
    func columns(of table: String) throws -> Set<String> {
        var names = Set<String>()
        try query("SELECT name FROM pragma_table_info(?)", [.text(table)]) { row in
            if let name = row.string(0) { names.insert(name) }
        }
        return names
    }

    enum Value {
        case int(Int64)
        case text(String)
    }

    /// Runs a statement and hands each row to `body`; the row is only valid
    /// inside the call.
    func query(_ sql: String, _ bindings: [Value] = [], _ body: (Row) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Failure.prepare(lastError)
        }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case let .int(number): sqlite3_bind_int64(statement, index, number)
            case let .text(string): sqlite3_bind_text(statement, index, string, -1, Self.transient)
            }
        }
        let row = Row(statement: statement)
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return }
            guard status == SQLITE_ROW else { throw Failure.step(lastError) }
            try body(row)
        }
    }

    /// A consistent single-file copy of this database, WAL frames folded in,
    /// via the online backup API. `pagesPerStep` -1 copies in one read
    /// transaction: right for a live database another process writes to,
    /// where a stepped copy restarts after every write. A stepped copy of a
    /// database nobody writes can stop between steps when `isCancelled`.
    func backup(to destination: SQLiteDatabase, pagesPerStep: Int32 = -1, isCancelled: () -> Bool = { false }) throws {
        guard let backup = sqlite3_backup_init(destination.handle, "main", handle, "main") else {
            throw Failure.backup(destination.lastError, errno: sqlite3_system_errno(destination.handle))
        }
        var status = SQLITE_OK
        var busy = 0
        while true {
            if isCancelled() {
                sqlite3_backup_finish(backup)
                throw CancellationError()
            }
            status = sqlite3_backup_step(backup, pagesPerStep)
            if status == SQLITE_DONE { break }
            if status == SQLITE_BUSY || status == SQLITE_LOCKED {
                busy += 1
                guard busy <= Self.busyRetries else { break }
                usleep(100_000)
                continue
            }
            guard status == SQLITE_OK else { break }
        }
        let code = sqlite3_system_errno(handle)
        sqlite3_backup_finish(backup)
        guard status == SQLITE_DONE else { throw Failure.backup(lastError, errno: code) }
        // The copied header keeps the source's WAL mode; a lone file reads
        // more simply (and opens read-only) as a rollback-journal database.
        try destination.query("PRAGMA journal_mode=DELETE") { _ in }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    struct Row {
        fileprivate let statement: OpaquePointer

        func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }

        func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }

        func optionalInt(_ column: Int32) -> Int64? { isNull(column) ? nil : int(column) }

        func string(_ column: Int32) -> String? {
            guard !isNull(column), let text = sqlite3_column_text(statement, column) else { return nil }
            return String(cString: text)
        }

        func data(_ column: Int32) -> Data? {
            guard !isNull(column) else { return nil }
            let count = Int(sqlite3_column_bytes(statement, column))
            guard count > 0, let bytes = sqlite3_column_blob(statement, column) else { return Data() }
            return Data(bytes: bytes, count: count)
        }
    }
}
