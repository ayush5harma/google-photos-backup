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
///
/// The app adds to a Google album but never removes from it, and cannot
/// read what it holds: a photo the owner took out of a (perhaps shared)
/// album by hand is invisible to it. So once an album is linked, only
/// photos that joined the Photos album since are ever sent to it; the
/// members recorded here are never sent again.
public struct AlbumMirror: Codable, Equatable, Sendable {
    /// Unset until the first batch creates the album.
    public var googleAlbumID: String?
    /// Assets already added to that album. The only members ever offered
    /// as probes, since the bridge re-adds a probe to the album.
    public var addedAssetIDs: Set<String>
    /// Members taken as known without being sent: the whole album when its
    /// record of members was found empty (rebaselineUnknownMirrors), and
    /// held members the owner chose to skip. Never sent to the album and
    /// never a probe. nil when there are none, so a record that never
    /// needed it is written exactly as before.
    public var knownAssetIDs: Set<String>?
    /// Members cleared to go into the linked album whatever their number:
    /// the ones the album was created with, until they are in (a first run
    /// that stops part-way is not a re-add), and held members the owner
    /// chose to add. Dropped as they go in; nil when there are none.
    public var approvedAssetIDs: Set<String>?

    public init(googleAlbumID: String? = nil, addedAssetIDs: Set<String> = [], knownAssetIDs: Set<String>? = nil,
                approvedAssetIDs: Set<String>? = nil) {
        self.googleAlbumID = googleAlbumID
        self.addedAssetIDs = addedAssetIDs
        self.knownAssetIDs = knownAssetIDs
        self.approvedAssetIDs = approvedAssetIDs
    }

    private enum CodingKeys: String, CodingKey {
        case googleAlbumID, addedAssetIDs, knownAssetIDs, approvedAssetIDs
    }

    /// A mirror whose member list is missing (a hand edit, a damaged file)
    /// still loads, as a linked album with no record of its members, which
    /// the next run re-baselines instead of refilling; the rest of the
    /// record loads with it rather than the whole file being refused.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        googleAlbumID = try container.decodeIfPresent(String.self, forKey: .googleAlbumID)
        addedAssetIDs = try container.decodeIfPresent(Set<String>.self, forKey: .addedAssetIDs) ?? []
        knownAssetIDs = try container.decodeIfPresent(Set<String>.self, forKey: .knownAssetIDs)
        approvedAssetIDs = try container.decodeIfPresent(Set<String>.self, forKey: .approvedAssetIDs)
    }

    /// Every member this mirror has a record of, sent or only known.
    /// Read every pass for every linked album: without known members it is
    /// addedAssetIDs itself, not a copy.
    public var recordedAssetIDs: Set<String> {
        guard let known = knownAssetIDs, !known.isEmpty else { return addedAssetIDs }
        return addedAssetIDs.union(known)
    }
}

/// A linked album found with no record of its members, taken as holding
/// every member it has now.
public struct RebaselinedAlbum: Equatable, Sendable {
    public let albumID: String
    public let title: String
    public let count: Int
}

/// Everything the app remembers between launches, keyed by PHAsset and
/// PHAssetCollection local identifiers (stable on one Mac, not across Macs).
public struct BackupState: Codable, Equatable, Sendable {
    public var uploaded: [String: BackupRecord] = [:]
    public var mirrors: [String: AlbumMirror] = [:]
    public var selectedAlbumIDs: Set<String> = []
    /// The Google account the records above belong to; nil until the first
    /// account check (and in state written before accounts were tracked).
    /// Each account has a record of its own (AccountLibrary), so records
    /// are never handed from one account to another.
    public var accountEmail: String?

    public init() {}

    /// Assets whose next upload skips gpmc's hash check: Google lost the key
    /// it had given them (see forgetUploads). Optional so state written
    /// before it decodes.
    public var forcedUploads: Set<String>?

    public mutating func recordUpload(assetID: String, mediaKey: String, existing: Bool, at date: Date = Date(), stamp: EditStamp? = nil) {
        forcedUploads?.remove(assetID)
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
            forcedUploads = (forcedUploads ?? []).union([assetID])
            for (albumID, mirror) in mirrors where mirror.addedAssetIDs.contains(assetID) {
                mirrors[albumID]?.addedAssetIDs.remove(assetID)
            }
        }
        return assetIDs
    }

    /// The assets among `assetIDs` whose uploaded key is one of `mediaKeys`.
    public func assets(_ assetIDs: [String], withMediaKeys mediaKeys: [String]) -> [String] {
        let keys = Set(mediaKeys)
        return assetIDs.filter { uploaded[$0].map { keys.contains($0.mediaKey) } ?? false }
    }

    /// - Parameter members: the Photos album's visible members, read when
    ///   this call creates the Google album: they may all still go in on a
    ///   later pass or run without counting as re-adds.
    /// - Returns: how many of `assetIDs` went into an album that was linked
    ///   already without being approved, which the run counts against
    ///   BackupPlanner.linkedAlbumAddLimit.
    @discardableResult
    public mutating func recordAlbum(_ albumID: String, googleAlbumID: String, added assetIDs: some Sequence<String>,
                                     members: [String] = []) -> Int {
        var mirror = mirrors[albumID] ?? AlbumMirror()
        let added = Set(assetIDs)
        var approved = mirror.approvedAssetIDs ?? []
        let counted: Int
        if mirror.googleAlbumID == nil {
            approved.formUnion(members)
            counted = 0
        } else {
            counted = added.subtracting(mirror.addedAssetIDs).subtracting(approved).count
        }
        mirror.googleAlbumID = googleAlbumID
        mirror.addedAssetIDs.formUnion(added)
        approved.subtract(mirror.addedAssetIDs)
        mirror.approvedAssetIDs = approved.isEmpty ? nil : approved
        mirrors[albumID] = mirror
        return counted
    }

    /// "Add them": the owner clears held members to go into the album.
    public mutating func approveAlbumAdds(_ albumID: String, assetIDs: some Sequence<String>) {
        guard var mirror = mirrors[albumID] else { return }
        let approved = (mirror.approvedAssetIDs ?? []).union(assetIDs).subtracting(mirror.recordedAssetIDs)
        mirror.approvedAssetIDs = approved.isEmpty ? nil : approved
        mirrors[albumID] = mirror
    }

    /// "Skip": held members are recorded as known, and never sent.
    public mutating func skipAlbumAdds(_ albumID: String, assetIDs: some Sequence<String>) {
        guard var mirror = mirrors[albumID] else { return }
        let skipped = Set(assetIDs)
        guard !skipped.isEmpty else { return }
        mirror.knownAssetIDs = (mirror.knownAssetIDs ?? []).union(skipped)
        let approved = (mirror.approvedAssetIDs ?? []).subtracting(skipped)
        mirror.approvedAssetIDs = approved.isEmpty ? nil : approved
        mirrors[albumID] = mirror
    }

    /// Guard C: a linked album with no record of what it holds (its members
    /// cleared by a reset, a damaged file or a hand edit) is never refilled.
    /// Re-adding every member would put back photos the owner took out of
    /// the Google album by hand: on 2026-11-05 a cleared state re-added a
    /// whole Apple album to a shared Google album. Each such selected user
    /// album instead takes its current members, hidden ones too, as known,
    /// and only photos that join it later go in. Returns the albums
    /// re-baselined, for the timeline.
    public mutating func rebaselineUnknownMirrors(in albums: [AlbumSnapshot]) -> [RebaselinedAlbum] {
        var rebaselined: [RebaselinedAlbum] = []
        for album in albums where album.kind == .user && selectedAlbumIDs.contains(album.id) && !album.assetIDs.isEmpty {
            guard var mirror = mirrors[album.id], mirror.googleAlbumID != nil, mirror.recordedAssetIDs.isEmpty else { continue }
            mirror.knownAssetIDs = Set(album.assetIDs)
            mirror.approvedAssetIDs = nil
            mirrors[album.id] = mirror
            rebaselined.append(RebaselinedAlbum(albumID: album.id, title: album.title, count: album.assetIDs.count))
        }
        return rebaselined
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
        fresh.forcedUploads = forcedUploads
        return fresh
    }

    /// Where the next batch for this album should go: the album the first
    /// batch created, or a new one with the Photos album's name.
    public func albumTarget(for albumID: String, title: String) -> AlbumTarget {
        AlbumTarget(id: mirrors[albumID]?.googleAlbumID, name: title)
    }

    /// The target the Mac app sends: split out keys Google no longer has,
    /// checked against up to three photos the album already holds. Picked
    /// afresh each time: dead keys cluster by upload (3 of the 4 waiting for
    /// one album, 2026-10-27), and a fixed three that all died would make a
    /// live album look deleted on every run.
    public func splittingAlbumTarget(for albumID: String, title: String) -> AlbumTarget {
        var target = albumTarget(for: albumID, title: title)
        target.splitMissing = true
        if target.id != nil, let members = mirrors[albumID]?.addedAssetIDs {
            let probes = members.shuffled().lazy.compactMap { uploaded[$0]?.mediaKey }.prefix(3)
            target.probeMediaKeys = probes.isEmpty ? nil : Array(probes)
        }
        return target
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
