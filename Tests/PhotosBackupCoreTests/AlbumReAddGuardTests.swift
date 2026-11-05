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

private func ids(_ prefix: String, _ count: Int) -> [String] { (0..<count).map { "\(prefix)\($0)" } }

/// A linked album holding "old0"..."old9", plus `newcomers` photos added to
/// the Apple album since, all backed up.
private func linked(newcomers: Int, approved: Set<String>? = nil) -> (AlbumSnapshot, BackupState) {
    let old = ids("old", 10), new = ids("new", newcomers)
    let album = AlbumSnapshot(id: "shared", title: "Shared", kind: .user, assetIDs: new + old)
    let state = state(selected: ["shared"], uploaded: new + old,
                      mirrors: ["shared": AlbumMirror(googleAlbumID: "g-shared", addedAssetIDs: Set(old), approvedAssetIDs: approved)])
    return (album, state)
}

private func added(_ steps: [PlannedStep]) -> [String] {
    steps.flatMap { step -> [String] in
        switch step {
        case let .addToAlbum(_, _, assetIDs, _): assetIDs
        case let .upload(_, .some, assetIDs): assetIDs
        default: []
        }
    }
}

/// Guard C (2) and (3): one run never adds more than 25 photos by itself to
/// a Google album that was linked before it; past that, the adds wait for
/// the owner ("Add them" or "Skip"), whatever made them (new members, a
/// re-add after dead keys).
@Suite struct ALinkedAlbumNeverTakesABulkReAddTests {
    @Test func upToTheLimitPhotosAddedSinceGoInAsBefore() {
        let (album, state) = linked(newcomers: BackupPlanner.linkedAlbumAddLimit)
        let steps = BackupPlanner.plan(albums: [album], state: state, mirrorAlbums: true, batchSize: 10, uploadsHidden: true)
        #expect(added(steps) == ids("new", 25))
        #expect(BackupPlanner.heldAlbumAdds(albums: [album], state: state).isEmpty)
    }

    @Test func pastTheLimitNothingGoesInAndTheAddsAreHeld() {
        let (album, state) = linked(newcomers: 26)
        #expect(BackupPlanner.plan(albums: [album], state: state, mirrorAlbums: true, batchSize: 10, uploadsHidden: true).isEmpty)
        #expect(BackupPlanner.heldAlbumAdds(albums: [album], state: state)
            == [HeldAlbumAdds(albumID: "shared", title: "Shared", assetIDs: ids("new", 26))])
    }

    @Test func heldPhotosNotBackedUpYetStillGoToTheLibrary() {
        let new = ids("new", 30)
        let album = AlbumSnapshot(id: "shared", title: "Shared", kind: .user, assetIDs: new + ["old"])
        let state = state(selected: ["shared"], uploaded: ["old"],
                          mirrors: ["shared": AlbumMirror(googleAlbumID: "g-shared", addedAssetIDs: ["old"])])
        let steps = BackupPlanner.plan(albums: [album], state: state, mirrorAlbums: true, batchSize: 100, uploadsHidden: true)
        #expect(steps == [.upload(albumID: "shared", albumTitle: nil, assetIDs: new)])
    }

    @Test func addsEarlierInTheRunCountTowardsTheLimit() {
        let (album, state) = linked(newcomers: 6)
        #expect(added(BackupPlanner.plan(albums: [album], state: state, mirrorAlbums: true, batchSize: 10,
                                         uploadsHidden: true, albumAddsThisRun: ["shared": 19])) == ids("new", 6))
        #expect(BackupPlanner.plan(albums: [album], state: state, mirrorAlbums: true, batchSize: 10,
                                   uploadsHidden: true, albumAddsThisRun: ["shared": 20]).isEmpty)
        #expect(BackupPlanner.heldAlbumAdds(albums: [album], state: state, albumAddsThisRun: ["shared": 20]).first?.assetIDs.count == 6)
    }

    @Test func addThemSendsTheHeldPhotosAndOnlyThose() {
        var (album, state) = linked(newcomers: 40)
        state.approveAlbumAdds("shared", assetIDs: ids("new", 40) + ["old0"])
        #expect(state.mirrors["shared"]?.approvedAssetIDs == Set(ids("new", 40)), "a member already in stays out")
        let steps = BackupPlanner.plan(albums: [album], state: state, mirrorAlbums: true, batchSize: 10, uploadsHidden: true)
        #expect(added(steps) == ids("new", 40))
        #expect(BackupPlanner.heldAlbumAdds(albums: [album], state: state).isEmpty)

        // Approved adds are not counted, and are dropped once they are in.
        #expect(state.recordAlbum("shared", googleAlbumID: "g-shared", added: ids("new", 40)) == 0)
        #expect(state.mirrors["shared"]?.approvedAssetIDs == nil)
        // A later photo past the limit is held again.
        album = AlbumSnapshot(id: "shared", title: "Shared", kind: .user, assetIDs: album.assetIDs + ids("late", 30))
        for id in ids("late", 30) { state.recordUpload(assetID: id, mediaKey: "key-\(id)", existing: false) }
        #expect(BackupPlanner.heldAlbumAdds(albums: [album], state: state).first?.assetIDs == ids("late", 30))
    }

    @Test func skipRecordsTheHeldPhotosAsKnownWithoutSendingThem() {
        var (album, state) = linked(newcomers: 30, approved: ["new0"])
        state.skipAlbumAdds("shared", assetIDs: ids("new", 30))
        #expect(state.mirrors["shared"]?.knownAssetIDs == Set(ids("new", 30)))
        #expect(state.mirrors["shared"]?.approvedAssetIDs == nil)
        #expect(state.mirrors["shared"]?.addedAssetIDs == Set(ids("old", 10)), "skipped photos are not taken for added (or probes)")
        #expect(BackupPlanner.plan(albums: [album], state: state, mirrorAlbums: true, batchSize: 10, uploadsHidden: true).isEmpty)
        #expect(BackupPlanner.heldAlbumAdds(albums: [album], state: state).isEmpty)
        // A photo added after the skip goes in as usual.
        state.recordUpload(assetID: "after", mediaKey: "key-after", existing: false)
        album = AlbumSnapshot(id: "shared", title: "Shared", kind: .user, assetIDs: ["after"] + album.assetIDs)
        #expect(added(BackupPlanner.plan(albums: [album], state: state, mirrorAlbums: true, batchSize: 10, uploadsHidden: true)) == ["after"])
    }

    @Test func onlyAddsToAnAlbumLinkedBeforeAreCounted() {
        var state = state(selected: ["shared"])
        #expect(state.recordAlbum("shared", googleAlbumID: "g", added: ["a", "b"], members: ["a", "b", "c", "d"]) == 0)
        #expect(state.mirrors["shared"]?.approvedAssetIDs == ["c", "d"])
        #expect(state.recordAlbum("shared", googleAlbumID: "g", added: ["c", "e", "f"]) == 2, "e and f were neither in nor approved")
        #expect(state.mirrors["shared"]?.approvedAssetIDs == ["d"])
    }

    /// The first run on a newly added account creates the album with its
    /// first batch and stops (sleep, Stop, a lost network): the next run
    /// still fills it, since that is not a re-add.
    @Test func aNewAlbumWhoseFirstRunStoppedIsStillFilled() {
        let members = ids("m", 60)
        let album = AlbumSnapshot(id: "shared", title: "Shared", kind: .user, assetIDs: members)
        var state = state(selected: ["shared"])
        let first = BackupPlanner.plan(albums: [album], state: state, mirrorAlbums: true, batchSize: 10, uploadsHidden: true)
        #expect(added(first) == members, "a brand-new album takes every member")
        for id in members.prefix(10) { state.recordUpload(assetID: id, mediaKey: "key-\(id)", existing: false) }
        state.recordAlbum("shared", googleAlbumID: "g-new", added: members.prefix(10), members: members)

        let next = BackupPlanner.plan(albums: [album], state: state, mirrorAlbums: true, batchSize: 100, uploadsHidden: true)
        #expect(next == [.upload(albumID: "shared", albumTitle: "Shared", assetIDs: Array(members.dropFirst(10)))])
        #expect(BackupPlanner.heldAlbumAdds(albums: [album], state: state).isEmpty)
    }

    /// Guard C (3): photos uploaded again after Google lost their keys are
    /// re-adds like any other: a few go back in, a bulk is held.
    @Test func reAddsAfterDeadKeysFollowTheSameLimit() {
        let members = ids("m", 40)
        let album = AlbumSnapshot(id: "shared", title: "Shared", kind: .user, assetIDs: members)
        var few = state(selected: ["shared"], uploaded: members,
                        mirrors: ["shared": AlbumMirror(googleAlbumID: "g-shared", addedAssetIDs: Set(members))])
        var bulk = few
        few.forgetUploads(withMediaKeys: members.prefix(3).map { "key-\($0)" })
        #expect(BackupPlanner.plan(albums: [album], state: few, mirrorAlbums: true, batchSize: 10, uploadsHidden: true)
            == [.upload(albumID: "shared", albumTitle: "Shared", assetIDs: Array(members.prefix(3)))])

        bulk.forgetUploads(withMediaKeys: members.prefix(30).map { "key-\($0)" })
        #expect(BackupPlanner.plan(albums: [album], state: bulk, mirrorAlbums: true, batchSize: 100, uploadsHidden: true)
            == [.upload(albumID: "shared", albumTitle: nil, assetIDs: Array(members.prefix(30)))])
        #expect(BackupPlanner.heldAlbumAdds(albums: [album], state: bulk).first?.assetIDs == Array(members.prefix(30)))
    }

    @Test func aStateWithoutTheNewFieldsLoadsAndSavesAsBefore() throws {
        let json = #"{"mirrors":{"trip":{"addedAssetIDs":["b"],"googleAlbumID":"g1"}},"selectedAlbumIDs":["trip"],"uploaded":{}}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(BackupState.self, from: Data(json.utf8))
        #expect(state.mirrors["trip"] == AlbumMirror(googleAlbumID: "g1", addedAssetIDs: ["b"]))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(String(data: try encoder.encode(state.mirrors), encoding: .utf8) == #"{"trip":{"addedAssetIDs":["b"],"googleAlbumID":"g1"}}"#)
    }
}
