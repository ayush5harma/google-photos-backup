import Foundation
import Testing
@testable import PhotosBackupCore

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

private func album(_ id: String, kind: AlbumKind = .allPhotos, _ assets: [String: Date]) -> AlbumSnapshot {
    AlbumSnapshot(id: id, title: id, kind: kind, assetIDs: assets.keys.sorted(), modified: assets)
}

private func uploaded(_ stamps: [String: EditStamp?], selected: Set<String> = ["all"]) -> BackupState {
    var state = BackupState()
    state.selectedAlbumIDs = selected
    for (id, stamp) in stamps { state.recordUpload(assetID: id, mediaKey: "key-\(id)", existing: false, stamp: stamp) }
    return state
}

@Suite struct EditDetectionTests {
    @Test func anAssetEditedAfterItsBackupIsPlannedForReupload() {
        let state = uploaded(["a": EditStamp(modified: t0, edited: false), "b": EditStamp(modified: t0, edited: false)])
        let library = album("all", ["a": t0.addingTimeInterval(120), "b": t0])
        let steps = BackupPlanner.plan(albums: [library], state: state, mirrorAlbums: true, batchSize: 10, reuploadEdits: true)
        #expect(steps == [.reupload(assetIDs: ["a"])])
        #expect(BackupPlanner.plan(albums: [library], state: state, mirrorAlbums: true, batchSize: 10, reuploadEdits: false).isEmpty)
    }

    @Test func newUploadsComeBeforeReuploadsAndBatchesApply() {
        let state = uploaded(["a": EditStamp(modified: t0, edited: true), "b": EditStamp(modified: t0, edited: false),
                              "c": EditStamp(modified: t0, edited: false)])
        let later = t0.addingTimeInterval(60)
        let library = album("all", ["a": later, "b": later, "c": later, "n": t0])
        let steps = BackupPlanner.plan(albums: [library], state: state, mirrorAlbums: true, batchSize: 2, reuploadEdits: true)
        #expect(steps == [.upload(albumID: "all", albumTitle: nil, assetIDs: ["n"]),
                          .reupload(assetIDs: ["a", "b"]), .reupload(assetIDs: ["c"])])
    }

    @Test func anAssetInSeveralAlbumsIsReuploadedOnce() {
        let state = uploaded(["a": EditStamp(modified: t0, edited: false)], selected: ["all", "trip"])
        let later = ["a": t0.addingTimeInterval(60)]
        let steps = BackupPlanner.plan(albums: [album("all", later), album("trip", kind: .user, later)], state: state,
                                       mirrorAlbums: false, batchSize: 10, reuploadEdits: true)
        #expect(steps == [.reupload(assetIDs: ["a"])])
    }

    @Test func subSecondDifferencesAreNotEdits() throws {
        // state.json keeps whole seconds, so a stamp read back is up to a
        // second older than the date it was made from.
        let precise = t0.addingTimeInterval(0.734)
        var state = uploaded(["a": EditStamp(modified: precise, edited: false)])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("state.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try BackupStore(url: url).save(state)
        state = try BackupStore(url: url).load()

        let library = album("all", ["a": precise])
        #expect(BackupPlanner.plan(albums: [library], state: state, mirrorAlbums: true, batchSize: 10, reuploadEdits: true).isEmpty)
        let edited = album("all", ["a": precise.addingTimeInterval(1)])
        #expect(BackupPlanner.plan(albums: [edited], state: state, mirrorAlbums: true, batchSize: 10, reuploadEdits: true)
            == [.reupload(assetIDs: ["a"])])
    }

    @Test func failuresUnstampedAndUnknownDatesAreLeftAlone() {
        let state = uploaded(["a": EditStamp(modified: t0, edited: false), "legacy": nil, "nodate": EditStamp(modified: t0, edited: false)])
        let library = AlbumSnapshot(id: "all", title: "All", kind: .allPhotos, assetIDs: ["a", "legacy", "nodate"],
                                    modified: ["a": t0.addingTimeInterval(60), "legacy": t0.addingTimeInterval(60)])
        #expect(BackupPlanner.plan(albums: [library], state: state, mirrorAlbums: true, batchSize: 10,
                                   excludingAssets: ["a"], reuploadEdits: true).isEmpty)
    }

    @Test func unselectedAlbumsAndMessagesItemsAreNeverReuploaded() {
        var state = uploaded(["a": EditStamp(modified: t0, edited: false)], selected: ["trip"])
        state.recordUpload(assetID: "messages:abc", mediaKey: "m", existing: false)
        let library = album("all", ["a": t0.addingTimeInterval(60), "messages:abc": t0.addingTimeInterval(60)])
        #expect(BackupPlanner.plan(albums: [library], state: state, mirrorAlbums: true, batchSize: 10, reuploadEdits: true).isEmpty)
        state.selectedAlbumIDs = ["all"]
        #expect(BackupPlanner.plan(albums: [library], state: state, mirrorAlbums: true, batchSize: 10, reuploadEdits: true)
            == [.reupload(assetIDs: ["a"])])
    }

    @Test func uploadsFromBeforeStampsAreStampedWithTheirCurrentDate() {
        var state = uploaded(["a": nil, "b": EditStamp(modified: t0, edited: true)])
        state.recordUpload(assetID: "messages:abc", mediaKey: "m", existing: false)
        let library = album("all", ["a": t0, "b": t0, "c": t0])
        #expect(BackupPlanner.unstampedAssets(albums: [library], state: state) == ["a": t0])
    }

    @Test(arguments: [
        // Unedited now.
        (false as Bool?, nil as String?, false, nil as String?, BackupPlanner.EditAction.refreshStamp),  // a favourite, a keyword
        (nil, nil, false, nil, .refreshStamp),            // from before stamps
        (true, "e1", false, nil, .upload),                // edit reverted to the original
        (true, nil, false, nil, .upload),
        // Edited now.
        (false, nil, true, "e1", .upload),                // edited since the backup
        (nil, nil, true, "e1", .upload),
        (true, "e1", true, "e1", .refreshStamp),          // same edit: metadata or a re-render only
        (true, "e1", true, "e2", .upload),                // edited again
        (true, nil, true, "e1", .upload),                 // no identity then: cannot tell
        (true, "e1", true, nil, .upload),                 // adjustment data unreadable now
    ])
    func whatToDoWithAChangedAsset(wasEdited: Bool?, wasIdentity: String?, isEdited: Bool, identity: String?,
                                   expected: BackupPlanner.EditAction) {
        let stamp = EditStamp(modified: t0, edited: wasEdited, editIdentity: wasIdentity)
        #expect(BackupPlanner.editAction(was: stamp, isEdited: isEdited, editIdentity: identity) == expected)
    }

    @Test func aMissingStampActsLikeOneFromBeforeStamps() {
        #expect(BackupPlanner.editAction(was: nil, isEdited: false, editIdentity: nil) == .refreshStamp)
        #expect(BackupPlanner.editAction(was: nil, isEdited: true, editIdentity: "e1") == .upload)
    }

    @Test func stampsWithoutAnEditIdentityStillDecode() throws {
        let json = #"{"date":"2026-10-01T10:00:00Z","existing":false,"mediaKey":"k","editStamp":{"modified":"2026-10-01T09:00:00Z","edited":true}}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(BackupRecord.self, from: Data(json.utf8))
        #expect(record.editStamp?.edited == true)
        #expect(record.editStamp?.editIdentity == nil)
    }
}

@Suite struct EditStampStateTests {
    @Test func stateFromBeforeStampsStillDecodes() throws {
        let legacy = #"""
        {"accountEmail":"x@gmail.com","mirrors":{"trip":{"addedAssetIDs":["A"],"googleAlbumID":"g"}},
         "selectedAlbumIDs":["all-photos"],
         "uploaded":{"A":{"date":"2026-10-01T10:00:00Z","existing":false,"mediaKey":"k1"},
                     "messages:ff":{"date":"2026-10-01T10:00:00Z","existing":true,"mediaKey":"k2"}}}
        """#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(BackupState.self, from: Data(legacy.utf8))
        #expect(state.uploaded["A"]?.mediaKey == "k1")
        #expect(state.uploaded["A"]?.editStamp == nil)
        #expect(state.mirrors["trip"]?.googleAlbumID == "g")
    }

    @Test func stampsRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("state.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var state = BackupState()
        state.recordUpload(assetID: "A", mediaKey: "k", existing: false, at: t0, stamp: EditStamp(modified: t0, edited: true))
        state.recordUpload(assetID: "B", mediaKey: "k2", existing: false, at: t0, stamp: EditStamp(modified: t0, edited: nil))
        try BackupStore(url: url).save(state)
        #expect(try BackupStore(url: url).load() == state)
    }

    @Test func aReuploadWithANewMediaKeyIsFiledInItsAlbumsAgain() {
        var state = BackupState()
        state.recordUpload(assetID: "A", mediaKey: "old", existing: false, stamp: EditStamp(modified: t0, edited: false))
        state.recordAlbum("trip", googleAlbumID: "g", added: ["A", "B"])

        state.recordUpload(assetID: "A", mediaKey: "old", existing: true, stamp: EditStamp(modified: t0.addingTimeInterval(60), edited: false))
        #expect(state.mirrors["trip"]?.addedAssetIDs == ["A", "B"])

        state.recordUpload(assetID: "A", mediaKey: "new", existing: false, stamp: EditStamp(modified: t0.addingTimeInterval(90), edited: true))
        #expect(state.uploaded["A"]?.mediaKey == "new")
        #expect(state.mirrors["trip"]?.addedAssetIDs == ["B"])
        let trip = AlbumSnapshot(id: "trip", title: "Trip", kind: .user, assetIDs: ["A"])
        state.selectedAlbumIDs = ["trip"]
        #expect(BackupPlanner.plan(albums: [trip], state: state, mirrorAlbums: true, batchSize: 10)
            == [.addToAlbum(albumID: "trip", albumTitle: "Trip", assetIDs: ["A"], mediaKeys: ["new"])])
    }

    @Test func refreshingAStampLeavesTheRecordOtherwiseAlone() {
        var state = BackupState()
        state.recordUpload(assetID: "A", mediaKey: "k", existing: false, at: t0, stamp: EditStamp(modified: t0, edited: false))
        state.refreshStamp(assetID: "A", EditStamp(modified: t0.addingTimeInterval(60), edited: false))
        #expect(state.uploaded["A"] == BackupRecord(mediaKey: "k", date: t0, existing: false,
                                                    editStamp: EditStamp(modified: t0.addingTimeInterval(60), edited: false)))
        state.refreshStamp(assetID: "missing", EditStamp(modified: t0, edited: false))
        #expect(state.uploaded["missing"] == nil)
    }
}
