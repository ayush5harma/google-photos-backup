import Foundation
import PhotosBackupCore
import Testing

private let megabyte: Int64 = 1_000_000

private func sample(_ megabytes: Int64, seconds: TimeInterval = 10, items: Int = 20, rateLimited: Bool = false,
                    serverFailures: Int = 0) -> UploadSample {
    UploadSample(bytes: megabytes * megabyte, seconds: seconds, items: items, rateLimited: rateLimited, serverFailures: serverFailures)
}

@Suite struct UploadParallelismTests {
    @Test func theCeilingIsSixteenAndTheStartStaysAtFour() {
        #expect(UploadParallelism.automaticCap == 16)
        #expect(UploadParallelism.initial == 4)
        #expect(UploadParallelism(cap: UploadParallelism.automaticCap, automatic: true).current == 4)
        #expect(UploadParallelism(cap: 17, automatic: true).cap == 16)
    }

    @Test func automaticClimbsToSixteenOnlyWhileEveryStepIsFaster() {
        var parallelism = UploadParallelism(cap: UploadParallelism.automaticCap, automatic: true)
        // Twelve steps, 4 to 16, each 20% faster than the last.
        var megabytes = 40.0
        for level in 4...15 {
            #expect(parallelism.current == level)
            parallelism.measured(sample(Int64(megabytes)))
            megabytes *= 1.2
        }
        #expect(parallelism.current == 16)
        #expect(parallelism.isClimbing)
        parallelism.measured(sample(Int64(megabytes)))
        #expect(parallelism.current == 16)
        #expect(parallelism.isClimbing == false)
    }

    @Test func automaticStartsAtFourAndClimbsWhileEachStepIsFaster() {
        var parallelism = UploadParallelism(cap: 8, automatic: true)
        #expect(parallelism.current == 4)
        for (level, megabytes) in zip(4...7, [40, 50, 60, 70] as [Int64]) {
            #expect(parallelism.current == level)
            parallelism.measured(sample(megabytes))
        }
        #expect(parallelism.current == 8)
        parallelism.measured(sample(80))
        #expect(parallelism.current == 8)
        #expect(parallelism.isClimbing == false)
    }

    @Test func aStepThatIsNotFasterGoesBackToTheBestLevelAndStays() {
        var parallelism = UploadParallelism(cap: 8, automatic: true)
        parallelism.measured(sample(40))  // 4 MB/s at 4
        parallelism.measured(sample(60))  // 6 MB/s at 5
        parallelism.measured(sample(62))  // 6.2 at 6: under 10% better
        #expect(parallelism.current == 5)
        #expect(parallelism.isClimbing == false)
        parallelism.measured(sample(200))
        #expect(parallelism.current == 5)
    }

    @Test func aRateLimitHalvesAndStopsTheClimb() {
        var parallelism = UploadParallelism(cap: 8, automatic: true)
        parallelism.measured(sample(40))
        parallelism.measured(sample(60))
        #expect(parallelism.current == 6)
        parallelism.measured(sample(60, rateLimited: true))
        #expect(parallelism.current == 3)
        #expect(parallelism.isClimbing == false)
        parallelism.measured(sample(400))
        #expect(parallelism.current == 3)
        parallelism.measured(sample(10, rateLimited: true))
        parallelism.measured(sample(10, rateLimited: true))
        #expect(parallelism.current == 1)
    }

    @Test func repeatedServerFailuresStepDownOneAndStopTheClimb() {
        var parallelism = UploadParallelism(cap: 8, automatic: true)
        parallelism.measured(sample(40, serverFailures: 1))  // one passing 5xx is not pressure
        #expect(parallelism.current == 5)
        parallelism.measured(sample(60, serverFailures: 2))
        #expect(parallelism.current == 4)
        #expect(parallelism.isClimbing == false)
    }

    @Test func aSmallSampleWaitsForMore() {
        var parallelism = UploadParallelism(cap: 8, automatic: true)
        // Everything already in Google Photos: nothing went up, nothing to judge.
        parallelism.measured(UploadSample(bytes: 0, seconds: 3, items: 0, rateLimited: false, serverFailures: 0))
        #expect(parallelism.current == 4)
        // Two small batches add up to one decision.
        parallelism.measured(sample(10, seconds: 2))
        #expect(parallelism.current == 4)
        parallelism.measured(sample(20, seconds: 3))
        #expect(parallelism.current == 5)
    }

    @Test func theRequestThatStartedTheBridgeCountsOnlyForPushback() {
        var parallelism = UploadParallelism(cap: 8, automatic: true)
        var first = sample(40, seconds: 20)
        first.includesStartUp = true
        parallelism.measured(first)
        #expect(parallelism.current == 4)
        parallelism.measured(sample(40))
        #expect(parallelism.current == 5)
        var limited = UploadParallelism(cap: 8, automatic: true)
        first.rateLimited = true
        limited.measured(first)
        #expect(limited.current == 2)
    }

    @Test func aCapUnderTheStartIsTheMostAutomaticUses() {
        var two = UploadParallelism(cap: 2, automatic: true)
        #expect(two.current == 2)
        two.measured(sample(400))
        #expect(two.current == 2)
        #expect(UploadParallelism(cap: 40, automatic: true).cap == UploadParallelism.automaticCap)
        #expect(UploadParallelism(cap: 0, automatic: true).current == 1)
    }

    /// 2026-11-05, v0.6.0: a chosen 16 still started at four and climbed one
    /// level per ~24 MB measured; that run of small photos went at about one
    /// photo a second on a 177 Mbit/s uplink. A chosen number is now the
    /// number from the first request.
    @Test func aChosenNumberIsUsedFromTheFirstRequest() {
        for chosen in 1...UploadParallelism.automaticCap {
            let parallelism = UploadParallelism(cap: chosen, automatic: false)
            #expect(parallelism.current == chosen, "\(chosen)")
            #expect(parallelism.isClimbing == false, "\(chosen)")
        }
        var sixteen = UploadParallelism(cap: 16, automatic: false)
        #expect(sixteen.summary == "16 at a time (as chosen in Settings)")
        // Nothing it measures moves it, faster or slower.
        for megabytes in [400, 40, 4000, 41] as [Int64] {
            sixteen.measured(sample(megabytes))
            #expect(sixteen.current == 16)
        }
        #expect(UploadParallelism(cap: 0, automatic: false).current == 1)
    }

    @Test func aChosenNumberStillBacksOffWhenGooglePushesBack() {
        var parallelism = UploadParallelism(cap: 16, automatic: false)
        parallelism.measured(sample(40, serverFailures: 1))  // one passing 5xx is not pressure
        #expect(parallelism.current == 16)
        parallelism.measured(sample(40, rateLimited: true))
        #expect(parallelism.current == 8)
        #expect(parallelism.summary == "8 at a time (Google asked to slow down)")
        parallelism.measured(sample(40, serverFailures: 2))
        #expect(parallelism.current == 7)
        // It never goes back up within the run.
        for _ in 0..<20 { parallelism.measured(sample(400)) }
        #expect(parallelism.current == 7)
        #expect(parallelism.isClimbing == false)
    }

    @Test func itSaysWhyItIsWhereItIs() {
        var parallelism = UploadParallelism(cap: 8, automatic: true)
        #expect(parallelism.summary == "4 at a time, finding the fastest")
        parallelism.measured(sample(40))
        parallelism.measured(sample(41))
        #expect(parallelism.summary == "4 at a time (no faster at 5)")
        parallelism.measured(sample(10, rateLimited: true))
        #expect(parallelism.summary == "2 at a time (Google asked to slow down)")
    }
}

@Suite struct ThroughputMeterTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    @Test func speedIsTheBytesSentInTheLastHalfMinute() {
        var meter = ThroughputMeter()
        for second in 0...40 {
            meter.sent(id: "a", total: Int64(second) * 2 * megabyte, at: start.addingTimeInterval(Double(second)))
        }
        let rate = try? #require(meter.bytesPerSecond(at: start.addingTimeInterval(40)))
        #expect(rate == Double(2 * megabyte))
        #expect(meter.bytesSent == 80 * megabyte)
    }

    @Test func parallelFilesAddUpAndARetryIsNotCountedTwice() {
        var meter = ThroughputMeter()
        meter.sent(id: "a", total: 5 * megabyte, at: start)
        meter.sent(id: "b", total: 3 * megabyte, at: start)
        meter.sent(id: "a", total: 6 * megabyte, at: start.addingTimeInterval(1))
        // b starts over after a failure: its new bytes are sent again, really.
        meter.sent(id: "b", total: 1 * megabyte, at: start.addingTimeInterval(1))
        #expect(meter.bytesSent == 10 * megabyte)
        // An item sent again (Retry, a new pass) starts from nothing.
        meter.finished(id: "a", at: start.addingTimeInterval(2))
        meter.sent(id: "a", total: 6 * megabyte, at: start.addingTimeInterval(3))
        #expect(meter.bytesSent == 16 * megabyte)
    }

    @Test func noSpeedBeforeThereIsAnythingToShow() {
        var meter = ThroughputMeter()
        #expect(meter.bytesPerSecond(at: start) == nil)
        meter.sent(id: "a", total: megabyte, at: start)
        #expect(meter.bytesPerSecond(at: start.addingTimeInterval(1)) == nil)
    }

    @Test func timeLeftFollowsHowFastItemsFinish() {
        var meter = ThroughputMeter()
        for index in 0..<10 {
            meter.finished(id: "\(index)", at: start.addingTimeInterval(Double(index) * 6))
        }
        // 10 items over 54 s: 6 s each; 100 left is about 10 minutes.
        let left = meter.secondsLeft(remaining: 100, at: start.addingTimeInterval(54))
        #expect(left.map { Int($0.rounded()) } == 600)
        #expect(meter.secondsLeft(remaining: 0, at: start.addingTimeInterval(54)) == 0)
        #expect(ThroughputMeter().secondsLeft(remaining: 5, at: start) == nil)
    }

    @Test func theLineReadsLikeTheRestOfTheApp() {
        #expect(ThroughputMeter.describe(bytesPerSecond: 12_345_678, secondsLeft: 14 * 60 + 20) == "12.3 MB/s, about 14 min left")
        #expect(ThroughputMeter.describe(bytesPerSecond: 640_000, secondsLeft: 40) == "0.6 MB/s, less than a minute left")
        #expect(ThroughputMeter.describe(bytesPerSecond: 3_000_000, secondsLeft: 2 * 3600 + 30 * 60) == "3.0 MB/s, about 2 h 30 min left")
        #expect(ThroughputMeter.describe(bytesPerSecond: 3_000_000, secondsLeft: nil) == "3.0 MB/s")
        #expect(ThroughputMeter.describe(bytesPerSecond: nil, secondsLeft: 90) == nil)
    }
}

@Suite struct StagingWindowTests {
    @Test func exportRunsAheadByTwoBatchesWithinTheByteCap() {
        #expect(StagingWindow.mayStage(batchesReady: 0, bytesReady: 0))
        #expect(StagingWindow.mayStage(batchesReady: 1, bytesReady: 500 * megabyte))
        #expect(!StagingWindow.mayStage(batchesReady: 2, bytesReady: 0))
        #expect(!StagingWindow.mayStage(batchesReady: 1, bytesReady: StagingWindow.bytesAhead))
    }

    /// PR #52 review: an export ahead asks before each item, so one batch of
    /// large videos cannot stage past the cap.
    @Test func anItemGoesAheadOnlyIfItFitsUnderTheCap() {
        let cap = StagingWindow.bytesAhead
        #expect(StagingWindow.mayExportAhead(staged: 0, next: 600 * megabyte, freeSpace: nil))
        #expect(StagingWindow.mayExportAhead(staged: cap - 600 * megabyte, next: 600 * megabyte, freeSpace: nil))
        #expect(!StagingWindow.mayExportAhead(staged: cap - 600 * megabyte, next: 601 * megabyte, freeSpace: nil))
        // One video larger than the whole window waits for its own turn.
        #expect(!StagingWindow.mayExportAhead(staged: 0, next: cap + 1, freeSpace: nil))
    }

    @Test func anItemOfUnknownSizeGoesAheadOnlyWhileUnderTheCap() {
        let cap = StagingWindow.bytesAhead
        #expect(StagingWindow.mayExportAhead(staged: cap - 1, next: nil, freeSpace: nil))
        #expect(!StagingWindow.mayExportAhead(staged: cap, next: nil, freeSpace: nil))
    }

    @Test func anExportAheadLeavesTheDiskItsFloor() {
        let floor = StagingWindow.freeSpaceFloor
        #expect(StagingWindow.mayExportAhead(staged: 0, next: 500 * megabyte, freeSpace: floor + 500 * megabyte))
        #expect(!StagingWindow.mayExportAhead(staged: 0, next: 500 * megabyte, freeSpace: floor + 499 * megabyte))
        #expect(!StagingWindow.mayExportAhead(staged: 0, next: nil, freeSpace: floor - 1))
        #expect(StagingWindow.mayExportAhead(staged: 0, next: nil, freeSpace: floor))
    }

    @Test func largeFilesGoFirstAndUnknownSizesLast() {
        let sizes: [(String, Int64?)] = [("a", 3), ("b", nil), ("c", 900), ("d", 3), ("e", 40)]
        #expect(StagingWindow.largestFirst(sizes, size: \.1).map(\.0) == ["c", "e", "a", "d", "b"])
    }
}
