import Foundation
import Observation
import PhotosBackupCore

struct ActivityItem: Identifiable, Equatable {
    enum Status: Equatable {
        case exporting, hashing, checking
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

    var isFailed: Bool {
        if case .failed = status { true } else { false }
    }
}

/// Where a failed item came from, so Retry can queue it the same way again.
private enum FailureSource {
    /// A Photos asset in a selected album: the planner finds it again.
    case asset
    case picked
    case messages(MessagesMediaItem)
}

/// One staged file in a batch, with what to record once Google confirms it.
private struct BatchItem {
    let bridgeItem: BridgeItem
    let size: Int64?
    let stamp: EditStamp?

    var id: String { bridgeItem.id }
}

/// Runs backups: plans from the selected albums, exports each batch from
/// Photos, uploads it through the bridge and records what Google confirmed.
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
    /// This run's counts; each item counts once, as confirmed or failed.
    private(set) var tally = RunTally()
    /// Items this run set out to upload, and how many have an outcome.
    var runTotal: Int { tally.total }
    var runDone: Int { tally.done }
    private(set) var lastError: String?
    private(set) var lastRun: Date?
    /// Set while phase is `.waiting`.
    private(set) var waitReason: WaitReason?
    /// When the current wait began, for the diagnostic report.
    private(set) var waitingSince: Date?
    /// The run in progress, counted as it goes; it joins the history at the end.
    private(set) var currentRun: RunRecord?
    /// Items that failed for their run, by id, until retried or backed up.
    private var failures: [String: FailureSource] = [:]

    @ObservationIgnored private unowned let model: AppModel
    @ObservationIgnored private let bridge = BridgeProcess()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var picked: [String] = []
    @ObservationIgnored private var messages: [MessagesMediaItem] = []
    @ObservationIgnored private var messagesOnly = false
    @ObservationIgnored private var failedAssets = Set<String>()
    @ObservationIgnored private var failedAlbums = Set<String>()
    /// The batch being exported or sent; Retry leaves these alone.
    @ObservationIgnored private var inFlight = Set<String>()
    @ObservationIgnored private var retries = RetryTracker()
    /// Lives across runs: Google's hold does not end because a run did.
    @ObservationIgnored private var rateLimiter = RateLimiter()
    /// Back Up Now and Retry go ahead on a metered network or battery.
    @ObservationIgnored private var overridesConditions = false
    /// Retry asked for items while a run was going; it makes another pass.
    @ObservationIgnored private var retryRequested = false
    @ObservationIgnored private var sleepActivity: NSObjectProtocol?
    @ObservationIgnored private var lastLoggedFailure: String?

    private static let activityLimit = 2000
    /// A failure's first line, this long at most, is the row's label; the
    /// whole text is in `detail`.
    private static let labelLimit = 160

    init(model: AppModel) {
        self.model = model
    }

    var remaining: Int { max(0, runTotal - runDone) }
    var runFraction: Double { runTotal == 0 ? 0 : Double(runDone) / Double(runTotal) }
    var isActive: Bool { phase == .running || phase == .pausing || phase == .stopping || phase == .waiting }
    /// Failed items that Retry would queue again.
    var failedCount: Int { failures.count }
    /// Google's words for each failed row, for the diagnostic report.
    var failureMessages: [String] { activity.compactMap { $0.isFailed ? ($0.detail ?? $0.status.label) : nil } }

    // MARK: - Controls

    func start(trigger: RunTrigger = .manual) {
        guard task == nil else {
            if phase == .pausing { phase = .running }
            // Asked for in person while an automatic run holds for battery
            // or a metered network: the person's choice wins, as it would
            // have had this been the run that started.
            if !trigger.isAutomatic { overridesConditions = true }
            return
        }
        phase = .running
        overridesConditions = !trigger.isAutomatic
        task = Task { [weak self] in
            let halted = await self?.run(trigger: trigger) ?? true
            guard let self else { return }
            self.finishRun(halted: halted)
            self.task = nil
            self.lastRun = Date()
            if self.phase != .paused { self.phase = .idle }
            // Photos picked while the last pass was finishing were never
            // planned; failed picks were dropped by run(), and a halted run
            // (stop, fatal error) does not restart, so this ends.
            if !halted, self.phase == .idle, !self.picked.isEmpty || !self.messages.isEmpty || self.retryRequested {
                self.start(trigger: self.retryRequested ? .retry : trigger)
            }
        }
    }

    /// A hand-picked selection, uploaded ahead of the albums.
    func backUp(picked ids: [String]) {
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
        guard !pending.isEmpty else { return }
        // A run already going keeps its photos: Messages-only may narrow a
        // run that is about to start, never one in progress.
        if task == nil {
            messagesOnly = !includingPhotos
        } else if includingPhotos {
            messagesOnly = false
        }
        start(trigger: trigger)
    }

    /// While waiting, this ends the wait at once: no bridge is running then.
    func pauseAfterCurrent() {
        if phase == .running || phase == .waiting { phase = .pausing }
    }

    func resume() {
        if phase == .paused { phase = .idle }
        start()
    }

    /// The run keeps reading the bridge until it exits, so every item Google
    /// confirmed before the stop is still recorded; cancelling the task would
    /// end that read early. A run that is waiting has no bridge, and leaves
    /// its wait within a second.
    func stop() {
        picked = []
        messages = []
        guard task != nil else {
            phase = .idle
            return
        }
        phase = .stopping
        waitReason = nil
        bridge.terminate()
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

    /// Queue one failed item again (a photo, a pick or a Messages item).
    /// Ignored while stopping: the stop is about to clear the queues, and the
    /// row would wait for a run that never comes.
    func retry(_ id: String) {
        guard phase != .stopping, requeue(id) else { return }
        startRetry()
    }

    /// Queue every failed item again.
    func retryFailed() {
        guard phase != .stopping else { return }
        let requeued = Array(failures.keys).filter { requeue($0) }
        guard !requeued.isEmpty else { return }
        startRetry()
    }

    func canRetry(_ id: String) -> Bool { phase != .stopping && failures[id] != nil && !isBusy(id) }

    /// Being sent now, or queued to be: Retry must not reset its attempts.
    /// (A failure of this run stays in its queue until the next prune; that
    /// does not count as queued.)
    private func isBusy(_ id: String) -> Bool {
        if inFlight.contains(id) { return true }
        if failedAssets.contains(id) { return false }
        return picked.contains(id) || messages.contains { $0.id == id }
    }

    private func requeue(_ id: String) -> Bool {
        guard failures[id] != nil, !isBusy(id), let source = failures.removeValue(forKey: id) else { return false }
        failedAssets.remove(id)
        retries.forget(id)
        // A failure of this run stops counting; the item counts again when
        // it is sent.
        tally.requeued(id)
        syncRunCounts()
        switch source {
        case .asset: break
        case .picked: if !picked.contains(id) { picked.append(id) }
        case let .messages(item): if !messages.contains(where: { $0.id == id }) { messages.append(item) }
        }
        update(id) {
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
            retryRequested = true
            overridesConditions = true
        }
    }

    #if DEBUG
    /// Snapshot fixtures only: a populated engine to draw.
    func applyFixture(activity: [ActivityItem], runTotal: Int, runDone: Int, phase: Phase,
                      lastRun: Date?, waitReason: WaitReason? = nil, lastError: String? = nil) {
        self.activity = activity
        self.tally = RunTally(total: runTotal, done: runDone)
        self.phase = phase
        self.lastRun = lastRun
        self.waitReason = waitReason
        self.lastError = lastError
    }
    #endif

    // MARK: - The run

    private var shouldHalt: Bool {
        phase == .stopping || phase == .pausing
    }

    /// Returns true when the run halted (stop, fatal error, nothing to run
    /// with) rather than running out of work.
    private func run(trigger: RunTrigger) async -> Bool {
        lastError = nil
        failedAssets = []
        failedAlbums = []
        retries = RetryTracker()
        tally = RunTally()
        rateLimiter.runStarted()
        // Assets are planned afresh, so their earlier failures are tried
        // again anyway; a pick or a Messages item is only if Retry queues it.
        if !messagesOnly { failures = failures.filter { if case .asset = $0.value { false } else { true } } }
        currentRun = RunRecord(kind: messagesOnly ? .messagesMedia : .photos, trigger: trigger, conditions: model.conditions.summary)
        model.diagnostics.runActive = true

        guard let runtime = BridgeRuntime.locate() else {
            lastError = "The uploader runtime is missing; build the app with scripts/build-app.sh."
            endQueues()
            return true
        }
        guard let auth = model.authData else {
            lastError = "Sign in with Google in Settings to start backing up."
            endQueues()
            return true
        }
        holdAwake()
        defer {
            endQueues()
            endWait()
            allowSleep()
        }

        var announced = false
        // Passes repeat because one pass can make work for the next: an asset
        // uploaded for All Photos may also belong to a mirrored album.
        while !shouldHalt {
            retryRequested = false
            messages.removeAll { model.state.uploaded[$0.id] != nil || failedAssets.contains($0.id) }
            if !messages.isEmpty {
                let batch = Array(messages.prefix(model.settings.batchSize))
                planned(batch.count)
                announce(&announced, trigger: trigger)
                // Every item of a batch ends uploaded or failed (or the run
                // halts), so the next batch is always different.
                if await upload(messages: batch, auth: auth, runtime: runtime, settings: model.settings) == .halt { return true }
                continue
            }
            if messagesOnly { break }
            await model.reloadAlbums()
            let settings = model.settings
            let albums = model.albums.map(\.snapshot)
            if settings.reuploadEdits { stampEarlierUploads(in: albums) }
            picked.removeAll { model.state.uploaded[$0] != nil || failedAssets.contains($0) }
            // What this run already confirmed is never planned again in it,
            // not even as an edit (Photos' analysis or a favourite can move
            // its date mid-run), so every asset goes to Google at most once
            // per run and re-uploads cannot keep the passes going.
            let steps = BackupPlanner.plan(picked: picked, state: model.state, batchSize: settings.batchSize)
                + BackupPlanner.plan(albums: albums, state: model.state, mirrorAlbums: settings.mirrorAlbums,
                                     batchSize: settings.batchSize,
                                     excludingAssets: failedAssets.union(picked).union(tally.confirmedIDs),
                                     excludingAlbums: failedAlbums, reuploadEdits: settings.reuploadEdits)
            guard !steps.isEmpty else { break }
            planned(steps.reduce(0) { total, step in
                if case let .upload(_, _, ids) = step { total + ids.count } else { total }
            })
            announce(&announced, trigger: trigger)

            var progressed = false
            for step in steps {
                if shouldHalt { break }
                switch await execute(step, auth: auth, runtime: runtime, settings: settings) {
                case .progressed: progressed = true
                case .nothing: break
                case .halt: return true
                }
            }
            if !progressed, !retryRequested { break }
        }
        if phase == .pausing { phase = .paused }
        return phase == .stopping
    }

    /// Drops from the queues what is backed up or failed for this run, and
    /// ends the run-scoped Messages-only flag; on every way out of a run,
    /// including the early ones, or the next photo run would stop after the
    /// Messages queue.
    private func endQueues() {
        picked.removeAll { model.state.uploaded[$0] != nil || failedAssets.contains($0) }
        messages.removeAll { model.state.uploaded[$0.id] != nil || failedAssets.contains($0.id) }
        messagesOnly = false
    }

    private func planned(_ count: Int) {
        tally.planned(count)
        syncRunCounts()
    }

    /// The run record mirrors the tally as it goes, for views that show it.
    private func syncRunCounts() {
        guard currentRun != nil else { return }
        currentRun?.uploaded = tally.uploaded
        currentRun?.existing = tally.existing
        currentRun?.failed = tally.failed
        currentRun?.bytes = tally.bytes
    }

    private func announce(_ announced: inout Bool, trigger: RunTrigger) {
        guard !announced, runTotal > 0 else { return }
        announced = true
        model.log(.run, "Started backing up \(runTotal) item\(runTotal == 1 ? "" : "s") (\(trigger.title))")
    }

    /// Ends the run's record and hands it to the history, once per run.
    private func finishRun(halted: Bool) {
        allowSleep()
        model.diagnostics.runActive = false
        // No row may promise a wait the ended run will not finish: Retry
        // during a halted run, or an item held when the run gave up.
        for index in activity.indices {
            if case .waiting = activity[index].status { activity[index].status = .stopped }
        }
        syncRunCounts()
        guard var record = currentRun else { return }
        currentRun = nil
        record.finishedAt = Date()
        if phase == .stopping {
            record.outcome = .stopped
        } else if phase == .paused {
            record.outcome = .paused
        } else if halted {
            record.outcome = .failed(lastError ?? "The run ended early.")
        } else {
            record.outcome = .completed
        }
        if !record.isIdle {
            let counts = "\(record.uploaded) uploaded, \(record.existing) already in Google Photos, \(record.failed) failed"
            switch record.outcome {
            case let .failed(reason):
                // A missing runtime or credential fails every timer run the
                // same way; once in the timeline is enough.
                if reason != lastLoggedFailure { model.log(.run, "\(record.kind.title) run stopped early (\(counts)): \(reason)", problem: true) }
                lastLoggedFailure = reason
            case .stopped: model.log(.run, "\(record.kind.title) run stopped (\(counts))")
            case .paused: model.log(.run, "\(record.kind.title) run paused (\(counts))")
            default:
                model.log(.run, "\(record.kind.title) run finished: \(counts)", problem: record.failed > 0)
                lastLoggedFailure = nil
            }
        }
        model.runFinished(record)
    }

    private enum Outcome { case progressed, nothing, halt }

    private func execute(_ step: PlannedStep, auth: String, runtime: BridgeRuntime, settings: BackupSettings) async -> Outcome {
        // An album call that failed may still have created the album on
        // Google's side (a lost response), so the rest of this run leaves the
        // album alone rather than create it again; the next run retries.
        switch step {
        case let .upload(albumID, albumTitle, assetIDs):
            let title = failedAlbums.contains(albumID) ? nil : albumTitle
            return await upload(assetIDs, album: title.map { (albumID, $0) }, auth: auth, runtime: runtime, settings: settings)
        case let .addToAlbum(albumID, albumTitle, assetIDs, mediaKeys):
            if failedAlbums.contains(albumID) { return .nothing }
            return await addToAlbum(assetIDs, mediaKeys: mediaKeys, albumID: albumID, albumTitle: albumTitle, auth: auth, runtime: runtime)
        case let .reupload(assetIDs):
            let changed = await checkEdits(assetIDs)
            guard !changed.isEmpty else { return .nothing }
            planned(changed.count)
            return await upload(changed, album: nil, auth: auth, runtime: runtime, settings: settings)
        }
    }

    // MARK: - Edits

    /// Uploads from before edit stamps get one now, so a later edit shows.
    private func stampEarlierUploads(in albums: [AlbumSnapshot]) {
        let unstamped = BackupPlanner.unstampedAssets(albums: albums, state: model.state)
        guard !unstamped.isEmpty else { return }
        for (id, date) in unstamped { model.state.refreshStamp(assetID: id, EditStamp(modified: date, edited: nil)) }
        model.saveState()
    }

    /// The changed assets that need uploading; a change that left Google's
    /// copy right (a favourite, a keyword) only refreshes the stamp.
    private func checkEdits(_ assetIDs: [String]) async -> [String] {
        let states = await AssetExporter.editStates(of: assetIDs)
        var changed: [String] = []
        var refreshed = false
        for id in assetIDs {
            guard let state = states[id], let modified = state.modified else {
                // Gone from the library: the export says so in the row.
                changed.append(id)
                continue
            }
            let was = model.state.uploaded[id]?.editStamp
            switch BackupPlanner.editAction(was: was, isEdited: state.edited, editIdentity: state.identity) {
            case .refreshStamp:
                model.state.refreshStamp(assetID: id, EditStamp(modified: modified, edited: state.edited, editIdentity: state.identity))
                refreshed = true
            case .upload:
                changed.append(id)
            }
        }
        if refreshed { model.saveState() }
        if !changed.isEmpty { model.log(.photos, "\(changed.count) edited photo\(changed.count == 1 ? "" : "s") to back up again") }
        return changed
    }

    // MARK: - Batches

    private func upload(_ assetIDs: [String], album: (id: String, title: String)?, auth: String,
                        runtime: BridgeRuntime, settings: BackupSettings) async -> Outcome {
        // iCloud originals download during the export, so it waits for the
        // network like the upload does.
        if let outcome = await clearance(retryAt: nil, holding: [], category: .photos) { return outcome }
        let batch = model.paths.staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
        inFlight = Set(assetIDs)
        defer {
            inFlight = []
            try? FileManager.default.removeItem(at: batch)
        }

        var items: [BatchItem] = []
        await AssetExporter().export(assetIDs, into: batch, shouldStop: { self.phase == .stopping }, started: { id, filename in
            self.show(id, filename: filename, status: .exporting)
        }, finished: { id, result in
            switch result {
            case let .success(file):
                items.append(BatchItem(bridgeItem: BridgeItem(id: id, path: file.url.path, filename: file.filename), size: file.size, stamp: file.stamp))
                self.update(id) { $0.size = file.size; $0.status = .hashing }
            case let .failure(error):
                // A missing asset or an unreadable original: sending it again
                // within this run would fail the same way.
                self.fail(id, error.localizedDescription, retryable: false)
            }
        })
        if phase == .stopping {
            markStopped(items.map(\.id))
            return .halt
        }
        guard !items.isEmpty else { return .nothing }
        return await send(items, album: album, category: .photos, auth: auth, runtime: runtime, settings: settings)
    }

    private func upload(messages items: [MessagesMediaItem], auth: String,
                        runtime: BridgeRuntime, settings: BackupSettings) async -> Outcome {
        // Rows appear once the batch may go, not while it is held offline.
        if let outcome = await clearance(retryAt: nil, holding: [], category: .messages) { return outcome }
        items.forEach { show($0.id, filename: $0.filename, status: .hashing) }
        let batch = model.paths.staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
        inFlight = Set(items.map(\.id))
        defer {
            inFlight = []
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
                return BatchItem(bridgeItem: BridgeItem(id: item.id, path: staged.path, filename: item.filename), size: size, stamp: nil)
            }
        }.value
        if phase == .stopping {
            markStopped(items.map(\.id))
            return .halt
        }
        let preparedIDs = Set(prepared.map(\.id))
        for item in items where !preparedIDs.contains(item.id) {
            fail(item.id, "The Messages attachment changed or is no longer available.", retryable: false)
        }
        prepared.forEach { prepared in update(prepared.id) { $0.size = prepared.size } }
        guard !prepared.isEmpty else { return .nothing }
        return await send(prepared, album: nil, category: .messages, auth: auth, runtime: runtime, settings: settings)
    }

    /// Sends staged items through the bridge until each is confirmed or has
    /// failed for this run: retryable failures go again after their backoff,
    /// a 429 holds every upload and refunds the attempt, and the staged
    /// files stay in place for every round.
    private func send(_ items: [BatchItem], album: (id: String, title: String)?, category: EventCategory,
                      auth: String, runtime: BridgeRuntime, settings: BackupSettings) async -> Outcome {
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var pending = items.map(\.id)
        var retryAt: Date?
        var progressed = false
        var exhausted: [String] = []
        defer {
            // Counts only: a Messages id is a content hash, and Google's
            // words are in each row.
            if !exhausted.isEmpty {
                model.log(category, "\(exhausted.count) item\(exhausted.count == 1 ? "" : "s") failed after "
                                    + "\(retries.policy.maxAttempts) attempts; Activity shows what Google said.", problem: true)
            }
        }

        while !pending.isEmpty {
            // Stop or pause while holding: nothing is in flight, and the items
            // stay un-uploaded rather than failed.
            if let outcome = await clearance(retryAt: retryAt, holding: pending, category: category) {
                return outcome == .nothing && progressed ? .progressed : outcome
            }
            retryAt = nil
            holdAwake()

            // Resolved now, not at planning: an earlier batch of this run may
            // have just created the album.
            let target = album.flatMap { failedAlbums.contains($0.id) ? nil : model.state.albumTarget(for: $0.id, title: $0.title) }
            let sending = Set(pending)
            var confirmed: [String] = []
            var answered = Set<String>()
            var failed: [(id: String, message: String, retryable: Bool?)] = []
            var fatal: (FatalKind, String)?
            let request = BridgeRequest.upload(auth, items: pending.compactMap { byID[$0]?.bridgeItem }, quality: settings.quality,
                                               threads: settings.threads, album: target)
            let exit: Int32
            do {
                exit = try await bridge.run(request, runtime: runtime, workDirectory: model.paths.logs, log: model.paths.bridgeLog) { event in
                    switch event {
                    case let .progress(id?, phase, completed, total) where sending.contains(id):
                        self.update(id) { $0.status = Self.status(for: phase, completed: completed, total: total, current: $0.status) }
                    case let .item(id, mediaKey, existing) where sending.contains(id) && !answered.contains(id):
                        answered.insert(id)
                        confirmed.append(id)
                        self.confirm(id, mediaKey: mediaKey, existing: existing, item: byID[id])
                    case let .itemFailed(id, message, retryable) where sending.contains(id) && !answered.contains(id):
                        answered.insert(id)
                        failed.append((id, message, retryable))
                    case let .album(googleID, _):
                        if let album { self.model.state.recordAlbum(album.id, googleAlbumID: googleID, added: confirmed) }
                    case let .albumFailed(message):
                        if let album {
                            self.failedAlbums.insert(album.id)
                            self.lastError = "Backed up, but not added to the album \u{201C}\(album.title)\u{201D}: \(message)"
                        }
                    case let .fatal(kind, message):
                        fatal = (kind, message)
                    default:
                        break
                    }
                }
            } catch {
                // Confirmations already read are on disk before the run ends.
                model.saveState()
                lastError = error.localizedDescription
                markStopped(pending)
                return .halt
            }
            model.saveState()
            if !confirmed.isEmpty { progressed = true }

            var next: [String] = []
            var limited = false
            for failure in failed {
                let kind = FailureClassifier.classify(message: failure.message, bridgeRetryable: failure.retryable)
                limited = limited || kind == .rateLimited
                if retryLater(failure.id, kind, message: failure.message, next: &next, retryAt: &retryAt) == false {
                    fail(failure.id, failure.message, retryable: kind != .permanent)
                    if kind != .permanent { exhausted.append(failure.id) }
                }
            }
            let unanswered = pending.filter { !answered.contains($0) }

            if let (kind, message) = fatal {
                switch kind {
                case .rateLimit:
                    limited = true
                    for id in unanswered { _ = retryLater(id, .rateLimited, message: message, next: &next, retryAt: &retryAt) }
                case .network where phase != .stopping:
                    var spent: [String] = []
                    for id in unanswered where !retryLater(id, .retryable, message: message, next: &next, retryAt: &retryAt) {
                        spent.append(id)
                    }
                    if !spent.isEmpty {
                        // Attempts spent and Google still unreachable: the run
                        // ends as it always has, and the next one tries again.
                        lastError = AppModel.describe(kind, message)
                        model.log(.network, AppModel.describe(kind, message), problem: true)
                        spent.forEach { fail($0, message, retryable: true) }
                        markStopped(next)
                        return .halt
                    }
                default:
                    if phase != .stopping {
                        lastError = AppModel.describe(kind, message)
                        model.log(kind == .auth ? .account : category, AppModel.describe(kind, message), problem: true)
                    }
                    markStopped(unanswered + next)
                    return .halt
                }
            } else if phase != .stopping, exit != 0 || !unanswered.isEmpty {
                let noAnswer = "No answer from the uploader"
                var gaveUp = false
                for id in unanswered where !retryLater(id, .retryable, message: noAnswer, next: &next, retryAt: &retryAt) {
                    fail(id, noAnswer, retryable: true)
                    exhausted.append(id)
                    gaveUp = true
                }
                if gaveUp || unanswered.isEmpty {
                    lastError = "The uploader stopped unexpectedly (exit \(exit)); see the log in Settings."
                }
            }

            if phase == .stopping {
                markStopped(unanswered + next)
                return .halt
            }
            if limited {
                if holdForRateLimit() {
                    endRun(failing: Self.rateLimitGiveUp, category: .network, leaving: next)
                    return .halt
                }
            } else if !confirmed.isEmpty {
                rateLimiter.batchSucceeded()
            }
            pending = next
        }
        return progressed ? .progressed : .nothing
    }

    private static let rateLimitGiveUp = "\(EventPhrase.rateLimited) through \(RateLimiter.maximumHoldsPerRun) waits in a row, "
        + "so this run stopped; the next run tries again."

    /// nil when the batch may go. Otherwise what the caller returns: Stop or
    /// Pause ended the wait (rows left as stopped, not failed), or the wait
    /// gave up and the run fails.
    private func clearance(retryAt: Date?, holding ids: [String], category: EventCategory) async -> Outcome? {
        switch await waitUntilClear(retryAt: retryAt) {
        case .clear:
            return nil
        case .halted:
            markStopped(ids)
            return phase == .stopping ? .halt : .nothing
        case let .gaveUp(reason):
            endRun(failing: reason, category: category, leaving: ids)
            return .halt
        }
    }

    /// Ends the run as failed with `reason`; `ids` were not sent and stay
    /// un-uploaded (not failed), so the next run picks them up.
    private func endRun(failing reason: String, category: EventCategory, leaving ids: [String]) {
        lastError = reason
        model.log(category, reason, problem: true)
        markStopped(ids)
    }

    /// Queues `id` for another round if its failure allows one; false when
    /// it has failed for this run.
    private func retryLater(_ id: String, _ kind: FailureClass, message: String, next: inout [String], retryAt: inout Date?) -> Bool {
        switch retries.failed(id, as: kind) {
        case let .retry(after):
            let at = Date().addingTimeInterval(after)
            retryAt = max(retryAt ?? at, at)
            next.append(id)
            update(id) {
                $0.status = .waiting("Trying again (attempt \(self.retries.attempts(for: id) + 1) of \(self.retries.policy.maxAttempts))")
                $0.detail = message
            }
            return true
        case .waitForRateLimit:
            next.append(id)
            update(id) { $0.status = .waiting("Waiting: Google asked to slow down") }
            return true
        case .giveUp:
            return false
        }
    }

    /// Starts (or joins) Google's hold; true when this run has waited
    /// through its allowance of holds and should end instead.
    private func holdForRateLimit() -> Bool {
        let previous = rateLimiter.holdUntil
        let until = rateLimiter.hitLimit(at: Date())
        if rateLimiter.runShouldGiveUp { return true }
        if until != previous {
            let seconds = Int(until.timeIntervalSinceNow.rounded())
            model.log(.network, "\(EventPhrase.rateLimited); uploads wait \(seconds) s and then carry on.")
        }
        return false
    }

    private func addToAlbum(_ assetIDs: [String], mediaKeys: [String], albumID: String, albumTitle: String,
                            auth: String, runtime: BridgeRuntime) async -> Outcome {
        while true {
            if let outcome = await clearance(retryAt: nil, holding: [], category: .photos) { return outcome }
            holdAwake()
            let target = model.state.albumTarget(for: albumID, title: albumTitle)
            var added = false
            var fatal: (FatalKind, String)?
            do {
                _ = try await bridge.run(.addToAlbum(auth, mediaKeys: mediaKeys, album: target), runtime: runtime,
                                         workDirectory: model.paths.logs, log: model.paths.bridgeLog) { event in
                    switch event {
                    case let .album(googleID, _):
                        self.model.state.recordAlbum(albumID, googleAlbumID: googleID, added: assetIDs)
                        added = true
                    case let .fatal(kind, message):
                        fatal = (kind, message)
                    default:
                        break
                    }
                }
            } catch {
                model.saveState()
                lastError = error.localizedDescription
                return .halt
            }
            model.saveState()
            guard let (kind, message) = fatal else { return added ? .progressed : .nothing }
            if phase == .stopping { return .halt }
            switch kind {
            case .rateLimit:
                // Google refused before doing anything; the same call goes
                // again once the hold is over.
                if holdForRateLimit() {
                    endRun(failing: Self.rateLimitGiveUp, category: .network, leaving: [])
                    return .halt
                }
                continue
            case .auth, .network, .storageFull:
                lastError = AppModel.describe(kind, message)
                model.log(kind == .auth ? .account : .network, AppModel.describe(kind, message), problem: true)
                return .halt
            default:
                failedAlbums.insert(albumID)
                lastError = "Could not add photos to the album \u{201C}\(albumTitle)\u{201D}: \(message)"
                model.log(.photos, lastError ?? message, problem: true)
                return added ? .progressed : .nothing
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
    /// after two minutes.
    private func waitUntilClear(retryAt: Date?) async -> WaitResult {
        defer { endWait() }
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
            } else if let until = rateLimiter.hold(at: now) {
                reason = .rateLimited(until: until)
            } else if let retryAt, retryAt > now {
                reason = .retrying(until: retryAt)
            } else {
                return .clear
            }
            enterWait(reason)
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

    private func enterWait(_ reason: WaitReason) {
        if phase == .running { phase = .waiting }
        guard waitReason != reason else { return }
        if waitReason == nil {
            waitingSince = Date()
            allowSleep()
        }
        let wasCondition = waitReason.map { $0.until == nil } ?? false
        waitReason = reason
        if reason.until == nil, !wasCondition { model.log(.network, "Uploads held: \(reason.title.lowercased())") }
    }

    private func endWait() {
        if phase == .waiting { phase = .running }
        waitReason = nil
        waitingSince = nil
        if phase == .running { holdAwake() }
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

    private func confirm(_ id: String, mediaKey: String, existing: Bool, item: BatchItem?) {
        model.state.recordUpload(assetID: id, mediaKey: mediaKey, existing: existing, stamp: item?.stamp)
        // A confirmation overrides an earlier failure of the same item.
        tally.confirmed(id, existing: existing, bytes: item?.size ?? 0)
        syncRunCounts()
        failures[id] = nil
        failedAssets.remove(id)
        update(id) {
            $0.status = existing ? .existing : .uploaded
            $0.detail = nil
            $0.retryable = nil
        }
    }

    private func show(_ id: String, filename: String, status: ActivityItem.Status) {
        activity.removeAll { $0.id == id }
        activity.insert(ActivityItem(id: id, filename: filename, size: nil, status: status), at: 0)
        if activity.count > Self.activityLimit { activity.removeLast(activity.count - Self.activityLimit) }
    }

    private func update(_ id: String, _ change: (inout ActivityItem) -> Void) {
        guard let index = activity.firstIndex(where: { $0.id == id }) else { return }
        change(&activity[index])
    }

    /// The item has failed for this run; Retry or the next run releases it.
    private func fail(_ id: String, _ message: String, retryable: Bool) {
        failedAssets.insert(id)
        tally.failed(id)
        syncRunCounts()
        if id.hasPrefix("messages:") {
            if let item = messages.first(where: { $0.id == id }) { failures[id] = .messages(item) }
        } else {
            failures[id] = picked.contains(id) ? .picked : .asset
        }
        let firstLine = message.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? message
        let label = firstLine.count > Self.labelLimit ? String(firstLine.prefix(Self.labelLimit - 3)) + "..." : firstLine
        if !activity.contains(where: { $0.id == id }) { show(id, filename: "Photo", status: .failed(label)) }
        update(id) {
            $0.status = .failed(label)
            $0.detail = message
            $0.retryable = retryable
        }
    }

    private func markStopped(_ ids: [String]) {
        for id in ids { update(id) { $0.status = .stopped } }
    }
}
