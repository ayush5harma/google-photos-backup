import Foundation
import Testing
@testable import PhotosBackupCore

@Suite struct FailureClassifierTests {
    // Messages are what gpmc 0.9.0 logs through requests and urllib3.
    @Test(arguments: [
        "429 Client Error: Too Many Requests for url: https://photos.googleapis.com/data/upload/uploadmedia/interactive",
        "Too Many Requests",
    ])
    func googleSlowingDownIsARateLimit(message: String) {
        #expect(FailureClassifier.classify(message: message, bridgeRetryable: nil) == .rateLimited)
        // The status decides even when an older bridge sent no flag or a wrong one.
        #expect(FailureClassifier.classify(message: message, bridgeRetryable: false) == .rateLimited)
    }

    @Test(arguments: [
        "503 Server Error: Service Unavailable for url: https://photosdata-pa.googleapis.com/x",
        "500 Server Error: Internal Server Error for url: https://x",
        "408 Client Error: Request Timeout for url: https://x",
        "HTTPSConnectionPool(host='photos.googleapis.com', port=443): Read timed out. (read timeout=60)",
        "('Connection aborted.', RemoteDisconnected('Remote end closed connection without response'))",
        "[Errno 54] Connection reset by peer",
        "HTTPSConnectionPool(host='x', port=443): Max retries exceeded with url: /y (Caused by ResponseError('too many 503 error responses'))",
        "No answer from the uploader",
    ])
    func networkTroubleIsRetryable(message: String) {
        #expect(FailureClassifier.classify(message: message, bridgeRetryable: nil) == .retryable)
    }

    @Test(arguments: [
        "413 Client Error: Request Entity Too Large for url: https://x",
        "400 Client Error: Bad Request for url: https://x",
        "404 Client Error: Not Found for url: https://x",
        "File upload rejected by api",
        "[Errno 2] No such file or directory: '/tmp/x'",
    ])
    func badFilesAndOtherClientErrorsArePermanent(message: String) {
        #expect(FailureClassifier.classify(message: message, bridgeRetryable: nil) == .permanent)
    }

    @Test func aClientErrorStaysPermanentWhateverTheFlagSays() {
        #expect(FailureClassifier.classify(message: "413 Client Error: Request Entity Too Large", bridgeRetryable: true) == .permanent)
    }

    @Test func theBridgeFlagDecidesAMessageWithNoSignal() {
        #expect(FailureClassifier.classify(message: "something odd", bridgeRetryable: true) == .retryable)
        #expect(FailureClassifier.classify(message: "something odd", bridgeRetryable: false) == .permanent)
        #expect(FailureClassifier.classify(message: "something odd", bridgeRetryable: nil) == .permanent)
    }

    @Test func aNumberInsideAURLIsNotAStatus() {
        #expect(FailureClassifier.classify(message: "rejected https://x/429/y", bridgeRetryable: nil) == .permanent)
        #expect(FailureClassifier.statusCode(in: "upload_id=503abc failed") == nil)
        #expect(FailureClassifier.statusCode(in: "502 Server Error: Bad Gateway") == 502)
    }
}

@Suite struct RetryPolicyTests {
    @Test func backoffDoublesFromOneSecondAndStopsAtThirty() {
        let policy = RetryPolicy()
        #expect((1...7).map { policy.delay(afterFailedAttempt: $0) } == [1, 2, 4, 8, 16, 30, 30])
        #expect(policy.delay(afterFailedAttempt: 0) == 1)
        #expect(policy.delay(afterFailedAttempt: 1000) == 30)
    }

    @Test func aRetryableFailureGetsThreeAttemptsInAll() {
        var tracker = RetryTracker()
        #expect(tracker.failed("a", as: .retryable) == .retry(after: 1))
        #expect(tracker.failed("a", as: .retryable) == .retry(after: 2))
        #expect(tracker.failed("a", as: .retryable) == .giveUp)
        #expect(tracker.attempts(for: "a") == 3)
    }

    @Test func aPermanentFailureGivesUpAtOnce() {
        var tracker = RetryTracker()
        #expect(tracker.failed("a", as: .permanent) == .giveUp)
    }

    @Test func aRateLimitDoesNotUseUpAnAttempt() {
        var tracker = RetryTracker()
        #expect(tracker.failed("a", as: .retryable) == .retry(after: 1))
        for _ in 0..<10 { #expect(tracker.failed("a", as: .rateLimited) == .waitForRateLimit) }
        #expect(tracker.attempts(for: "a") == 1)
        #expect(tracker.failed("a", as: .retryable) == .retry(after: 2))
        #expect(tracker.failed("a", as: .retryable) == .giveUp)
    }

    @Test func itemsAreCountedSeparately() {
        var tracker = RetryTracker()
        _ = tracker.failed("a", as: .retryable)
        _ = tracker.failed("a", as: .retryable)
        #expect(tracker.failed("b", as: .retryable) == .retry(after: 1))
        tracker.forget("a")
        #expect(tracker.failed("a", as: .retryable) == .retry(after: 1))
    }
}

@Suite struct RateLimiterTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    @Test func holdsSixtySecondsThenDoublesToTenMinutes() {
        var limiter = RateLimiter()
        var now = start
        var holds: [TimeInterval] = []
        for _ in 0..<6 {
            let until = limiter.hitLimit(at: now)
            holds.append(until.timeIntervalSince(now))
            now = until  // the next batch runs once the hold is over
        }
        #expect(holds == [60, 120, 240, 480, 600, 600])
    }

    @Test func moreLimitsDuringOneHoldShareIt() {
        var limiter = RateLimiter()
        let until = limiter.hitLimit(at: start)
        #expect(limiter.hitLimit(at: start.addingTimeInterval(5)) == until)
        #expect(limiter.hitLimit(at: start.addingTimeInterval(30)) == until)
        // Only once the hold is over does the next one double.
        #expect(limiter.hitLimit(at: until).timeIntervalSince(until) == 120)
    }

    @Test func aSuccessfulBatchStartsOverAtOneMinute() {
        var limiter = RateLimiter()
        let first = limiter.hitLimit(at: start)
        _ = limiter.hitLimit(at: first)
        limiter.batchSucceeded()
        #expect(limiter.holdUntil == nil)
        #expect(limiter.hitLimit(at: start.addingTimeInterval(1000)).timeIntervalSince(start.addingTimeInterval(1000)) == 60)
    }

    @Test func aRunGivesUpAfterFiveHoldsWithNothingGettingThrough() {
        var limiter = RateLimiter()
        var now = start
        for _ in 0..<RateLimiter.maximumHoldsPerRun {
            now = limiter.hitLimit(at: now)
            #expect(!limiter.runShouldGiveUp)
        }
        // Refusals during a hold do not count as more holds.
        _ = limiter.hitLimit(at: now.addingTimeInterval(-1))
        #expect(!limiter.runShouldGiveUp)
        _ = limiter.hitLimit(at: now)
        #expect(limiter.runShouldGiveUp)

        // A new run starts its allowance over but keeps Google's hold.
        let hold = limiter.holdUntil
        limiter.runStarted()
        #expect(!limiter.runShouldGiveUp)
        #expect(limiter.holdUntil == hold)
    }

    @Test func aBatchThatGetsThroughResetsTheAllowance() {
        var limiter = RateLimiter()
        var now = start
        for _ in 0..<4 { now = limiter.hitLimit(at: now) }
        limiter.batchSucceeded()
        for _ in 0..<RateLimiter.maximumHoldsPerRun { now = limiter.hitLimit(at: now) }
        #expect(!limiter.runShouldGiveUp)
    }

    @Test func remainingHoldEndsByItself() {
        var limiter = RateLimiter()
        #expect(limiter.hold(at: start) == nil)
        let until = limiter.hitLimit(at: start)
        #expect(limiter.hold(at: start.addingTimeInterval(10)) == until)
        #expect(limiter.hold(at: until) == nil)
    }
}

/// Review of PR #68, HIGH 1: accounts side by side shared one limiter, so
/// one account's success cancelled another's 429 hold.
@Suite struct AccountRateLimitsTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)
    private let first = "first@example.com"
    private let second = "second@example.com"

    @Test func anAccountInAHoldStaysHeldWhileAnotherAccountsRequestsSucceed() {
        var limits = AccountRateLimits()
        let until = limits.hitLimit(first, at: start)
        // The second account's request was in flight and comes back confirmed.
        limits.batchSucceeded(second)
        limits.batchSucceeded(second)
        #expect(limits.hold(first, at: start.addingTimeInterval(1)) == until, "still held a second later")
        #expect(limits[first].holdsThisRun == 1)
        #expect(limits.hold(second, at: start.addingTimeInterval(1)) == nil, "the other account sends on")
    }

    @Test func theHoldGrowsOnOneAccountsRepeatedLimitsWhateverAnotherDoes() {
        var limits = AccountRateLimits()
        var now = start
        var holds: [TimeInterval] = []
        for _ in 0..<4 {
            let until = limits.hitLimit(first, at: now)
            holds.append(until.timeIntervalSince(now))
            limits.batchSucceeded(second)
            now = until
        }
        #expect(holds == [60, 120, 240, 480])
    }

    @Test func eachAccountHasItsOwnAllowanceOfHolds() {
        var limits = AccountRateLimits()
        var now = start
        for _ in 0...RateLimiter.maximumHoldsPerRun { now = limits.hitLimit(first, at: now) }
        #expect(limits.runShouldGiveUp(first))
        _ = limits.hitLimit(second, at: now)
        #expect(!limits.runShouldGiveUp(second), "one 429 of its own does not end the second account's part")
        #expect(limits[second].holdsThisRun == 1)

        // A new run starts every allowance over and keeps Google's holds.
        let during = now.addingTimeInterval(-1)
        let hold = limits.hold(first, at: during)
        #expect(hold != nil)
        limits.runStarted()
        #expect(!limits.runShouldGiveUp(first))
        #expect(limits.hold(first, at: during) == hold)
    }

    @Test func theExportWaitsOnlyWhileEveryAccountIsHeld() {
        var limits = AccountRateLimits()
        let firstUntil = limits.hitLimit(first, at: start)
        #expect(limits.everyHeld([first, second], at: start) == nil)
        let secondUntil = limits.hitLimit(second, at: start.addingTimeInterval(10))
        #expect(limits.everyHeld([first, second], at: start.addingTimeInterval(10)) == min(firstUntil, secondUntil))
        #expect(limits.everyHeld([], at: start) == nil)
    }
}
