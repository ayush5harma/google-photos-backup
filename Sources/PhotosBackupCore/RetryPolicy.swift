import Foundation

/// What a failed item calls for, decided from Google's answer.
public enum FailureClass: Equatable, Sendable {
    /// HTTP 429: every upload waits (RateLimiter); the attempt is refunded.
    case rateLimited
    /// The network or Google itself had trouble; the same request may work.
    case retryable
    /// The file or the request is the problem; sending it again cannot help.
    case permanent
}

/// Reads a failure message as gpmc 0.9.0 words it. gpmc catches every
/// per-file exception itself and keeps only its text, so the text is all
/// either side of the bridge has: requests words an HTTP error as
/// "503 Server Error: Service Unavailable for url: ...", urllib3 a spent
/// retry budget as "... too many 503 error responses".
public enum FailureClassifier {
    public static func classify(message: String, bridgeRetryable: Bool?) -> FailureClass {
        if let status = statusCode(in: message) {
            if status == 429 { return .rateLimited }
            if status == 408 || status >= 500 { return .retryable }
            if status >= 400 { return .permanent }
        }
        let lowered = message.lowercased()
        if lowered.contains("too many requests") { return .rateLimited }
        if networkMarkers.contains(where: lowered.contains) { return .retryable }
        return bridgeRetryable == true ? .retryable : .permanent
    }

    /// The HTTP status a message names, or nil. Only the phrasings requests,
    /// urllib3 and the bridge use count, so a number inside a URL or an
    /// upload id is never read as a status.
    public static func statusCode(in message: String) -> Int? {
        let patterns = [
            #"\b([1-5][0-9]{2}) (?:Client|Server) Error\b"#,
            #"too many ([1-5][0-9]{2}) error responses"#,
            #"\bHTTP(?: Error)?:? ([1-5][0-9]{2})\b"#,
            #"\bstatus(?: code)?:? ([1-5][0-9]{2})\b"#,
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = expression.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
                  let range = Range(match.range(at: 1), in: message) else { continue }
            return Int(message[range])
        }
        return nil
    }

    /// Lowercased fragments of requests/urllib3/OSError texts for a network
    /// that failed before Google answered, plus the engine's own wording for
    /// a bridge that ended without reporting an item.
    private static let networkMarkers = [
        "timed out", "timeout", "connection reset", "connection aborted", "connection refused", "connectionerror",
        "remotedisconnected", "max retries exceeded", "newconnectionerror", "nameresolutionerror", "name resolution",
        "network is unreachable", "no route to host", "broken pipe", "temporarily unavailable", "eof occurred",
        "no answer from the uploader",
    ]
}

/// How often and how soon a retryable failure is tried again within a run.
/// After the last attempt the item stays failed for the run and the next
/// run releases it again.
public struct RetryPolicy: Equatable, Sendable {
    public var maxAttempts = 3
    public var baseDelay: TimeInterval = 1
    public var maxDelay: TimeInterval = 30

    public init() {}

    /// 1 s after the first failed attempt, then 2 s, 4 s ... up to 30 s.
    public func delay(afterFailedAttempt attempt: Int) -> TimeInterval {
        let exponent = Double(min(max(attempt, 1) - 1, 30))
        return min(maxDelay, baseDelay * pow(2, exponent))
    }
}

/// Attempts per item for one run.
public struct RetryTracker: Equatable, Sendable {
    public enum Decision: Equatable, Sendable {
        case retry(after: TimeInterval)
        /// Send again once the rate-limit hold is over; no attempt used.
        case waitForRateLimit
        case giveUp
    }

    public let policy: RetryPolicy
    private var attempts: [String: Int] = [:]

    public init(policy: RetryPolicy = RetryPolicy()) {
        self.policy = policy
    }

    public func attempts(for id: String) -> Int { attempts[id, default: 0] }

    public mutating func failed(_ id: String, as failure: FailureClass) -> Decision {
        switch failure {
        case .rateLimited:
            // Google refused the request before looking at the file, so it
            // says nothing about whether this item can upload.
            return .waitForRateLimit
        case .permanent:
            attempts[id, default: 0] += 1
            return .giveUp
        case .retryable:
            attempts[id, default: 0] += 1
            let used = attempts[id, default: 0]
            return used >= policy.maxAttempts ? .giveUp : .retry(after: policy.delay(afterFailedAttempt: used))
        }
    }

    /// A person asked for this item again: it starts with fresh attempts.
    public mutating func forget(_ id: String) {
        attempts[id] = nil
    }
}

/// Google's HTTP 429 holds every upload, not just the item that hit it: a
/// minute at first, doubling while Google keeps refusing, ten minutes at
/// most, and back to a minute after a batch gets through (the iOS app's
/// rule).
public struct RateLimiter: Equatable, Sendable {
    public static let initialHold: TimeInterval = 60
    public static let maximumHold: TimeInterval = 600

    /// Holds a run may sit through with nothing getting through in between
    /// (1 + 2 + 4 + 8 + 10 minutes); the next 429 ends the run, so a run
    /// cannot hold forever and keep automatic runs from starting.
    public static let maximumHoldsPerRun = 5

    public private(set) var holdUntil: Date?
    /// Holds started in the current run since a batch last got through.
    public private(set) var holdsThisRun = 0
    private var nextHold = RateLimiter.initialHold

    public init() {}

    /// Starts a hold, or returns the one in force: items already in flight
    /// when the limit hit report it too, and one hold covers them all.
    @discardableResult
    public mutating func hitLimit(at now: Date) -> Date {
        if let holdUntil, holdUntil > now { return holdUntil }
        let until = now.addingTimeInterval(nextHold)
        nextHold = min(Self.maximumHold, nextHold * 2)
        holdUntil = until
        holdsThisRun += 1
        return until
    }

    public mutating func batchSucceeded() {
        holdUntil = nil
        nextHold = Self.initialHold
        holdsThisRun = 0
    }

    /// The hold itself outlives a run (Google's limit does); the count of
    /// holds a run sat through does not.
    public mutating func runStarted() {
        holdsThisRun = 0
    }

    /// True once Google has refused past the run's allowance of holds.
    public var runShouldGiveUp: Bool { holdsThisRun > Self.maximumHoldsPerRun }

    /// When the hold in force ends, or nil when uploads may go.
    public func hold(at now: Date) -> Date? {
        guard let holdUntil, holdUntil > now else { return nil }
        return holdUntil
    }
}
