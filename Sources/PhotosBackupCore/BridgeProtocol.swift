import Foundation

/// The Swift half of the line protocol documented in Bridge/gpmc_bridge.py.
public enum BridgeProtocol {
    public static let version = 1
}

/// What gpmc reports to Google as the uploading device, which decides the
/// quality and whether the upload counts against the account's storage.
public enum UploadQuality: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Original quality, free: gpmc commits as a Pixel XL.
    case original
    /// Storage saver (recompressed), free: gpmc commits as a Pixel 2.
    case saver
    /// Original quality counted against the Google storage quota (Pixel 8).
    case quota

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .original: "Original quality, unlimited"
        case .saver: "Storage saver, unlimited"
        case .quota: "Original quality, uses storage"
        }
    }
}

public struct BridgeItem: Codable, Equatable, Sendable {
    public let id: String
    public let path: String
    public let filename: String

    public init(id: String, path: String, filename: String) {
        self.id = id
        self.path = path
        self.filename = filename
    }
}

/// A Google Photos album: an existing one by its media key, or a new one by
/// name. When both are set the bridge appends to `id`.
public struct AlbumTarget: Codable, Equatable, Sendable {
    public var id: String?
    public var name: String?

    public init(id: String? = nil, name: String? = nil) {
        self.id = id
        self.name = name
    }
}

public struct BridgeRequest: Encodable, Equatable, Sendable {
    public var command: String
    public var authData: String?
    public var items: [BridgeItem]?
    public var quality: UploadQuality?
    public var threads: Int?
    public var force: Bool?
    public var timeout: Int?
    public var album: AlbumTarget?
    public var mediaKeys: [String]?

    enum CodingKeys: String, CodingKey {
        case command, items, quality, threads, force, timeout, album
        case authData = "auth_data"
        case mediaKeys = "media_keys"
    }

    public static let version = BridgeRequest(command: "version")

    public static func checkAuth(_ authData: String) -> BridgeRequest {
        BridgeRequest(command: "check-auth", authData: authData)
    }

    public static func upload(_ authData: String, items: [BridgeItem], quality: UploadQuality, threads: Int, album: AlbumTarget?) -> BridgeRequest {
        BridgeRequest(command: "upload", authData: authData, items: items, quality: quality, threads: threads, album: album)
    }

    public static func addToAlbum(_ authData: String, mediaKeys: [String], album: AlbumTarget) -> BridgeRequest {
        BridgeRequest(command: "add-to-album", authData: authData, album: album, mediaKeys: mediaKeys)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

/// gpmc's per-file phases, plus `unknown` so a newer gpmc cannot break decoding.
public enum UploadPhase: String, Sendable {
    case hashing, checking, uploading, finalizing, complete, skipped, error, unknown
}

public enum FatalKind: String, Sendable {
    case auth, network, request, `internal`, unknown
}

public enum BridgeEvent: Equatable, Sendable {
    case version(protocolVersion: Int, gpmc: String?, python: String?)
    case auth(email: String?)
    case progress(id: String?, phase: UploadPhase, completed: Int64, total: Int64)
    case item(id: String, mediaKey: String, existing: Bool)
    case itemFailed(id: String, message: String)
    case album(id: String, added: Int)
    case albumFailed(message: String)
    case done(uploaded: Int, existing: Int, failed: Int)
    /// The bridge honoured a SIGTERM; files not yet reported were abandoned.
    case stopped
    case fatal(kind: FatalKind, message: String)
    case unknown(type: String)

    public struct DecodingError: Error, Equatable {
        public let line: String
    }

    public static func decode(_ line: Data) throws -> BridgeEvent {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String
        else { throw DecodingError(line: String(decoding: line, as: UTF8.self)) }

        func string(_ key: String) -> String? { object[key] as? String }
        func int(_ key: String) -> Int { (object[key] as? NSNumber)?.intValue ?? 0 }
        func int64(_ key: String) -> Int64 { (object[key] as? NSNumber)?.int64Value ?? 0 }

        switch type {
        case "version":
            return .version(protocolVersion: int("protocol"), gpmc: string("gpmc"), python: string("python"))
        case "auth":
            return .auth(email: string("email"))
        case "progress":
            return .progress(id: string("id"), phase: UploadPhase(rawValue: string("phase") ?? "") ?? .unknown,
                             completed: int64("bytes_completed"), total: int64("bytes_total"))
        case "item":
            guard let id = string("id"), let key = string("media_key") else { break }
            return .item(id: id, mediaKey: key, existing: string("status") == "existing")
        case "item_failed":
            guard let id = string("id") else { break }
            return .itemFailed(id: id, message: string("message") ?? "upload failed")
        case "album":
            guard let id = string("album_id") else { break }
            return .album(id: id, added: int("added"))
        case "album_failed":
            return .albumFailed(message: string("message") ?? "adding to album failed")
        case "done":
            return .done(uploaded: int("uploaded"), existing: int("existing"), failed: int("failed"))
        case "stopped":
            return .stopped
        case "fatal":
            return .fatal(kind: FatalKind(rawValue: string("kind") ?? "") ?? .unknown, message: string("message") ?? "")
        default:
            return .unknown(type: type)
        }
        throw DecodingError(line: String(decoding: line, as: UTF8.self))
    }
}

/// Splits a byte stream into newline-terminated lines; a partial trailing
/// line waits for the next chunk (pipes deliver whatever size they like).
public struct LineSplitter: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ chunk: Data) -> [Data] {
        buffer.append(chunk)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<newline]
            if !line.isEmpty { lines.append(Data(line)) }
            buffer = Data(buffer[buffer.index(after: newline)...])
        }
        return lines
    }

    /// Whatever is left once the stream has closed.
    public mutating func finish() -> Data? {
        defer { buffer = Data() }
        return buffer.isEmpty ? nil : buffer
    }
}
