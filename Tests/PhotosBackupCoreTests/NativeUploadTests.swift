import Foundation
import Testing
@testable import PhotosBackupCore

/// UploadLane: the bridge's upload command and the Mac engine's decisions
/// between its requests, against a scripted Google.
@Suite struct UploadLaneTests {
    private func lane(_ fake: FakeUploader, parallel: Int = 4) -> UploadLane {
        UploadLane(account: "a@example.com", client: fake, quality: .original,
                   parallelism: UploadParallelism(cap: parallel, automatic: false))
    }

    @Test func aHashGoogleHasIsRecordedAsExistingWithoutSendingTheFile() async {
        let fake = FakeUploader()
        let item = Staged.item("IMG_1.HEIC")
        await fake.set { $0.existing[item.sha1] = "key-already" }
        let recorder = LaneRecorder()
        let end = await lane(fake).send([item], wait: recorder.waiter, report: recorder.reporter)
        #expect(end == .finished)
        #expect(await recorder.outcomes[item.assetID] == .committed(mediaKey: "key-already", existing: true))
        #expect(await fake.calls == ["find"])
    }

    @Test func aForcedItemSkipsTheHashCheckAndUploads() async {
        let fake = FakeUploader()
        let item = Staged.item("IMG_2.HEIC", force: true)
        await fake.set { $0.existing[item.sha1] = "key-lost-by-google" }
        let recorder = LaneRecorder()
        _ = await lane(fake).send([item], wait: recorder.waiter, report: recorder.reporter)
        #expect(await recorder.outcomes[item.assetID] == .committed(mediaKey: FakeUploader.key("IMG_2.HEIC"), existing: false))
        #expect(await !fake.calls.contains("find"))
    }

    @Test func commitsGoTwentyAtATimeAndAKeylessAnswerIsCommittedAlone() async {
        let fake = FakeUploader()
        let items = (0..<25).map { Staged.item("IMG_\($0).JPG") }
        await fake.set { $0.batchMisses = ["IMG_3.JPG"] }
        let recorder = LaneRecorder()
        let end = await lane(fake, parallel: 1).send(items, wait: recorder.waiter, report: recorder.reporter)
        #expect(end == .finished)
        #expect(await fake.commitSizes == [20, 5])
        #expect(await fake.calls.filter { $0.hasPrefix("commitOne") } == ["commitOne IMG_3.JPG"])
        let outcomes = await recorder.outcomes
        #expect(outcomes.count == 25)
        for item in items { #expect(outcomes[item.assetID] == .committed(mediaKey: FakeUploader.key(item.fileName), existing: false)) }
    }

    @Test func aPartialBatchKeepsItsKeysAndFailsOnlyTheItemWithout() async {
        let fake = FakeUploader()
        let items = ["A.JPG", "B.JPG", "C.JPG"].map { Staged.item($0) }
        await fake.set {
            $0.batchMisses = ["B.JPG"]
            $0.commitOneFailures["B.JPG"] = .invalidResponse("File upload rejected by api")
        }
        let recorder = LaneRecorder()
        _ = await lane(fake).send(items, wait: recorder.waiter, report: recorder.reporter)
        let outcomes = await recorder.outcomes
        #expect(outcomes["asset-A.JPG"] == .committed(mediaKey: "key-A.JPG", existing: false))
        #expect(outcomes["asset-C.JPG"] == .committed(mediaKey: "key-C.JPG", existing: false))
        #expect(outcomes["asset-B.JPG"] == .failed(message: "File upload rejected by api", retryable: false))
    }

    @Test func aRateLimitHoldsTheAccountWithoutUsingAnAttempt() async {
        let fake = FakeUploader()
        let item = Staged.item("IMG_9.HEIC")
        // More 429s than the attempt limit: none of them counts as one.
        await fake.set { $0.uploadFailures["IMG_9.HEIC"] = [.rateLimited, .rateLimited, .rateLimited] }
        let recorder = LaneRecorder()
        let clock = ManualClock()
        let start = clock.now
        let lane = UploadLane(account: "a@example.com", client: fake, quality: .original,
                              parallelism: UploadParallelism(cap: 2, automatic: false), now: clock.reader)
        let end = await lane.send([item], wait: clock.waiter(recorder), report: recorder.reporter)
        #expect(end == .finished)
        #expect(await recorder.outcomes[item.assetID] == .committed(mediaKey: "key-IMG_9.HEIC", existing: false))
        let waits = await recorder.waits
        #expect(waits.first == .some(nil))
        // The first hold is RateLimiter.initialHold, then it doubles.
        #expect(waits.dropFirst().first == .some(start.addingTimeInterval(RateLimiter.initialHold)))
        #expect(waits.dropFirst(2).first == .some(start.addingTimeInterval(RateLimiter.initialHold * 3)))
        #expect(await lane.retries.attempts(for: item.assetID) == 0)
    }

    @Test func googleKeptRefusingThroughEveryHoldEndsTheAccountsPart() async {
        let fake = FakeUploader()
        let item = Staged.item("IMG_8.HEIC")
        await fake.set { $0.uploadFailures["IMG_8.HEIC"] = Array(repeating: .rateLimited, count: 20) }
        let recorder = LaneRecorder()
        let clock = ManualClock()
        let lane = UploadLane(account: "a@example.com", client: fake, quality: .original,
                              parallelism: UploadParallelism(cap: 2, automatic: false), now: clock.reader)
        let end = await lane.send([item], wait: clock.waiter(recorder), report: recorder.reporter)
        #expect(end == .halted(LaneHalt(kind: .rateLimit, message: UploadLane.rateLimitGiveUp)))
        #expect(await recorder.outcomes[item.assetID] == .notSent)
    }

    @Test func retryableFailuresGoAgainAfterABackoffAndPermanentOnesFailAtOnce() async {
        let fake = FakeUploader()
        let flaky = Staged.item("FLAKY.JPG"), broken = Staged.item("BROKEN.JPG"), down = Staged.item("DOWN.JPG")
        await fake.set {
            $0.uploadFailures["FLAKY.JPG"] = [.http(status: 503, message: ""), .http(status: 503, message: "")]
            $0.uploadFailures["BROKEN.JPG"] = [.http(status: 400, message: "bad file")]
            $0.uploadFailures["DOWN.JPG"] = Array(repeating: .http(status: 500, message: ""), count: 5)
        }
        let recorder = LaneRecorder()
        let end = await lane(fake).send([flaky, broken, down], wait: recorder.waiter, report: recorder.reporter)
        #expect(end == .finished)
        let outcomes = await recorder.outcomes
        #expect(outcomes[flaky.assetID] == .committed(mediaKey: "key-FLAKY.JPG", existing: false))
        #expect(outcomes[broken.assetID] == .failed(message: "HTTP 400 from Google Photos: bad file", retryable: false))
        #expect(outcomes[down.assetID] == .failed(message: "HTTP 500 from Google Photos", retryable: true))
        // Three attempts (RetryPolicy.maxAttempts) for the one that kept failing.
        #expect(await fake.calls.filter { $0 == "upload DOWN.JPG" }.count == RetryPolicy().maxAttempts)
        #expect(await fake.calls.filter { $0 == "upload BROKEN.JPG" }.count == 1)
        // Every round after a retryable failure waited for its backoff.
        #expect(await recorder.waits.dropFirst().allSatisfy { $0 != nil })
    }

    @Test func aRefusedAccountEndsItsPartAndLeavesTheRestUnsent() async {
        let fake = FakeUploader()
        let items = ["A.JPG", "B.JPG"].map { Staged.item($0) }
        await fake.set { $0.uploadFailures["A.JPG"] = [.auth("BadAuthentication")] }
        let recorder = LaneRecorder()
        let end = await lane(fake, parallel: 1).send(items, wait: recorder.waiter, report: recorder.reporter)
        #expect(end == .halted(LaneHalt(kind: .auth, message: "BadAuthentication")))
        let outcomes = await recorder.outcomes
        #expect(outcomes["asset-A.JPG"] == .notSent)
        #expect(outcomes["asset-B.JPG"] == .committed(mediaKey: "key-B.JPG", existing: false))
    }

    @Test func anUnreachableGoogleEndsThePartOnceAttemptsAreSpent() async {
        let fake = FakeUploader()
        let item = Staged.item("NET.JPG")
        await fake.set { $0.uploadFailures["NET.JPG"] = Array(repeating: .network("offline"), count: 5) }
        let recorder = LaneRecorder()
        let end = await lane(fake).send([item], wait: recorder.waiter, report: recorder.reporter)
        #expect(end == .halted(LaneHalt(kind: .network, message: "Could not reach Google: offline")))
        #expect(await recorder.outcomes[item.assetID] == .failed(message: "Could not reach Google: offline", retryable: true))
    }

    @Test func cancellingMidBatchRecordsOnlyWhatWasCommitted() async throws {
        let fake = FakeUploader()
        let quick = Staged.item("QUICK.JPG"), slow = Staged.item("SLOW.MOV", size: 100), later = Staged.item("LATER.JPG")
        await fake.set {
            $0.existing[quick.sha1] = "key-quick"
            $0.hanging = ["SLOW.MOV"]
        }
        let recorder = LaneRecorder()
        let lane = lane(fake, parallel: 2)
        let task = Task { await lane.send([quick, slow, later], wait: recorder.waiter, report: recorder.reporter) }
        // LATER.JPG uploads beside the hanging SLOW.MOV and waits for a commit.
        for _ in 0..<200 where await fake.calls.filter({ $0.hasPrefix("upload") }).count < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        #expect(await task.value == .stopped)
        let outcomes = await recorder.outcomes
        #expect(outcomes[quick.assetID] == .committed(mediaKey: "key-quick", existing: true))
        // Uploaded bytes without a commit are not a backup.
        #expect(outcomes[slow.assetID] == .notSent)
        #expect(outcomes[later.assetID] == .notSent)
        #expect(await !fake.calls.contains { $0.hasPrefix("commit") })
        #expect(await recorder.reportCount == 3)
    }

    @Test func noKeyNoRecord() async {
        let fake = FakeUploader()
        let items = ["A.JPG", "B.JPG"].map { Staged.item($0) }
        // The batch is refused and so is each item on its own: no item may
        // come back committed.
        await fake.set {
            $0.commitFailures = Array(repeating: .invalidResponse("Google's answer to a commit could not be read."), count: 5)
        }
        let recorder = LaneRecorder()
        _ = await lane(fake).send(items, wait: recorder.waiter, report: recorder.reporter)
        let outcomes = await recorder.outcomes
        #expect(outcomes.count == 2)
        #expect(outcomes.values.allSatisfy { $0.mediaKey == nil })
        #expect(outcomes.values.allSatisfy { if case .failed = $0 { true } else { false } })
    }
}

/// AlbumMirroring: the bridge's _add_splitting_missing over the native calls.
@Suite struct AlbumMirroringTests {
    private static let noWait: AlbumMirroring.Sleeper = { _ in true }

    private static func keys(_ count: Int, from start: Int = 0) -> [String] { (start..<start + count).map { "k\($0)" } }

    @Test func aNewAlbumIsCreatedWithFiveHundredAndTheRestAppended() async {
        let fake = FakeUploader()
        let keys = Self.keys(1_200)
        let result = await AlbumMirroring.add(keys, to: nil, named: "Iceland", using: fake, sleep: Self.noWait)
        #expect(result.albumKey == "album-1")
        #expect(result.added == keys)
        #expect(result.error == nil)
        #expect(await fake.calls == ["create 500", "add 500", "add 200"])
        #expect(await fake.albums["album-1"] == keys)
    }

    @Test func anExistingAlbumIsAppendedToAndNeverCreatedAgain() async {
        let fake = FakeUploader()
        let result = await AlbumMirroring.add(Self.keys(3), to: "album-known", named: "Family", using: fake, sleep: Self.noWait)
        #expect(result.albumKey == "album-known")
        #expect(result.added == Self.keys(3))
        #expect(await fake.calls == ["add 3"])
    }

    @Test func aDeadKeyIsIsolatedByHalvingAndTheLiveOnesGoIn() async {
        let fake = FakeUploader()
        let keys = Self.keys(8)
        await fake.set { $0.deadKeys = ["k5"] }
        let result = await AlbumMirroring.add(keys, to: "album-known", named: "Family", using: fake, sleep: Self.noWait)
        #expect(result.missing == ["k5"])
        #expect(Set(result.added) == Set(keys).subtracting(["k5"]))
        #expect(result.error == nil)
        #expect(await fake.albums["album-known"].map(Set.init) == Set(keys).subtracting(["k5"]))
    }

    @Test func aDeadKeyInTheFirstBatchStillCreatesTheAlbum() async {
        let fake = FakeUploader()
        await fake.set { $0.deadKeys = ["k0"] }
        let result = await AlbumMirroring.add(Self.keys(4), to: nil, named: "Trip", using: fake, sleep: Self.noWait)
        #expect(result.albumKey != nil)
        #expect(result.missing == ["k0"])
        #expect(Set(result.added) == ["k1", "k2", "k3"])
    }

    @Test func aGoneAlbumIsTheAlbumsRefusalNotTheKeys() async {
        let fake = FakeUploader()
        await fake.set { $0.albumGone = true }
        let result = await AlbumMirroring.add(Self.keys(2), to: "album-deleted", named: "Old", using: fake, sleep: Self.noWait)
        // Nothing went in, and each key reads back alive: the 404 was the
        // album's. None is reported missing, and none is uploaded again.
        #expect(result.missing.isEmpty)
        #expect(result.added.isEmpty)
        #expect(result.error == .http(status: 404, message: "Not Found"))
        #expect(await fake.calls.filter { $0.hasPrefix("read") } == ["read k0", "read k1"])
    }

    @Test func keysThatAllReadBackDeadAreMissingAndTheAlbumIsFine() async {
        let fake = FakeUploader()
        await fake.set { $0.deadKeys = ["k0", "k1"] }
        let result = await AlbumMirroring.add(Self.keys(2), to: "album-known", named: "Family", using: fake, sleep: Self.noWait)
        // Nothing went in, so the 404s alone proved nothing; each key reading
        // back 404 too settles it: the keys are dead, the album is not.
        #expect(Set(result.missing) == ["k0", "k1"])
        #expect(result.error == nil)
    }

    @Test func anUnreadableKeyLeavesTheRefusalTheAlbumsButReportsTheDeadOnes() async {
        let fake = FakeUploader()
        await fake.set {
            $0.deadKeys = ["k0", "k1"]
            $0.unreadableKeys = ["k1"]
        }
        let result = await AlbumMirroring.add(Self.keys(2), to: "album-known", named: "Family", using: fake, sleep: Self.noWait)
        #expect(result.missing == ["k0"])
        #expect(result.error == .http(status: 404, message: "Not Found"))
    }

    @Test func noMoreThanSixteenKeysAreReadBack() async {
        let fake = FakeUploader()
        let keys = Self.keys(20)
        await fake.set { $0.deadKeys = Set(keys) }
        let result = await AlbumMirroring.add(keys, to: "album-known", named: "Family", using: fake, sleep: Self.noWait)
        #expect(await fake.calls.filter { $0.hasPrefix("read") }.count == AlbumMirroring.readBackBudget)
        // Past the budget nothing is settled: the dead ones read are reported,
        // the refusal stays the album's.
        #expect(result.missing.count == AlbumMirroring.readBackBudget)
        #expect(result.error == .http(status: 404, message: "Not Found"))
    }

    @Test func googlesPassingServerErrorsAreWaitedOut() async {
        let fake = FakeUploader()
        await fake.set { $0.albumFailures = [.http(status: 503, message: ""), .http(status: 500, message: "")] }
        let result = await AlbumMirroring.add(Self.keys(2), to: nil, named: "Trip", using: fake, sleep: Self.noWait)
        #expect(result.albumKey == "album-1")
        #expect(result.added == Self.keys(2))
        #expect(await fake.calls == ["create 2", "create 2", "create 2"])
    }

    @Test func aRateLimitStopsTheStepButKeepsWhatWentIn() async {
        let fake = FakeUploader()
        let keys = Self.keys(700)
        let result = await AlbumMirroring.add(keys, to: nil, named: "Trip", using: fake, sleep: { _ in true })
        #expect(result.added.count == 700)
        await fake.set { $0.albumFailures = [.rateLimited] }
        let second = await AlbumMirroring.add(Self.keys(600, from: 700), to: result.albumKey, named: "Trip", using: fake,
                                              sleep: Self.noWait)
        #expect(second.albumKey == result.albumKey)
        #expect(second.error == .rateLimited)
        #expect(second.added.isEmpty)
    }

    @Test func aDeadKeysPhotoIsForgottenAndForcedWhileTheRestIsRecorded() async {
        var state = BackupState()
        for id in ["a", "b", "c"] { state.recordUpload(assetID: id, mediaKey: "key-\(id)", existing: false) }
        var result = AlbumStepResult(albumKey: "album-1")
        result.added = ["key-a", "key-c"]
        result.missing = ["key-b"]
        let applied = AlbumMirroring.apply(result, albumID: "trip", assetIDs: ["a", "b", "c"], members: ["a", "b", "c"], to: &state)
        #expect(applied.forgotten == ["b"])
        #expect(state.uploaded["b"] == nil)
        #expect(state.forcedUploads == ["b"])
        #expect(state.mirrors["trip"]?.googleAlbumID == "album-1")
        #expect(state.mirrors["trip"]?.addedAssetIDs == ["a", "c"])
    }

    @Test func aStepThatMadeNoAlbumRecordsNothingButStillForgetsDeadKeys() async {
        var state = BackupState()
        state.recordUpload(assetID: "a", mediaKey: "key-a", existing: false)
        var result = AlbumStepResult(albumKey: nil)
        result.missing = ["key-a"]
        _ = AlbumMirroring.apply(result, albumID: "trip", assetIDs: ["a"], members: [], to: &state)
        #expect(state.mirrors["trip"] == nil)
        #expect(state.uploaded["a"] == nil)
    }

    @Test func aStopDuringAWaitEndsTheStepAndKeepsTheAlbum() async {
        let fake = FakeUploader()
        await fake.set { $0.albumFailures = [.http(status: 503, message: "")] }
        let result = await AlbumMirroring.add(Self.keys(600), to: nil, named: "Trip", using: fake, sleep: { _ in false })
        #expect(result.stopped)
        #expect(result.albumKey == nil)
        #expect(result.added.isEmpty)
    }
}
