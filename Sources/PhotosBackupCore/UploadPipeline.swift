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
    /// The run's first request, whose time includes the bridge's start-up
    /// and sign-in: it counts for pushback, not for speed.
    public var includesStartUp: Bool

    public init(bytes: Int64, seconds: TimeInterval, items: Int, rateLimited: Bool, serverFailures: Int,
                includesStartUp: Bool = false) {
        self.bytes = bytes
        self.seconds = seconds
        self.items = items
        self.rateLimited = rateLimited
        self.serverFailures = serverFailures
        self.includesStartUp = includesStartUp
    }
}

/// How many uploads go at once, decided between bridge requests (issue #50).
///
/// It starts at four and adds one while each step is measurably faster
/// (10% more bytes a second); the first step that is not goes back to the
/// best level and stays. A step that is not faster is the link's limit
/// showing as longer per-file times, so that is also how rising latency
/// reads here. Google pushing back ends the climb for the run: a 429 halves
/// the level, two or more retryable failures in one request take one off,
/// and the level only ever goes down after that. A chosen number in Settings
/// is the most it uses.
public struct UploadParallelism: Equatable, Sendable {
    /// The bridge's MAX_THREADS.
    public static let automaticCap = 8
    public static let initial = 4
    public static let improvement = 0.10
    /// A level is judged on at least this much: one batch of photos is
    /// usually enough, a batch of items Google already has is not.
    public static let decisionBytes: Int64 = 24_000_000
    public static let decisionSeconds: TimeInterval = 4
    /// One passing 5xx is Google's noise, not pressure.
    public static let serverFailuresThatCount = 2

    private enum Reason: Equatable, Sendable {
        case finding, noFaster(Int), most, rateLimited, serverTrouble
    }

    public let cap: Int
    public private(set) var current: Int
    public private(set) var isClimbing: Bool
    private var reason = Reason.finding
    private var best: (level: Int, rate: Double)?
    private var pendingBytes: Int64 = 0
    private var pendingSeconds: TimeInterval = 0

    public init(cap: Int) {
        self.cap = min(max(1, cap), Self.automaticCap)
        current = min(Self.initial, self.cap)
        isClimbing = current < self.cap
        if !isClimbing { reason = .most }
    }

    public mutating func measured(_ sample: UploadSample) {
        if sample.rateLimited {
            backOff(to: current / 2, because: .rateLimited)
            return
        }
        if sample.serverFailures >= Self.serverFailuresThatCount {
            backOff(to: current - 1, because: .serverTrouble)
            return
        }
        guard isClimbing, sample.items > 0, !sample.includesStartUp else { return }
        pendingBytes += sample.bytes
        pendingSeconds += sample.seconds
        guard pendingBytes >= Self.decisionBytes, pendingSeconds >= Self.decisionSeconds else { return }
        let rate = Double(pendingBytes) / pendingSeconds
        pendingBytes = 0
        pendingSeconds = 0
        if let best, rate < best.rate * (1 + Self.improvement) {
            reason = .noFaster(current)
            current = best.level
            isClimbing = false
            return
        }
        best = (current, rate)
        if current < cap {
            current += 1
        } else {
            reason = .most
            isClimbing = false
        }
    }

    private mutating func backOff(to level: Int, because cause: Reason) {
        current = max(1, level)
        isClimbing = false
        reason = cause
        pendingBytes = 0
        pendingSeconds = 0
    }

    /// For Diagnostics: where it is and why.
    public var summary: String {
        let level = "\(current) at a time"
        switch reason {
        case .finding: return "\(level), finding the fastest"
        case let .noFaster(tried): return "\(level) (no faster at \(tried))"
        case .most: return "\(level) (the most it uses)"
        case .rateLimited: return "\(level) (Google asked to slow down)"
        case .serverTrouble: return "\(level) (Google had trouble keeping up)"
        }
    }

    public static func == (lhs: UploadParallelism, rhs: UploadParallelism) -> Bool {
        lhs.cap == rhs.cap && lhs.current == rhs.current && lhs.isClimbing == rhs.isClimbing && lhs.reason == rhs.reason
            && lhs.best?.level == rhs.best?.level && lhs.best?.rate == rhs.best?.rate
            && lhs.pendingBytes == rhs.pendingBytes && lhs.pendingSeconds == rhs.pendingSeconds
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
