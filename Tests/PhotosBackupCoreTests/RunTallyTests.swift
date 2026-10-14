import Foundation
import Testing
@testable import PhotosBackupCore

@Suite struct RunTallyTests {
    @Test func countsEachOutcomeOnce() {
        var tally = RunTally()
        tally.planned(3)
        let result1 = tally.confirmed("a", existing: false, bytes: 100)
        #expect(result1)
        let result2 = tally.confirmed("b", existing: true, bytes: 50)
        #expect(result2)
        let result3 = tally.failed("c")
        #expect(result3)
        let result4 = tally.confirmed("a", existing: false, bytes: 100)
        #expect(!result4)
        let result5 = tally.failed("c")
        #expect(!result5)
        let result6 = tally.failed("a")
        #expect(!result6)
        #expect((tally.total, tally.done, tally.uploaded, tally.existing, tally.failed, tally.bytes) == (3, 3, 1, 1, 1, 100))
    }

    @Test func aRetriedItemThatGoesThroughIsNotAlsoAFailure() {
        var tally = RunTally()
        tally.planned(2)
        tally.confirmed("a", existing: false, bytes: 10)
        tally.failed("b")
        let result7 = tally.requeued("b")
        #expect(result7)
        #expect((tally.total, tally.done, tally.failed) == (1, 1, 0))
        tally.planned(1)  // planned again by the next pass
        tally.confirmed("b", existing: false, bytes: 20)
        #expect((tally.total, tally.done, tally.uploaded, tally.failed, tally.bytes) == (2, 2, 2, 0, 30))
    }

    @Test func aConfirmationAfterAFailureReplacesIt() {
        var tally = RunTally()
        tally.planned(1)
        tally.failed("a")
        tally.confirmed("a", existing: true, bytes: 0)
        #expect((tally.total, tally.done, tally.existing, tally.failed) == (1, 1, 1, 0))
        #expect(tally.failedIDs.isEmpty)
    }

    @Test func requeueingSomethingThatDidNotFailHereChangesNothing() {
        var tally = RunTally()
        tally.planned(1)
        let result8 = tally.requeued("from-an-earlier-run")
        #expect(!result8)
        #expect(tally == { var t = RunTally(); t.planned(1); return t }())
    }

    @Test func assetsConfirmedThisRunAreNeverPlannedAgainEvenAsEdits() {
        // Photos' analysis or a favourite moves an asset's date while the run
        // is going; the planner must not send it again in the same run.
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        var state = BackupState()
        state.selectedAlbumIDs = ["all"]
        state.recordUpload(assetID: "a", mediaKey: "k", existing: false, stamp: EditStamp(modified: t0, edited: true))
        var tally = RunTally()
        tally.confirmed("a", existing: false, bytes: 1)
        let moved = AlbumSnapshot(id: "all", title: "All", kind: .allPhotos, assetIDs: ["a"], modified: ["a": t0.addingTimeInterval(30)])

        #expect(BackupPlanner.plan(albums: [moved], state: state, mirrorAlbums: true, batchSize: 10, reuploadEdits: true)
            == [.reupload(assetIDs: ["a"])])
        #expect(BackupPlanner.plan(albums: [moved], state: state, mirrorAlbums: true, batchSize: 10,
                                   excludingAssets: tally.confirmedIDs, reuploadEdits: true).isEmpty)
    }
}
