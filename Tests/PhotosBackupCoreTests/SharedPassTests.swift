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

/// Every (album, title, asset) an account's sends carry, and every one its
/// own upload steps planned: the merge may only regroup them into batches.
private func carried(_ pass: SharedPass, _ account: String) -> [String] {
    pass.batches.flatMap { batch in
        batch.sends(for: account).flatMap { send in send.assetIDs.map { "\(send.albumID)|\(send.albumTitle ?? "-")|\($0)" } }
    }.sorted()
}

private func planned(_ steps: [PlannedStep]) -> [String] {
    steps.flatMap { step -> [String] in
        guard case let .upload(albumID, title, ids) = step else { return [] }
        return ids.map { "\(albumID)|\(title ?? "-")|\($0)" }
    }.sorted()
}

/// Issue #66: several accounts in one pass, each photo exported once.
@Suite struct SharedPassTests {
    @Test func twoAccountsWithTheSamePlanShareEveryBatch() {
        let steps: [PlannedStep] = [.upload(albumID: "all", albumTitle: nil, assetIDs: ["a", "b", "c"]),
                                    .upload(albumID: "all", albumTitle: nil, assetIDs: ["d"])]
        let pass = SharedPass(plans: [("first", steps), ("second", steps)], batchSize: 2)
        #expect(pass.batches.map(\.assetIDs) == [["a", "b"], ["c", "d"]])
        #expect(pass.batches.allSatisfy { $0.accounts == ["first", "second"] })
        #expect(pass.batches[1].sends == [
            .init(account: "first", albumID: "all", albumTitle: nil, assetIDs: ["c"]),
            .init(account: "first", albumID: "all", albumTitle: nil, assetIDs: ["d"]),
            .init(account: "second", albumID: "all", albumTitle: nil, assetIDs: ["c"]),
            .init(account: "second", albumID: "all", albumTitle: nil, assetIDs: ["d"]),
        ])
        #expect(pass.uploads == ["first": 4, "second": 4])
    }

    @Test func anAccountThatHasAPhotoIsNeverSentIt() {
        let pass = SharedPass(plans: [("first", [.upload(albumID: "all", albumTitle: nil, assetIDs: ["c"])]),
                                      ("second", [.upload(albumID: "all", albumTitle: nil, assetIDs: ["a", "b", "c"])])],
                              batchSize: 2)
        #expect(pass.batches.map(\.assetIDs) == [["c", "a"], ["b"]], "each photo exported once, in the order first planned")
        #expect(carried(pass, "first") == ["all|-|c"])
        #expect(carried(pass, "second") == ["all|-|a", "all|-|b", "all|-|c"])
        #expect(pass.batches[1].accounts == ["second"])
    }

    @Test func picksAreExportedWithHiddenPhotosAndOnlyForWhoPlannedThem() {
        let pass = SharedPass(plans: [("first", [.upload(albumID: BackupPlanner.pickedAlbumID, albumTitle: nil, assetIDs: ["p"]),
                                                 .upload(albumID: "all", albumTitle: nil, assetIDs: ["a"])]),
                                      ("second", [.upload(albumID: "all", albumTitle: nil, assetIDs: ["a", "p"])])],
                              batchSize: 10)
        #expect(pass.batches.map(\.includingHidden) == [true, false])
        #expect(pass.batches[0].sends == [.init(account: "first", albumID: BackupPlanner.pickedAlbumID, albumTitle: nil, assetIDs: ["p"])])
        #expect(carried(pass, "second") == ["all|-|a", "all|-|p"], "the other account's p goes in a batch exported without hidden photos")
    }

    @Test func otherStepsStayWithTheirAccountInOrder() {
        let add = PlannedStep.addToAlbum(albumID: "trip", albumTitle: "Trip", assetIDs: ["x"], mediaKeys: ["key-x"])
        let edit = PlannedStep.reupload(assetIDs: ["y"])
        let pass = SharedPass(plans: [("first", [add, edit]), ("second", [])], batchSize: 10)
        #expect(pass.batches.isEmpty)
        #expect(pass.rest == ["first": [add, edit]])
        #expect(pass.uploads == ["first": 0, "second": 0])
        #expect(!pass.isEmpty)
        #expect(SharedPass(plans: [("first", []), ("second", [])], batchSize: 10).isEmpty)
    }

    /// The guards of 0.6.0 through the merge, for two accounts at once: the
    /// planner's per-account plans are all that reach the sends.
    @Test func theAlbumGuardsHoldPerAccountWhenTwoAccountsShareAPass() {
        let trip = AlbumSnapshot(id: "trip", title: "Trip", kind: .user, assetIDs: ["a", "h", "b", "n"], hiddenAssetIDs: ["h"])
        let everything = AlbumSnapshot(id: "all", title: "All Photos", kind: .allPhotos, assetIDs: ["a", "h", "b", "n", "c"],
                                       hiddenAssetIDs: ["h"])
        let primary = state(selected: ["trip", "all"])
        // The added account linked Trip earlier with a and b, then 30 more
        // photos joined the album: more than 25 adds wait for the owner.
        let newcomers = (0..<30).map { "new-\($0)" }
        let busy = AlbumSnapshot(id: "trip", title: "Trip", kind: .user, assetIDs: ["a", "h", "b", "n"] + newcomers, hiddenAssetIDs: ["h"])
        let added = state(selected: ["trip", "all"], uploaded: ["a", "b"],
                          mirrors: ["trip": AlbumMirror(googleAlbumID: "g-trip", addedAssetIDs: ["a", "b"])])
        let firstSteps = BackupPlanner.plan(albums: [trip, everything], state: primary, mirrorAlbums: true, batchSize: 3, uploadsHidden: true)
        let secondSteps = BackupPlanner.plan(albums: [busy, everything], state: added, mirrorAlbums: true, batchSize: 3, uploadsHidden: false)
        let pass = SharedPass(plans: [("first", firstSteps), ("second", secondSteps)], batchSize: 3)

        #expect(carried(pass, "first") == planned(firstSteps))
        #expect(carried(pass, "second") == planned(secondSteps))
        let secondSends = pass.batches.flatMap { $0.sends(for: "second") }
        #expect(!secondSends.contains { $0.assetIDs.contains("h") }, "the hidden photo never goes to another account")
        let intoAlbums = pass.batches.flatMap(\.sends).filter { $0.albumTitle != nil }
        #expect(!intoAlbums.contains { $0.assetIDs.contains("h") }, "nor into any album")
        #expect(pass.batches.flatMap(\.sends).contains { $0.account == "first" && $0.albumTitle == nil && $0.assetIDs == ["h"] },
                "the primary's library still gets it")
        let secondIntoTrip = secondSends.filter { $0.albumID == "trip" && $0.albumTitle != nil }.flatMap(\.assetIDs)
        #expect(secondIntoTrip.isEmpty, "30 newcomers wait for the owner; none go into the linked album")
        #expect(!secondSends.contains { $0.assetIDs.contains("a") || $0.assetIDs.contains("b") }, "no re-add of what it has")
        #expect(BackupPlanner.heldAlbumAdds(albums: [busy], state: added).map(\.assetIDs.count) == [31])
        // Every staged photo is in exactly one batch.
        let staged = pass.batches.flatMap(\.assetIDs)
        #expect(staged.count == Set(staged).count)
        #expect(pass.batches.allSatisfy { $0.assetIDs.count <= 3 })
    }
}
