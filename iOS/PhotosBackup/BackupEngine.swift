import Foundation
import Observation
import PhotosBackupCore

// The seam between the app and the backup engine. The AppModel and every
// view talk only to this protocol: NativeBackupEngine (Engine/) backs up,
// FixtureBackupEngine draws a run for screenshots.

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

/// What the engine reports to the app.
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
    /// iOS took the background time back: stop where the run is and save.
    func expire()
    /// Write whatever the run holds in memory (the app is leaving the front).
    func saveNow()
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
    func expire() {}
    func saveNow() {}
}
#endif
