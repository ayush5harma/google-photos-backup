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

private let shared = AlbumSnapshot(id: "shared", title: "Shared", kind: .user, assetIDs: ["a", "b", "c"])

/// Guard C (1): the 2026-11-05 incident. Every mirror's addedAssetIDs was
/// cleared, and the next run re-added each Apple album's members to its
/// Google album, a shared one included, putting back photos the owner had
/// taken out by hand. A linked album with no record of its members is
/// re-baselined, never refilled.
@Suite struct AnAlbumWithNoRecordIsNeverRefilledTests {
    @Test func aLinkedAlbumWhoseRecordWasClearedGetsNothingAdded() {
        let cleared = state(selected: ["shared"], uploaded: ["a", "b", "c"],
                            mirrors: ["shared": AlbumMirror(googleAlbumID: "g-shared", addedAssetIDs: [])])
        #expect(BackupPlanner.plan(albums: [shared], state: cleared, mirrorAlbums: true, batchSize: 10, uploadsHidden: true).isEmpty)
    }

    @Test func membersNotBackedUpYetGoToTheLibraryOnly() {
        let cleared = state(selected: ["shared"], uploaded: ["a"],
                            mirrors: ["shared": AlbumMirror(googleAlbumID: "g-shared", addedAssetIDs: [])])
        #expect(BackupPlanner.plan(albums: [shared], state: cleared, mirrorAlbums: true, batchSize: 10, uploadsHidden: true)
            == [.upload(albumID: "shared", albumTitle: nil, assetIDs: ["b", "c"])])
    }

    @Test func reBaseliningTakesTheMembersAsKnownAndOnlyLaterOnesGoIn() {
        var cleared = state(selected: ["shared"], uploaded: ["a", "b", "c"],
                            mirrors: ["shared": AlbumMirror(googleAlbumID: "g-shared", addedAssetIDs: [])])
        let hiddenToo = AlbumSnapshot(id: "shared", title: "Shared", kind: .user, assetIDs: ["a", "b", "c", "h"], hiddenAssetIDs: ["h"])
        #expect(cleared.rebaselineUnknownMirrors(in: [hiddenToo]) == [RebaselinedAlbum(albumID: "shared", title: "Shared", count: 4)])
        #expect(cleared.mirrors["shared"] == AlbumMirror(googleAlbumID: "g-shared", addedAssetIDs: [], knownAssetIDs: ["a", "b", "c", "h"]))
        #expect(cleared.rebaselineUnknownMirrors(in: [hiddenToo]).isEmpty, "once is enough")
        #expect(BackupPlanner.plan(albums: [hiddenToo], state: cleared, mirrorAlbums: true, batchSize: 10, uploadsHidden: true)
            == [.upload(albumID: "shared", albumTitle: nil, assetIDs: ["h"])], "the primary's library only, as before")

        // A photo added to the Apple album afterwards goes in.
        cleared.recordUpload(assetID: "new", mediaKey: "key-new", existing: false)
        let later = AlbumSnapshot(id: "shared", title: "Shared", kind: .user, assetIDs: ["new", "a", "b", "c"])
        #expect(BackupPlanner.plan(albums: [later], state: cleared, mirrorAlbums: true, batchSize: 10, uploadsHidden: true)
            == [.addToAlbum(albumID: "shared", albumTitle: "Shared", assetIDs: ["new"], mediaKeys: ["key-new"])])
        // Known members are never offered as probes: the bridge re-adds a probe.
        #expect(cleared.splittingAlbumTarget(for: "shared", title: "Shared").probeMediaKeys == nil)
    }

    @Test func aMirrorWithoutItsMemberListStillLoadsAndIsReBaselined() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("state.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json = #"{"uploaded":{"a":{"mediaKey":"key-a","date":"2026-11-01T00:00:00Z","existing":false}},"#
            + #""mirrors":{"shared":{"googleAlbumID":"g-shared"}},"selectedAlbumIDs":["shared"]}"#
        try Data(json.utf8).write(to: url)
        var loaded = try BackupStore(url: url).load()
        #expect(loaded.uploaded["a"]?.mediaKey == "key-a")
        #expect(loaded.mirrors["shared"] == AlbumMirror(googleAlbumID: "g-shared"))
        #expect(BackupPlanner.plan(albums: [shared], state: loaded, mirrorAlbums: true, batchSize: 10, uploadsHidden: true)
            == [.upload(albumID: "shared", albumTitle: nil, assetIDs: ["b", "c"])])
        #expect(loaded.rebaselineUnknownMirrors(in: [shared]).map(\.count) == [3])
    }

    @Test func onlySelectedLinkedUserAlbumsWithNoRecordAreReBaselined() {
        let complete = AlbumMirror(googleAlbumID: "g1", addedAssetIDs: ["a"])
        let unlinked = AlbumMirror(googleAlbumID: nil, addedAssetIDs: [])
        let other = AlbumSnapshot(id: "other", title: "Other", kind: .user, assetIDs: ["a"])
        let smart = AlbumSnapshot(id: "smart", title: "Favourites", kind: .smart, assetIDs: ["a"])
        var untouched = state(selected: ["shared", "smart"], mirrors: [
            "shared": complete, "other": AlbumMirror(googleAlbumID: "g2"), "smart": AlbumMirror(googleAlbumID: "g3"),
        ])
        let before = untouched
        #expect(untouched.rebaselineUnknownMirrors(in: [shared, other, smart]).isEmpty)
        #expect(untouched == before, "a complete mirror, an unselected album and a smart album stay as they are")

        var fresh = state(selected: ["shared"], mirrors: ["shared": unlinked])
        #expect(fresh.rebaselineUnknownMirrors(in: [shared]).isEmpty, "an album not created yet is not a re-add")
    }

    @Test func aBrandNewAlbumIsStillCreatedWithAllItsMembers() {
        let steps = BackupPlanner.plan(albums: [shared], state: state(selected: ["shared"], uploaded: ["a"]), mirrorAlbums: true,
                                       batchSize: 10, uploadsHidden: true)
        #expect(steps == [
            .upload(albumID: "shared", albumTitle: "Shared", assetIDs: ["b", "c"]),
            .addToAlbum(albumID: "shared", albumTitle: "Shared", assetIDs: ["a"], mediaKeys: ["key-a"]),
        ])
    }
}
