#if DEBUG
import Foundation
import PhotosBackupCore

/// Debug builds only: PHOTOS_BACKUP_SNAPSHOT_FIXTURE=1 fills the model with
/// made-up data for screenshots (scripts/ios-snapshots.sh): the Mac
/// fixture's pretend library of about 48,000 items, three accounts at the
/// reserved example.com domain, a run in progress to two of them, and a
/// history and timeline. Nothing here reads Photos, the Keychain or the
/// network, and nothing is written.
@MainActor
enum SnapshotFixture {
    static let primary = "jane.appleseed@example.com"
    static let family = "family.photos@example.com"
    static let archive = "jane.archive@example.com"

    private static func album(_ id: String, _ title: String, _ kind: AlbumKind, _ symbol: String, count: Int, offset: Int = 0) -> LibraryAlbum {
        LibraryAlbum(snapshot: AlbumSnapshot(id: id, title: title, kind: kind, assetIDs: (offset..<offset + count).map { "fixture-\($0)" }),
                     symbol: symbol)
    }

    static let albums: [LibraryAlbum] = [
        album(PhotoLibrary.allPhotosID, "All Photos", .allPhotos, "photo.on.rectangle.angled", count: 48_213),
        album("smart-favorites", "Favorites", .smart, "heart", count: 1_342, offset: 100),
        album("smart-recents", "Recently Added", .smart, "clock", count: 214, offset: 47_999),
        album("smart-videos", "Videos", .smart, "video", count: 2_861, offset: 3_000),
        album("smart-selfies", "Selfies", .smart, "person.crop.square", count: 611, offset: 9_000),
        album("smart-live", "Live Photos", .smart, "livephoto", count: 7_420, offset: 12_000),
        album("smart-screenshots", "Screenshots", .smart, "camera.viewfinder", count: 3_904, offset: 20_000),
        album("user-iceland", "Iceland, June 2025", .user, "rectangle.stack", count: 812, offset: 30_000),
        album("user-family", "Family", .user, "rectangle.stack", count: 2_506, offset: 31_000),
        album("user-wedding", "Wedding: Priya and Arjun, Udaipur", .user, "rectangle.stack", count: 1_977, offset: 34_000),
        album("user-recipes", "Recipes", .user, "rectangle.stack", count: 96, offset: 36_500),
        album("user-drawings", "Kids' drawings", .user, "rectangle.stack", count: 143, offset: 36_700),
        album("user-ice-hockey", "Ice hockey league", .user, "rectangle.stack", count: 320, offset: 37_000),
    ]

    static let selected: Set<String> = [PhotoLibrary.allPhotosID, "smart-favorites", "user-iceland", "user-family", "user-wedding", "user-recipes"]

    /// Everything selected backed up except `missing` items.
    private static func record(missing: Int) -> BackupState {
        var state = BackupState()
        state.selectedAlbumIDs = selected
        var ids = Set<String>()
        for album in albums where selected.contains(album.id) { ids.formUnion(album.snapshot.assetIDs) }
        for id in ids.sorted().dropFirst(missing) {
            state.recordUpload(assetID: id, mediaKey: "fixture-key", existing: false)
        }
        state.recordAlbum("user-iceland", googleAlbumID: "fixture-album-1", added: [])
        state.recordAlbum("user-family", googleAlbumID: "fixture-album-2", added: [])
        return state
    }

    static func apply(to model: AppModel) {
        let now = Date()
        func minutesAgo(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        let runs = [
            RunRecord(kind: .photos, trigger: .launch, startedAt: minutesAgo(26 * 60), finishedAt: minutesAgo(26 * 60 - 14),
                      uploaded: 212, existing: 9, bytes: 812_000_000, outcome: .completed, account: AccountLibrary.reference(for: primary)),
            RunRecord(kind: .photos, trigger: .libraryChange, startedAt: minutesAgo(5 * 60), finishedAt: minutesAgo(5 * 60 - 3),
                      uploaded: 38, existing: 2, failed: 1, bytes: 140_000_000, outcome: .completed, account: AccountLibrary.reference(for: primary)),
            RunRecord(kind: .photos, trigger: .manual, startedAt: minutesAgo(95), finishedAt: minutesAgo(80),
                      uploaded: 1_204, existing: 31, bytes: 4_100_000_000, outcome: .stopped, account: AccountLibrary.reference(for: family)),
        ]
        let events: [(EventCategory, String, Bool)] = [
            (.app, "Launched", false),
            (.account, "Connected \(primary)", false),
            (.account, "Added \(family); its first backup waits for a storage check", false),
            (.account, "Backups to \(family) start", false),
            (.account, "Added \(archive); its first backup waits for a storage check", false),
            (.run, "Automatic backup waits: Paused on a metered network", false),
            (.photos, "IMG_3301.HEIC failed: Google could not process this file (400)", true),
            (.run, "Back Up Now: backing up to 2 accounts at the same time", false),
        ]
        let engine = BackupEngineStatus(
            phase: .running, runDone: 1_812, runTotal: 4_406, failedCount: 1, currentFilename: "IMG_4821.HEIC",
            accounts: [.init(account: GoogleSignIn.normalizedEmail(primary), done: 412, total: 1_234),
                       .init(account: GoogleSignIn.normalizedEmail(family), done: 1_400, total: 3_172)],
            lastError: nil, lastRun: minutesAgo(80))
        model.applyFixture(
            albums: albums,
            accounts: [
                .init(email: primary, status: .connected(email: primary), record: record(missing: 1_234)),
                .init(email: family, status: .connected(email: family), record: record(missing: 3_172)),
                .init(email: archive, status: .connected(email: archive), storageChecked: false, record: record(missing: 28_000)),
            ],
            choice: .all, engine: engine, runs: runs, events: events)
    }
}
#endif
