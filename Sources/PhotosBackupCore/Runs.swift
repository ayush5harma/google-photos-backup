import Foundation

/// What started a run. Recorded with it, so the history and a diagnostic
/// report can tell an automatic backup from one a person asked for.
public enum RunTrigger: String, Codable, Sendable, CaseIterable {
    case launch, timer, libraryChange, wake, conditions
    case manual, picker, albumSelected, signIn, automation, retry, schedule

    public var title: String {
        switch self {
        case .launch: "At launch"
        case .timer: "Every 30 minutes"
        case .libraryChange: "New in Photos"
        case .wake: "After waking"
        case .conditions: "Conditions allowed it"
        case .manual: "Back Up Now"
        case .picker: "Chosen photos"
        case .albumSelected: "Album turned on"
        case .signIn: "After signing in"
        case .automation: "Shortcut or link"
        case .retry: "Retry"
        case .schedule: "Daily schedule"
        }
    }

    /// Runs nobody asked for in the moment; their results are worth a
    /// notification, a run someone started is watched already.
    public var isAutomatic: Bool {
        switch self {
        case .launch, .timer, .libraryChange, .wake, .conditions, .schedule: true
        case .manual, .picker, .albumSelected, .signIn, .automation, .retry: false
        }
    }

    /// Runs a person asked to go now, which go ahead on a metered network,
    /// in Low Data Mode or on battery. Turning an album on or signing in is
    /// not such a request: those runs respect the "pause on..." settings.
    public var overridesConditions: Bool {
        switch self {
        case .manual, .picker, .retry, .automation: true
        case .launch, .timer, .libraryChange, .wake, .conditions, .schedule, .albumSelected, .signIn: false
        }
    }
}

public enum RunKind: String, Codable, Sendable {
    case photos
    case messagesMedia
    case messagesArchive

    public var title: String {
        switch self {
        case .photos: "Photos"
        case .messagesMedia: "Messages media"
        case .messagesArchive: "Messages archive"
        }
    }
}

public enum RunOutcome: Codable, Equatable, Sendable {
    case completed
    case stopped
    case paused
    case failed(String)
}

/// One run, kept in the history once it ends.
public struct RunRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var kind: RunKind
    public var trigger: RunTrigger
    public var startedAt: Date
    public var finishedAt: Date?
    /// Items Google stored for this run, and those it already had.
    public var uploaded: Int
    public var existing: Int
    public var failed: Int
    public var bytes: Int64
    public var outcome: RunOutcome?
    /// The network and power conditions when it started, in words.
    public var conditions: String?

    public init(id: UUID = UUID(), kind: RunKind, trigger: RunTrigger, startedAt: Date = Date(), finishedAt: Date? = nil,
                uploaded: Int = 0, existing: Int = 0, failed: Int = 0, bytes: Int64 = 0,
                outcome: RunOutcome? = nil, conditions: String? = nil) {
        self.id = id
        self.kind = kind
        self.trigger = trigger
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.uploaded = uploaded
        self.existing = existing
        self.failed = failed
        self.bytes = bytes
        self.outcome = outcome
        self.conditions = conditions
    }

    public var duration: TimeInterval? { finishedAt.map { $0.timeIntervalSince(startedAt) } }
}

/// Why a run is holding instead of uploading. The run stays alive and
/// carries on by itself once the reason clears.
public enum WaitReason: Equatable, Sendable {
    case offline
    case expensiveNetwork
    case lowDataMode
    case onBattery
    case lowPowerMode
    /// Google answered 429; every upload waits until then.
    case rateLimited(until: Date)
    /// A retryable failure backs off before the next attempt.
    case retrying(until: Date)

    public var title: String {
        switch self {
        case .offline: "Waiting for a network connection"
        case .expensiveNetwork: "Paused on a metered network"
        case .lowDataMode: "Paused in Low Data Mode"
        case .onBattery: "Paused on battery power"
        case .lowPowerMode: "Paused in Low Power Mode"
        case .rateLimited: "Google asked to slow down"
        case .retrying: "Retrying shortly"
        }
    }

    public var symbol: String {
        switch self {
        case .offline: "wifi.slash"
        case .expensiveNetwork: "personalhotspot"
        case .lowDataMode: "antenna.radiowaves.left.and.right.slash"
        case .onBattery: "battery.50percent"
        case .lowPowerMode: "bolt.slash"
        case .rateLimited: "hourglass"
        case .retrying: "arrow.clockwise"
        }
    }

    /// When a timed wait ends; nil for a condition that has to change.
    public var until: Date? {
        switch self {
        case let .rateLimited(until), let .retrying(until): until
        default: nil
        }
    }
}

public enum EventCategory: String, Codable, Sendable, CaseIterable {
    case app, account, photos, messages, archive, run, network
}

/// One line of the event timeline. Never holds a token or message text:
/// accounts appear by address, items by identifier or count.
public struct EventRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var date: Date
    public var category: EventCategory
    public var message: String
    public var isProblem: Bool

    public init(id: UUID = UUID(), date: Date = Date(), category: EventCategory, message: String, isProblem: Bool = false) {
        self.id = id
        self.date = date
        self.category = category
        self.message = message
        self.isProblem = isProblem
    }
}

/// What the app keeps on disk, for the Storage settings.
public struct StorageUsage: Equatable, Sendable {
    public var staging: Int64
    public var logs: Int64
    public var state: Int64
    public var history: Int64

    public init(staging: Int64 = 0, logs: Int64 = 0, state: Int64 = 0, history: Int64 = 0) {
        self.staging = staging
        self.logs = logs
        self.state = state
        self.history = history
    }

    public var total: Int64 { staging + logs + state + history }
}
