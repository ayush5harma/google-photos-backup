import Foundation
import Testing
@testable import PhotosBackupCore

private func state(selected: Set<String>, uploaded: [String] = [], mirrors: [String: AlbumMirror] = [:]) -> BackupState {
    var state = BackupState()
    state.selectedAlbumIDs = selected
    for id in uploaded { state.recordUpload(assetID: id, mediaKey: "key-\(id)", existing: false) }
    state.mirrors = mirrors
    return state
}

/// "h" is hidden in Photos; "b" and "d" are not.
private let trip = AlbumSnapshot(id: "trip", title: "Trip", kind: .user, assetIDs: ["b", "h", "d"], hiddenAssetIDs: ["h"])

/// Guard A: a hidden photo never goes into a Google album, whichever account
/// and whatever the fetch options handed the planner.
@Suite struct HiddenPhotosNeverJoinAnAlbumTests {
    @Test func aNewAlbumIsCreatedWithoutItsHiddenMembers() {
        let steps = BackupPlanner.plan(albums: [trip], state: state(selected: ["trip"]), mirrorAlbums: true, batchSize: 10,
                                       uploadsHidden: true)
        #expect(steps == [
            .upload(albumID: "trip", albumTitle: "Trip", assetIDs: ["b", "d"]),
            .upload(albumID: "trip", albumTitle: nil, assetIDs: ["h"]),
        ])
    }

    @Test func aHiddenPhotoAlreadyBackedUpIsNeverAddedToALinkedAlbum() {
        // "h" was uploaded by an explicit pick from the Hidden album.
        let steps = BackupPlanner.plan(albums: [trip], state: state(selected: ["trip"], uploaded: ["b", "h", "d"],
                                                                  mirrors: ["trip": AlbumMirror(googleAlbumID: "g1", addedAssetIDs: ["b"])]),
                                       mirrorAlbums: true, batchSize: 10, uploadsHidden: true)
        #expect(steps == [.addToAlbum(albumID: "trip", albumTitle: "Trip", assetIDs: ["d"], mediaKeys: ["key-d"])])
    }

    @Test func aHiddenPhotoIsNeverAddedToANewAlbumEither() {
        let steps = BackupPlanner.plan(albums: [trip], state: state(selected: ["trip"], uploaded: ["b", "h", "d"]),
                                       mirrorAlbums: true, batchSize: 10, uploadsHidden: true)
        #expect(steps == [.addToAlbum(albumID: "trip", albumTitle: "Trip", assetIDs: ["b", "d"], mediaKeys: ["key-b", "key-d"])])
    }

    @Test func aPickFromTheHiddenAlbumGoesToTheLibraryWithNoAlbum() {
        let steps = BackupPlanner.plan(picked: ["h"], state: state(selected: ["trip"]), batchSize: 10)
        #expect(steps == [.upload(albumID: BackupPlanner.pickedAlbumID, albumTitle: nil, assetIDs: ["h"])])
    }
}

private let library = AlbumSnapshot(id: "all", title: "All Photos", kind: .allPhotos, assetIDs: ["a", "h", "c"],
                                    modified: ["a": Date(timeIntervalSince1970: 2_000), "h": Date(timeIntervalSince1970: 2_000)],
                                    hiddenAssetIDs: ["h"])

/// Guard B: an account other than the primary never gets a hidden photo,
/// in its library or an album, and never counts one as still to back up.
@Suite struct HiddenPhotosStayWithThePrimaryTests {
    @Test func anotherAccountIsNeverSentAHiddenPhoto() {
        let fresh = state(selected: ["all", "trip"])
        #expect(BackupPlanner.plan(albums: [library, trip], state: fresh, mirrorAlbums: true, batchSize: 10, uploadsHidden: false) == [
            .upload(albumID: "trip", albumTitle: "Trip", assetIDs: ["b", "d"]),
            .upload(albumID: "all", albumTitle: nil, assetIDs: ["a", "c"]),
        ])
        #expect(BackupPlanner.plan(albums: [library, trip], state: fresh, mirrorAlbums: false, batchSize: 10, uploadsHidden: false) == [
            .upload(albumID: "trip", albumTitle: nil, assetIDs: ["b", "d"]),
            .upload(albumID: "all", albumTitle: nil, assetIDs: ["a", "c"]),
        ])
    }

    @Test func thePrimaryStillBacksAHiddenPhotoUpToItsLibrary() {
        let steps = BackupPlanner.plan(albums: [library], state: state(selected: ["all"]), mirrorAlbums: true, batchSize: 10,
                                       uploadsHidden: true)
        #expect(steps == [.upload(albumID: "all", albumTitle: nil, assetIDs: ["a", "h", "c"])])
    }

    @Test func anEditedHiddenPhotoIsNeverSentAgainToAnotherAccount() {
        // Both backed up before "h" was hidden; both changed since.
        var backedUp = state(selected: ["all"], uploaded: ["a", "h", "c"])
        for id in ["a", "h"] { backedUp.refreshStamp(assetID: id, EditStamp(modified: Date(timeIntervalSince1970: 1_000), edited: false)) }
        #expect(BackupPlanner.plan(albums: [library], state: backedUp, mirrorAlbums: true, batchSize: 10, reuploadEdits: true,
                                   uploadsHidden: false) == [.reupload(assetIDs: ["a"])])
        #expect(BackupPlanner.plan(albums: [library], state: backedUp, mirrorAlbums: true, batchSize: 10, reuploadEdits: true,
                                   uploadsHidden: true) == [.reupload(assetIDs: ["a", "h"])])
    }

    @Test func anotherAccountsCountsLeaveHiddenPhotosOut() {
        let fresh = state(selected: ["all", "trip"])
        #expect(BackupPlanner.summary(albums: [library, trip], state: fresh, includingHidden: false)
            == BackupSummary(backedUp: 0, pending: 4, selectedAlbums: 2))
        #expect(BackupPlanner.summary(albums: [library, trip], state: fresh, includingHidden: true)
            == BackupSummary(backedUp: 0, pending: 5, selectedAlbums: 2))
        let some = state(selected: ["trip"], uploaded: ["b", "h"])
        #expect(BackupPlanner.progress(of: trip, state: some, includingHidden: false) == AlbumProgress(total: 2, backedUp: 1))
        #expect(BackupPlanner.progress(of: trip, state: some, includingHidden: true) == AlbumProgress(total: 3, backedUp: 2))
    }
}
