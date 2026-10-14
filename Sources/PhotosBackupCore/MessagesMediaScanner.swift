import CryptoKit
import Foundation

/// A locally available attachment that can use the normal uploader without
/// exposing Messages text, chat names, or contact identifiers to the app.
public struct MessagesMediaItem: Equatable, Sendable {
    public let id: String
    public let path: String
    public let filename: String

    public init(id: String, path: String, filename: String) {
        self.id = id
        self.path = path
        self.filename = filename
    }

    public var contentHash: String? {
        id.hasPrefix("messages:") ? String(id.dropFirst("messages:".count)) : nil
    }
}

public struct MessagesMediaScanReport: Equatable, Sendable {
    public let items: [MessagesMediaItem]
    public let skipped: Int
    /// nil means this pass reached the end and the next scan starts at row 0.
    public let nextCursor: Int?

    public init(items: [MessagesMediaItem], skipped: Int, nextCursor: Int?) {
        self.items = items
        self.skipped = skipped
        self.nextCursor = nextCursor
    }
}

public struct MessagesMediaScanner: Sendable {
    public struct Configuration: Sendable {
        public let attachmentsRoot: URL
        public let database: URL
        public let homeDirectory: URL
        public let temporaryDirectory: URL
        public let maximumDuration: TimeInterval
        public let cursor: Int
        /// Test-only row cap. Production leaves this nil and uses the time cap.
        public let maximumRows: Int?

        public init(attachmentsRoot: URL, database: URL, homeDirectory: URL? = nil,
                    temporaryDirectory: URL = FileManager.default.temporaryDirectory, maximumDuration: TimeInterval = 300,
                    cursor: Int = 0, maximumRows: Int? = nil) {
            self.attachmentsRoot = attachmentsRoot
            self.database = database
            self.homeDirectory = homeDirectory ?? database.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            self.temporaryDirectory = temporaryDirectory
            self.maximumDuration = maximumDuration
            self.cursor = max(0, cursor)
            self.maximumRows = maximumRows
        }
    }

    public enum ScanError: Error, Equatable {
        case attachmentsUnavailable
        case databaseUnavailable
        case snapshotFailed
        case sqliteUnavailable
        case queryFailed
    }

    private let configuration: Configuration
    private static let mediaExtensions: Set<String> = ["heic", "heif", "jpg", "jpeg", "png", "gif", "webp", "mov", "mp4", "m4v"]

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    public static func defaultConfiguration(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Configuration {
        Configuration(attachmentsRoot: home.appendingPathComponent("Library/Messages/Attachments", isDirectory: true),
                      database: home.appendingPathComponent("Library/Messages/chat.db"), homeDirectory: home)
    }

    public static func describe(_ error: Error) -> String {
        switch error {
        case ScanError.attachmentsUnavailable: "needs Full Disk Access or has no Messages attachments"
        case ScanError.databaseUnavailable: "cannot read the Messages database"
        case ScanError.snapshotFailed: "could not snapshot the Messages database"
        case ScanError.sqliteUnavailable: "the system SQLite reader is unavailable"
        case ScanError.queryFailed: "could not read Messages attachments"
        default: "could not scan Messages attachments"
        }
    }

    public func scan() throws -> MessagesMediaScanReport {
        let files = FileManager.default
        let root = configuration.attachmentsRoot.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard files.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ScanError.attachmentsUnavailable
        }
        do {
            _ = try files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        } catch {
            throw ScanError.attachmentsUnavailable
        }
        guard files.fileExists(atPath: configuration.database.path) else { throw ScanError.databaseUnavailable }

        let snapshot = configuration.temporaryDirectory.appendingPathComponent("photos-backup-messages-\(UUID().uuidString)", isDirectory: true)
        do { try files.createDirectory(at: snapshot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { throw ScanError.snapshotFailed }
        defer { try? files.removeItem(at: snapshot) }
        let database = snapshot.appendingPathComponent("chat.db")
        do {
            try files.copyItem(at: configuration.database, to: database)
            for suffix in ["-wal", "-shm"] {
                let sidecar = URL(fileURLWithPath: configuration.database.path + suffix)
                if files.fileExists(atPath: sidecar.path) { try files.copyItem(at: sidecar, to: URL(fileURLWithPath: database.path + suffix)) }
            }
        } catch { throw ScanError.snapshotFailed }

        let rows = try query(snapshot: database)
        var items: [MessagesMediaItem] = []
        var ids = Set<String>()
        var skipped = 0
        let deadline = Date().addingTimeInterval(configuration.maximumDuration)
        var processed = 0
        var lastCursor = configuration.cursor
        for (rowid, path) in rows {
            if Date() >= deadline || configuration.maximumRows.map({ processed >= $0 }) == true {
                return MessagesMediaScanReport(items: items, skipped: skipped, nextCursor: lastCursor)
            }
            processed += 1
            lastCursor = rowid
            let file = sourceURL(for: path).resolvingSymlinksInPath().standardizedFileURL
            guard isChild(file, of: root), Self.mediaExtensions.contains(file.pathExtension.lowercased()), locallyAvailable(file) else {
                skipped += 1; continue
            }
            guard let digest = Self.contentHash(of: file) else { skipped += 1; continue }
            // The hash makes this id stable for exactly these bytes, while the
            // prefix prevents any collision with PhotoKit local identifiers.
            let id = "messages:\(digest)"
            guard ids.insert(id).inserted else { continue }
            let safeName = "Messages-\(digest.prefix(12)).\(file.pathExtension.lowercased())"
            items.append(MessagesMediaItem(id: id, path: file.path, filename: safeName))
        }
        return MessagesMediaScanReport(items: items, skipped: skipped, nextCursor: nil)
    }

    private func query(snapshot: URL) throws -> [(Int, String)] {
        let files = FileManager.default
        guard files.isExecutableFile(atPath: "/usr/bin/sqlite3") else { throw ScanError.sqliteUnavailable }
        // No message text, chat title, participant, or handle is selected. Hex
        // keeps filenames with tabs or newlines from changing the row format.
        let sql = "SELECT ROWID, hex(filename) FROM attachment WHERE ROWID > \(configuration.cursor) AND filename IS NOT NULL AND filename <> '' ORDER BY ROWID;"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-batch", "-noheader", "-separator", "\t", snapshot.path, sql]
        let output = Pipe()
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw ScanError.sqliteUnavailable }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ScanError.queryFailed }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 1)
            guard fields.count == 2, let rowid = Int(fields[0]), let data = Data(hex: String(fields[1])),
                  let path = String(data: data, encoding: .utf8) else { return nil }
            return (rowid, path)
        }
    }

    private func isChild(_ file: URL, of root: URL) -> Bool {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return file.path.hasPrefix(rootPath)
    }

    private func sourceURL(for path: String) -> URL {
        if path.hasPrefix("~/") {
            return configuration.homeDirectory.appendingPathComponent(String(path.dropFirst(2)))
        }
        return URL(fileURLWithPath: path)
    }

    private func locallyAvailable(_ file: URL) -> Bool {
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
              values.isRegularFile == true, (values.fileSize ?? 0) > 0 else { return false }
        return values.isUbiquitousItem != true || values.ubiquitousItemDownloadingStatus == .current
    }

    public static func contentHash(of file: URL) -> String? {
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private extension Data {
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var data = Data(); data.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte); index = next
        }
        self = data
    }
}
