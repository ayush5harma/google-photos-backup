import Foundation
import Observation
import PhotosBackupCore

/// Where one account's part of a run goes, as a pass asks for it.
struct LanePlan: Equatable {
    let account: String
    /// The album selection goes to it.
    let photos: Bool
    /// It follows the saved choice: left out during the run, it stops taking
    /// the selection at the engine's next pass, rather than uploading the
    /// rest of the selection to an account someone just unticked. False for
    /// a one-off to it.
    let followsChoice: Bool
}

/// One account's part of a run (issue #66): everything that was the engine's
/// own while it backed up to one account at a time. Each account has its own
/// bridge process, upload parallelism, retries, album work and run record,
/// and its record is saved after each of its requests, as before; the
/// engine runs the lanes of a pass side by side and shares only the export
/// from Photos, the conditions, Google's 429 hold, Pause and Stop.
///
/// One bridge process per account because a serve session answers one
/// request at a time, in order, and its events carry no request id
/// (Bridge/gpmc_bridge.py `serve`): two requests on one session would read
/// each other's media keys.
@MainActor
@Observable
final class AccountLane {
    let plan: LanePlan
    var account: String { plan.account }
    /// For the run view.
    let title: String
    @ObservationIgnored let auth: String
    @ObservationIgnored let bridge = BridgeSession()
    /// How many uploads go at once to this account, for the rest of the run.
    var parallelism: UploadParallelism
    /// This account's counts in the run; each item counts once.
    var tally = RunTally()
    /// Why this account's part ended early, when it did.
    var lastError: String?
    /// Ended early (a refused sign-in, a full account, Google unreachable):
    /// the other accounts carry on.
    var halted = false
    @ObservationIgnored var record: RunRecord
    @ObservationIgnored var retries = RetryTracker()
    @ObservationIgnored var failedAssets = Set<String>()
    @ObservationIgnored var failedAlbums = Set<String>()
    /// Guard C (2): per album, the photos this run added by itself to a
    /// Google album linked before it (BackupState.recordAlbum's count),
    /// which BackupPlanner.linkedAlbumAddLimit caps; per account.
    @ObservationIgnored var albumAddsThisRun: [String: Int] = [:]
    /// Albums whose held adds this run already put in the timeline.
    @ObservationIgnored var heldAlbumsLogged = Set<String>()

    init(plan: LanePlan, title: String, auth: String, parallelism: UploadParallelism, record: RunRecord) {
        self.plan = plan
        self.title = title
        self.auth = auth
        self.parallelism = parallelism
        self.record = record
    }

    var remaining: Int { max(0, tally.total - tally.done) }

    /// "12 of 100, 8 at a time" for the run view.
    var progressLine: String {
        let counts = tally.total > 0 ? "\(tally.done.formatted()) of \(tally.total.formatted())" : "Looking for new items"
        return "\(counts), \(parallelism.current) at a time"
    }
}
