import Foundation

/// One run's counts, kept consistent however an item ends: an item counts
/// once, as failed or as confirmed. A failure that Retry takes back, or that
/// a later confirmation overrides, stops counting as a failure, so a run
/// whose retried item went through ends without a failure (and without a
/// problem notification for it).
public struct RunTally: Equatable, Sendable {
    /// Items the run set out to send, and how many have an outcome.
    public private(set) var total = 0
    public private(set) var done = 0
    public private(set) var uploaded = 0
    public private(set) var existing = 0
    public private(set) var failed = 0
    /// Bytes Google stored for this run (items it already had send nothing).
    public private(set) var bytes: Int64 = 0
    /// Confirmed in this run: never planned again in it, not even as an
    /// edit, so a date that moves during the run cannot send one twice.
    public private(set) var confirmedIDs: Set<String> = []
    public private(set) var failedIDs: Set<String> = []

    public init(total: Int = 0, done: Int = 0) {
        self.total = total
        self.done = done
    }

    public mutating func planned(_ count: Int) {
        total += max(0, count)
    }

    /// False for an item already confirmed in this run (a repeated report).
    @discardableResult
    public mutating func confirmed(_ id: String, existing alreadyThere: Bool, bytes size: Int64) -> Bool {
        guard confirmedIDs.insert(id).inserted else { return false }
        if failedIDs.remove(id) != nil {
            failed -= 1
            done -= 1
        }
        done += 1
        if alreadyThere {
            existing += 1
        } else {
            uploaded += 1
            bytes += max(0, size)
        }
        return true
    }

    /// False when the item already has an outcome in this run.
    @discardableResult
    public mutating func failed(_ id: String) -> Bool {
        guard !confirmedIDs.contains(id), failedIDs.insert(id).inserted else { return false }
        failed += 1
        done += 1
        return true
    }

    /// Retry took a failure of this run back; the item is planned (and
    /// counted) again when it is sent. False when it had not failed here.
    @discardableResult
    public mutating func requeued(_ id: String) -> Bool {
        guard failedIDs.remove(id) != nil else { return false }
        failed -= 1
        done -= 1
        total -= 1
        return true
    }
}
