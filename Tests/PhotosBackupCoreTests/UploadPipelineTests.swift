import Foundation
import PhotosBackupCore
import Testing

private let megabyte: Int64 = 1_000_000

private func sample(_ megabytes: Int64, seconds: TimeInterval = 10, items: Int = 20, rateLimited: Bool = false,
                    serverFailures: Int = 0, requested: Int = 0) -> UploadSample {
    UploadSample(bytes: megabytes * megabyte, seconds: seconds, items: items, rateLimited: rateLimited, serverFailures: serverFailures,
                 requested: requested)
}

@Suite struct UploadParallelismTests {
    @Test func theCeilingIsThirtyTwoAndTheStartStaysAtFour() {
        #expect(UploadParallelism.automaticCap == 32)
        #expect(UploadParallelism.initial == 4)
        #expect(UploadParallelism(cap: UploadParallelism.automaticCap, automatic: true).current == 4)
        #expect(UploadParallelism(cap: 32, automatic: false).current == 32)
        #expect(UploadParallelism(cap: 33, automatic: true).cap == 32)
        #expect(UploadParallelism(cap: 33, automatic: false).current == 32)
    }

    @Test func automaticClimbsToThirtyTwoOnlyWhileEveryStepIsFaster() {
        var parallelism = UploadParallelism(cap: UploadParallelism.automaticCap, automatic: true)
        // Nine steps, 4 to 32, each 20% faster than the last.
        var megabytes = 40.0
        for level in UploadParallelism.ladder.dropLast() {
            #expect(parallelism.current == level)
            parallelism.measured(sample(Int64(megabytes)))
            megabytes *= 1.2
        }
        #expect(parallelism.current == 32)
        #expect(parallelism.isClimbing)
        parallelism.measured(sample(Int64(megabytes)))
        #expect(parallelism.current == 32)
        #expect(parallelism.isClimbing == false)
    }

    /// One upload more at level L is only 1/L more in flight, so with steps
    /// of one a link that scales perfectly settled at 21 of 32: from about 20
    /// on no step of one or two can be 10% faster.
    @Test func everyStepAddsAtLeastAFifthSoALinkThatScalesReachesTheCap() {
        let ladder = UploadParallelism.ladder
        #expect(ladder.first == UploadParallelism.initial)
        #expect(ladder.last == UploadParallelism.automaticCap)
        for (lower, higher) in zip(ladder, ladder.dropFirst()) {
            #expect(Double(higher) >= 1.2 * Double(lower), "\(lower) to \(higher)")
        }
        var parallelism = UploadParallelism(cap: UploadParallelism.automaticCap, automatic: true)
        for _ in 0..<40 {
            // 1 MB/s for every upload in flight.
            parallelism.measured(sample(Int64(parallelism.current) * 10))
        }
        #expect(parallelism.current == 32)
        #expect(parallelism.summary == "32 at a time (the most it uses)")
    }

    @Test func automaticStartsAtFourAndClimbsWhileEachStepIsFaster() {
        var parallelism = UploadParallelism(cap: 8, automatic: true)
        #expect(parallelism.current == 4)
        for (level, megabytes) in zip([4, 5, 6], [40, 50, 60] as [Int64]) {
            #expect(parallelism.current == level)
            parallelism.measured(sample(megabytes))
        }
        #expect(parallelism.current == 8)
        parallelism.measured(sample(80))
        #expect(parallelism.current == 8)
        #expect(parallelism.isClimbing == false)
    }

    /// Through 0.6.0 the first step under 10% faster settled the level for
    /// the rest of the run, so one noisy batch (a few slow commits, a burst
    /// of tiny files) could hold a run at four or five uploads for hours.
    @Test func oneStepThatIsNotFasterDoesNotSettleTheLevel() {
        var parallelism = UploadParallelism(cap: 16, automatic: true)
        parallelism.measured(sample(40))  // 4 MB/s at 4
        parallelism.measured(sample(60))  // 6 MB/s at 5
        parallelism.measured(sample(62))  // 6.2 at 6: under 10% better than 5
        #expect(parallelism.current == 8)
        #expect(parallelism.isClimbing)
        parallelism.measured(sample(80))  // 8 at 8: better than the best, 6 at 5
        #expect(parallelism.current == 10)
        #expect(parallelism.isClimbing)
    }

    @Test func twoStepsInARowThatAreNotFasterGoBackToTheBestLevel() {
        var parallelism = UploadParallelism(cap: 16, automatic: true)
        parallelism.measured(sample(40))  // 4 MB/s at 4
        parallelism.measured(sample(60))  // 6 MB/s at 5
        parallelism.measured(sample(62))  // 6.2 at 6
        parallelism.measured(sample(64))  // 6.4 at 8: still under 6.6
        #expect(parallelism.current == 5)
        #expect(parallelism.isClimbing == false)
        #expect(parallelism.summary == "5 at a time (no faster at 8)")
        parallelism.measured(sample(200))
        #expect(parallelism.current == 5)
    }

    @Test func atTheTopASlowWindowIsMeasuredAgainBeforeItCounts() {
        var top = UploadParallelism(cap: 6, automatic: true)
        top.measured(sample(40))
        top.measured(sample(60))
        top.measured(sample(62))  // at 6, the cap: nowhere higher to look
        #expect(top.current == 6)
        #expect(top.isClimbing)
        top.measured(sample(70))
        #expect(top.current == 6)
        #expect(top.summary == "6 at a time (the most it uses)")
        var back = UploadParallelism(cap: 6, automatic: true)
        for megabytes in [40, 60, 62, 63] as [Int64] { back.measured(sample(megabytes)) }
        #expect(back.current == 5)
        #expect(back.summary == "5 at a time (no faster at 6)")
    }

    /// The link a run starts on is not the one it has hours later.
    @Test func aSettledLevelIsTriedOneStepHigherAgainLater() {
        var parallelism = UploadParallelism(cap: 16, automatic: true)
        for megabytes in [40, 60, 62, 64] as [Int64] { parallelism.measured(sample(megabytes)) }
        #expect(parallelism.current == 5)
        for _ in 1..<UploadParallelism.reprobeAfter {
            parallelism.measured(sample(60))
            #expect(parallelism.current == 5)
            #expect(parallelism.isClimbing == false)
        }
        parallelism.measured(sample(60))
        #expect(parallelism.current == 6)
        #expect(parallelism.isClimbing)
        #expect(parallelism.summary == "6 at a time, finding the fastest")
        parallelism.measured(sample(70))  // 7 at 6: over 6.6
        #expect(parallelism.current == 8)
    }

    @Test func aReprobeIsJudgedAgainstTheSettledLevelsLatestRate() {
        var parallelism = UploadParallelism(cap: 16, automatic: true)
        for megabytes in [40, 60, 62, 64] as [Int64] { parallelism.measured(sample(megabytes)) }
        // The link halves meanwhile: 3 MB/s at 5 is the baseline now, not 6.
        for _ in 0..<UploadParallelism.reprobeAfter { parallelism.measured(sample(30)) }
        #expect(parallelism.current == 6)
        parallelism.measured(sample(34))
        #expect(parallelism.current == 8)
        #expect(parallelism.isClimbing)
    }

    @Test func googlePushingBackEndsTheReprobesForTheRun() {
        var parallelism = UploadParallelism(cap: 16, automatic: true)
        for megabytes in [40, 60, 62, 64] as [Int64] { parallelism.measured(sample(megabytes)) }
        parallelism.measured(sample(60, rateLimited: true))
        #expect(parallelism.current == 2)
        for _ in 0..<(3 * UploadParallelism.reprobeAfter) { parallelism.measured(sample(400)) }
        #expect(parallelism.current == 2)
        #expect(parallelism.isClimbing == false)
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
        parallelism.measured(sample(60, items: 10, serverFailures: 2, requested: 12))
        #expect(parallelism.current == 4)
        #expect(parallelism.isClimbing == false)
    }

    /// Issue #66: two failures in a hundred-photo request are under a tenth
    /// of it, Google's noise rather than the level.
    @Test func failuresUnderATenthOfTheRequestAreNoise() {
        var parallelism = UploadParallelism(cap: 16, automatic: false)
        parallelism.measured(sample(40, items: 91, serverFailures: 9, requested: 100))
        #expect(parallelism.current == 16)
        parallelism.measured(sample(40, items: 90, serverFailures: 10, requested: 100))
        #expect(parallelism.current == 15, "a tenth of the request takes one off")
        // Not known how many were sent: the items that went up and the failures.
        parallelism.measured(sample(40, items: 18, serverFailures: 2))
        #expect(parallelism.current == 14)
        parallelism.measured(sample(40, items: 19, serverFailures: 2))
        #expect(parallelism.current == 14, "2 of 21 is under a tenth")
    }

    /// The 2026-11-05 run on 0.6.1: 16 at once to one account, 42 of 100
    /// photos saved. One off per request took 40+ minutes to reach a level
    /// Google accepts; half or more failing halves it.
    @Test func halfTheRequestFailingHalvesTheLevel() {
        var parallelism = UploadParallelism(cap: 16, automatic: false)
        parallelism.measured(sample(40, items: 42, serverFailures: 58, requested: 100))
        #expect(parallelism.current == 8)
        parallelism.measured(sample(40, items: 50, serverFailures: 50, requested: 100))
        #expect(parallelism.current == 4, "exactly half halves")
        parallelism.measured(sample(40, items: 51, serverFailures: 49, requested: 100))
        #expect(parallelism.current == 3, "just under half takes one off")
        parallelism.measured(sample(4, items: 0, serverFailures: 3, requested: 3))
        parallelism.measured(sample(4, items: 0, serverFailures: 3, requested: 3))
        #expect(parallelism.current == 1, "never under one")
        #expect(parallelism.summary == "1 at a time (Google had trouble keeping up)")
    }

    /// Review of PR #68, MEDIUM 3: a retry round carries only the items that
    /// just failed. 9 of 100 failing is noise; 5 of those 9 failing again
    /// read as 56% and halved the level.
    @Test func aRetryRoundsShareOfFailuresDoesNotLowerTheLevel() {
        var parallelism = UploadParallelism(cap: 16, automatic: false)
        parallelism.measured(sample(40, items: 91, serverFailures: 9, requested: 100))
        #expect(parallelism.current == 16)
        var retry = sample(2, items: 4, serverFailures: 5, requested: 9)
        retry.firstRound = false
        parallelism.measured(retry)
        #expect(parallelism.current == 16, "5 of the 9 retried is not half the level failing")
        // The next batch's first request is judged as before.
        parallelism.measured(sample(40, items: 42, serverFailures: 58, requested: 100))
        #expect(parallelism.current == 8)
        // A 429 in a retry round still halves.
        var limited = sample(2, items: 0, rateLimited: true, requested: 9)
        limited.firstRound = false
        parallelism.measured(limited)
        #expect(parallelism.current == 4)
    }

    @Test func aRetryRoundsFailureKeepsTheDecisionFromBeingClean() {
        var automatic = halvedFromEight()
        for _ in 1..<UploadParallelism.reprobeAfter { automatic.measured(sample(60)) }
        var retry = sample(60, items: 1, serverFailures: 3, requested: 4)
        retry.firstRound = false
        automatic.measured(retry)
        #expect(automatic.current == 4, "not lowered, and not a clean decision either")
        for _ in 1..<UploadParallelism.reprobeAfter { automatic.measured(sample(60)) }
        automatic.measured(sample(60))
        #expect(automatic.current == 5, "the count of clean decisions started again")
    }

    /// Issue #66: automatically, a level lowered for Google's trouble is
    /// tried one step higher after `reprobeAfter` clean decisions, and climbs
    /// on from there while each step is faster.
    @Test func automaticTriesALevelLoweredForTroubleAgainAfterCleanDecisions() {
        var parallelism = UploadParallelism(cap: 16, automatic: true)
        for megabytes in [40, 60, 80, 100, 130, 170] as [Int64] { parallelism.measured(sample(megabytes)) }
        #expect(parallelism.current == 16)
        parallelism.measured(sample(40, items: 42, serverFailures: 58, requested: 100))
        #expect(parallelism.current == 8)
        #expect(parallelism.mayRise)
        for _ in 1..<UploadParallelism.reprobeAfter { parallelism.measured(sample(60)) }
        #expect(parallelism.current == 8)
        parallelism.measured(sample(60))
        #expect(parallelism.current == 10, "one step up the ladder")
        #expect(parallelism.isClimbing)
        parallelism.measured(sample(80))
        #expect(parallelism.current == 13, "faster, so it climbs on")
    }

    /// Cap 8, climbed to 8 and halved to 4 for Google's trouble.
    private func halvedFromEight() -> UploadParallelism {
        var parallelism = UploadParallelism(cap: 8, automatic: true)
        for megabytes in [40, 60, 80] as [Int64] { parallelism.measured(sample(megabytes)) }
        #expect(parallelism.current == 8)
        parallelism.measured(sample(40, items: 4, serverFailures: 8, requested: 12))
        #expect(parallelism.current == 4)
        return parallelism
    }

    /// A one-off step down leaves no rung under the level Google had
    /// trouble at, so that level stays for the run.
    @Test func aLevelSteppedDownOneIsNotTriedAgain() {
        var parallelism = UploadParallelism(cap: 8, automatic: true)
        parallelism.measured(sample(40, items: 10, serverFailures: 2, requested: 12))
        #expect(parallelism.current == 3)
        #expect(parallelism.mayRise == false, "the timeline says for the rest of the backup")
        for _ in 0..<(3 * UploadParallelism.reprobeAfter) { parallelism.measured(sample(60)) }
        #expect(parallelism.current == 3)
        #expect(parallelism.mayRise == false)
        #expect(parallelism.summary == "3 at a time (Google had trouble keeping up at 4)")
    }

    /// From 16 halved to 8, then `reprobeAfter` clean decisions at 8.
    private func recoveringFromSixteen() -> UploadParallelism {
        var parallelism = UploadParallelism(cap: 32, automatic: true)
        for megabytes in [40, 60, 80, 100, 130, 170] as [Int64] { parallelism.measured(sample(megabytes)) }
        #expect(parallelism.current == 16)
        parallelism.measured(sample(40, items: 42, serverFailures: 58, requested: 100))
        #expect(parallelism.current == 8)
        for _ in 0..<UploadParallelism.reprobeAfter { parallelism.measured(sample(60)) }
        #expect(parallelism.current == 10)
        return parallelism
    }

    /// Review of PR #68, MEDIUM 4: the re-probe after Google's trouble
    /// re-entered the climb, whose "one miss climbs on" took 8 on to 10 and
    /// then 13 though 10 was no faster.
    @Test func aRecoveryProbeThatIsNotFasterSettlesAtOnce() {
        var parallelism = recoveringFromSixteen()
        parallelism.measured(sample(60))
        #expect(parallelism.current == 8, "10 was no faster than 8: back to 8, not on to 13")
        #expect(parallelism.isClimbing == false)
        #expect(parallelism.summary == "8 at a time (no faster at 10)")
    }

    @Test func aRecoveryClimbStopsUnderTheLevelGoogleHadTroubleAt() {
        var parallelism = recoveringFromSixteen()
        parallelism.measured(sample(80))
        #expect(parallelism.current == 13, "faster, so it climbs on")
        parallelism.measured(sample(100))
        #expect(parallelism.current == 13, "16 is where Google had trouble")
        #expect(parallelism.mayRise == false)
        #expect(parallelism.summary == "13 at a time (Google had trouble keeping up at 16)")
        for _ in 0..<(3 * UploadParallelism.reprobeAfter) { parallelism.measured(sample(400)) }
        #expect(parallelism.current == 13, "not for the rest of the run either")
    }

    @Test func aLaterProbeNeverReachesTheLevelGoogleHadTroubleAt() {
        var parallelism = recoveringFromSixteen()
        parallelism.measured(sample(60))
        #expect(parallelism.current == 8)
        // Settled at 8: the next probe climbs as usual, one miss on, but
        // never to 16.
        var levels: [Int] = []
        for _ in 0..<(4 * UploadParallelism.reprobeAfter) {
            parallelism.measured(sample(60))
            levels.append(parallelism.current)
        }
        #expect(levels.contains(10))
        #expect(levels.allSatisfy { $0 < 16 })
    }

    @Test func aFailureTooSmallToLowerTheLevelStartsTheCleanCountAgain() {
        var parallelism = UploadParallelism(cap: 16, automatic: false)
        var automatic = halvedFromEight()
        for _ in 1..<UploadParallelism.reprobeAfter { automatic.measured(sample(60)) }
        automatic.measured(sample(60, items: 99, serverFailures: 1, requested: 100))
        #expect(automatic.current == 4, "that decision was not clean")
        for _ in 1..<UploadParallelism.reprobeAfter { automatic.measured(sample(60)) }
        #expect(automatic.current == 4)
        automatic.measured(sample(60))
        #expect(automatic.current == 5)
        // A chosen number lowered for trouble stays lowered.
        parallelism.measured(sample(40, items: 42, serverFailures: 58, requested: 100))
        #expect(parallelism.mayRise == false)
        for _ in 0..<(3 * UploadParallelism.reprobeAfter) { parallelism.measured(sample(400)) }
        #expect(parallelism.current == 8)
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
        parallelism.measured(sample(40, items: 10, serverFailures: 2, requested: 12))
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
        parallelism.measured(sample(41))
        #expect(parallelism.summary == "4 at a time (no faster at 6)")
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
