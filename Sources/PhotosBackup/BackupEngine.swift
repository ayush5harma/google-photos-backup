import Foundation
import CryptoKit
import Observation
import PhotosBackupCore

struct ActivityItem: Identifiable, Equatable {
    enum Status: Equatable {
        case exporting, hashing, checking
        /// Exported ahead of its batch's turn, waiting for the uploads before it.
        case ready
        case uploading(Double)
        case finalizing, uploaded, existing, stopped
        /// Holding before the next attempt; the text says why.
        case waiting(String)
        case failed(String)

        var isFinished: Bool {
            switch self {
            case .uploaded, .existing, .failed, .stopped: true
            default: false
            }
        }

        var label: String {
            switch self {
            case .exporting: "Preparing from Photos..."
            case .hashing: "Checking..."
            case .checking: "Looking for it in Google Photos..."
            case .ready: "Ready to upload"
            case let .uploading(fraction): "Uploading \(Int(fraction * 100))%"
            case .finalizing: "Finishing..."
            case .uploaded: "Backed up"
            case .existing: "Already backed up"
            case .stopped: "Stopped"
            case let .waiting(reason): reason
            case let .failed(message): message
            }
        }
    }

    /// The row: with several accounts a photo has one per account
    /// (BackupEngine.row), so a failure and its Retry are that account's.
    let id: String
    var filename: String
    var size: Int64?
    var status: Status
    /// Google's own words for a failure, in full, for the detail sheet.
    var detail: String?
    var date = Date()
    /// For a failure: whether trying again may work (the network, a busy
    /// Google) rather than the file itself being the problem.
    var retryable: Bool?
    /// The account the row's upload goes to, for the run view.
    var account: String?

    var isFailed: Bool {
        if case .failed = status { true } else { false }
    }

    /// The photo, Messages item or device item the row is about.
    var assetID: String { BackupEngine.assetID(ofRow: id) }
}

/// Where a failed item came from, so Retry can queue it the same way again.
private enum FailureSource {
    /// A Photos asset in a selected album: the planner finds it again.
    case asset
    case picked
    case messages(MessagesMediaItem)
    case device(DeviceMediaItem)
}

/// A failed item and the account whose run it failed in. Retry queues it for
/// that account again: a failure of another account's run once retried on
/// the primary went to the wrong account (PR #53 review).
private struct Failure {
    let source: FailureSource
    let account: String?
}

/// One staged file in a batch, with what to record once Google confirms it.
private struct BatchItem {
    let bridgeItem: BridgeItem
    let size: Int64?
    let stamp: EditStamp?
    /// Present only for connected-device staging. This binds the deletion
    /// decision to the exact bytes Google later reads back.
    let fingerprint: SourceFingerprint?

    var id: String { bridgeItem.id }
}

private struct SourceFingerprint: Equatable {
    let sha256: String
    let bytes: Int64
}

/// One upload step's photos, exported into private staging folders (a
/// second one when an export ahead stopped part-way and the rest followed).
/// With several accounts, one export serves every account that planned it,
/// and its folders go once each of them is done (issue #66).
private struct StagedBatch {
    var directories: [URL]
    var ids: [String]
    /// The activity rows (account and asset) the batch holds in flight.
    var rows: [String] = []
    var items: [BatchItem] = []
    /// false when the export stopped before all of `ids` (a hold, the
    /// staging cap, low disk, a stop); the step exports the rest itself.
    var complete = true

    var bytes: Int64 { items.reduce(0) { $0 + ($1.size ?? 0) } }

    mutating func append(_ other: StagedBatch) {
        directories += other.directories
        ids += other.ids
        rows += other.rows
        items += other.items
    }

    func removeFiles() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
    }
}

/// Runs backups: plans from the selected albums for each account the run
/// goes to, exports each batch from Photos once, uploads it through one
/// bridge per account, all accounts at the same time, and records what
/// Google confirmed in each account's own record.
@MainActor
@Observable
final class BackupEngine {
    enum Phase: Equatable {
        case idle, running, pausing, paused, stopping
        /// Alive but holding before the next batch; `waitReason` says why.
        case waiting
    }

    private(set) var phase: Phase = .idle
    private(set) var activity: [ActivityItem] = []
    /// The accounts of the run in progress, or of the last one, in run order.
    private(set) var lanes: [AccountLane] = []
    #if DEBUG
    @ObservationIgnored private var fixtureTally: RunTally?
    #endif
    /// Items this run set out to upload, and how many have an outcome, over
    /// every account: a photo going to two accounts counts twice.
    var runTotal: Int {
        #if DEBUG
        if let fixtureTally { return fixtureTally.total }
        #endif
        return lanes.reduce(0) { $0 + $1.tally.total }
    }

    var runDone: Int {
        #if DEBUG
        if let fixtureTally { return fixtureTally.done }
        #endif
        return lanes.reduce(0) { $0 + $1.tally.done }
    }

    private(set) var lastError: String?
    private(set) var lastRun: Date?
    /// Set while phase is `.waiting`.
    private(set) var waitReason: WaitReason?
    /// When the current wait began, for the diagnostic report.
    private(set) var waitingSince: Date?
    /// Items that failed for their run, by row, until retried or backed up.
    private var failures: [String: Failure] = [:]

    /// Upload speed and time left in this run, over every account.
    private(set) var meter = ThroughputMeter()

    @ObservationIgnored private unowned let model: AppModel
    /// Upload batches of the current pass exported ahead of their turn, by
    /// batch index. An export let go by a stop or a pass's end finishes its
    /// item in progress on its own; its files go then.
    @ObservationIgnored private let ahead = ExportAhead<StagedBatch>(bytes: \.bytes, isComplete: \.complete,
                                                                     abandoned: { $0.removeFiles() })
    /// What each batch of the current pass exports ahead, by batch index, so
    /// a discard can stop the rows of the one still exporting.
    @ObservationIgnored private var aheadSteps: [Int: (ids: [String], rows: [String])] = [:]
    /// Verification belongs to the run just like upload: Stop terminates it,
    /// and no orphan child can later make a deletion decision.
    @ObservationIgnored private let verifier = BridgeProcess()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var runtime: BridgeRuntime?
    /// Where the next run goes: set by AccountRunner for a pass, and by a
    /// pause for its resume; nil is the active account (see defaultPlans).
    @ObservationIgnored private var nextPlans: [LanePlan]?
    /// Accounts whose failures Retry queued while no run of theirs was going.
    @ObservationIgnored private var retryAccounts: [String] = []
    /// A run that could not start any account: its record, for the history.
    @ObservationIgnored private var unstartedRecord: RunRecord?
    @ObservationIgnored private var picked: [String] = []
    /// Picker files for picks PhotoKit cannot see, until Google has them.
    @ObservationIgnored private var pickedFiles: [String: URL] = [:]
    @ObservationIgnored private var messages: [MessagesMediaItem] = []
    @ObservationIgnored private var deviceItems: [DeviceMediaItem] = []
    /// Kept only while a connected-device run is queued. The device is the
    /// authority for the bytes, never a persistent path on the Mac.
    @ObservationIgnored private weak var deviceSource: ConnectedDeviceSource?
    @ObservationIgnored private var deviceAlbumName: String?
    @ObservationIgnored private var deviceReclaimRequested = false
    @ObservationIgnored private var reclaimGeneration = 0
    @ObservationIgnored private var messagesOnly = false
    /// The rows being exported or sent; Retry leaves these alone.
    @ObservationIgnored private var inFlight = Set<String>()
    /// Lives across runs: Google's hold does not end because a run did. One
    /// per account (review of PR #68): a 429 holds that account's uploads
    /// and album calls; the other accounts carry on.
    @ObservationIgnored private var rateLimits = AccountRateLimits()
    /// Back Up Now, picks, Retry and Shortcuts go ahead on a metered network
    /// or battery (RunTrigger.overridesConditions); other runs wait.
    @ObservationIgnored private var overridesConditions = false
    /// Retry asked for items while a run was going; it makes another pass.
    @ObservationIgnored private var retryRequested = false
    @ObservationIgnored private var sleepActivity: NSObjectProtocol?
    /// Per account, the last failure put in the timeline.
    @ObservationIgnored private var lastLoggedFailure: [String: String] = [:]
    @ObservationIgnored private let redactor = Redactor()
    /// What each account sending (or the export, "") waits for, if anything.
    /// The run shows as waiting only once every one of `workers` waits.
    @ObservationIgnored private var waits: [String: WaitReason] = [:]
    @ObservationIgnored private var workers = 1
    #if DEBUG
    /// Tests without a Photos library: files that stand in for the selected
    /// albums, planned and exported per account as an album would be.
    @ObservationIgnored var standInsForTesting: [MessagesMediaItem]?
    /// How many stand-in files were exported: once per photo, however many
    /// accounts it went to.
    @ObservationIgnored private(set) var standInExportsForTesting = 0
    /// The most accounts that had a bridge request in flight at once.
    @ObservationIgnored private(set) var mostAccountsSendingForTesting = 0
    @ObservationIgnored private var accountsSending = 0
    #endif

    private static let activityLimit = 2000
    /// A failure's first line, this long at most, is the row's label; the
    /// whole text is in `detail`.
    private static let labelLimit = 160
    private static let exportWaiter = ""

    init(model: AppModel) {
        self.model = model
    }

    /// One account's row for one item.
    nonisolated static func row(_ account: String, _ assetID: String) -> String { "\(account)\u{1F}\(assetID)" }

    nonisolated static func assetID(ofRow row: String) -> String {
        row.split(separator: "\u{1F}", maxSplits: 1).last.map(String.init) ?? row
    }

    private nonisolated static func account(ofRow row: String) -> String? {
        let parts = row.split(separator: "\u{1F}", maxSplits: 1)
        return parts.count == 2 ? String(parts[0]) : nil
    }

    var remaining: Int { max(0, runTotal - runDone) }
    var runFraction: Double { runTotal == 0 ? 0 : Double(runDone) / Double(runTotal) }
    var isActive: Bool { phase == .running || phase == .pausing || phase == .stopping || phase == .waiting }
    /// Failed items that Retry would queue again.
    var failedCount: Int { failures.values.filter(isRetryable).count }

    /// The account of a failure is still one a run can go to and, for a
    /// library photo, one that takes the album selection on the pass Retry
    /// starts: a photo is retried by planning the selection to its account
    /// again. A one-off's failure for an account the choice leaves out once
    /// had its failure cleared for a run that never planned it, and the row
    /// ended "Stopped" (review of PR #68); now it stays failed, and another
    /// one-off to that account tries it again. Retry never widens a run to
    /// the whole selection for an account someone left out.
    private func isRetryable(_ failure: Failure) -> Bool {
        guard let account = failure.account, model.runnableAccounts.contains(where: { $0.id == account }) else { return false }
        guard case .asset = failure.source else { return true }
        // A run going on to it takes it on its next pass; otherwise the next
        // run, whose plan for it follows the saved choice (defaultPlans).
        if task != nil, let lane = lane(account), !lane.halted { return takesAlbums(lane) }
        return model.isIncluded(account)
    }

    /// Whether the run in progress goes to `id`.
    func isBackingUp(to id: String) -> Bool { isActive && lanes.contains { $0.account == id && !$0.halted } }

    /// The accounts the run in progress is backing up to, in run order.
    var accountsBackingUp: [String] { isActive ? lanes.filter { !$0.halted }.map(\.account) : [] }

    /// For Diagnostics: each account's upload parallelism.
    var parallelismSummary: String {
        guard !lanes.isEmpty else { return UploadParallelism(cap: model.settings.parallelUploadCap,
                                                             automatic: model.settings.threadsAutomatic).summary }
        if lanes.count == 1 { return lanes[0].parallelism.summary }
        return lanes.map { "\(redactor.redact($0.title)): \($0.parallelism.summary)" }.joined(separator: "; ")
    }

    /// Picks, Messages media or a device import still queued. Only the
    /// primary account takes these, and only its part of a run sends them.
    var hasQueuedPrimaryOnlyWork: Bool { !picked.isEmpty || !messages.isEmpty || !deviceItems.isEmpty }

    /// Takes the primary-only work out of the queues. Picks go back to the
    /// app with their picker files, to wait for the primary; Messages media
    /// and a device import are let go (a later scan finds those Messages
    /// items again; the device keeps its files). Only while no run is going.
    /// - Returns: the picks, their files, and how many items were let go.
    func setAsidePrimaryOnlyWork() -> (picked: [String], files: [String: URL], dropped: Int) {
        guard task == nil else { return ([], [:], 0) }
        let held = picked
        let files = pickedFiles.filter { held.contains($0.key) }
        for id in held { pickedFiles[id] = nil }
        picked = []
        let dropped = messages.count + deviceItems.count
        messages = []
        deviceItems = []
        deviceSource?.releaseSelectedDeviceAfterImport()
        deviceSource = nil
        deviceAlbumName = nil
        deviceReclaimRequested = false
        return (held, files, dropped)
    }

    /// Forgets failed picks, Messages media and device items, so that Retry
    /// cannot send what the old primary account was to take to a new one.
    func forgetPrimaryOnlyFailures() {
        failures = failures.filter { if case .asset = $0.value.source { true } else { false } }
        discardPickedFiles()
    }
    /// Google's words for each failed row, for the diagnostic report.
    var failureMessages: [String] { activity.compactMap { $0.isFailed ? ($0.detail ?? $0.status.label) : nil } }

    /// "12.3 MB/s, about 14 min left" while a run is uploading, over every
    /// account; nil before there is a speed to show, and while it waits (the
    /// wait line says why).
    func speedLine(at now: Date = Date()) -> String? {
        guard phase == .running || phase == .pausing else { return nil }
        return ThroughputMeter.describe(bytesPerSecond: meter.bytesPerSecond(at: now),
                                        secondsLeft: meter.secondsLeft(remaining: remaining, at: now))
    }

    // MARK: - Controls

    /// The next start goes to these accounts (AccountRunner's pass); nil
    /// goes back to the active account.
    func prepare(_ plans: [LanePlan]?) {
        nextPlans = plans
    }

    func start(trigger: RunTrigger = .manual) {
        guard task == nil else {
            if phase == .pausing { phase = .running }
            // Asked for in person while an automatic run holds for battery
            // or a metered network: the person's choice wins, as it would
            // have had this been the run that started.
            if trigger.overridesConditions { overridesConditions = true }
            return
        }
        let plans = nextPlans ?? defaultPlans()
        nextPlans = nil
        phase = .running
        overridesConditions = trigger.overridesConditions
        task = Task { [weak self] in
            let ended = await self?.run(trigger: trigger, plans: plans) ?? .halted
            guard let self else { return }
            self.finishRun()
            self.task = nil
            self.lastRun = Date()
            if self.phase == .paused {
                // Resume carries on to every account the run was going to.
                self.nextPlans = plans
            } else {
                self.phase = .idle
            }
            // Photos picked while the last pass was finishing were never
            // planned; failed picks were dropped by run(), and a halted run
            // (stop, fatal error, the primary's part ended early) does not
            // restart, so this ends.
            let queued = !self.picked.isEmpty || !self.messages.isEmpty
            if ended == .ranOut, self.phase == .idle, queued || self.retryRequested || !self.retryAccounts.isEmpty {
                self.start(trigger: self.retryRequested || !self.retryAccounts.isEmpty ? .retry : trigger)
            }
        }
    }

    /// A run started by itself (picks, Messages media, Retry, Resume, a
    /// link): the active account, which is the primary, with the selection
    /// when the choice includes it, and any account whose failures Retry
    /// queued since its last run.
    private func defaultPlans() -> [LanePlan] {
        var plans: [LanePlan] = []
        if let active = model.activeAccountID {
            plans.append(LanePlan(account: active, photos: !messagesOnly && model.isIncluded(active), followsChoice: true))
        }
        for account in retryAccounts where !plans.contains(where: { $0.account == account })
            && model.runnableAccounts.contains(where: { $0.id == account }) {
            plans.append(LanePlan(account: account, photos: true, followsChoice: true))
        }
        retryAccounts = []
        return plans
    }

    /// A hand-picked selection, uploaded ahead of the albums.
    /// - Parameter files: files the picker handed over for picks PhotoKit
    ///   cannot see (hidden photos when the Hidden album is locked).
    func backUp(picked ids: [String], files: [String: URL] = [:]) {
        for (id, url) in files {
            if let old = pickedFiles[id], old != url { PickedFile.discard(old) }
            pickedFiles[id] = url
        }
        picked.append(contentsOf: ids.filter { !picked.contains($0) })
        start(trigger: .picker)
    }

    /// Messages attachments are outside PhotoKit. Their content-hash ids share
    /// the confirmed-upload state, while their separate queue lets this run
    /// without Photos permission or a selected album.
    func backUp(messages items: [MessagesMediaItem], includingPhotos: Bool, trigger: RunTrigger = .manual) {
        let queued = Set(messages.map(\.id))
        let pending = items.filter { model.state.uploaded[$0.id] == nil && !queued.contains($0.id) }
        messages.append(contentsOf: pending)
        // Items a primary's part that ended early left queued start the run
        // as new ones would: the scan finds them again, already queued.
        guard !messages.isEmpty else { return }
        // A run already going keeps its photos: Messages-only may narrow a
        // run that is about to start, never one in progress.
        if task == nil {
            messagesOnly = !includingPhotos
        } else if includingPhotos {
            messagesOnly = false
        }
        start(trigger: trigger)
    }

    /// Queue explicit media from a directly connected device. These are not
    /// Photos albums; one optional destination album name is supplied by the
    /// person importing and is created in Google Photos by the normal bridge.
    func backUp(device items: [DeviceMediaItem], source: ConnectedDeviceSource, destinationAlbumName: String?,
                reclaimOriginals: Bool = false) {
        let queued = Set(deviceItems.map(\.id))
        let pending = DeviceImportPlan.selected(items, ids: Set(items.map(\.id)))
            .filter { model.state.uploaded[$0.id] == nil && !queued.contains($0.id) }
        guard !pending.isEmpty else { return }
        guard source.lockSelectedDeviceForImport() else {
            lastError = "Choose a connected device before starting this import."
            return
        }
        deviceItems.append(contentsOf: pending)
        deviceSource = source
        let trimmed = destinationAlbumName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        deviceAlbumName = trimmed.isEmpty ? nil : trimmed
        deviceReclaimRequested = reclaimOriginals
        start(trigger: .picker)
    }

    /// While waiting, this ends the wait at once: no bridge is running then.
    func pauseAfterCurrent() {
        if phase == .running || phase == .waiting { phase = .pausing }
    }

    func resume() {
        if phase == .paused { phase = .idle }
        start()
    }

    /// The run keeps reading each bridge until it exits, so every item Google
    /// confirmed before the stop is still recorded; cancelling the task would
    /// end that read early. A run that is waiting has no bridge, and leaves
    /// its wait within a second.
    func stop() {
        reclaimGeneration &+= 1
        picked = []
        discardPickedFiles()
        messages = []
        deviceItems = []
        nextPlans = nil
        retryAccounts = []
        deviceSource?.cancelDownload()
        verifier.terminate()
        guard task != nil else {
            // A queued or paused run can hold the device selection without a
            // task yet. Stopping it must release that lock before returning.
            deviceSource?.releaseSelectedDeviceAfterImport()
            deviceSource = nil
            deviceAlbumName = nil
            deviceReclaimRequested = false
            phase = .idle
            return
        }
        phase = .stopping
        waitReason = nil
        for lane in lanes { lane.bridge.terminate() }
        // At once, not when the pass ends: a step may be waiting for its
        // export ahead, whose item in progress can be a long iCloud download.
        discardStagedAhead()
    }

    /// Stop, then wait (bounded) until the run has recorded what it got.
    func stopAndWait(timeout: Duration = .seconds(15)) async {
        guard isActive else { return }
        stop()
        let deadline = ContinuousClock.now + timeout
        while isActive, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(100)) }
    }

    func clearFinished() {
        activity.removeAll { $0.status.isFinished }
    }

    /// Queue one failed row again (a photo, a pick or a Messages item).
    /// Ignored while stopping: the stop is about to clear the queues, and the
    /// row would wait for a run that never comes.
    func retry(_ row: String) {
        guard phase != .stopping, requeue(row) else { return }
        startRetry()
    }

    /// Queue every failed item again, for each account it failed for.
    func retryFailed() {
        guard phase != .stopping else { return }
        let requeued = Array(failures.keys).filter { requeue($0) }
        guard !requeued.isEmpty else { return }
        startRetry()
    }

    func canRetry(_ row: String) -> Bool { phase != .stopping && failures[row].map(isRetryable) == true && !isBusy(row) }

    /// Being sent now, or queued to be: Retry must not reset its attempts.
    /// (A failure of this run stays in its queue until the next prune; that
    /// does not count as queued.)
    private func isBusy(_ row: String) -> Bool {
        if inFlight.contains(row) { return true }
        let id = Self.assetID(ofRow: row)
        if let account = Self.account(ofRow: row), lane(account)?.failedAssets.contains(id) == true { return false }
        return picked.contains(id) || messages.contains { $0.id == id } || deviceItems.contains { $0.id == id }
    }

    private func requeue(_ row: String) -> Bool {
        guard let failure = failures[row], isRetryable(failure), !isBusy(row), let account = failure.account else { return false }
        failures[row] = nil
        let id = Self.assetID(ofRow: row)
        if let lane = lane(account), task != nil {
            lane.failedAssets.remove(id)
            lane.retries.forget(id)
            // A failure of this run stops counting; the item counts again
            // when it is sent.
            lane.tally.requeued(id)
            syncRunCounts(lane)
        }
        // The account's next run plans it again; one going now may not be
        // going to that account.
        if !retryAccounts.contains(account) { retryAccounts.append(account) }
        switch failure.source {
        case .asset: break
        case .picked: if !picked.contains(id) { picked.append(id) }
        case let .messages(item): if !messages.contains(where: { $0.id == id }) { messages.append(item) }
        case let .device(item): if !deviceItems.contains(where: { $0.id == id }) { deviceItems.append(item) }
        }
        update(row) {
            $0.status = .waiting("Waiting to retry")
            $0.retryable = nil
        }
        return true
    }

    private func startRetry() {
        if phase == .paused { phase = .idle }
        // Retry is a request to run; a run about to pause carries on.
        if phase == .pausing { phase = .running }
        if task == nil {
            start(trigger: .retry)
        } else {
            // Accounts the run is going to take theirs on its next pass; the
            // others when it ends (start()'s restart).
            retryAccounts.removeAll { account in lanes.contains { $0.account == account && !$0.halted } }
            retryRequested = true
            overridesConditions = true
        }
    }

    #if DEBUG
    /// Snapshot fixtures only: a populated engine to draw.
    func applyFixture(activity: [ActivityItem], runTotal: Int, runDone: Int, phase: Phase,
                      lastRun: Date?, waitReason: WaitReason? = nil, lastError: String? = nil) {
        self.activity = activity
        self.fixtureTally = RunTally(total: runTotal, done: runDone)
        self.phase = phase
        self.lastRun = lastRun
        self.waitReason = waitReason
        self.lastError = lastError
    }

    /// Tests only: the pick queue set without starting a run, so planPass
    /// can be read without exporting anything (exports reach PhotoKit).
    func setPickedForTesting(_ ids: [String]) {
        picked = ids
    }

    /// Tests only: each account's plan for one pass of a run to `plans`, all
    /// planned together as the run plans them (re-baselines and holds
    /// included), and the shared batches they make, without exporting or
    /// sending anything.
    func planPassForTesting(_ plans: [LanePlan], settings: BackupSettings) -> (steps: [String: [PlannedStep]], pass: SharedPass) {
        let lanes = plans.map(makeLane)
        let steps = lanes.map { ($0.account, planPass(for: $0, settings: settings)) }
        return (Dictionary(steps, uniquingKeysWith: { first, _ in first }),
                SharedPass(plans: steps, batchSize: settings.batchSize))
    }

    /// Tests only: where the next start goes, as AccountRunner prepared it.
    var preparedPlansForTesting: [LanePlan]? { nextPlans }
    #endif

    /// The steps a run started now would plan for the active account, as
    /// its part of the first pass.
    func planPass(settings: BackupSettings) -> [PlannedStep] {
        guard let plan = defaultPlansPreview().first else { return [] }
        return planPass(for: makeLane(plan), settings: settings)
    }

    private func defaultPlansPreview() -> [LanePlan] {
        guard let active = model.activeAccountID else { return [] }
        return [LanePlan(account: active, photos: !messagesOnly && model.isIncluded(active), followsChoice: true)]
    }

    // MARK: - The run

    private var shouldHalt: Bool {
        phase == .stopping || phase == .pausing
    }

    private enum Ended: Equatable {
        /// Out of work: what was queued meanwhile may start another run.
        case ranOut
        /// Stop, pause, a fatal error, nothing to run with, or the primary's
        /// part ended early with its queues left.
        case halted
    }

    private func lane(_ account: String) -> AccountLane? { lanes.first { $0.account == account } }

    private var primaryLane: AccountLane? { lanes.first(where: isPrimary) }

    /// Read when it matters, not at the run's start: only the primary may be
    /// sent a hidden photo, picks, Messages media or a device import.
    private func isPrimary(_ lane: AccountLane) -> Bool { lane.account == model.primaryAccount?.id }

    private func makeLane(_ plan: LanePlan) -> AccountLane {
        let settings = model.settings
        let title = model.accounts.first { $0.id == plan.account }?.title ?? "Google account"
        return AccountLane(plan: plan, title: title, auth: model.credential(for: plan.account) ?? "",
                           parallelism: UploadParallelism(cap: settings.parallelUploadCap, automatic: settings.threadsAutomatic),
                           record: RunRecord(kind: .photos, trigger: .manual, conditions: nil))
    }

    /// Whether this pass backs up the album selection to the lane's account:
    /// asked for, still signed in, and, for the saved choice, still included.
    private func takesAlbums(_ lane: AccountLane) -> Bool {
        lane.plan.photos && (!lane.plan.followsChoice || model.isIncluded(lane.account))
            && model.runnableAccounts.contains { $0.id == lane.account }
    }

    private func run(trigger: RunTrigger, plans: [LanePlan]) async -> Ended {
        lastError = nil
        meter = ThroughputMeter()
        rateLimits.runStarted()
        unstartedRecord = nil
        let messagesAlone = !messages.isEmpty && picked.isEmpty && deviceItems.isEmpty
        lanes = plans.map { plan in
            let lane = makeLane(plan)
            let messagesPart = messagesAlone && plan.account == model.primaryAccount?.id && !plan.photos
            lane.record = RunRecord(kind: messagesPart ? .messagesMedia : .photos, trigger: trigger, conditions: model.conditions.summary)
            return lane
        }
        // Assets are planned afresh for every account this run takes the
        // selection to, so their earlier failures there are tried again
        // anyway; another account's stay (isRetryable). A pick or a Messages
        // item is only tried again if Retry queues it.
        if !messagesOnly {
            let planned = Set(lanes.filter(takesAlbums).map(\.account))
            failures = failures.filter { _, failure in
                guard case .asset = failure.source else { return true }
                return failure.account.map { !planned.contains($0) } ?? false
            }
        }
        retryAccounts.removeAll { account in plans.contains { $0.account == account } }
        #if DEBUG
        mostAccountsSendingForTesting = 0
        #endif
        model.diagnostics.runActive = true

        guard !lanes.isEmpty else {
            lastError = "Sign in with Google in Settings to start backing up."
            unstartedRecord = RunRecord(kind: messagesAlone ? .messagesMedia : .photos, trigger: trigger, conditions: model.conditions.summary)
            endQueues()
            return .halted
        }
        guard let runtime = BridgeRuntime.locate() else {
            haltEveryLane("The uploader runtime is missing; build the app with scripts/build-app.sh.")
            endQueues()
            return .halted
        }
        self.runtime = runtime
        for lane in lanes where lane.auth.isEmpty {
            halt(lane, "Sign in with Google in Settings to start backing up.")
        }
        holdAwake()
        defer {
            for lane in lanes { lane.bridge.close() }
            endQueues()
            endAllWaits()
            allowSleep()
        }

        var announced = false
        // Passes repeat because one pass can make work for the next: an asset
        // uploaded for All Photos may also belong to a mirrored album.
        while !shouldHalt, lanes.contains(where: { !$0.halted }) {
            retryRequested = false
            if let primary = primaryLane, !primary.halted {
                switch await sendPrimaryQueues(primary, trigger: trigger, announced: &announced) {
                case .progressed: continue
                case .halt:
                    if phase == .stopping { return .halted }
                    continue
                case .nothing: break
                }
            }
            // Messages media alone (a Messages-only run, or the primary's
            // part of a pass whose photos go nowhere): no pass over the albums.
            if !lanes.contains(where: { !$0.halted && takesAlbums($0) }), picked.isEmpty { break }
            await model.reloadAlbums()
            let settings = model.settings
            let working = lanes.filter { !$0.halted && (takesAlbums($0) || (isPrimary($0) && !picked.isEmpty)) }
            let pass = sharedPass(working, settings: settings)
            guard !pass.isEmpty else { break }
            for lane in working { planned(lane, pass.uploads[lane.account] ?? 0) }
            announce(&announced, trigger: trigger)

            let progressed = await execute(pass, settings: settings)
            // Pause, Stop or a halt can leave later batches exported and unsent.
            discardStagedAhead()
            if phase == .stopping { return .halted }
            if !progressed, !retryRequested { break }
        }
        if phase == .pausing { phase = .paused }
        if phase == .stopping || phase == .paused || lanes.allSatisfy(\.halted) { return .halted }
        // The primary's part ended early: its queues wait for its next run
        // rather than make this one start again at once.
        if primaryLane?.halted == true, hasQueuedPrimaryOnlyWork { return .halted }
        return .ranOut
    }

    /// The device import, then Messages media: the primary's part alone,
    /// before the passes over the albums.
    private func sendPrimaryQueues(_ lane: AccountLane, trigger: RunTrigger, announced: inout Bool) async -> Outcome {
        guard let runtime else { return .halt }
        deviceItems.removeAll { record(lane).uploaded[$0.id] != nil || lane.failedAssets.contains($0.id) }
        if !deviceItems.isEmpty {
            guard let deviceSource else {
                for item in deviceItems { fail(item.id, lane: lane, "The connected device is no longer available.", retryable: true) }
                return .progressed
            }
            let batch = deviceReclaimRequested
                ? deviceSource.batchKeepingPairsTogether(deviceItems, limit: model.settings.batchSize)
                : Array(deviceItems.prefix(model.settings.batchSize))
            planned(lane, batch.count)
            announce(&announced, trigger: trigger)
            let album = deviceAlbumName.map { (id: "device-album:\($0)", title: $0) }
            if await upload(device: batch, source: deviceSource, album: album, lane: lane,
                            accountEmail: record(lane).accountEmail, reclaimGeneration: reclaimGeneration, runtime: runtime,
                            settings: model.settings) == .halt { return endPart(lane) }
            return .progressed
        }
        messages.removeAll { record(lane).uploaded[$0.id] != nil || lane.failedAssets.contains($0.id) }
        if !messages.isEmpty {
            let batch = Array(messages.prefix(model.settings.batchSize))
            planned(lane, batch.count)
            announce(&announced, trigger: trigger)
            // Every item of a batch ends uploaded or failed (or the run
            // halts), so the next batch is always different.
            if await upload(messages: batch, lane: lane, settings: model.settings) == .halt { return endPart(lane) }
            return .progressed
        }
        return .nothing
    }

    /// A part that answered `.halt`: the whole run on Stop, else this
    /// account's part ends and the others carry on.
    private func endPart(_ lane: AccountLane) -> Outcome {
        if phase != .stopping, phase != .pausing { lane.halted = true }
        return .halt
    }

    /// Every account's plan for one pass, merged so each photo is exported
    /// once. Picks go only into the primary's plan; another account gets
    /// only what its own plan (and so its guards) give it.
    private func sharedPass(_ lanes: [AccountLane], settings: BackupSettings) -> SharedPass {
        SharedPass(plans: lanes.map { ($0.account, planPass(for: $0, settings: settings)) }, batchSize: settings.batchSize)
    }

    /// One account's pass over the Photos library: the picks first (the
    /// primary only), then the selected albums when the run takes them to
    /// it. Read every pass, so unticking an account mid-run stops its albums
    /// at the next pass. Only the primary may be sent a hidden photo the
    /// albums list (and never into an album): another account never gets one.
    private func planPass(for lane: AccountLane, settings: BackupSettings) -> [PlannedStep] {
        let takes = takesAlbums(lane)
        let primary = isPrimary(lane)
        let albums = takes ? model.albums.map(\.snapshot) : []
        if settings.mirrorAlbums, takes { rebaselineUnknownMirrors(in: albums + model.unlistedAlbums, lane: lane) }
        if settings.reuploadEdits { stampEarlierUploads(in: albums, lane: lane) }
        var steps: [PlannedStep] = []
        if primary {
            picked.removeAll { record(lane).uploaded[$0] != nil || lane.failedAssets.contains($0) }
            steps = BackupPlanner.plan(picked: picked, state: record(lane), batchSize: settings.batchSize)
        }
        #if DEBUG
        if let standIns = standInsForTesting {
            let state = record(lane)
            let ids = takes ? standIns.map(\.id).filter { state.uploaded[$0] == nil && !lane.failedAssets.contains($0)
                && !lane.tally.confirmedIDs.contains($0) } : []
            let size = max(1, settings.batchSize)
            return steps + stride(from: 0, to: ids.count, by: size).map {
                .upload(albumID: "stand-ins", albumTitle: nil, assetIDs: Array(ids[$0..<min($0 + size, ids.count)]))
            }
        }
        #endif
        // What this run already confirmed is never planned again in it,
        // not even as an edit (Photos' analysis or a favourite can move
        // its date mid-run), so every asset goes to Google at most once
        // per run and re-uploads cannot keep the passes going.
        steps += BackupPlanner.plan(albums: albums, state: record(lane), mirrorAlbums: settings.mirrorAlbums,
                                    batchSize: settings.batchSize,
                                    excludingAssets: lane.failedAssets.union(primary ? picked : []).union(lane.tally.confirmedIDs),
                                    excludingAlbums: lane.failedAlbums, reuploadEdits: settings.reuploadEdits,
                                    uploadsHidden: primary, albumAddsThisRun: lane.albumAddsThisRun)
        if settings.mirrorAlbums { holdAlbumAdds(in: albums, lane: lane) }
        return steps
    }

    /// Guard C (2): adds held back from an album that already exists are
    /// kept in its record until the owner chooses (a hold caused by this
    /// run's earlier adds would otherwise go in by itself next run), and go
    /// in the timeline as a problem once per album and run; the Overview
    /// offers "Add them" and "Skip" for each (AppModel.heldAlbumAdds).
    /// Per account: each account's record holds its own.
    private func holdAlbumAdds(in albums: [AlbumSnapshot], lane: AccountLane) {
        let held = BackupPlanner.heldAlbumAdds(albums: albums, state: record(lane), albumAddsThisRun: lane.albumAddsThisRun)
        // Only a hold that grew is news: one already waiting is on the
        // Overview, and a problem line every run would bury the timeline.
        let grown = held.filter { album in change(lane) { $0.holdAlbumAdds(album.albumID, assetIDs: album.assetIDs) } ?? false }
        if !grown.isEmpty { save(lane) }
        for album in grown where lane.heldAlbumsLogged.insert(album.albumID).inserted {
            let photos = Self.photos(album.assetIDs.count)
            model.log(.photos, "\(photos) waiting to be added to an album: more than \(BackupPlanner.linkedAlbumAddLimit) would have "
                      + "gone into a Google album that already exists, so none were sent. Add them or skip them on the Overview.",
                      problem: true)
            model.log(.photos, "Waiting for Add Them or Skip: \(photos) for \"\(album.title)\"\(to(lane)).")
        }
    }

    /// An album call Google refused outright: the album is gone, or every
    /// photo sent was. The bridge cannot tell which without re-adding a photo
    /// the album holds (which could put back one removed by hand), so nothing
    /// is uploaded again; the timeline names the album for the owner to look.
    private func logAlbumRefused(_ title: String, _ message: String, lane: AccountLane) {
        model.log(.photos, "Google Photos refused to add photos to an album (\(message)). Its Google album may have been "
                  + "deleted; nothing was sent again, and the next backup tries once more.", problem: true)
        model.log(.photos, "The album Google Photos refused is \"\(title)\"\(to(lane)).")
    }

    /// " (to x***@gmail.com)" in a plain timeline line when the run goes to
    /// several accounts; problem lines, which reach the shareable report,
    /// carry counts only.
    private func to(_ lane: AccountLane) -> String {
        lanes.count > 1 ? " (to \(lane.title))" : ""
    }

    /// Problem lines reach the shareable report (DiagnosticReport keeps the
    /// last 30), so they carry counts only; each album's title goes in a
    /// plain line beside it, which stays in the timeline.
    private static func photos(_ count: Int) -> String {
        "\(count.formatted()) photo\(count == 1 ? "" : "s")"
    }

    /// Records what an album call put in, and counts it against the run's
    /// limit for albums linked before the call. A call that creates the
    /// album passes its visible members, which may all follow uncounted.
    private func recordAlbum(_ albumID: String, googleAlbumID: String, added: [String], lane: AccountLane) {
        let members = record(lane).mirrors[albumID]?.googleAlbumID == nil
            ? model.albums.first { $0.id == albumID }?.snapshot.visibleAssetIDs ?? []
            : []
        let counted = change(lane) { $0.recordAlbum(albumID, googleAlbumID: googleAlbumID, added: added, members: members) } ?? 0
        if counted > 0 { lane.albumAddsThisRun[albumID, default: 0] += counted }
    }

    /// Guard C (1): a linked album found with no record of its members is
    /// never refilled, only re-baselined; the timeline says which and how
    /// many, as a problem, since something reset the record.
    private func rebaselineUnknownMirrors(in albums: [AlbumSnapshot], lane: AccountLane) {
        let rebaselined = change(lane) { $0.rebaselineUnknownMirrors(in: albums) } ?? []
        guard !rebaselined.isEmpty else { return }
        save(lane)
        for album in rebaselined {
            let photos = Self.photos(album.count)
            model.log(.photos, "A Google album had no record of what it holds, so nothing was added to it: its \(photos) are "
                      + "taken as already there, and only photos added to the album from now on go in.", problem: true)
            model.log(.photos, "The album taken as already holding its \(photos) is \"\(album.title)\"\(to(lane)).")
        }
    }

    /// Drops from the queues what is backed up or failed for this run, and
    /// ends the run-scoped Messages-only flag; on every way out of a run,
    /// including the early ones, or the next photo run would stop after the
    /// Messages queue. The queues are the primary's: they are judged against
    /// its record and its part's failures.
    private func endQueues() {
        let failed = primaryLane?.failedAssets ?? []
        let state = model.primaryAccount.flatMap { model.record(of: $0.id) } ?? model.state
        picked.removeAll { state.uploaded[$0] != nil || failed.contains($0) }
        discardPickedFiles()
        messages.removeAll { state.uploaded[$0.id] != nil || failed.contains($0.id) }
        deviceItems.removeAll { state.uploaded[$0.id] != nil || failed.contains($0.id) }
        if deviceItems.isEmpty {
            deviceSource?.releaseSelectedDeviceAfterImport()
            deviceSource = nil
            deviceAlbumName = nil
            deviceReclaimRequested = false
        }
        messagesOnly = false
    }

    private func planned(_ lane: AccountLane, _ count: Int) {
        lane.tally.planned(count)
        syncRunCounts(lane)
    }

    /// The run record mirrors the tally as it goes.
    private func syncRunCounts(_ lane: AccountLane) {
        lane.record.uploaded = lane.tally.uploaded
        lane.record.existing = lane.tally.existing
        lane.record.failed = lane.tally.failed
        lane.record.bytes = lane.tally.bytes
    }

    private func announce(_ announced: inout Bool, trigger: RunTrigger) {
        guard !announced, runTotal > 0 else { return }
        announced = true
        let accounts = lanes.count > 1 ? " to \(lanes.count) accounts at the same time" : ""
        model.log(.run, "Started backing up \(runTotal) item\(runTotal == 1 ? "" : "s")\(accounts) (\(trigger.title))")
    }

    private func halt(_ lane: AccountLane, _ reason: String) {
        lane.halted = true
        lane.lastError = reason
        lastError = reason
    }

    private func haltEveryLane(_ reason: String) {
        for lane in lanes { halt(lane, reason) }
    }

    /// Ends each account's record and hands it to the history, once per run.
    private func finishRun() {
        allowSleep()
        model.diagnostics.runActive = false
        // No row may promise a wait the ended run will not finish: Retry
        // during a halted run, or an item held when the run gave up.
        for index in activity.indices {
            switch activity[index].status {
            case .waiting, .ready: activity[index].status = .stopped
            default: break
            }
        }
        if lanes.isEmpty, var record = unstartedRecord {
            unstartedRecord = nil
            record.finishedAt = Date()
            record.outcome = .failed(redactor.redact(lastError ?? "The run ended early."))
            finished(record, account: nil)
            return
        }
        for lane in lanes { finish(lane) }
    }

    private func finish(_ lane: AccountLane) {
        syncRunCounts(lane)
        var record = lane.record
        record.finishedAt = Date()
        if phase == .stopping {
            record.outcome = .stopped
        } else if phase == .paused {
            record.outcome = .paused
        } else if lane.halted {
            // history.json is not the report: redact before it is stored.
            record.outcome = .failed(redactor.redact(lane.lastError ?? "The run ended early."))
        } else {
            record.outcome = .completed
        }
        finished(record, account: lane.account)
    }

    private func finished(_ record: RunRecord, account: String?) {
        let key = account ?? ""
        if !record.isIdle {
            let counts = "\(record.uploaded) uploaded, \(record.existing) already in Google Photos, \(record.failed) failed"
            switch record.outcome {
            case let .failed(reason):
                // A missing runtime or credential fails every timer run the
                // same way; once in the timeline is enough.
                if reason != lastLoggedFailure[key] { model.log(.run, "\(record.kind.title) run stopped early (\(counts)): \(reason)", problem: true) }
                lastLoggedFailure[key] = reason
            case .stopped: model.log(.run, "\(record.kind.title) run stopped (\(counts))")
            case .paused: model.log(.run, "\(record.kind.title) run paused (\(counts))")
            default:
                model.log(.run, "\(record.kind.title) run finished: \(counts)", problem: record.failed > 0)
                lastLoggedFailure[key] = nil
            }
        }
        model.runFinished(record, account: account)
    }

    private enum Outcome { case progressed, nothing, halt }

    /// One pass: the shared batches, every account sending its part of each
    /// at the same time, then each account's own album adds and edits.
    private func execute(_ pass: SharedPass, settings: BackupSettings) async -> Bool {
        var progressed = false
        for (index, batch) in pass.batches.enumerated() {
            if shouldHalt { break }
            switch await send(batch, at: index, of: pass, settings: settings) {
            case .progressed: progressed = true
            case .nothing: break
            case .halt: if phase == .stopping { return progressed }
            }
            if !lanes.contains(where: { !$0.halted }) { return progressed }
        }
        guard !shouldHalt else { return progressed }
        let rest = lanes.filter { !$0.halted && !(pass.rest[$0.account] ?? []).isEmpty }
        let outcomes = await sideBySide(rest) { lane in
            var progressed = false
            for step in pass.rest[lane.account] ?? [] {
                if self.shouldHalt || lane.halted { break }
                switch await self.execute(step, lane: lane, settings: settings) {
                case .progressed: progressed = true
                case .nothing: break
                case .halt: return self.endPart(lane)
                }
            }
            return progressed ? .progressed : .nothing
        }
        return progressed || outcomes.contains(.progressed)
    }

    /// Runs `part` for each lane at the same time and waits for all of them;
    /// the run shows as waiting only while every one of them waits.
    private func sideBySide(_ lanes: [AccountLane], _ part: @escaping @MainActor (AccountLane) async -> Outcome) async -> [Outcome] {
        guard !lanes.isEmpty else { return [] }
        workers = lanes.count
        let outcomes = await withTaskGroup(of: Outcome.self) { group in
            for lane in lanes {
                group.addTask { @MainActor in
                    let outcome = await part(lane)
                    // One done: the others alone decide whether the run waits.
                    self.workers = max(1, self.workers - 1)
                    self.showWaits()
                    return outcome
                }
            }
            var outcomes: [Outcome] = []
            for await outcome in group { outcomes.append(outcome) }
            return outcomes
        }
        workers = 1
        showWaits()
        return outcomes
    }

    /// One shared batch: exported once (or taken from the export ahead),
    /// then every account that planned some of it sends its part at the
    /// same time through its own bridge. The staged files go once every
    /// account is done with them.
    ///
    /// The accounts move in lockstep: the next batch starts only once the
    /// slowest account is done with this one (a retry backoff or a 429 hold
    /// included), so a fast account waits for a slow one at every batch. In
    /// total this is never slower than one account at a time, but it caps
    /// the gain at the slowest account's pace. The follow-up (review of
    /// PR #68) is per-lane batch pulling: each lane takes the next batch
    /// when it is ready, with a per-batch count of the lanes still using its
    /// files, which are removed when that count reaches zero.
    private func send(_ batch: SharedPass.Batch, at index: Int, of pass: SharedPass, settings: BackupSettings) async -> Outcome {
        let sending = batch.accounts.compactMap(lane).filter { !$0.halted }
        let sends = batch.sends.filter { send in sending.contains { $0.account == send.account } }
        let owners = Self.owners(of: sends)
        let ids = batch.assetIDs.filter { owners[$0] != nil }
        guard !ids.isEmpty else { return .nothing }
        var staged = await ahead.take(index) ?? StagedBatch(directories: [], ids: [])
        defer { release(staged) }
        // Not exported yet: the whole batch, or what an export ahead left
        // when a hold stopped it part-way (it neither exported nor failed those).
        let exported = Set(staged.items.map(\.id))
        let missing = ids.filter { id in
            !exported.contains(id) && (owners[id] ?? []).contains { lane($0).map { !$0.failedAssets.contains(id) } ?? false }
        }
        if !missing.isEmpty {
            // iCloud originals download during the export, so it waits for the
            // network like the upload does.
            if let outcome = await clearance(retryAt: nil, holding: [], category: .photos, waiter: Self.exportWaiter) {
                markStopped(staged.rows)
                if outcome == .halt, phase != .stopping { haltEveryLane(lastError ?? "The run ended early.") }
                return outcome
            }
            staged.append(await stage(missing, includingHidden: batch.includingHidden, owners: owners, ahead: false))
        }
        if phase == .stopping {
            markStopped(staged.rows)
            return .halt
        }
        guard !staged.items.isEmpty else { return .nothing }
        stageAhead(pass, after: index)
        let byID = Dictionary(staged.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let outcomes = await sideBySide(sending) { lane in
            var progressed = false
            for send in sends where send.account == lane.account {
                if self.shouldHalt || lane.halted { break }
                let items = send.assetIDs.compactMap { byID[$0] }.filter { !lane.failedAssets.contains($0.id) }
                guard !items.isEmpty else { continue }
                // An album call that failed may still have created the album
                // on Google's side (a lost response), so the rest of this run
                // leaves the album alone rather than create it again.
                let title = lane.failedAlbums.contains(send.albumID) ? nil : send.albumTitle
                switch await self.send(items, lane: lane, album: title.map { (send.albumID, $0) }, category: .photos, settings: settings) {
                case .progressed: progressed = true
                case .nothing: break
                case .halt: return self.endPart(lane)
                }
            }
            return progressed ? .progressed : .nothing
        }
        if phase == .stopping { return .halt }
        return outcomes.contains(.progressed) ? .progressed : .nothing
    }

    /// Which accounts each asset of a batch goes to.
    private static func owners(of sends: [SharedPass.Send]) -> [String: [String]] {
        var owners: [String: [String]] = [:]
        for send in sends {
            for id in send.assetIDs where owners[id]?.contains(send.account) != true { owners[id, default: []].append(send.account) }
        }
        return owners
    }

    private func execute(_ step: PlannedStep, lane: AccountLane, settings: BackupSettings) async -> Outcome {
        switch step {
        case let .upload(albumID, albumTitle, assetIDs):
            // Uploads go through the shared batches; kept for completeness.
            let title = lane.failedAlbums.contains(albumID) ? nil : albumTitle
            return await upload(assetIDs, lane: lane, album: title.map { (albumID, $0) },
                                includingHidden: albumID == BackupPlanner.pickedAlbumID, settings: settings)
        case let .addToAlbum(albumID, albumTitle, assetIDs, _):
            if lane.failedAlbums.contains(albumID) { return .nothing }
            return await addToAlbum(assetIDs, albumID: albumID, albumTitle: albumTitle, lane: lane)
        case let .reupload(assetIDs):
            let changed = await checkEdits(assetIDs, lane: lane)
            guard !changed.isEmpty else { return .nothing }
            planned(lane, changed.count)
            return await upload(changed, lane: lane, album: nil, settings: settings)
        }
    }

    // MARK: - Edits

    /// Uploads from before edit stamps get one now, so a later edit shows.
    private func stampEarlierUploads(in albums: [AlbumSnapshot], lane: AccountLane) {
        let unstamped = BackupPlanner.unstampedAssets(albums: albums, state: record(lane))
        guard !unstamped.isEmpty else { return }
        change(lane) { state in
            for (id, date) in unstamped { state.refreshStamp(assetID: id, EditStamp(modified: date, edited: nil)) }
        }
        save(lane)
    }

    /// The changed assets that need uploading; a change that left Google's
    /// copy right (a favourite, a keyword) only refreshes the stamp.
    private func checkEdits(_ assetIDs: [String], lane: AccountLane) async -> [String] {
        let states = await AssetExporter.editStates(of: assetIDs)
        var changed: [String] = []
        var refreshed = false
        for id in assetIDs {
            guard let state = states[id], let modified = state.modified else {
                // Gone from the library: the export says so in the row.
                changed.append(id)
                continue
            }
            let was = record(lane).uploaded[id]?.editStamp
            switch BackupPlanner.editAction(was: was, isEdited: state.edited, editIdentity: state.identity) {
            case .refreshStamp:
                change(lane) { $0.refreshStamp(assetID: id, EditStamp(modified: modified, edited: state.edited, editIdentity: state.identity)) }
                refreshed = true
            case .upload:
                changed.append(id)
            }
        }
        if refreshed { save(lane) }
        if !changed.isEmpty { model.log(.photos, "\(changed.count) edited photo\(changed.count == 1 ? "" : "s") to back up again") }
        return changed
    }

    // MARK: - Batches

    /// One account's own upload of `assetIDs`, exported for it alone: an
    /// edited photo, which each account decides on from its own record.
    private func upload(_ assetIDs: [String], lane: AccountLane, album: (id: String, title: String)?, includingHidden: Bool = false,
                        settings: BackupSettings) async -> Outcome {
        let ids = assetIDs.filter { !lane.failedAssets.contains($0) }
        guard !ids.isEmpty else { return .nothing }
        if let outcome = await clearance(retryAt: nil, holding: [], category: .photos, waiter: lane.account) { return outcome }
        let batch = await stage(ids, includingHidden: includingHidden && isPrimary(lane), owners: Dictionary(uniqueKeysWithValues: ids.map { ($0, [lane.account]) }),
                                ahead: false)
        defer { release(batch) }
        if phase == .stopping {
            markStopped(batch.rows)
            return .halt
        }
        guard !batch.items.isEmpty else { return .nothing }
        return await send(batch.items, lane: lane, album: album, category: .photos, settings: settings)
    }

    /// Exports `assetIDs` from Photos into a new private staging folder,
    /// once for every account in `owners`. Its rows wait as ready when it
    /// runs ahead of its turn rather than look like they are uploading; see
    /// stopsExport for when it stops part-way.
    private func stage(_ assetIDs: [String], includingHidden: Bool, owners: [String: [String]], ahead: Bool) async -> StagedBatch {
        let directory = model.paths.staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let rows = assetIDs.flatMap { id in (owners[id] ?? []).map { Self.row($0, id) } }
        var batch = StagedBatch(directories: [directory], ids: assetIDs, rows: rows)
        var stopped = false
        inFlight.formUnion(rows)
        let started: (String, String) -> Void = { id, filename in
            // Let go by a discard, which has already stopped these rows.
            if ahead, Task.isCancelled { return }
            for account in owners[id] ?? [] { self.show(Self.row(account, id), account: account, filename: filename, status: .exporting) }
        }
        let exported: (String, Result<ExportedAsset, Error>) -> Void = { id, result in
            // The file goes with the folder; the next run finds the item again.
            if ahead, Task.isCancelled { return }
            switch result {
            case let .success(file):
                batch.items.append(BatchItem(bridgeItem: BridgeItem(id: id, path: file.url.path, filename: file.filename),
                                             size: file.size, stamp: file.stamp, fingerprint: nil))
                for account in owners[id] ?? [] {
                    self.update(Self.row(account, id)) { $0.size = file.size; $0.status = ahead ? .ready : .hashing }
                }
            case let .failure(error):
                // A missing asset or an unreadable original: sending it again
                // within this run would fail the same way, for every account.
                for account in owners[id] ?? [] {
                    if let lane = self.lane(account) { self.fail(id, lane: lane, error.localizedDescription, retryable: false) }
                }
            }
        }
        #if DEBUG
        if let standIns = standInsForTesting {
            let files = Dictionary(standIns.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for id in assetIDs {
                guard let item = files[id] else { continue }
                started(id, item.filename)
                let staged = directory.appendingPathComponent(item.filename)
                do {
                    try FileManager.default.copyItem(at: URL(fileURLWithPath: item.path), to: staged)
                    standInExportsForTesting += 1
                    let size = Int64((try? staged.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0)
                    exported(id, .success(ExportedAsset(assetID: id, url: staged, filename: item.filename, size: size, stamp: nil)))
                } catch {
                    exported(id, .failure(error))
                }
            }
            return batch
        }
        #endif
        await AssetExporter().export(assetIDs, includingHidden: includingHidden,
                                     pickedFiles: includingHidden ? pickedFiles : [:], into: directory, shouldStop: { upcoming in
            stopped = self.stopsExport(ahead: ahead, exported: batch.bytes, upcoming: upcoming)
            return stopped
        }, started: started, finished: exported)
        batch.complete = !stopped
        return batch
    }

    /// Whether an export stops before its next item, of `upcoming` bytes if
    /// known, having written `exported`. Every export stops for Stop. One
    /// ahead of its turn also stops for Pause, when discarded, and whenever
    /// the run waits or a condition would hold it (offline, a metered
    /// network...), so it never downloads iCloud originals the settings say
    /// to hold; and when the item would take what waits on disk past
    /// StagingWindow's cap or the disk below its floor. Its batch exports the
    /// rest on its turn.
    private func stopsExport(ahead isAhead: Bool, exported: Int64, upcoming: Int64?) -> Bool {
        if phase == .stopping { return true }
        guard isAhead else { return false }
        if Task.isCancelled || shouldHalt || phase == .waiting || holdingCondition() != nil { return true }
        let free = try? model.paths.staging.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return !ahead.mayExport(upcoming, after: exported, freeSpace: free?.volumeAvailableCapacityForImportantUsage)
    }

    /// The batch is sent or given up by every account: its files go, and
    /// Retry may take its rows again.
    private func release(_ batch: StagedBatch) {
        inFlight.subtract(batch.rows)
        batch.removeFiles()
    }

    /// While batch `index` uploads, exports the next batches of the pass,
    /// one at a time in order, as far as StagingWindow allows. Not while the
    /// run is held: iCloud originals download during an export, and the
    /// batch exports with its own wait once it is its turn. One account in a
    /// 429 hold does not hold the run while another still sends.
    private func stageAhead(_ pass: SharedPass, after index: Int) {
        guard !shouldHalt, holdingCondition() == nil, everyLaneRateHeld(at: Date()) == nil else { return }
        var exports: [Int: (ids: [String], hidden: Bool, owners: [String: [String]])] = [:]
        for next in pass.batches.indices where next > index {
            let batch = pass.batches[next]
            let sends = batch.sends.filter { send in lane(send.account).map { !$0.halted } ?? false }
            let owners = Self.owners(of: sends)
            let ids = batch.assetIDs.filter { owners[$0] != nil }
            if !ids.isEmpty { exports[next] = (ids, batch.includingHidden, owners) }
        }
        aheadSteps = exports.mapValues { export in
            (export.ids, export.ids.flatMap { id in (export.owners[id] ?? []).map { Self.row($0, id) } })
        }
        ahead.stage(exports.keys.sorted()) { next in
            // Discarded before it began: discardStagedAhead has already taken
            // its rows out of flight, and stage() would put them back.
            if Task.isCancelled { return StagedBatch(directories: [], ids: [], complete: false) }
            // Held since it was queued: nothing now; the batch exports it all
            // on its turn, after its wait.
            if self.phase == .waiting || self.holdingCondition() != nil { return StagedBatch(directories: [], ids: [], complete: false) }
            guard let export = exports[next] else { return StagedBatch(directories: [], ids: [], complete: false) }
            return await self.stage(export.ids, includingHidden: export.hidden, owners: export.owners, ahead: true)
        }
    }

    /// Exports ahead that a stop or the pass's end let go, at once: their
    /// files go and their rows show as stopped, like any item a stop leaves
    /// unsent. PR #52 review: this used to wait for the export still running,
    /// whose item in progress cannot be interrupted, so a stop during a large
    /// iCloud download stayed on Stopping for minutes. That export now stops
    /// before its next item, its rows stop here, and its folder goes when
    /// PhotoKit has finished the item.
    private func discardStagedAhead() {
        let discarded = ahead.discard()
        for batch in discarded.ready {
            markStopped(batch.rows)
            release(batch)
        }
        if let index = discarded.exporting, let rows = aheadSteps[index]?.rows {
            inFlight.subtract(rows)
            for row in rows { update(row) { if !$0.status.isFinished { $0.status = .stopped } } }
        }
        aheadSteps = [:]
    }

    private func upload(messages items: [MessagesMediaItem], lane: AccountLane, settings: BackupSettings) async -> Outcome {
        // Rows appear once the batch may go, not while it is held offline.
        if let outcome = await clearance(retryAt: nil, holding: [], category: .messages, waiter: lane.account) { return outcome }
        items.forEach { show(Self.row(lane.account, $0.id), account: lane.account, filename: $0.filename, status: .hashing) }
        let batch = model.paths.staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let rows = items.map { Self.row(lane.account, $0.id) }
        inFlight.formUnion(rows)
        defer {
            inFlight.subtract(rows)
            try? FileManager.default.removeItem(at: batch)
        }
        let prepared = await Task.detached(priority: .utility) { () -> [BatchItem] in
            let files = FileManager.default
            do {
                try files.createDirectory(at: batch, withIntermediateDirectories: true,
                                          attributes: [.posixPermissions: 0o700])
                try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: batch.path)
            } catch {
                return []
            }
            return items.compactMap { item in
                let staged = batch.appendingPathComponent(item.filename)
                guard (try? files.copyItem(at: URL(fileURLWithPath: item.path), to: staged)) != nil,
                      MessagesMediaScanner.contentHash(of: staged) == item.contentHash else { return nil }
                let attributes = try? files.attributesOfItem(atPath: staged.path)
                let size = (attributes?[.size] as? NSNumber)?.int64Value
                return BatchItem(bridgeItem: BridgeItem(id: item.id, path: staged.path, filename: item.filename), size: size, stamp: nil, fingerprint: nil)
            }
        }.value
        if phase == .stopping {
            markStopped(rows)
            return .halt
        }
        let preparedIDs = Set(prepared.map(\.id))
        for item in items where !preparedIDs.contains(item.id) {
            fail(item.id, lane: lane, "The Messages attachment changed or is no longer available.", retryable: false)
        }
        prepared.forEach { prepared in update(Self.row(lane.account, prepared.id)) { $0.size = prepared.size } }
        guard !prepared.isEmpty else { return .nothing }
        return await send(prepared, lane: lane, album: nil, category: .messages, settings: settings)
    }

    private func upload(device items: [DeviceMediaItem], source: ConnectedDeviceSource,
                        album: (id: String, title: String)?, lane: AccountLane, accountEmail: String?,
                        reclaimGeneration: Int,
                        runtime: BridgeRuntime, settings: BackupSettings) async -> Outcome {
        if let outcome = await clearance(retryAt: nil, holding: [], category: .photos, waiter: lane.account) { return outcome }
        let batch = model.paths.staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let rows = items.map { Self.row(lane.account, $0.id) }
        inFlight.formUnion(rows)
        defer {
            inFlight.subtract(rows)
            try? FileManager.default.removeItem(at: batch)
        }
        do {
            try FileManager.default.createDirectory(at: batch, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: batch.path)
        } catch {
            for item in items { fail(item.id, lane: lane, "Could not create the private import folder: \(error.localizedDescription)", retryable: true) }
            return .nothing
        }
        var prepared: [BatchItem] = []
        for item in items {
            if phase == .stopping { markStopped(rows); return .halt }
            show(Self.row(lane.account, item.id), account: lane.account, filename: item.filename, status: .exporting)
            do {
                let staged = try await source.download(item, into: batch)
                let values = try staged.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values.isRegularFile == true else { throw ConnectedDeviceSource.ImportError.missingOutput }
                let bytes = Int64(values.fileSize ?? 0)
                guard bytes > 0 else { throw ConnectedDeviceSource.ImportError.missingOutput }
                let fingerprint = try Self.fingerprint(of: staged)
                prepared.append(BatchItem(bridgeItem: BridgeItem(id: item.id, path: staged.path, filename: item.filename),
                                          size: bytes, stamp: nil, fingerprint: fingerprint))
                update(Self.row(lane.account, item.id)) { $0.size = bytes; $0.status = .hashing }
            } catch {
                fail(item.id, lane: lane, error.localizedDescription, retryable: true)
            }
        }
        guard !prepared.isEmpty else { return .nothing }
        let outcome = await send(prepared, lane: lane, album: album, category: .photos, settings: settings)
        guard outcome != .halt, deviceReclaimRequested else { return outcome }
        await verifyAndReclaim(prepared, source: source, lane: lane, accountEmail: accountEmail,
                               reclaimGeneration: reclaimGeneration, runtime: runtime)
        return outcome
    }

    /// Verification is completed while the private staging files still exist.
    /// Any missing proof, source change, bridge failure, or deletion error
    /// retains the source; the app never turns an upload acknowledgement into
    /// a deletion permission.
    private func verifyAndReclaim(_ items: [BatchItem], source: ConnectedDeviceSource, lane: AccountLane, accountEmail: String?,
                                  reclaimGeneration: Int, runtime: BridgeRuntime) async {
        let verifiedInputs = items.compactMap { item -> OriginalVerificationItem? in
            guard let record = record(lane).uploaded[item.id], let fingerprint = item.fingerprint else { return nil }
            return OriginalVerificationItem(id: item.id, path: item.bridgeItem.path, mediaKey: record.mediaKey,
                                            expectedSHA256: fingerprint.sha256, expectedBytes: fingerprint.bytes)
        }
        guard !verifiedInputs.isEmpty else { return }
        var verified = Set<String>()
        let request = BridgeRequest.verifyOriginal(lane.auth, items: verifiedInputs)
        do {
            let exit = try await verifier.run(request, runtime: runtime, workDirectory: model.paths.logs, log: model.paths.bridgeLog) { event in
                if case let .verified(id, mediaKey, sha256, bytes) = event,
                   let expected = verifiedInputs.first(where: { $0.id == id }),
                   expected.mediaKey == mediaKey, expected.expectedSHA256 == sha256, expected.expectedBytes == bytes {
                    verified.insert(id)
                }
            }
            guard exit == 0, verified.count == verifiedInputs.count else {
                model.log(.photos, "Original verification did not complete; source media was retained.", problem: true)
                return
            }
            // A new sign-in, Stop, or account transition invalidates a
            // confirmation even after Google replied. Check immediately
            // before the destructive request, on the main actor.
            guard phase == .running, self.reclaimGeneration == reclaimGeneration, isPrimary(lane),
                  model.credential(for: lane.account) == lane.auth, record(lane).accountEmail == accountEmail else {
                model.log(.photos, "Backup state changed while verifying; source media was retained.")
                return
            }
            let deleted = try await source.deleteVerified(verified)
            if deleted.count == verified.count {
                model.log(.photos, "Removed \(deleted.count) independently verified source item\(deleted.count == 1 ? "" : "s") from the connected device.")
            } else {
                model.log(.photos, "Some verified source media could not be removed; retained items remain on the device.", problem: true)
            }
        } catch {
            model.log(.photos, "Original verification or source removal failed; source media was retained.", problem: true)
        }
    }

    private static func fingerprint(of url: URL) throws -> SourceFingerprint {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var bytes: Int64 = 0
        while true {
            let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
            bytes += Int64(chunk.count)
        }
        guard bytes > 0 else { throw ConnectedDeviceSource.ImportError.missingOutput }
        return SourceFingerprint(sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined(), bytes: bytes)
    }

    /// Sends staged items to one account through its bridge until each is
    /// confirmed or has failed for this run: retryable failures go again
    /// after their backoff, a 429 holds this account's uploads (not the
    /// others') and refunds the attempt, and the staged files stay in place
    /// for every round.
    private func send(_ items: [BatchItem], lane: AccountLane, album: (id: String, title: String)?, category: EventCategory,
                      settings: BackupSettings) async -> Outcome {
        guard let runtime else { return .halt }
        let account = lane.account
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var pending = StagingWindow.largestFirst(items, size: \.size).map(\.id)
        var retryAt: Date?
        var progressed = false
        var exhausted: [String] = []
        // Later rounds carry only what the one before left: their share of
        // failures is not the level's (UploadSample.firstRound).
        var firstRound = true
        defer {
            // Counts only: a Messages id is a content hash, and Google's
            // words are in each row.
            if !exhausted.isEmpty {
                model.log(category, "\(exhausted.count) item\(exhausted.count == 1 ? "" : "s") failed after "
                                    + "\(lane.retries.policy.maxAttempts) attempts; Activity shows what Google said.", problem: true)
            }
        }

        while !pending.isEmpty {
            // Stop or pause while holding: nothing is in flight, and the items
            // stay un-uploaded rather than failed.
            if let outcome = await clearance(retryAt: retryAt, holding: pending.map { Self.row(account, $0) }, category: category,
                                             waiter: account) {
                return outcome == .nothing && progressed ? .progressed : outcome
            }
            retryAt = nil
            holdAwake()

            // Resolved now, not at planning: an earlier batch of this run may
            // have just created the album.
            let state = record(lane)
            let target = album.flatMap { lane.failedAlbums.contains($0.id) ? nil : state.splittingAlbumTarget(for: $0.id, title: $0.title) }
            // Forced (no hash check) per account: Google lost this account's
            // copy, not necessarily another's.
            let bridgeItems = pending.compactMap { id in byID[id].map { item in
                BridgeItem(id: id, path: item.bridgeItem.path, filename: item.bridgeItem.filename,
                           force: state.forcedUploads?.contains(id) == true ? true : item.bridgeItem.force)
            } }
            let sending = Set(pending)
            var confirmed: [String] = []
            var answered = Set<String>()
            var failed: [(id: String, message: String, retryable: Bool?)] = []
            var fatal: (FatalKind, String)?
            var albumLimited = false
            var missingKeys: [String] = []
            var sample = UploadSample(bytes: 0, seconds: 0, items: 0, rateLimited: false, serverFailures: 0, requested: pending.count,
                                      firstRound: firstRound)
            let request = BridgeRequest.upload(lane.auth, items: bridgeItems, quality: settings.quality,
                                               threads: lane.parallelism.current, album: target)
            let sentAt = Date()
            // The request's album step runs after its uploads: the
            // parallelism controller is timed to the last item's answer.
            var uploadsEndedAt: Date?
            let exit: Int32
            #if DEBUG
            accountsSending += 1
            mostAccountsSendingForTesting = max(mostAccountsSendingForTesting, accountsSending)
            defer { accountsSending -= 1 }
            #endif
            do {
                exit = try await lane.bridge.run(request, runtime: runtime, workDirectory: model.paths.logs, log: model.paths.bridgeLog) { event in
                    switch event {
                    case let .progress(id?, phase, completed, total) where sending.contains(id):
                        let row = Self.row(account, id)
                        self.update(row) { $0.status = Self.status(for: phase, completed: completed, total: total, current: $0.status) }
                        if phase == .uploading { self.meter.sent(id: row, total: completed, at: Date()) }
                    case let .item(id, mediaKey, existing) where sending.contains(id) && !answered.contains(id):
                        answered.insert(id)
                        confirmed.append(id)
                        uploadsEndedAt = Date()
                        self.meter.finished(id: Self.row(account, id), at: Date())
                        if !existing {
                            sample.items += 1
                            sample.bytes += byID[id]?.size ?? 0
                        }
                        self.confirm(id, lane: lane, mediaKey: mediaKey, existing: existing, item: byID[id])
                    case let .itemFailed(id, message, retryable) where sending.contains(id) && !answered.contains(id):
                        answered.insert(id)
                        uploadsEndedAt = Date()
                        self.meter.finished(id: Self.row(account, id), at: Date())
                        failed.append((id, message, retryable))
                    case let .missingMedia(keys):
                        missingKeys += keys
                    case let .album(googleID, _, addedKeys):
                        if let album {
                            let added = addedKeys.map { self.record(lane).assets(confirmed, withMediaKeys: $0) } ?? confirmed
                            self.recordAlbum(album.id, googleAlbumID: googleID, added: added, lane: lane)
                        }
                    case let .albumFailed(message):
                        guard let album else { break }
                        if FailureClassifier.classify(message: message, bridgeRetryable: nil) == .rateLimited {
                            // Google refused the call or a later part of it:
                            // what went in is recorded above; hold, and the
                            // next pass adds the rest with an album step that
                            // waits for the hold (with its cap).
                            albumLimited = true
                        } else {
                            // The title stays out of lastError, which lands in
                            // the shareable report; the timeline names it.
                            lane.failedAlbums.insert(album.id)
                            self.lastError = "Backed up, but not added to a Google Photos album: \(message)"
                            self.logAlbumRefused(album.title, message, lane: lane)
                        }
                    case let .fatal(kind, message):
                        fatal = (kind, message)
                    default:
                        break
                    }
                }
            } catch {
                // Confirmations already read are on disk before the run ends.
                forgetMissing(missingKeys, among: confirmed, album: album?.id, lane: lane)
                save(lane)
                halt(lane, error.localizedDescription)
                markStopped(pending.map { Self.row(account, $0) })
                return .halt
            }
            forgetMissing(missingKeys, among: confirmed, album: album?.id, lane: lane)
            save(lane)
            if !confirmed.isEmpty { progressed = true }

            var next: [String] = []
            var limited = albumLimited
            for failure in failed {
                let kind = FailureClassifier.classify(message: failure.message, bridgeRetryable: failure.retryable)
                limited = limited || kind == .rateLimited
                if kind == .retryable { sample.serverFailures += 1 }
                if retryLater(failure.id, lane: lane, kind, message: failure.message, next: &next, retryAt: &retryAt) == false {
                    fail(failure.id, lane: lane, failure.message, retryable: kind != .permanent)
                    if kind != .permanent { exhausted.append(failure.id) }
                }
            }
            let unanswered = pending.filter { !answered.contains($0) }
            sample.seconds = (uploadsEndedAt ?? Date()).timeIntervalSince(sentAt)
            sample.rateLimited = limited || fatal?.0 == .rateLimit
            sample.includesStartUp = lane.bridge.lastRequestStartedBridge
            adjustParallelism(after: sample, lane: lane, category: category)
            firstRound = false

            if let (kind, message) = fatal {
                switch kind {
                case .rateLimit:
                    limited = true
                    for id in unanswered { _ = retryLater(id, lane: lane, .rateLimited, message: message, next: &next, retryAt: &retryAt) }
                case .network where phase != .stopping:
                    var spent: [String] = []
                    for id in unanswered where !retryLater(id, lane: lane, .retryable, message: message, next: &next, retryAt: &retryAt) {
                        spent.append(id)
                    }
                    if !spent.isEmpty {
                        // Attempts spent and Google still unreachable: this
                        // account's part ends as a run always has, and the
                        // next one tries again.
                        halt(lane, AppModel.describe(kind, message))
                        model.log(.network, AppModel.describe(kind, message), problem: true)
                        spent.forEach { fail($0, lane: lane, message, retryable: true) }
                        markStopped(next.map { Self.row(account, $0) })
                        return .halt
                    }
                default:
                    if phase != .stopping {
                        halt(lane, AppModel.describe(kind, message))
                        model.log(kind == .auth ? .account : category, AppModel.describe(kind, message), problem: true)
                    }
                    markStopped((unanswered + next).map { Self.row(account, $0) })
                    return .halt
                }
            } else if phase != .stopping, exit != 0 || !unanswered.isEmpty {
                let noAnswer = "No answer from the uploader"
                var gaveUp = false
                for id in unanswered where !retryLater(id, lane: lane, .retryable, message: noAnswer, next: &next, retryAt: &retryAt) {
                    fail(id, lane: lane, noAnswer, retryable: true)
                    exhausted.append(id)
                    gaveUp = true
                }
                if gaveUp || unanswered.isEmpty {
                    lastError = "The uploader stopped unexpectedly (exit \(exit)); see the log in Settings."
                }
            }

            if phase == .stopping {
                markStopped((unanswered + next).map { Self.row(account, $0) })
                return .halt
            }
            if limited {
                if holdForRateLimit(lane) {
                    endPart(lane, failing: Self.rateLimitGiveUp, category: .network, leaving: next.map { Self.row(account, $0) })
                    return .halt
                }
            } else if !confirmed.isEmpty {
                rateLimits.batchSucceeded(account)
            }
            pending = next
        }
        return progressed ? .progressed : .nothing
    }

    private static let rateLimitGiveUp = "\(EventPhrase.rateLimited) through \(RateLimiter.maximumHoldsPerRun) waits in a row, "
        + "so this run stopped; the next run tries again."

    /// One request measured; a step down is worth a line in the timeline,
    /// since it holds for the rest of the run or (automatically, after
    /// Google's trouble) until a level higher is tried again.
    private func adjustParallelism(after sample: UploadSample, lane: AccountLane, category: EventCategory) {
        let before = lane.parallelism.current
        lane.parallelism.measured(sample)
        if lane.parallelism.current < before, sample.rateLimited || sample.serverFailures > 0 {
            let until = lane.parallelism.mayRise ? "until a higher level is tried again" : "for the rest of this backup"
            model.log(category, "Uploads go \(lane.parallelism.summary) \(until)\(to(lane)).")
        }
    }

    /// nil when the batch may go. Otherwise what the caller returns: Stop or
    /// Pause ended the wait (rows left as stopped, not failed), or the wait
    /// gave up and the run fails.
    private func clearance(retryAt: Date?, holding rows: [String], category: EventCategory, waiter: String) async -> Outcome? {
        switch await waitUntilClear(retryAt: retryAt, waiter: waiter) {
        case .clear:
            return nil
        case .halted:
            markStopped(rows)
            return phase == .stopping ? .halt : .nothing
        case let .gaveUp(reason):
            lastError = reason
            model.log(category, reason, problem: true)
            if let lane = lane(waiter) { halt(lane, reason) }
            markStopped(rows)
            return .halt
        }
    }

    /// Ends one account's part as failed with `reason`; `rows` were not sent
    /// and stay un-uploaded (not failed), so the next run picks them up.
    private func endPart(_ lane: AccountLane, failing reason: String, category: EventCategory, leaving rows: [String]) {
        halt(lane, reason)
        model.log(category, reason, problem: true)
        markStopped(rows)
    }

    /// Queues `id` for another round if its failure allows one; false when
    /// it has failed for this run.
    private func retryLater(_ id: String, lane: AccountLane, _ kind: FailureClass, message: String,
                            next: inout [String], retryAt: inout Date?) -> Bool {
        let row = Self.row(lane.account, id)
        switch lane.retries.failed(id, as: kind) {
        case let .retry(after):
            let at = Date().addingTimeInterval(after)
            retryAt = max(retryAt ?? at, at)
            next.append(id)
            update(row) {
                $0.status = .waiting("Trying again (attempt \(lane.retries.attempts(for: id) + 1) of \(lane.retries.policy.maxAttempts))")
                $0.detail = message
            }
            return true
        case .waitForRateLimit:
            next.append(id)
            update(row) { $0.status = .waiting("Waiting: Google asked to slow down") }
            return true
        case .giveUp:
            return false
        }
    }

    /// Starts (or joins) Google's hold on the lane's account; true when this
    /// account's part has waited through its allowance of holds and should
    /// end instead.
    private func holdForRateLimit(_ lane: AccountLane) -> Bool {
        let previous = rateLimits[lane.account].holdUntil
        let until = rateLimits.hitLimit(lane.account, at: Date())
        if rateLimits.runShouldGiveUp(lane.account) { return true }
        if until != previous {
            let seconds = Int(until.timeIntervalSinceNow.rounded())
            model.log(.network, "\(EventPhrase.rateLimited); uploads wait \(seconds) s and then carry on\(to(lane)).")
        }
        return false
    }

    /// Google's hold the export waits for: only once every account still
    /// sending is held, since an export for one that is not feeds it.
    private func everyLaneRateHeld(at now: Date) -> Date? {
        rateLimits.everyHeld(lanes.filter { !$0.halted }.map(\.account), at: now)
    }

    private func addToAlbum(_ assetIDs: [String], albumID: String, albumTitle: String, lane: AccountLane) async -> Outcome {
        guard let runtime else { return .halt }
        var progressed = false
        while true {
            if let outcome = await clearance(retryAt: nil, holding: [], category: .photos, waiter: lane.account) { return outcome }
            holdAwake()
            // Worked out again on every try: a call that stopped part-way has
            // already filed some of these, and found others gone.
            let state = record(lane)
            let filed = state.mirrors[albumID]?.addedAssetIDs ?? []
            let pending = assetIDs.filter { state.uploaded[$0] != nil && !filed.contains($0) }
            guard !pending.isEmpty else { return progressed ? .progressed : .nothing }
            let mediaKeys = pending.compactMap { state.uploaded[$0]?.mediaKey }
            let target = state.splittingAlbumTarget(for: albumID, title: albumTitle)
            var fatal: (FatalKind, String)?
            var missingKeys: [String] = []
            do {
                _ = try await lane.bridge.run(.addToAlbum(lane.auth, mediaKeys: mediaKeys, album: target), runtime: runtime,
                                              workDirectory: model.paths.logs, log: model.paths.bridgeLog) { event in
                    switch event {
                    case let .missingMedia(keys):
                        missingKeys += keys
                    case let .album(googleID, _, addedKeys):
                        let added = addedKeys.map { self.record(lane).assets(pending, withMediaKeys: $0) } ?? pending
                        self.recordAlbum(albumID, googleAlbumID: googleID, added: added, lane: lane)
                        progressed = progressed || !added.isEmpty
                    case let .fatal(kind, message):
                        fatal = (kind, message)
                    default:
                        break
                    }
                }
            } catch {
                forgetMissing(missingKeys, among: pending, album: albumID, lane: lane)
                save(lane)
                halt(lane, error.localizedDescription)
                return .halt
            }
            // Forgotten photos are planned for upload on the next pass, so a
            // call that only found dead keys still moved the run on.
            progressed = forgetMissing(missingKeys, among: pending, album: albumID, lane: lane) > 0 || progressed
            save(lane)
            guard let (kind, message) = fatal else { return progressed ? .progressed : .nothing }
            if phase == .stopping { return .halt }
            switch kind {
            case .rateLimit:
                // Google refused the call, or a later part of it: what went in
                // is recorded above, and the rest goes again once the hold is
                // over.
                if holdForRateLimit(lane) {
                    endPart(lane, failing: Self.rateLimitGiveUp, category: .network, leaving: [])
                    return .halt
                }
                continue
            case .auth, .network, .storageFull:
                halt(lane, AppModel.describe(kind, message))
                model.log(kind == .auth ? .account : .network, AppModel.describe(kind, message), problem: true)
                return .halt
            default:
                lane.failedAlbums.insert(albumID)
                lastError = "Could not add photos to a Google Photos album: \(message)"
                logAlbumRefused(albumTitle, message, lane: lane)
                return progressed ? .progressed : .nothing
            }
        }
    }

    // MARK: - Waiting

    private enum WaitResult: Equatable {
        case clear
        /// Stop or Pause ended the wait.
        case halted
        /// The run should end failed, for this reason.
        case gaveUp(String)
    }

    /// Holds before the next bridge run while a condition, Google's hold or
    /// a retry's backoff says so. Re-checks every second (conditions, Stop,
    /// Pause). A run someone started stops waiting for a missing network
    /// after two minutes. `waiter` is the account waiting (or the export).
    private func waitUntilClear(retryAt: Date?, waiter: String) async -> WaitResult {
        defer { endWait(for: waiter) }
        var offlineSince: Date?
        while !shouldHalt {
            let now = Date()
            let reason: WaitReason
            if let condition = holdingCondition() {
                reason = condition
                if reason == .offline {
                    let since = offlineSince ?? now
                    offlineSince = since
                    if ConditionsEvaluator.givesUpWaiting(for: reason, startedByPerson: overridesConditions, since: since, now: now) {
                        return .gaveUp("No network connection, so this backup stopped; it starts again when you ask or automatically later.")
                    }
                } else {
                    offlineSince = nil
                }
            } else if let until = waiter == Self.exportWaiter ? everyLaneRateHeld(at: now) : rateLimits.hold(waiter, at: now) {
                reason = .rateLimited(until: until)
            } else if let retryAt, retryAt > now {
                reason = .retrying(until: retryAt)
            } else {
                return .clear
            }
            enterWait(reason, for: waiter)
            let remaining = reason.until.map { $0.timeIntervalSince(now) } ?? 1
            try? await Task.sleep(for: .seconds(min(1, max(0.05, remaining))))
        }
        return .halted
    }

    /// Only having no network at all holds a run someone started; the
    /// "pause on..." settings hold automatic runs.
    private func holdingCondition() -> WaitReason? {
        guard let reason = model.conditions.blocking(for: model.settings) else { return nil }
        return overridesConditions && reason != .offline ? nil : reason
    }

    private func enterWait(_ reason: WaitReason, for waiter: String) {
        guard waits[waiter] != reason else { return }
        waits[waiter] = reason
        showWaits()
    }

    private func endWait(for waiter: String) {
        guard waits.removeValue(forKey: waiter) != nil else { return }
        showWaits()
    }

    private func endAllWaits() {
        waits = [:]
        showWaits()
    }

    /// The run waits once every account sending waits: one account backing
    /// off a retry while another uploads is still a running backup. The wait
    /// shown is a condition first (it holds them all), then Google's hold,
    /// then the retry due soonest.
    private func showWaits() {
        let shown: WaitReason? = waits.count >= max(1, workers) ? Self.leading(waits.values) : nil
        guard let shown else {
            if phase == .waiting { phase = .running }
            waitReason = nil
            waitingSince = nil
            if phase == .running { holdAwake() }
            return
        }
        if phase == .running { phase = .waiting }
        guard waitReason != shown else { return }
        if waitReason == nil {
            waitingSince = Date()
            allowSleep()
        }
        let wasCondition = waitReason.map { $0.until == nil } ?? false
        waitReason = shown
        if shown.until == nil, !wasCondition { model.log(.network, "Uploads held: \(shown.title.lowercased())") }
    }

    private static func leading(_ reasons: some Collection<WaitReason>) -> WaitReason? {
        if let condition = reasons.first(where: { $0.until == nil }) { return condition }
        if let hold = reasons.first(where: { if case .rateLimited = $0 { true } else { false } }) { return hold }
        return reasons.min { ($0.until ?? .distantPast) < ($1.until ?? .distantPast) }
    }

    // MARK: - Sleep

    /// Idle sleep would cut an upload off mid-file; the Mac may sleep again
    /// while the run waits and once it ends.
    private func holdAwake() {
        guard sleepActivity == nil else { return }
        sleepActivity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .suddenTerminationDisabled, .automaticTerminationDisabled],
            reason: "Backing up to Google Photos")
    }

    private func allowSleep() {
        guard let activity = sleepActivity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        sleepActivity = nil
    }

    // MARK: - Records

    /// The lane's account's record, with the shared selection.
    private func record(_ lane: AccountLane) -> BackupState {
        model.record(of: lane.account) ?? BackupState()
    }

    /// Changes the lane's account's record in memory; save(_:) writes it.
    @discardableResult
    private func change<T>(_ lane: AccountLane, _ body: (inout BackupState) -> T) -> T? {
        model.modifyRecord(of: lane.account, body)
    }

    private func save(_ lane: AccountLane) {
        model.saveRecord(of: lane.account)
    }

    // MARK: - Activity rows

    private static func status(for phase: UploadPhase, completed: Int64, total: Int64, current: ActivityItem.Status) -> ActivityItem.Status {
        switch phase {
        case .hashing: .hashing
        case .checking: .checking
        case .uploading: .uploading(total > 0 ? Double(completed) / Double(total) : 0)
        case .finalizing: .finalizing
        // complete, skipped and error are settled by the item events.
        default: current
        }
    }

    private func confirm(_ id: String, lane: AccountLane, mediaKey: String, existing: Bool, item: BatchItem?) {
        change(lane) { $0.recordUpload(assetID: id, mediaKey: mediaKey, existing: existing, stamp: item?.stamp) }
        if isPrimary(lane), let file = pickedFiles.removeValue(forKey: id) { PickedFile.discard(file) }
        // A confirmation overrides an earlier failure of the same item.
        lane.tally.confirmed(id, existing: existing, bytes: item?.size ?? 0)
        syncRunCounts(lane)
        let row = Self.row(lane.account, id)
        failures[row] = nil
        lane.failedAssets.remove(id)
        update(row) {
            $0.status = existing ? .existing : .uploaded
            $0.detail = nil
            $0.retryable = nil
        }
    }

    private func show(_ row: String, account: String?, filename: String, status: ActivityItem.Status) {
        activity.removeAll { $0.id == row }
        activity.insert(ActivityItem(id: row, filename: filename, size: nil, status: status, account: account), at: 0)
        if activity.count > Self.activityLimit { activity.removeLast(activity.count - Self.activityLimit) }
    }

    private func update(_ row: String, _ change: (inout ActivityItem) -> Void) {
        guard let index = activity.firstIndex(where: { $0.id == row }) else { return }
        change(&activity[index])
    }

    /// An album call found these keys gone from Google Photos (measured
    /// 2026-10-27: 1 of 72 sampled keys a day after upload): forget those
    /// uploads so the photos go up again, without the hash check. A photo this
    /// run already sent waits for the next backup, since the planner never
    /// sends an asset twice in a run. Returns how many uploads were forgotten.
    @discardableResult
    private func forgetMissing(_ keys: [String], among assetIDs: [String], album albumID: String?, lane: AccountLane) -> Int {
        guard !keys.isEmpty else { return 0 }
        let forgotten = change(lane) { $0.forgetUploads(withMediaKeys: keys, among: assetIDs, reportedBy: albumID) } ?? []
        guard !forgotten.isEmpty else { return 0 }
        let later = forgotten.filter { lane.tally.confirmedIDs.contains($0) }.count
        let now = forgotten.count - later
        var parts: [String] = []
        if now > 0 { parts.append("\(now) uploading again now") }
        if later > 0 { parts.append("\(later) on the next backup") }
        model.log(.photos, "Google Photos no longer had \(forgotten.count) backed-up \(forgotten.count == 1 ? "photo" : "photos")\(to(lane)): "
                  + parts.joined(separator: ", ") + ".")
        return forgotten.count
    }

    /// Picker files are hidden photos: keep one only while its pick is still
    /// queued or waiting in Activity for Retry.
    private func discardPickedFiles() {
        let failedPicks = Set(failures.compactMap { row, failure in
            if case .picked = failure.source { Self.assetID(ofRow: row) } else { nil }
        })
        for (id, url) in pickedFiles where !picked.contains(id) && !failedPicks.contains(id) {
            PickedFile.discard(url)
            pickedFiles[id] = nil
        }
    }

    /// The item has failed for this account's part of the run; Retry or the
    /// next run releases it.
    private func fail(_ id: String, lane: AccountLane, _ message: String, retryable: Bool) {
        lane.failedAssets.insert(id)
        let row = Self.row(lane.account, id)
        // Done for this account, even in a batch exported ahead: Retry may take it now.
        inFlight.remove(row)
        lane.tally.failed(id)
        syncRunCounts(lane)
        if id.hasPrefix("messages:") {
            if let item = messages.first(where: { $0.id == id }) { failures[row] = Failure(source: .messages(item), account: lane.account) }
        } else if id.hasPrefix("device:") {
            if let item = deviceItems.first(where: { $0.id == id }) { failures[row] = Failure(source: .device(item), account: lane.account) }
        } else {
            failures[row] = Failure(source: isPrimary(lane) && picked.contains(id) ? .picked : .asset, account: lane.account)
        }
        let firstLine = message.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? message
        let label = firstLine.count > Self.labelLimit ? String(firstLine.prefix(Self.labelLimit - 3)) + "..." : firstLine
        if !activity.contains(where: { $0.id == row }) { show(row, account: lane.account, filename: "Photo", status: .failed(label)) }
        update(row) {
            $0.status = .failed(label)
            $0.detail = message
            $0.retryable = retryable
        }
    }

    private func markStopped(_ rows: [String]) {
        for row in rows { update(row) { $0.status = .stopped } }
    }
}
