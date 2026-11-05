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
        // No member ever goes to the bridge again except as an add.
        #expect(cleared.splittingAlbumTarget(for: "shared", title: "Shared") == AlbumTarget(id: "g-shared", name: "Shared", splitMissing: true))
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

    /// Review of feat/53-guards, minor 6: an Apple album that was empty when
    /// its record was cleared is re-baselined as empty (a record, though an
    /// empty one), so photos added to it later go in instead of all being
    /// taken as known.
    @Test func anAlbumEmptyWhenReBaselinedStillTakesPhotosAddedLater() {
        var cleared = state(selected: ["shared"], mirrors: ["shared": AlbumMirror(googleAlbumID: "g-shared", addedAssetIDs: [])])
        let empty = AlbumSnapshot(id: "shared", title: "Shared", kind: .user, assetIDs: [])
        #expect(cleared.rebaselineUnknownMirrors(in: [empty]) == [RebaselinedAlbum(albumID: "shared", title: "Shared", count: 0)])
        #expect(cleared.mirrors["shared"]?.knownAssetIDs == [], "an empty record, not a missing one")
        #expect(cleared.rebaselineUnknownMirrors(in: [empty]).isEmpty, "once is enough")

        cleared.recordUpload(assetID: "new", mediaKey: "key-new", existing: false)
        let later = AlbumSnapshot(id: "shared", title: "Shared", kind: .user, assetIDs: ["new"])
        #expect(cleared.rebaselineUnknownMirrors(in: [later]).isEmpty)
        #expect(BackupPlanner.plan(albums: [later], state: cleared, mirrorAlbums: true, batchSize: 10, uploadsHidden: true)
            == [.addToAlbum(albumID: "shared", albumTitle: "Shared", assetIDs: ["new"], mediaKeys: ["key-new"])])
    }

    /// Review of feat/53-guards, minor 5: the listing leaves hidden photos
    /// out, so the snapshot carries hidden members separately, and the
    /// re-baseline records them too: a member hidden then and unhidden later
    /// never goes in by itself.
    @Test func aMemberHiddenAtReBaselineNeverGoesInOnceUnhidden() {
        var cleared = state(selected: ["shared"], uploaded: ["a", "h"],
                            mirrors: ["shared": AlbumMirror(googleAlbumID: "g-shared", addedAssetIDs: [])])
        let listed = AlbumSnapshot(id: "shared", title: "Shared", kind: .user, assetIDs: ["a"], hiddenAssetIDs: ["h"])
        #expect(cleared.rebaselineUnknownMirrors(in: [listed]).map(\.count) == [2])
        #expect(cleared.mirrors["shared"]?.knownAssetIDs == ["a", "h"])

        let unhidden = AlbumSnapshot(id: "shared", title: "Shared", kind: .user, assetIDs: ["a", "h"])
        #expect(BackupPlanner.plan(albums: [unhidden], state: cleared, mirrorAlbums: true, batchSize: 10, uploadsHidden: true).isEmpty)
        #expect(BackupPlanner.heldAlbumAdds(albums: [unhidden], state: cleared).isEmpty)
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
        #expect(state.mirrors["shared"]?.addedAssetIDs == Set(ids("old", 10)), "skipped photos are not taken for added")
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

    /// Guard C (3): photos uploaded again after Google lost their keys go
    /// back only to the album whose call was adding them (and found the keys
    /// dead), under the same limit; every other linked album keeps them
    /// recorded and gets nothing, however many died.
    @Test func reAddsAfterDeadKeysGoOnlyWhereTheyWereBeingAdded() {
        let members = ids("m", 40)
        let elsewhere = AlbumSnapshot(id: "elsewhere", title: "Elsewhere", kind: .user, assetIDs: members)
        var state = state(selected: ["shared", "elsewhere"], uploaded: members,
                          mirrors: ["shared": AlbumMirror(googleAlbumID: "g-shared", addedAssetIDs: ["old"]),
                                    "elsewhere": AlbumMirror(googleAlbumID: "g-else", addedAssetIDs: Set(members))])
        state.recordUpload(assetID: "old", mediaKey: "key-old", existing: false)
        // 30 of them were being added to "shared" (approved by the owner) when their keys came back dead.
        state.approveAlbumAdds("shared", assetIDs: members.prefix(30))
        let dead = Array(members.prefix(30))
        #expect(state.forgetUploads(withMediaKeys: dead.map { "key-\($0)" }, among: dead, reportedBy: "shared") == dead.sorted())
        #expect(state.mirrors["elsewhere"]?.addedAssetIDs == Set(members))

        let shared = AlbumSnapshot(id: "shared", title: "Shared", kind: .user, assetIDs: dead + ["old"])
        let steps = BackupPlanner.plan(albums: [shared, elsewhere], state: state, mirrorAlbums: true, batchSize: 100, uploadsHidden: true)
        #expect(steps == [.upload(albumID: "shared", albumTitle: "Shared", assetIDs: dead)], "approved, so they go back into shared only")

        // Not approved: the same 30 are held for "shared", and still nothing for "elsewhere".
        state.mirrors["shared"]?.approvedAssetIDs = nil
        #expect(BackupPlanner.plan(albums: [shared, elsewhere], state: state, mirrorAlbums: true, batchSize: 100, uploadsHidden: true)
            == [.upload(albumID: "shared", albumTitle: nil, assetIDs: dead)])
        #expect(BackupPlanner.heldAlbumAdds(albums: [shared, elsewhere], state: state).map(\.albumID) == ["shared"])
    }

    /// Review of feat/53-guards, minor 7: a hold stays until the owner
    /// chooses, even when what caused it (earlier adds in the same run) is
    /// gone by the next run; it never goes in by itself.
    @Test func aHeldPhotoWaitsForTheOwnerAcrossRuns() throws {
        let json = #"{"mirrors":{"shared":{"addedAssetIDs":["old"],"googleAlbumID":"g","heldAssetIDs":["new0","new1"]}},"#
            + #""selectedAlbumIDs":["shared"],"uploaded":{}}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var state = try decoder.decode(BackupState.self, from: Data(json.utf8))
        for id in ["old", "new0", "new1", "new2"] { state.recordUpload(assetID: id, mediaKey: "key-\(id)", existing: false) }
        let album = AlbumSnapshot(id: "shared", title: "Shared", kind: .user, assetIDs: ["new0", "new1", "new2", "old"])

        #expect(added(BackupPlanner.plan(albums: [album], state: state, mirrorAlbums: true, batchSize: 10, uploadsHidden: true)) == ["new2"],
                "a photo added since, under the limit, goes in; the held two do not")
        #expect(BackupPlanner.heldAlbumAdds(albums: [album], state: state)
            == [HeldAlbumAdds(albumID: "shared", title: "Shared", assetIDs: ["new0", "new1"])])

        var approved = state
        approved.approveAlbumAdds("shared", assetIDs: ["new0", "new1"])
        #expect(added(BackupPlanner.plan(albums: [album], state: approved, mirrorAlbums: true, batchSize: 10, uploadsHidden: true))
            == ["new0", "new1", "new2"])
        var skipped = state
        skipped.skipAlbumAdds("shared", assetIDs: ["new0", "new1"])
        #expect(BackupPlanner.heldAlbumAdds(albums: [album], state: skipped).isEmpty)
        #expect(added(BackupPlanner.plan(albums: [album], state: skipped, mirrorAlbums: true, batchSize: 10, uploadsHidden: true)) == ["new2"])
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
