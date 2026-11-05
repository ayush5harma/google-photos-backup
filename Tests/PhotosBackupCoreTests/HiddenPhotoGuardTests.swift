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
