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

private let library = AlbumSnapshot(id: "all", title: "All Photos", kind: .allPhotos, assetIDs: ["a", "b", "c", "d", "e"])
private let trip = AlbumSnapshot(id: "trip", title: "Trip", kind: .user, assetIDs: ["b", "d"])
private let live = AlbumSnapshot(id: "live", title: "Live Photos", kind: .smart, assetIDs: ["c"])

@Suite struct PlanTests {
    @Test func uploadsEachAssetOnceIntoItsMirroredAlbumFirst() {
        let steps = BackupPlanner.plan(albums: [library, live, trip], state: state(selected: ["all", "live", "trip"]),
                                       mirrorAlbums: true, batchSize: 10)
        #expect(steps == [
            .upload(albumID: "trip", albumTitle: "Trip", assetIDs: ["b", "d"]),
            .upload(albumID: "live", albumTitle: nil, assetIDs: ["c"]),
            .upload(albumID: "all", albumTitle: nil, assetIDs: ["a", "e"]),
        ])
    }

    @Test func unselectedAlbumsAreIgnored() {
        let steps = BackupPlanner.plan(albums: [library, trip], state: state(selected: ["trip"]), mirrorAlbums: true, batchSize: 10)
        #expect(steps == [.upload(albumID: "trip", albumTitle: "Trip", assetIDs: ["b", "d"])])
    }

    @Test func batchesFollowTheBatchSize() {
        let steps = BackupPlanner.plan(albums: [library], state: state(selected: ["all"]), mirrorAlbums: true, batchSize: 2)
        #expect(steps.count == 3)
        #expect(steps.last == .upload(albumID: "all", albumTitle: nil, assetIDs: ["e"]))
    }

    @Test func alreadyUploadedAssetsAreAddedToTheMirrorNotReuploaded() {
        let steps = BackupPlanner.plan(albums: [trip], state: state(selected: ["trip"], uploaded: ["b", "d"],
                                                                  mirrors: ["trip": AlbumMirror(googleAlbumID: "g1", addedAssetIDs: ["b"])]),
                                       mirrorAlbums: true, batchSize: 10)
        #expect(steps == [.addToAlbum(albumID: "trip", albumTitle: "Trip", assetIDs: ["d"], mediaKeys: ["key-d"])])
    }

    @Test func mirroringOffMeansNoAlbumWork() {
        let steps = BackupPlanner.plan(albums: [trip], state: state(selected: ["trip"], uploaded: ["b"]), mirrorAlbums: false, batchSize: 10)
        #expect(steps == [.upload(albumID: "trip", albumTitle: nil, assetIDs: ["d"])])
    }

    @Test func failuresInThisRunAreNotRetriedInIt() {
        let steps = BackupPlanner.plan(albums: [trip], state: state(selected: ["trip"], uploaded: ["b"]), mirrorAlbums: true,
                                       batchSize: 10, excludingAssets: ["d"], excludingAlbums: ["trip"])
        #expect(steps.isEmpty)
    }

    @Test func upToDateLibraryPlansNothing() {
        let steps = BackupPlanner.plan(albums: [library, trip], state: state(selected: ["all", "trip"], uploaded: ["a", "b", "c", "d", "e"],
                                                                           mirrors: ["trip": AlbumMirror(googleAlbumID: "g", addedAssetIDs: ["b", "d"])]),
                                       mirrorAlbums: true, batchSize: 10)
        #expect(steps.isEmpty)
    }

    @Test func pickedAssetsSkipTheBackedUpAndDuplicates() {
        let steps = BackupPlanner.plan(picked: ["a", "b", "a", "c"], state: state(selected: [], uploaded: ["b"]), batchSize: 10)
        #expect(steps == [.upload(albumID: "picked", albumTitle: nil, assetIDs: ["a", "c"])])
    }

    @Test func summaryCountsUniqueAssetsAcrossSelectedAlbums() {
        let summary = BackupPlanner.summary(albums: [library, trip, live], state: state(selected: ["all", "trip"], uploaded: ["b", "c"]))
        #expect(summary == BackupSummary(backedUp: 2, pending: 3, selectedAlbums: 2))
        #expect(BackupPlanner.progress(of: trip, state: state(selected: [], uploaded: ["b"])) == AlbumProgress(total: 2, backedUp: 1))
    }
}

@Suite struct StateTests {
    @Test func albumTargetAppendsOnceTheAlbumExists() {
        var state = BackupState()
        #expect(state.albumTarget(for: "trip", title: "Trip") == AlbumTarget(id: nil, name: "Trip"))
        state.recordAlbum("trip", googleAlbumID: "g1", added: ["a"])
        state.recordAlbum("trip", googleAlbumID: "g1", added: ["b"])
        #expect(state.albumTarget(for: "trip", title: "Trip") == AlbumTarget(id: "g1", name: "Trip"))
        #expect(state.mirrors["trip"]?.addedAssetIDs == ["a", "b"])
    }

    @Test func clearingHistoryKeepsSelectionAndAlbumLinks() {
        var state = BackupState()
        state.selectedAlbumIDs = ["trip"]
        state.recordUpload(assetID: "a", mediaKey: "k", existing: false)
        state.recordAlbum("trip", googleAlbumID: "g1", added: ["a"])

        let cleared = state.clearingHistory()
        #expect(cleared.uploaded.isEmpty)
        #expect(cleared.selectedAlbumIDs == ["trip"])
        #expect(cleared.albumTarget(for: "trip", title: "Trip") == AlbumTarget(id: "g1", name: "Trip"))
        #expect(cleared.mirrors == state.mirrors)
    }

    @Test func clearedHistoryRechecksIntoTheSameGoogleAlbum() {
        var state = BackupState()
        state.selectedAlbumIDs = ["trip"]
        state.recordUpload(assetID: "b", mediaKey: "k", existing: false)
        state.recordAlbum("trip", googleAlbumID: "g1", added: ["b"])
        var cleared = state.clearingHistory()
        let trip = AlbumSnapshot(id: "trip", title: "Trip", kind: .user, assetIDs: ["b"])

        #expect(BackupPlanner.plan(albums: [trip], state: cleared, mirrorAlbums: true, batchSize: 10)
            == [.upload(albumID: "trip", albumTitle: "Trip", assetIDs: ["b"])])
        #expect(cleared.albumTarget(for: "trip", title: "Trip").id == "g1")
        cleared.recordUpload(assetID: "b", mediaKey: "k", existing: true)
        #expect(BackupPlanner.plan(albums: [trip], state: cleared, mirrorAlbums: true, batchSize: 10).isEmpty)
    }

    @Test func keysGoogleNoLongerHasAreUploadedAgainIntoTheSameAlbum() {
        var state = state(selected: ["trip"], uploaded: ["b", "d"],
                          mirrors: ["trip": AlbumMirror(googleAlbumID: "g1", addedAssetIDs: ["b"])])

        #expect(state.forgetUploads(withMediaKeys: ["key-b", "key-d", "key-unknown"]) == ["b", "d"])
        #expect(state.uploaded.isEmpty)
        #expect(state.mirrors["trip"]?.addedAssetIDs.isEmpty == true)
        #expect(state.albumTarget(for: "trip", title: "Trip").id == "g1")
        #expect(BackupPlanner.plan(albums: [trip], state: state, mirrorAlbums: true, batchSize: 10)
            == [.upload(albumID: "trip", albumTitle: "Trip", assetIDs: ["b", "d"])])
        #expect(state.forgetUploads(withMediaKeys: []) == [])
    }

    @Test func photosGoogleLostGoUpAgainWithoutTheHashCheckOnce() {
        var state = state(selected: ["trip"], uploaded: ["b", "d"])
        state.forgetUploads(withMediaKeys: ["key-b"])
        #expect(state.forcedUploads == ["b"])
        state.recordUpload(assetID: "b", mediaKey: "key-b2", existing: false)
        #expect(state.forcedUploads?.isEmpty == true)
        #expect(state.clearingHistory().forcedUploads == state.forcedUploads)
    }

    @Test func splittingTargetChecksTheAlbumWithPhotosItHolds() {
        var state = state(selected: ["trip"], uploaded: ["a", "b", "c", "d"])
        #expect(state.splittingAlbumTarget(for: "trip", title: "Trip") == AlbumTarget(id: nil, name: "Trip", splitMissing: true))
        state.recordAlbum("trip", googleAlbumID: "g1", added: ["d", "c", "b", "a"])
        let target = state.splittingAlbumTarget(for: "trip", title: "Trip")
        #expect(target.id == "g1" && target.splitMissing == true)
        let probes = target.probeMediaKeys ?? []
        #expect(probes.count == 3 && Set(probes).isSubset(of: ["key-a", "key-b", "key-c", "key-d"]))
        #expect(state.assets(["a", "b", "x"], withMediaKeys: ["key-b", "key-x"]) == ["b"])
    }

    @Test func stateWrittenBefore054StillLoads() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("state.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"uploaded":{},"mirrors":{"trip":{"googleAlbumID":"g1","addedAssetIDs":["b"]}},"selectedAlbumIDs":["trip"]}"#.utf8).write(to: url)
        let state = try BackupStore(url: url).load()
        #expect(state.forcedUploads == nil)
        #expect(state.mirrors["trip"]?.googleAlbumID == "g1")
    }

    @Test func storeRoundTripsAndStartsEmpty() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("state.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = BackupStore(url: url)
        #expect(try store.load() == BackupState())

        var state = BackupState()
        state.selectedAlbumIDs = ["all"]
        state.recordUpload(assetID: "a", mediaKey: "k", existing: true, at: Date(timeIntervalSince1970: 1_700_000_000))
        state.recordAlbum("trip", googleAlbumID: "g", added: ["a"])
        try store.save(state)
        #expect(try store.load() == state)
    }
}

@Suite struct NamingTests {
    @Test(arguments: [
        ("IMG_0636.HEIC", "IMG_0636.HEIC", "IMG_0636.HEIC"),
        ("IMG_0636.HEIC", "FullSizeRender.jpeg", "IMG_0636.jpeg"),
        ("IMG_0001.MOV", "FullSizeRender.mov", "IMG_0001.mov"),
        ("noext", "FullSizeRender.heic", "noext.heic"),
    ])
    func editedRenditionsKeepTheOriginalStem(original: String, rendition: String, expected: String) {
        #expect(ExportNaming.uploadFilename(original: original, rendition: rendition) == expected)
    }

    @Test func namesAreSinglePathComponents() {
        #expect(ExportNaming.uploadFilename(original: nil, rendition: "a/b:c.jpg") == "a_b_c.jpg")
        #expect(ExportNaming.sanitized("..hidden.jpg") == "hidden.jpg")
        #expect(ExportNaming.sanitized("  ") == "asset")
    }
}
