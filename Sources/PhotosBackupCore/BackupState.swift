import Foundation

/// Which version of a Photos asset a backup holds, so an edit made later
/// can be told apart from the version Google has.
public struct EditStamp: Codable, Equatable, Sendable {
    /// PHAsset.modificationDate when the uploaded rendition was exported.
    public var modified: Date
    /// Whether that rendition was the edited one; nil when not known (an
    /// upload from before stamps were kept).
    public var edited: Bool?
    /// For an edited rendition: a SHA-256 of the asset's adjustment data,
    /// which changes only when the edit does (not on a favourite, a keyword
    /// or a re-render). nil when unedited, unknown, or Photos had none.
    public var editIdentity: String?

    public init(modified: Date, edited: Bool?, editIdentity: String? = nil) {
        self.modified = modified
        self.edited = edited
        self.editIdentity = editIdentity
    }
}

/// One Photos asset that Google Photos has confirmed, by its media key.
public struct BackupRecord: Codable, Equatable, Sendable {
    public var mediaKey: String
    public var date: Date
    /// Google already had these bytes (gpmc's hash check), so nothing was sent.
    public var existing: Bool
    /// Photos assets only; Messages items never change.
    public var editStamp: EditStamp?

    public init(mediaKey: String, date: Date, existing: Bool, editStamp: EditStamp? = nil) {
        self.mediaKey = mediaKey
        self.date = date
        self.existing = existing
        self.editStamp = editStamp
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
    /// The Google account the records above belong to; nil until the first
    /// account check (and in state written before accounts were tracked).
    public var accountEmail: String?

    public init() {}

    public mutating func recordUpload(assetID: String, mediaKey: String, existing: Bool, at date: Date = Date(), stamp: EditStamp? = nil) {
        // A re-uploaded edit that Google stored as a new item is not in the
        // mirrored albums yet: forgetting the old membership makes the
        // planner add the new media key to them.
        if let previous = uploaded[assetID], previous.mediaKey != mediaKey {
            for (albumID, mirror) in mirrors where mirror.addedAssetIDs.contains(assetID) {
                mirrors[albumID]?.addedAssetIDs.remove(assetID)
            }
        }
        uploaded[assetID] = BackupRecord(mediaKey: mediaKey, date: date, existing: existing, editStamp: stamp)
    }

    /// The asset changed but Google's copy is still the right version (a
    /// favourite or a keyword, not an edit): remember the new date only.
    public mutating func refreshStamp(assetID: String, _ stamp: EditStamp) {
        uploaded[assetID]?.editStamp = stamp
    }

    /// Google no longer has these media keys (an album call answered 404 for
    /// them): forget the uploads they belong to, and their album membership,
    /// so the planner sends those assets again and their new keys join the
    /// albums. Returns the assets forgotten.
    @discardableResult
    public mutating func forgetUploads(withMediaKeys keys: some Sequence<String>) -> [String] {
        let gone = Set(keys)
        guard !gone.isEmpty else { return [] }
        let assetIDs = uploaded.compactMap { gone.contains($0.value.mediaKey) ? $0.key : nil }.sorted()
        for assetID in assetIDs {
            uploaded[assetID] = nil
            for (albumID, mirror) in mirrors where mirror.addedAssetIDs.contains(assetID) {
                mirrors[albumID]?.addedAssetIDs.remove(assetID)
            }
        }
        return assetIDs
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
        fresh.accountEmail = accountEmail
        return fresh
    }

    /// The state for `email`'s account. Records made for another account do
    /// not carry over: its media keys and albums exist only there, and
    /// keeping them would make the new account look backed up when it holds
    /// nothing. The selection does carry over.
    public func adopting(account email: String) -> BackupState {
        if let current = accountEmail, !GoogleSignIn.sameAccount(current, email) {
            var fresh = BackupState()
            fresh.selectedAlbumIDs = selectedAlbumIDs
            fresh.accountEmail = email
            return fresh
        }
        var same = self
        same.accountEmail = email
        return same
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
