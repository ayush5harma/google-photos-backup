import Foundation

/// The one line, and the one menu bar symbol, that sum up the app: what the
/// menu bar label, the panel's header and the window's subtitle all say.
public struct MenuBarStatus: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case upToDate, ready, backingUp, waiting, paused, attention
    }

    /// The engine, reduced to what the status line distinguishes.
    public enum Activity: Equatable, Sendable {
        case idle, running, pausing, paused, stopping
        case waiting(WaitReason?)
    }

    public struct Input: Equatable, Sendable {
        public var signedIn: Bool
        /// Google refused the stored account, or it could not be checked.
        public var accountProblem = false
        public var activity: Activity = .idle
        /// Left in the current run, and left across the selection.
        public var remaining = 0
        public var pending = 0
        public var total = 0
        public var failed = 0
        /// A short title for something that stops backups (storage full).
        public var problem: String?
        public var archiving = false

        public init(signedIn: Bool, accountProblem: Bool = false, activity: Activity = .idle, remaining: Int = 0,
                    pending: Int = 0, total: Int = 0, failed: Int = 0, problem: String? = nil, archiving: Bool = false) {
            self.signedIn = signedIn
            self.accountProblem = accountProblem
            self.activity = activity
            self.remaining = remaining
            self.pending = pending
            self.total = total
            self.failed = failed
            self.problem = problem
            self.archiving = archiving
        }
    }

    public let kind: Kind
    public let headline: String

    /// Template symbols, one per kind, all in the same circled family so the
    /// menu bar item keeps its footprint from state to state.
    public var symbol: String {
        switch kind {
        case .upToDate: "checkmark.circle"
        case .ready: "arrow.up.circle"
        case .backingUp: "arrow.up.circle.fill"
        case .waiting: "clock"
        case .paused: "pause.circle"
        case .attention: "exclamationmark.circle"
        }
    }

    /// Ordered by what a person can act on first: no account means nothing
    /// else works; a moving run is what they came to watch; an old problem
    /// only once nothing is moving.
    public init(_ input: Input, locale: Locale = .current) {
        func items(_ count: Int) -> String {
            "\(count.formatted(.number.locale(locale))) \(count == 1 ? "item" : "items")"
        }
        let (kind, headline): (Kind, String) = {
            if !input.signedIn { return (.attention, "Sign in to start") }
            switch input.activity {
            case .stopping: return (.backingUp, "Stopping…")
            case .pausing: return (.backingUp, "Pausing after this batch")
            case .running: return (.backingUp, input.remaining > 0 ? "Backing up \(items(input.remaining))" : "Backing up…")
            case let .waiting(reason): return (.waiting, reason?.title ?? "Waiting")
            case .paused: return (.paused, "Paused")
            case .idle: break
            }
            if input.accountProblem { return (.attention, "Sign in again") }
            if let problem = input.problem { return (.attention, problem) }
            if input.archiving { return (.backingUp, "Archiving Messages") }
            if input.failed > 0 { return (.attention, "\(items(input.failed)) couldn't be backed up") }
            if input.pending > 0 { return (.ready, "\(items(input.pending)) to back up") }
            if input.total == 0 { return (.ready, "Choose what to back up") }
            return (.upToDate, "Up to date")
        }()
        self.kind = kind
        self.headline = headline
    }
}

/// What a finished automatic run says in a notification, if anything. Runs
/// a person started are being watched already, and runs that changed
/// nothing are not news.
public struct RunNotification: Equatable, Sendable {
    public let title: String
    public let body: String
    /// Failures are explained in Activity; a click goes there.
    public let opensActivity: Bool

    public init?(_ run: RunRecord, locale: Locale = .current) {
        guard run.trigger.isAutomatic, run.uploaded > 0 || run.failed > 0 else { return nil }
        func number(_ count: Int) -> String { count.formatted(.number.locale(locale)) }

        if run.kind == .messagesArchive {
            guard run.uploaded > 0 else { return nil }
            title = "Messages archived"
            body = "\(number(run.uploaded)) new \(run.uploaded == 1 ? "message" : "messages")"
            opensActivity = false
            return
        }

        let noun = switch run.kind {
        case .messagesMedia: "Messages photos and videos"
        default: run.uploaded == 1 ? "photo" : "photos"
        }
        opensActivity = run.failed > 0
        if run.uploaded == 0 {
            title = "\(number(run.failed)) \(run.failed == 1 ? "item" : "items") couldn't be backed up"
            body = "Open Activity to see why and try again."
            return
        }
        title = "\(number(run.uploaded)) \(noun) backed up"
        if run.failed > 0 {
            body = "\(number(run.failed)) couldn't be backed up. Open Activity to try again."
        } else if run.outcome == .completed {
            body = "Everything you selected is in Google Photos."
        } else {
            body = "The rest continues with the next backup."
        }
    }
}

/// At most one problem notification per category per hour: a problem that
/// recurs every run (offline all afternoon) is said once, not every time.
public struct ProblemThrottle: Sendable {
    public static let interval: TimeInterval = 60 * 60
    private var lastShown: [EventCategory: Date] = [:]

    public init() {}

    public mutating func allows(_ category: EventCategory, at date: Date = Date()) -> Bool {
        if let last = lastShown[category], date.timeIntervalSince(last) < Self.interval { return false }
        lastShown[category] = date
        return true
    }
}
