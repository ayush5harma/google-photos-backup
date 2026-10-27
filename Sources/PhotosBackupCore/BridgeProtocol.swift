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
        case .original: "Original quality (Pixel XL profile)"
        case .saver: "Storage saver (Pixel 2 profile)"
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

/// The source bytes kept in private staging while Google is asked for a
/// fresh original readback. This proof is deliberately separate from an
/// upload acknowledgement: it is the minimum needed before a connected
/// device may offer reclaim.
public struct OriginalVerificationItem: Codable, Equatable, Sendable {
    public let id: String
    public let path: String
    public let mediaKey: String
    public let expectedSHA256: String?
    public let expectedBytes: Int64?

    public init(id: String, path: String, mediaKey: String, expectedSHA256: String? = nil, expectedBytes: Int64? = nil) {
        self.id = id
        self.path = path
        self.mediaKey = mediaKey
        self.expectedSHA256 = expectedSHA256
        self.expectedBytes = expectedBytes
    }

    enum CodingKeys: String, CodingKey {
        case id, path
        case mediaKey = "media_key"
        case expectedSHA256 = "expected_sha256"
        case expectedBytes = "expected_bytes"
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
    public var verificationItems: [OriginalVerificationItem]?

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

    public static func verifyOriginal(_ authData: String, items: [OriginalVerificationItem]) -> BridgeRequest {
        var request = BridgeRequest(command: "verify-original", authData: authData)
        request.verificationItems = items
        return request
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(command, forKey: .command)
        try values.encodeIfPresent(authData, forKey: .authData)
        if let verificationItems {
            try values.encode(verificationItems, forKey: .items)
        } else {
            try values.encodeIfPresent(items, forKey: .items)
        }
        try values.encodeIfPresent(quality, forKey: .quality)
        try values.encodeIfPresent(threads, forKey: .threads)
        try values.encodeIfPresent(force, forKey: .force)
        try values.encodeIfPresent(timeout, forKey: .timeout)
        try values.encodeIfPresent(album, forKey: .album)
        try values.encodeIfPresent(mediaKeys, forKey: .mediaKeys)
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
    /// Google answered 429: every upload waits, then the run carries on.
    case rateLimit = "rate_limit"
    /// The Google account has no room left; nothing more can be stored.
    case storageFull = "storage_full"
}

public enum BridgeEvent: Equatable, Sendable {
    case version(protocolVersion: Int, gpmc: String?, python: String?)
    case auth(email: String?)
    case progress(id: String?, phase: UploadPhase, completed: Int64, total: Int64)
    case item(id: String, mediaKey: String, existing: Bool)
    /// A new, independently downloaded Google original matched the still
    /// staged local bytes. It does not itself authorize source deletion.
    case verified(id: String, mediaKey: String, sha256: String, bytes: Int64)
    /// `retryable` is the bridge's own reading of the failure; nil from a
    /// bridge that predates the field.
    case itemFailed(id: String, message: String, retryable: Bool?)
    case album(id: String, added: Int)
    case albumFailed(message: String)
    /// Media keys an album call found Google no longer has; sent before the
    /// album event, and those keys are not among its `added`.
    case missingMedia(mediaKeys: [String])
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
        case "verified":
            guard let id = string("id"), let key = string("media_key"), let sha256 = string("sha256") else { break }
            return .verified(id: id, mediaKey: key, sha256: sha256, bytes: int64("bytes"))
        case "item_failed":
            guard let id = string("id") else { break }
            return .itemFailed(id: id, message: string("message") ?? "upload failed", retryable: object["retryable"] as? Bool)
        case "album":
            guard let id = string("album_id") else { break }
            return .album(id: id, added: int("added"))
        case "album_failed":
            return .albumFailed(message: string("message") ?? "adding to album failed")
        case "missing_media":
            guard let keys = object["media_keys"] as? [String] else { break }
            return .missingMedia(mediaKeys: keys)
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
