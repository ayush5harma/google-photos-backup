import Foundation

/// The event timeline, newest first: at most 400 events, none older than
/// 14 days, each redacted before it is kept.
public struct EventLog: Codable, Equatable, Sendable {
    public static let limit = 400
    public static let maximumAge: TimeInterval = 14 * 24 * 60 * 60
    /// A gpmc error can quote a whole response; the timeline is a summary.
    public static let messageLimit = 500

    public private(set) var events: [EventRecord]

    public init(events: [EventRecord] = [], now: Date = Date()) {
        self.events = Self.pruned(events.sorted { $0.date > $1.date }, now: now)
    }

    public mutating func append(_ event: EventRecord, redactor: Redactor, now: Date = Date()) {
        var event = event
        event.message = Self.truncated(redactor.redact(event.message))
        var events = events
        let index = events.firstIndex { $0.date <= event.date } ?? events.endIndex
        events.insert(event, at: index)
        self.events = Self.pruned(events, now: now)
    }

    public mutating func removeAll() {
        events = []
    }

    /// Past the limit, ordinary events go before problems (as on iOS): a
    /// burst of routine lines must not push out the failure being diagnosed.
    static func pruned(_ newestFirst: [EventRecord], now: Date) -> [EventRecord] {
        let cutoff = now.addingTimeInterval(-maximumAge)
        var events = newestFirst.filter { $0.date >= cutoff }
        var excess = events.count - limit
        guard excess > 0 else { return events }
        for index in events.indices.reversed() where excess > 0 && !events[index].isProblem {
            events.remove(at: index)
            excess -= 1
        }
        if excess > 0 { events.removeLast(excess) }
        return events
    }

    private static func truncated(_ message: String) -> String {
        message.count > messageLimit ? String(message.prefix(messageLimit - 3)) + "..." : message
    }

    public init(from decoder: Decoder) throws {
        self.init(events: try decoder.singleValueContainer().decode([EventRecord].self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(events)
    }
}
