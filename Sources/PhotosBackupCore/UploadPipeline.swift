import Foundation

/// One bridge request's upload, as the parallelism controller reads it.
public struct UploadSample: Equatable, Sendable {
    /// Bytes of the items Google stored (items it already had send nothing).
    public var bytes: Int64
    /// From sending the request to its answer.
    public var seconds: TimeInterval
    /// Items that went up (not already in Google Photos).
    public var items: Int
    /// Google answered HTTP 429 during the request.
    public var rateLimited: Bool
    /// Items that failed in a way sending again may fix: a 5xx, a 408, a
    /// dropped connection or a timeout.
    public var serverFailures: Int
    /// Items the request sent, whatever became of them: the share of
    /// failures is judged against this. 0 when not known, which counts as
    /// the items that went up plus those that failed.
    public var requested: Int
    /// The run's first request, whose time includes the bridge's start-up
    /// and sign-in: it counts for pushback, not for speed.
    public var includesStartUp: Bool
    /// False for a retry round: a request that carries only the items the
    /// one before it just failed. Its share of failures is not the level's
    /// (review of PR #68): 9 of 100 failing is noise, but 5 of those 9
    /// failing again read as 56% and halved the level.
    public var firstRound: Bool

    public init(bytes: Int64, seconds: TimeInterval, items: Int, rateLimited: Bool, serverFailures: Int,
                includesStartUp: Bool = false, requested: Int = 0, firstRound: Bool = true) {
        self.bytes = bytes
        self.seconds = seconds
        self.items = items
        self.rateLimited = rateLimited
        self.serverFailures = serverFailures
        self.includesStartUp = includesStartUp
        self.requested = requested
        self.firstRound = firstRound
    }

    /// The share of the request's items that failed retryably, 0 to 1.
    var failureShare: Double {
        let sent = max(requested, items + serverFailures)
        return sent == 0 ? 0 : Double(serverFailures) / Double(sent)
    }
}

/// How many uploads go at once, decided between bridge requests (issue #50),
/// for one account: with several accounts each has its own (issue #66).
///
/// A number chosen in Settings is used from the run's first request. Through
/// 0.6.0 it was only a ceiling for the climb below. Measured 2026-11-05 on
/// 0.6.0 with 16 chosen and a run of small photos: about one photo a second
/// (0.6-0.8 MB/s) on a 177 Mbit/s uplink, and a 5 s sample of the bridge had
/// 4 uploads sending and 4 waiting on Google. Each photo is about four round
/// trips (hash check, upload token, bytes, commit), so the photos in flight,
/// not the bandwidth, set the pace.
///
/// Automatically, it starts at four and climbs the `ladder` while each step
/// is measurably faster (10% more bytes a second than the best level so far).
/// A step that is not faster is the link's limit showing as longer per-file
/// times, so that is also how rising latency reads here; but one such step
/// can as well be noise (a few slow commits, a batch of tiny files), so it
/// climbs on, and only a second in a row goes back to the best level. A
/// settled level is tried one step higher after `reprobeAfter` decisions,
/// judged against its own latest rate, since the link a run starts on is not
/// the one it has hours later.
///
/// In either mode Google pushing back lowers it. A 429 halves the level and
/// ends the climb for the run. Retryable failures (5xx, timeouts) lower it in
/// proportion to how much of the request failed (issue #66): not at all
/// below two failures or below a tenth of the request's items, one off from
/// there, and half when half or more failed. Only a batch's first request
/// is judged this way: a retry round carries only items that just failed,
/// so its share says nothing about the level. Measured 2026-11-05 on 0.6.1 at
/// 16 to one account: Google's commit call answered 500/503 about 190 times
/// in 3.4 minutes across 104 files, and the first 100-photo batch saved 42
/// (0.2 a second); at about 4 to 8 on 0.6.0 there were 12 such errors in 70
/// minutes (0.66 a second). Taking one off per request took about 12
/// batches, over 40 minutes, to come down from 16; halving takes one or two.
/// What Google limits is the commits one account takes at once, which can
/// change over hours, so in automatic mode a level lowered this way is tried
/// one step higher again after `reprobeAfter` clean decisions (no retryable
/// failure in any request they measured) and climbs from there as above. A
/// chosen number stays lowered for the run.
public struct UploadParallelism: Equatable, Sendable {
    /// The bridge's MAX_THREADS, and the most a chosen number may be. A
    /// ceiling for the climb, which reaches it only while each step keeps
    /// improving throughput. 32 since 2026-11-05: with each photo about four
    /// round trips, the photos in flight bound a run of small photos long
    /// before a 177 Mbit/s uplink does.
    public static let automaticCap = 32
    public static let initial = 4
    /// The levels the climb steps through, each at least a fifth more uploads
    /// than the one before. With steps of one, a step at level L adds only
    /// 1/L more in flight, so from about ten on no step could be 10% faster
    /// even on a link that scales perfectly; such a link settled at 21 of 32.
    public static let ladder = [4, 5, 6, 8, 10, 13, 16, 20, 25, 32]
    public static let improvement = 0.10
    /// A level is judged on at least this much: one batch of photos is
    /// usually enough, a batch of items Google already has is not.
    public static let decisionBytes: Int64 = 24_000_000
    public static let decisionSeconds: TimeInterval = 4
    /// One passing 5xx is Google's noise, not pressure.
    public static let serverFailuresThatCount = 2
    /// Retryable failures under this share of a request's items are noise
    /// too: a 5xx or two in a hundred-photo batch say little about the level.
    public static let serverFailureShare = 0.10
    /// From this share of a request's items failed, the level halves.
    public static let halvingShare = 0.5
    /// Steps in a row not faster than the best before the climb settles.
    public static let missesToSettle = 2
    /// Decisions at a settled level before it is tried one step higher: about
    /// ten batches of photos, so a probe that is not faster costs a small
    /// share of the run.
    public static let reprobeAfter = 10

    private enum Reason: Equatable, Sendable {
        case finding, noFaster(Int), most, chosen, rateLimited, serverTrouble
    }

    private struct Rate: Equatable, Sendable {
        let level: Int
        let bytesPerSecond: Double
    }

    public let cap: Int
    /// False: `cap` is the number chosen in Settings, used as it is.
    public let automatic: Bool
    public private(set) var current: Int
    public private(set) var isClimbing: Bool
    private var reason = Reason.finding
    private var best: Rate?
    /// Steps in a row, since the best, that were not faster than it.
    private var misses = 0
    /// Decisions measured since the level settled, or clean ones since
    /// Google's trouble lowered it.
    private var settledDecisions = 0
    private var pendingBytes: Int64 = 0
    private var pendingSeconds: TimeInterval = 0
    /// A request measured since the last decision had a retryable failure,
    /// so that decision is not a clean one.
    private var troubleSinceDecision = false

    public init(cap: Int, automatic: Bool) {
        self.cap = min(max(1, cap), Self.automaticCap)
        self.automatic = automatic
        guard automatic else {
            current = self.cap
            isClimbing = false
            reason = .chosen
            return
        }
        current = min(Self.initial, self.cap)
        isClimbing = current < self.cap
        if !isClimbing { reason = .most }
    }

    public mutating func measured(_ sample: UploadSample) {
        if sample.rateLimited {
            backOff(to: current / 2, because: .rateLimited)
            return
        }
        // A retry round's failures still keep the decision from being clean
        // (below); only a first round's share says how the level fares.
        if sample.firstRound, sample.serverFailures >= Self.serverFailuresThatCount, sample.failureShare >= Self.serverFailureShare {
            backOff(to: sample.failureShare >= Self.halvingShare ? current / 2 : current - 1, because: .serverTrouble)
            return
        }
        if sample.serverFailures > 0 { troubleSinceDecision = true }
        // Only a climbing, a settled or (automatically) a level Google's
        // trouble lowered measures; a chosen number, the cap reached and a
        // level a 429 lowered stay where they are.
        guard mayRise, sample.items > 0, !sample.includesStartUp else { return }
        pendingBytes += sample.bytes
        pendingSeconds += sample.seconds
        guard pendingBytes >= Self.decisionBytes, pendingSeconds >= Self.decisionSeconds else { return }
        let rate = Rate(level: current, bytesPerSecond: Double(pendingBytes) / pendingSeconds)
        let clean = !troubleSinceDecision
        pendingBytes = 0
        pendingSeconds = 0
        troubleSinceDecision = false
        if isClimbing {
            climb(rate)
        } else if isRecovering, !clean {
            // A failure too small to lower it still says Google is not keeping
            // up: the count of clean decisions starts again.
            best = rate
            settledDecisions = 0
        } else {
            reprobe(rate)
        }
    }

    private var isSettled: Bool {
        if case .noFaster = reason { return true }
        return false
    }

    /// Lowered for Google's trouble in automatic mode: tried one step higher
    /// after `reprobeAfter` clean decisions.
    private var isRecovering: Bool { automatic && reason == .serverTrouble }

    /// Whether the level may still rise in this run: false at a chosen
    /// number, at the cap, and once a 429 (or, for a chosen number, Google's
    /// trouble) lowered it.
    public var mayRise: Bool { isClimbing || isSettled || isRecovering }

    private mutating func climb(_ rate: Rate) {
        if let best, rate.bytesPerSecond < best.bytesPerSecond * (1 + Self.improvement) {
            misses += 1
            if misses >= Self.missesToSettle {
                reason = .noFaster(current)
                current = best.level
                isClimbing = false
                settledDecisions = 0
            } else {
                // At the cap this measures the same level once more.
                current = step(above: current)
            }
            return
        }
        best = rate
        misses = 0
        if current < cap {
            current = step(above: current)
        } else {
            reason = .most
            isClimbing = false
        }
    }

    /// A decision at the settled level: its latest rate is the baseline the
    /// next probe has to beat.
    private mutating func reprobe(_ rate: Rate) {
        best = rate
        settledDecisions += 1
        guard settledDecisions >= Self.reprobeAfter else { return }
        reason = .finding
        misses = 0
        isClimbing = true
        current = step(above: current)
    }

    /// The next rung of the ladder above `level`, never past the cap; the cap
    /// itself when there is none.
    private func step(above level: Int) -> Int {
        min(cap, Self.ladder.first { $0 > level } ?? cap)
    }

    private mutating func backOff(to level: Int, because cause: Reason) {
        current = max(1, level)
        isClimbing = false
        reason = cause
        pendingBytes = 0
        pendingSeconds = 0
        settledDecisions = 0
        troubleSinceDecision = false
        misses = 0
    }

    /// For Diagnostics: where it is and why.
    public var summary: String {
        let level = "\(current) at a time"
        switch reason {
        case .finding: return "\(level), finding the fastest"
        case let .noFaster(tried): return "\(level) (no faster at \(tried))"
        case .most: return "\(level) (the most it uses)"
        case .chosen: return "\(level) (as chosen in Settings)"
        case .rateLimited: return "\(level) (Google asked to slow down)"
        case .serverTrouble: return "\(level) (Google had trouble keeping up)"
        }
    }
}

/// Upload speed and time left for the run view and Diagnostics, from the
/// bridge's per-file progress (bytes actually sent) and item outcomes.
public struct ThroughputMeter: Equatable, Sendable {
    /// Speed is what was sent over the last half minute.
    public static let window: TimeInterval = 30
    /// Time left follows the items finished over the last three minutes.
    public static let itemWindow: TimeInterval = 180
    static let minimumSpan: TimeInterval = 5
    static let minimumItems = 5

    private struct Mark: Equatable, Sendable {
        let at: Date
        let total: Int64
    }

    /// Every byte the uploads have sent this run, retries included.
    public private(set) var bytesSent: Int64 = 0
    public private(set) var firstSentAt: Date?
    private var perItem: [String: Int64] = [:]
    private var marks: [Mark] = []
    private var finishes: [Date] = []

    public init() {}

    /// The bridge says `total` bytes of item `id` have gone so far.
    public mutating func sent(id: String, total: Int64, at now: Date) {
        let before = perItem[id] ?? 0
        // Less than before: the item started over (a new attempt).
        let added = total >= before ? total - before : total
        perItem[id] = total
        guard added > 0 else { return }
        bytesSent += added
        if firstSentAt == nil { firstSentAt = now }
        marks.append(Mark(at: now, total: bytesSent))
        // Keep one mark at or before the window's start as the baseline.
        while marks.count > 2, marks[1].at <= now.addingTimeInterval(-Self.window) { marks.removeFirst() }
    }

    /// Item `id` has an outcome; if it is sent again it starts from nothing.
    public mutating func finished(id: String, at now: Date) {
        perItem[id] = nil
        finishes.append(now)
        finishes.removeAll { $0 < now.addingTimeInterval(-Self.itemWindow) }
    }

    public func bytesPerSecond(at now: Date) -> Double? {
        guard let latest = marks.last else { return nil }
        let start = now.addingTimeInterval(-Self.window)
        let baseline = marks.last(where: { $0.at <= start }) ?? marks[0]
        let span = now.timeIntervalSince(baseline.at)
        guard span >= Self.minimumSpan else { return nil }
        return Double(latest.total - baseline.total) / span
    }

    /// The run's average since its first byte, for Diagnostics.
    public func averageBytesPerSecond(at now: Date) -> Double? {
        guard let firstSentAt, now.timeIntervalSince(firstSentAt) >= Self.minimumSpan else { return nil }
        return Double(bytesSent) / now.timeIntervalSince(firstSentAt)
    }

    public func secondsLeft(remaining: Int, at now: Date) -> TimeInterval? {
        if remaining == 0 { return 0 }
        let recent = finishes.filter { $0 >= now.addingTimeInterval(-Self.itemWindow) }
        guard recent.count >= Self.minimumItems, let first = recent.first else { return nil }
        let span = now.timeIntervalSince(first)
        guard span > 0 else { return nil }
        return Double(remaining) * span / Double(recent.count - 1)
    }

    /// "12.3 MB/s, about 14 min left"; nil until there is a speed to show.
    public static func describe(bytesPerSecond: Double?, secondsLeft: TimeInterval?) -> String? {
        guard let bytesPerSecond else { return nil }
        let speed = speed(bytesPerSecond)
        guard let secondsLeft else { return speed }
        return "\(speed), \(timeLeft(secondsLeft))"
    }

    /// "12.3 MB/s" (decimal megabytes, as Finder counts them).
    public static func speed(_ bytesPerSecond: Double) -> String {
        String(format: "%.1f MB/s", bytesPerSecond / 1_000_000)
    }

    static func timeLeft(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if seconds < 60 || minutes == 0 { return "less than a minute left" }
        if minutes < 60 { return "about \(minutes) min left" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "about \(hours) h left" : "about \(hours) h \(rest) min left"
    }
}

/// How far the export from Photos may run ahead of the upload (issue #50):
/// the next batches are staged while one uploads, so the network does not
/// wait on PhotoKit, but a new export starts only while fewer than two
/// batches and under 2 GB are waiting, and an export ahead writes an item
/// only while that keeps it within 2 GB and leaves the disk room.
public enum StagingWindow {
    public static let batchesAhead = 2
    public static let bytesAhead: Int64 = 2_000_000_000
    /// Free space an export ahead leaves on the staging volume. The batch
    /// uploading is exported whatever the window says, and macOS needs room
    /// of its own; 5 GB is a margin chosen for both, not a measured limit.
    public static let freeSpaceFloor: Int64 = 5_000_000_000

    public static func mayStage(batchesReady: Int, bytesReady: Int64) -> Bool {
        batchesReady < batchesAhead && bytesReady < bytesAhead
    }

    /// Whether an export ahead may write its next item (PR #52 review: the
    /// cap used to be judged on finished batches only, before an export
    /// began, so one batch of large videos could stage any amount).
    /// - Parameters:
    ///   - staged: bytes exported ahead and not taken, the running export's included.
    ///   - next: the item's size, or nil when it is not known until it is
    ///     written; the window may then pass the cap by that one item.
    ///   - freeSpace: what the staging volume has available, nil if it did not say.
    public static func mayExportAhead(staged: Int64, next: Int64?, freeSpace: Int64?) -> Bool {
        let fits = next.map { staged + $0 <= bytesAhead } ?? (staged < bytesAhead)
        guard fits else { return false }
        guard let freeSpace else { return true }
        return freeSpace - (next ?? 0) >= freeSpaceFloor
    }

    /// The order a batch goes to the bridge: the largest first, so a long
    /// video starts early instead of being the batch's tail, sizes not known
    /// last, otherwise as planned.
    public static func largestFirst<T>(_ items: [T], size: (T) -> Int64?) -> [T] {
        items.enumerated()
            .sorted { lhs, rhs in
                let left = size(lhs.element) ?? -1
                let right = size(rhs.element) ?? -1
                return left != right ? left > right : lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}
