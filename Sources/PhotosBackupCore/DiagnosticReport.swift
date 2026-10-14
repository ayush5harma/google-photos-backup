import Foundation

/// Everything a diagnostic report says, gathered by the app at one moment.
public struct DiagnosticSnapshot: Sendable {
    public enum PhotosAccess: String, Sendable {
        case full, limited, denied, restricted, notDetermined

        var title: String {
            switch self {
            case .full: "Full"
            case .limited: "Limited to selected photos"
            case .denied: "Denied"
            case .restricted: "Restricted"
            case .notDetermined: "Not asked yet"
            }
        }
    }

    public struct Setting: Equatable, Sendable {
        public let name: String
        public let value: String

        public init(_ name: String, _ value: String) {
            self.name = name
            self.value = value
        }
    }

    public var generatedAt = Date()
    public var appVersion = "unknown"
    public var macOSVersion = "unknown"
    public var uploader = "unknown"
    public var settings: [Setting] = []
    /// The account's address; the report shows it masked.
    public var account: String?
    public var accountStatus = "Not signed in"
    public var photosAccess = PhotosAccess.notDetermined
    /// nil when nothing needed it, so it was not checked.
    public var fullDiskAccess: Bool?
    public var automaticBackups = true
    /// Messages media or the Messages archive is on.
    public var messagesFeatureOn = false
    public var backedUp = 0
    public var pending = 0
    public var failed = 0
    public var runActive = false
    public var runs: [RunRecord] = []
    public var events: [EventRecord] = []
    public var storage = StorageUsage()
    public var conditions = "Unknown"
    /// What holds uploads right now, and since when.
    public var holding: WaitReason?
    public var holdingSince: Date?
    /// Google's words for the items that failed in this session.
    public var failureMessages: [String] = []
    public var lastError: String?

    public init() {}
}

/// Fixed openings of event messages the report's rules look for; the
/// engine writes its events with them.
public enum EventPhrase {
    public static let rateLimited = "Google asked the app to slow down"
    public static let accountRefused = "Google refused the account"
    public static let storageFull = "The Google account is out of storage"
}

/// The plain-text report a person can paste into an issue: "What stands
/// out" first, then the facts behind it, all redacted.
public enum DiagnosticReport {
    static let day: TimeInterval = 24 * 60 * 60
    /// Failures sharing one cause, at or past this count, are worth a line.
    static let sameKindThreshold = 5
    static let longHold: TimeInterval = 60 * 60

    public static func build(_ snapshot: DiagnosticSnapshot, redactor: Redactor, timeZone: TimeZone = .current) -> String {
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.timeZone = timeZone
        date.dateFormat = "yyyy-MM-dd HH:mm"
        func when(_ value: Date) -> String { date.string(from: value) }

        var lines = [
            "Photos Backup diagnostic report",
            "Generated \(when(snapshot.generatedAt))",
            "Tokens, addresses, phone numbers and the home folder's name are removed, so this report is safe to share.",
            "",
            "What stands out",
        ]
        let findings = findings(snapshot)
        lines += findings.isEmpty ? ["- Nothing stands out."] : findings.map { "- \($0)" }

        lines += ["", "App and Mac",
                  "App version: \(snapshot.appVersion)",
                  "macOS: \(snapshot.macOSVersion)",
                  "Uploader: \(snapshot.uploader)"]

        lines += ["", "Account and permissions",
                  "Google account: \(snapshot.account.map(Redactor.maskEmail) ?? "none") (\(snapshot.accountStatus))",
                  "Photos access: \(snapshot.photosAccess.title)",
                  "Full Disk Access: \(snapshot.fullDiskAccess.map { $0 ? "Granted" : "Missing" } ?? "Not checked")"]

        lines += ["", "Settings"] + snapshot.settings.map { "\($0.name): \($0.value)" }

        lines += ["", "Backup",
                  "Backed up: \(snapshot.backedUp)",
                  "Waiting to back up: \(snapshot.pending)",
                  "Failed in this session: \(snapshot.failed)",
                  "A run is active: \(snapshot.runActive ? "yes" : "no")",
                  "Conditions now: \(snapshot.conditions)"]
        if let holding = snapshot.holding {
            lines.append("Holding: \(holding.title)\(snapshot.holdingSince.map { " since \(when($0))" } ?? "")")
        }
        if let error = snapshot.lastError { lines.append("Last error: \(error)") }

        let storage = snapshot.storage
        lines += ["", "Storage on this Mac",
                  "Exported copies waiting to upload: \(bytes(storage.staging))",
                  "Logs: \(bytes(storage.logs))",
                  "Backup record: \(bytes(storage.state))",
                  "History and timeline: \(bytes(storage.history))"]

        lines += ["", "Recent runs (newest first)"]
        lines += snapshot.runs.isEmpty ? ["None yet."] : snapshot.runs.prefix(20).map { run in
            let duration = run.duration.map { " \(Int($0.rounded())) s," } ?? ""
            return "\(when(run.startedAt)) \(run.kind.title), \(run.trigger.title):\(duration) \(run.uploaded) uploaded, "
                + "\(run.existing) already there, \(run.failed) failed, \(bytes(run.bytes)); \(outcome(run.outcome))"
                + (run.conditions.map { " [\($0)]" } ?? "")
        }

        let problems = snapshot.events.filter(\.isProblem).prefix(30)
        lines += ["", "Recent problems (newest first)"]
        lines += problems.isEmpty ? ["None."] : problems.map { "\(when($0.date)) [\($0.category.rawValue)] \($0.message)" }

        return redactor.redact(lines.joined(separator: "\n")) + "\n"
    }

    /// The rules behind "What stands out", in order of how much they block.
    public static func findings(_ snapshot: DiagnosticSnapshot) -> [String] {
        let now = snapshot.generatedAt
        var findings: [String] = []

        let refusals = snapshot.events.filter {
            $0.isProblem && $0.date > now.addingTimeInterval(-7 * day)
                && ($0.category == .account || $0.message.hasPrefix(EventPhrase.accountRefused))
        }
        if !refusals.isEmpty {
            findings.append("Google refused the account \(times(refusals.count)) in the last week; signing in again in Settings fixes this.")
        }
        if snapshot.events.contains(where: { $0.message.hasPrefix(EventPhrase.storageFull) && $0.date > now.addingTimeInterval(-7 * day) }) {
            findings.append("The Google account ran out of storage in the last week; uploads stop until space is freed.")
        }

        switch snapshot.photosAccess {
        case .limited:
            findings.append("Photos access is limited to selected photos, so only those can be backed up.")
        case .denied, .restricted:
            findings.append("Photos access is \(snapshot.photosAccess.title.lowercased()); nothing from Photos can be backed up.")
        case .full, .notDetermined:
            break
        }
        if snapshot.messagesFeatureOn, snapshot.fullDiskAccess == false {
            findings.append("A Messages feature is on but the app has no Full Disk Access, which Messages needs.")
        }

        if snapshot.automaticBackups {
            let lastCompleted = snapshot.runs.filter { $0.outcome == .completed }.compactMap(\.finishedAt).max()
            if lastCompleted.map({ $0 < now.addingTimeInterval(-day) }) ?? true {
                let since = lastCompleted.map { " (last on \(ISO8601DateFormatter().string(from: $0)))" } ?? ""
                findings.append("No backup has completed in the last 24 hours although automatic backups are on\(since).")
            }
        }

        let recent = snapshot.runs.prefix(5)
        let failing = recent.filter { $0.failed > 0 }
        if failing.count >= 3 {
            findings.append("\(failing.count) of the last \(recent.count) runs had failed items (\(failing.reduce(0) { $0 + $1.failed }) in all).")
        }

        let limits = snapshot.events.filter { $0.message.hasPrefix(EventPhrase.rateLimited) && $0.date > now.addingTimeInterval(-day) }
        if !limits.isEmpty {
            findings.append("Google asked the app to slow down \(times(limits.count)) in the last day; uploads wait and resume by themselves.")
        }

        if let holding = snapshot.holding, let since = snapshot.holdingSince, since < now.addingTimeInterval(-longHold) {
            let hours = Int(now.timeIntervalSince(since) / 3600)
            findings.append("Uploads have been held for \(hours) hour\(hours == 1 ? "" : "s"): \(holding.title.lowercased()).")
        }

        let kinds = Dictionary(grouping: snapshot.failureMessages, by: failureKind)
        for (kind, messages) in kinds.sorted(by: { ($0.value.count, $1.key) > ($1.value.count, $0.key) })
        where messages.count >= sameKindThreshold {
            findings.append("\(messages.count) uploads failed with \(kind).")
        }

        if !snapshot.runActive, snapshot.storage.staging > 0 {
            findings.append("\(bytes(snapshot.storage.staging)) of exported copies were left behind by an earlier run; Clean Up removes them.")
        }
        return findings
    }

    /// Failures grouped by what caused them: the HTTP status when there is
    /// one, else the message with its numbers blanked out.
    static func failureKind(_ message: String) -> String {
        if let status = FailureClassifier.statusCode(in: message) { return "HTTP \(status)" }
        let blanked = message.replacingOccurrences(of: #"[0-9]+"#, with: "#", options: .regularExpression)
        return "\u{201C}\(blanked.prefix(80))\u{201D}"
    }

    private static func times(_ count: Int) -> String {
        count == 1 ? "once" : "\(count) times"
    }

    private static func outcome(_ outcome: RunOutcome?) -> String {
        switch outcome {
        case .completed: "completed"
        case .stopped: "stopped"
        case .paused: "paused"
        case let .failed(reason): "failed: \(reason)"
        case nil: "unfinished"
        }
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
