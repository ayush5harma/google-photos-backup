import Foundation

public enum AlbumKind: String, Codable, Sendable {
    /// The whole library; never mirrored as an album.
    case allPhotos
    /// A smart album (Favorites, Live Photos, Portrait...); never mirrored.
    case smart
    /// An album the user made; mirrored as a Google Photos album when asked.
    case user
}

/// One Photos album as the planner sees it: identifiers only, newest first.
public struct AlbumSnapshot: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let kind: AlbumKind
    public let assetIDs: [String]
    /// Each asset's PHAsset.modificationDate, read during the same
    /// enumeration; an asset without one is never taken for edited.
    public let modified: [String: Date]

    public init(id: String, title: String, kind: AlbumKind, assetIDs: [String], modified: [String: Date] = [:]) {
        self.id = id
        self.title = title
        self.kind = kind
        self.assetIDs = assetIDs
        self.modified = modified
    }
}

public enum PlannedStep: Equatable, Sendable {
    /// Export and upload these assets; `albumTitle` is set when the album is
    /// mirrored. The Google album id is resolved when the step runs, not
    /// here: the first batch of a new album creates it, and every later batch
    /// in the same run must append to that one rather than create another.
    case upload(albumID: String, albumTitle: String?, assetIDs: [String])
    /// Assets Google already has that are missing from the mirrored album.
    case addToAlbum(albumID: String, albumTitle: String, assetIDs: [String], mediaKeys: [String])
    /// Backed-up assets changed since; each is checked before it is sent.
    case reupload(assetIDs: [String])
}

public struct AlbumProgress: Equatable, Sendable {
    public let total: Int
    public let backedUp: Int

    public var isComplete: Bool { backedUp >= total }
}

public struct BackupSummary: Equatable, Sendable {
    /// Unique assets across the selected albums that Google has.
    public let backedUp: Int
    /// Unique assets across the selected albums still to upload.
    public let pending: Int
    public let selectedAlbums: Int

    public var total: Int { backedUp + pending }
}

public enum BackupPlanner {
    /// Google Photos takes at most 500 media keys per add-to-album call.
    public static let albumBatchSize = 500

    /// Mirrored user albums go first so an asset in one is uploaded straight
    /// into it, then smart albums, then the whole library for the rest.
    static func order(_ albums: [AlbumSnapshot]) -> [AlbumSnapshot] {
        let rank: [AlbumKind: Int] = [.user: 0, .smart: 1, .allPhotos: 2]
        return albums.enumerated()
            .sorted { (rank[$0.element.kind]!, $0.offset) < (rank[$1.element.kind]!, $1.offset) }
            .map(\.element)
    }

    /// The steps that bring Google Photos level with the selected albums.
    ///
    /// - Parameters:
    ///   - excludingAssets: assets that failed earlier in this run; retried
    ///     on the next run, not in a loop within this one.
    ///   - excludingAlbums: albums whose album call failed in this run.
    ///   - reuploadEdits: also plan assets changed since their backup,
    ///     after everything new.
    public static func plan(
        albums: [AlbumSnapshot],
        state: BackupState,
        mirrorAlbums: Bool,
        batchSize: Int,
        excludingAssets: Set<String> = [],
        excludingAlbums: Set<String> = [],
        reuploadEdits: Bool = false
    ) -> [PlannedStep] {
        let steps = planNew(albums: albums, state: state, mirrorAlbums: mirrorAlbums, batchSize: batchSize,
                            excludingAssets: excludingAssets, excludingAlbums: excludingAlbums)
        guard reuploadEdits else { return steps }
        let changed = changedAssets(albums: albums, state: state, excluding: excludingAssets)
        return steps + changed.chunked(max(1, batchSize)).map { .reupload(assetIDs: $0) }
    }

    /// What to do with an asset changed since its backup, once its current
    /// resources are known. An asset that is unedited now changed only in
    /// its metadata (a favourite, a keyword, Photos' own analysis) unless it
    /// was uploaded edited, which means an edit was reverted. That includes
    /// uploads from before stamps (nil): nearly all were unedited, and
    /// re-exporting every one on its first metadata change would cost far
    /// more than the rare reverted edit it might catch. Any edited rendition
    /// uploads, and gpmc's hash check answers "existing" without sending
    /// anything when Google already has those bytes.
    public enum EditAction: Equatable, Sendable {
        case refreshStamp
        case upload
    }

    public static func editAction(wasEdited: Bool?, isEdited: Bool) -> EditAction {
        !isEdited && wasEdited != true ? .refreshStamp : .upload
    }

    /// Selected assets backed up before stamps were kept, with their date
    /// now. Stamping them with it means later edits are noticed; an edit
    /// made before this point is not (it never was).
    public static func unstampedAssets(albums: [AlbumSnapshot], state: BackupState) -> [String: Date] {
        var result: [String: Date] = [:]
        for album in albums where state.selectedAlbumIDs.contains(album.id) {
            for id in album.assetIDs where result[id] == nil && !isMessagesItem(id) {
                guard let record = state.uploaded[id], record.editStamp == nil, let date = album.modified[id] else { continue }
                result[id] = date
            }
        }
        return result
    }

    /// Selected, backed-up assets whose date moved past their stamp, once
    /// each, in album order. Whole seconds only: state.json keeps no
    /// fractions, so a stamp read back can be up to a second earlier than
    /// the date it was made from.
    static func changedAssets(albums: [AlbumSnapshot], state: BackupState, excluding: Set<String>) -> [String] {
        var seen = excluding
        var changed: [String] = []
        for album in order(albums) where state.selectedAlbumIDs.contains(album.id) {
            for id in album.assetIDs where !seen.contains(id) && !isMessagesItem(id) {
                guard let stamp = state.uploaded[id]?.editStamp, let current = album.modified[id] else { continue }
                seen.insert(id)
                if wholeSeconds(current) > wholeSeconds(stamp.modified) { changed.append(id) }
            }
        }
        return changed
    }

    private static func wholeSeconds(_ date: Date) -> Double {
        date.timeIntervalSinceReferenceDate.rounded(.down)
    }

    private static func isMessagesItem(_ id: String) -> Bool {
        id.hasPrefix("messages:")
    }

    private static func planNew(
        albums: [AlbumSnapshot],
        state: BackupState,
        mirrorAlbums: Bool,
        batchSize: Int,
        excludingAssets: Set<String>,
        excludingAlbums: Set<String>
    ) -> [PlannedStep] {
        let batchSize = max(1, batchSize)
        var planned = excludingAssets
        var steps: [PlannedStep] = []

        for album in order(albums) where state.selectedAlbumIDs.contains(album.id) {
            let mirrored = mirrorAlbums && album.kind == .user && !excludingAlbums.contains(album.id)
            let toUpload = album.assetIDs.filter { state.uploaded[$0] == nil && !planned.contains($0) }
            planned.formUnion(toUpload)
            for batch in toUpload.chunked(batchSize) {
                steps.append(.upload(albumID: album.id, albumTitle: mirrored ? album.title : nil, assetIDs: batch))
            }

            guard mirrored else { continue }
            let added = state.mirrors[album.id]?.addedAssetIDs ?? []
            let toAdd = album.assetIDs.filter { state.uploaded[$0] != nil && !added.contains($0) }
            for batch in toAdd.chunked(albumBatchSize) {
                steps.append(.addToAlbum(albumID: album.id, albumTitle: album.title, assetIDs: batch,
                                         mediaKeys: batch.compactMap { state.uploaded[$0]?.mediaKey }))
            }
        }
        return steps
    }

    /// A manual pick: upload whatever Google does not have yet, no album.
    public static func plan(picked assetIDs: [String], state: BackupState, batchSize: Int) -> [PlannedStep] {
        var seen = Set<String>()
        let toUpload = assetIDs.filter { state.uploaded[$0] == nil && seen.insert($0).inserted }
        return toUpload.chunked(max(1, batchSize)).map { .upload(albumID: "picked", albumTitle: nil, assetIDs: $0) }
    }

    public static func progress(of album: AlbumSnapshot, state: BackupState) -> AlbumProgress {
        AlbumProgress(total: album.assetIDs.count, backedUp: album.assetIDs.reduce(0) { $0 + (state.uploaded[$1] == nil ? 0 : 1) })
    }

    public static func summary(albums: [AlbumSnapshot], state: BackupState) -> BackupSummary {
        let selected = albums.filter { state.selectedAlbumIDs.contains($0.id) }
        var assets = Set<String>()
        for album in selected { assets.formUnion(album.assetIDs) }
        let backedUp = assets.reduce(0) { $0 + (state.uploaded[$1] == nil ? 0 : 1) }
        return BackupSummary(backedUp: backedUp, pending: assets.count - backedUp, selectedAlbums: selected.count)
    }
}

extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
