import Foundation

/// One Photos asset that Google Photos has confirmed, by its media key.
public struct BackupRecord: Codable, Equatable, Sendable {
    public var mediaKey: String
    public var date: Date
    /// Google already had these bytes (gpmc's hash check), so nothing was sent.
    public var existing: Bool

    public init(mediaKey: String, date: Date, existing: Bool) {
        self.mediaKey = mediaKey
        self.date = date
        self.existing = existing
    }
}

/// The Google Photos album standing in for one Photos album.
public struct AlbumMirror: Codable, Equatable, Sendable {
    /// Unset until the first batch creates the album.
    public var googleAlbumID: String?
    /// Assets already added to that album.
    public var addedAssetIDs: Set<String>

    public init(googleAlbumID: String? = nil, addedAssetIDs: Set<String> = []) {
        self.googleAlbumID = googleAlbumID
        self.addedAssetIDs = addedAssetIDs
    }
}

/// Everything the app remembers between launches, keyed by PHAsset and
/// PHAssetCollection local identifiers (stable on one Mac, not across Macs).
public struct BackupState: Codable, Equatable, Sendable {
    public var uploaded: [String: BackupRecord] = [:]
    public var mirrors: [String: AlbumMirror] = [:]
    public var selectedAlbumIDs: Set<String> = []

    public init() {}

    public mutating func recordUpload(assetID: String, mediaKey: String, existing: Bool, at date: Date = Date()) {
        uploaded[assetID] = BackupRecord(mediaKey: mediaKey, date: date, existing: existing)
    }

    public mutating func recordAlbum(_ albumID: String, googleAlbumID: String, added assetIDs: some Sequence<String>) {
        var mirror = mirrors[albumID] ?? AlbumMirror()
        mirror.googleAlbumID = googleAlbumID
        mirror.addedAssetIDs.formUnion(assetIDs)
        mirrors[albumID] = mirror
    }

    /// The same selection and album links with no record of what was
    /// uploaded. The links survive: dropping them would make the next run
    /// create a second copy of every mirrored album. So does each album's
    /// membership, which spares re-adding items Google already filed there.
    public func clearingHistory() -> BackupState {
        var fresh = BackupState()
        fresh.selectedAlbumIDs = selectedAlbumIDs
        fresh.mirrors = mirrors
        return fresh
    }

    /// Where the next batch for this album should go: the album the first
    /// batch created, or a new one with the Photos album's name.
    public func albumTarget(for albumID: String, title: String) -> AlbumTarget {
        AlbumTarget(id: mirrors[albumID]?.googleAlbumID, name: title)
    }
}

/// Reads and writes BackupState as JSON, atomically, so a crash mid-write
/// leaves the previous state rather than half a file.
public struct BackupStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() throws -> BackupState {
        guard FileManager.default.fileExists(atPath: url.path) else { return BackupState() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BackupState.self, from: Data(contentsOf: url))
    }

    public func save(_ state: BackupState) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(state).write(to: url, options: .atomic)
    }
}
