import Foundation
import Observation
import PhotosBackupCore

// The seam between the app and the backup engine. Phase 1 of the iOS app
// ships everything but the engine (export, upload, commit, albums and
// background execution); the AppModel and every view talk only to this
// protocol, so the real engine drops in without touching them.

/// Where a backup goes: where Settings > Accounts' "Back up to" says, or one
/// named account (a link's ?account=, a storage check's Start Backing Up).
enum BackupDestination: Equatable {
    case chosen
    case only(String)
}

/// What the views show about the engine, in one value.
struct BackupEngineStatus: Equatable {
    enum Phase: Equatable {
        case idle
        case running
        case waiting(WaitReason)
        case pausing
        case paused
        case stopping
    }

    /// One account's part of the run in progress.
    struct AccountProgress: Equatable, Identifiable {
        let account: String
        var done: Int
        var total: Int

        var id: String { account }
        var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
    }

    var phase: Phase = .idle
    var runDone = 0
    var runTotal = 0
    var failedCount = 0
    /// The file being worked on now, for "Uploading IMG_0042.HEIC".
    var currentFilename: String?
    var accounts: [AccountProgress] = []
    var lastError: String?
    var lastRun: Date?

    var isActive: Bool {
        switch phase {
        case .idle, .paused: false
        default: true
        }
    }

    var remaining: Int { max(0, runTotal - runDone) }
    var runFraction: Double { runTotal > 0 ? Double(runDone) / Double(runTotal) : 0 }

    var waitReason: WaitReason? {
        if case let .waiting(reason) = phase { reason } else { nil }
    }
}

/// What the engine may ask of the app. Phase 2 adds what a run needs (the
/// records, the credentials, the selection); phase 1 only reports.
@MainActor
protocol BackupEngineHost: AnyObject {
    func log(_ category: EventCategory, _ message: String, problem: Bool)
    func runFinished(_ record: RunRecord, account: String?)
}

/// "Back up now / pause / status": every control the app has over backing
/// up. Implementations are @Observable so views follow `status`.
@MainActor
protocol BackupEngine: AnyObject {
    var status: BackupEngineStatus { get }
    func backUpNow(to destination: BackupDestination, trigger: RunTrigger)
    func pause()
    func resume()
    func stop()
    func retryFailed()
}

/// Phase 1's engine: it runs nothing and says so in the Activity timeline,
/// so a button that does nothing is never mistaken for a backup that ran.
@MainActor
@Observable
final class PlaceholderBackupEngine: BackupEngine {
    private(set) var status = BackupEngineStatus()
    @ObservationIgnored private weak var host: BackupEngineHost?

    static let notice = "This build of Photos Backup for iOS does not upload yet: the backup engine comes in a later version. Nothing was sent to Google."

    init(host: BackupEngineHost) {
        self.host = host
    }

    func backUpNow(to destination: BackupDestination, trigger: RunTrigger) {
        Log.engine.notice("Backup requested (\(trigger.rawValue, privacy: .public)); placeholder engine, nothing runs")
        host?.log(.run, "\(trigger.title): \(Self.notice)", problem: false)
    }

    func pause() { host?.log(.run, "Pause: no backup is running. \(Self.notice)", problem: false) }
    func resume() { host?.log(.run, "Resume: no backup is paused. \(Self.notice)", problem: false) }
    func stop() { host?.log(.run, "Stop: no backup is running.", problem: false) }
    func retryFailed() { host?.log(.run, "Retry: nothing has failed. \(Self.notice)", problem: false) }
}

#if DEBUG
/// Screenshots only: a run in progress that never moves, with working
/// Pause / Resume / Stop so the controls can be drawn in each state.
@MainActor
@Observable
final class FixtureBackupEngine: BackupEngine {
    var status: BackupEngineStatus

    init(status: BackupEngineStatus) {
        self.status = status
    }

    func backUpNow(to destination: BackupDestination, trigger: RunTrigger) { status.phase = .running }
    func pause() { status.phase = .paused }
    func resume() { status.phase = .running }
    func stop() { status.phase = .idle }
    func retryFailed() {}
}
#endif
