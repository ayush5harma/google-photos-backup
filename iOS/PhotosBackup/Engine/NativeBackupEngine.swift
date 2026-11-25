import Foundation
import Observation
import PhotosBackupCore

/// What the background coordinator and the screen follow of a run.
@MainActor
protocol BackupRunObserver: AnyObject {
    func runStarted(personStarted: Bool)
    func runProgressed(done: Int, total: Int, waiting: WaitReason?)
    func runEnded()
}

/// One account's part of a run.
@MainActor
final class EngineLane {
    let account: String
    let title: String
    let upload: UploadLane
    let client: any GooglePhotosUploading
    let isPrimary: Bool
    var record: RunRecord
    var tally = RunTally()
    var halted = false
    var lastError: String?
    var failedAssets: Set<String> = []
    var failedAlbums: Set<String> = []
    var albumAddsThisRun: [String: Int] = [:]
    var heldAlbumsLogged: Set<String> = []
    /// What the send in progress committed, for its album step.
    var committedInSend: [String] = []

    init(account: String, title: String, upload: UploadLane, client: any GooglePhotosUploading, isPrimary: Bool, record: RunRecord) {
        self.account = account
        self.title = title
        self.upload = upload
        self.client = client
        self.isPrimary = isPrimary
        self.record = record
    }
}

/// A batch exported once, for every account that planned its assets.
struct StagedBatch {
    var items: [String: StagedItem] = [:]
    var stamps: [String: EditStamp] = [:]
    var failures: [String: String] = [:]
    var bytes: Int64 = 0
    let directory: URL

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

/// The iOS backup engine: the Mac BackupEngine's run (Sources/PhotosBackup/
/// BackupEngine.swift) with the native client in place of the bridge.
///
/// Each pass plans every account with BackupPlanner (the Mac's arguments),
/// merges the plans into a SharedPass so each photo is exported and hashed
/// once, and sends each batch to its accounts side by side, one UploadLane
/// each (Core: dedupe, uploads, batched commits, retries, Google's holds).
/// Album steps go through AlbumMirroring. Records are written through the
/// AppModel's AccountLibrary/AccountsStore at most about once a second, at
/// every batch's end, on pause and stop, and when the app leaves the front.
@MainActor
@Observable
final class NativeBackupEngine: BackupEngine {
    private(set) var status = BackupEngineStatus()

    @ObservationIgnored private unowned let model: AppModel
    @ObservationIgnored private let makeClient: (GooglePhotosCredential) -> any GooglePhotosUploading
    @ObservationIgnored weak var observer: BackupRunObserver?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var prefetch: Task<StagedBatch, Never>?
    @ObservationIgnored private(set) var lanes: [EngineLane] = []
    @ObservationIgnored private var destination: BackupDestination = .chosen
    @ObservationIgnored private var trigger: RunTrigger = .manual
    @ObservationIgnored private var overridesConditions = false
    @ObservationIgnored private var failures: [String: (account: String, assetID: String, message: String, retryable: Bool)] = [:]
    @ObservationIgnored private var retryRequested = false
    @ObservationIgnored private var dirty: Set<String> = []
    @ObservationIgnored private var lastSave = Date.distantPast
    @ObservationIgnored private var waits: [String: WaitReason] = [:]
    @ObservationIgnored private var announced = false
    @ObservationIgnored private var limitedNoted = false
    @ObservationIgnored private var expired = false
    @ObservationIgnored private var unstartedReason: String?
    @ObservationIgnored private var lastLoggedFailure: [String: String] = [:]
    /// The hold each account last announced, so each new one is logged once.
    @ObservationIgnored private var announcedHolds: [String: Date] = [:]

    /// A phone's pass: 20 photos a batch (one commit request each), at most
    /// 8 uploads at once per account (the Mac allows 32 on a wired uplink),
    /// one batch exported ahead while it holds under 300 MB and the phone
    /// keeps 1 GB free.
    static let batchSize = GooglePhotosClient.commitBatchSize
    static let parallelCap = 8
    static let bytesAhead: Int64 = 300_000_000
    static let freeSpaceFloor: Int64 = 1_000_000_000
    private static let exportWaiter = "export"

    init(model: AppModel, makeClient: @escaping (GooglePhotosCredential) -> any GooglePhotosUploading) {
        self.model = model
        self.makeClient = makeClient
    }

    private var shouldHalt: Bool { status.phase == .stopping || status.phase == .pausing || Task.isCancelled }

    // MARK: - Controls

    func backUpNow(to destination: BackupDestination, trigger: RunTrigger) {
        guard task == nil else {
            if status.phase == .pausing { status.phase = .running }
            // Asked for in person while an automatic run holds for battery or
            // Wi-Fi: the person's choice wins, as on the Mac.
            if trigger.overridesConditions { overridesConditions = true }
            return
        }
        start(destination, trigger: trigger)
    }

    func pause() {
        if status.phase == .running || status.phase.isWaiting { status.phase = .pausing }
    }

    func resume() {
        guard status.phase == .paused || status.phase == .pausing else { return }
        if task != nil {
            status.phase = .running
            return
        }
        status.phase = .idle
        start(destination, trigger: .manual)
    }

    /// Uploads in flight are abandoned (the next run's hash check finds any
    /// Google kept); every key already reported is recorded and saved.
    func stop() {
        retryRequested = false
        guard task != nil else {
            status.phase = .idle
            return
        }
        status.phase = .stopping
        prefetch?.cancel()
        task?.cancel()
    }

    func retryFailed() {
        guard status.phase != .stopping else { return }
        let retryable = failures.filter(\.value.retryable)
        guard !retryable.isEmpty else { return }
        for key in retryable.keys { failures[key] = nil }
        status.failedCount = failures.count
        if task == nil {
            start(destination, trigger: .retry)
        } else {
            retryRequested = true
        }
    }

    /// iOS took the background time back: stop where the run is and save.
    func expire() {
        guard task != nil else { return }
        expired = true
        stop()
        saveAll()
    }

    /// The app left the front: write what is in memory now.
    func saveNow() { saveAll() }

    private func start(_ destination: BackupDestination, trigger: RunTrigger) {
        self.destination = destination
        self.trigger = trigger
        overridesConditions = trigger.overridesConditions
        expired = false
        status.phase = .running
        status.lastError = nil
        observer?.runStarted(personStarted: trigger.overridesConditions)
        task = Task { [weak self] in
            guard let self else { return }
            await self.run()
            self.finishRun()
        }
    }

    // MARK: - The run

    private func run() async {
        announced = false
        announcedHolds = [:]
        limitedNoted = false
        unstartedReason = nil
        lanes = makeLanes()
        guard !lanes.isEmpty else {
            unstartedReason = "Sign in with Google in Settings to start backing up."
            status.lastError = unstartedReason
            return
        }
        for lane in lanes { await lane.upload.runStarted() }
        if model.photosStatus == .limited, !limitedNoted {
            limitedNoted = true
            model.log(.photos, "Photos access is limited to the photos you chose: only those are backed up.")
        }
        // Passes repeat because one pass can make work for the next: a photo
        // uploaded for All Photos may also belong to a mirrored album.
        while !shouldHalt, lanes.contains(where: { !$0.halted }) {
            await model.reloadAlbums()
            let working = lanes.filter { !$0.halted }
            let pass = SharedPass(plans: working.map { ($0.account, plan(for: $0)) }, batchSize: Self.batchSize)
            for lane in working { lane.tally.planned(pass.uploads[lane.account] ?? 0) }
            syncStatus()
            announce()
            guard !pass.isEmpty else { break }
            let progressed = await execute(pass)
            saveAll()
            if shouldHalt || !progressed { break }
        }
    }

    private func makeLanes() -> [EngineLane] {
        let accounts: [BackupAccount] = switch destination {
        case .chosen: model.targetAccounts
        case let .only(id): model.runnableAccounts.filter { $0.id == id }
        }
        let quality = model.settings.quality
        return accounts.compactMap { account in
            let record = RunRecord(kind: .photos, trigger: trigger, conditions: model.conditions.summary)
            guard let authData = model.credential(for: account.id),
                  let credential = try? GooglePhotosCredential(authData: authData) else {
                model.log(.account, "\(account.title) has no usable sign-in on this device; sign in again in Settings.", problem: true)
                return nil
            }
            let client = makeClient(credential)
            let upload = UploadLane(account: account.id, client: client, quality: quality,
                                    parallelism: UploadParallelism(cap: Self.parallelCap, automatic: true))
            return EngineLane(account: account.id, title: account.title, upload: upload, client: client,
                              isPrimary: account.id == model.primaryAccount?.id, record: record)
        }
    }

    /// One account's pass over the selected albums, as the Mac plans it.
    /// What this run already confirmed is never planned again in it.
    private func plan(for lane: EngineLane) -> [PlannedStep] {
        let settings = model.settings
        let albums = model.albums.map(\.snapshot)
        if settings.mirrorAlbums { rebaselineUnknownMirrors(in: albums + model.unlistedAlbums, lane: lane) }
        if settings.reuploadEdits { stampEarlierUploads(in: albums, lane: lane) }
        let steps = BackupPlanner.plan(albums: albums, state: record(lane), mirrorAlbums: settings.mirrorAlbums,
                                       batchSize: Self.batchSize, excludingAssets: lane.failedAssets.union(lane.tally.confirmedIDs),
                                       excludingAlbums: lane.failedAlbums, reuploadEdits: settings.reuploadEdits,
                                       uploadsHidden: lane.isPrimary, albumAddsThisRun: lane.albumAddsThisRun)
        if settings.mirrorAlbums { holdAlbumAdds(in: albums, lane: lane) }
        return steps
    }

    /// Every batch of the pass, each sent to its accounts side by side, then
    /// each account's own album adds and edits.
    private func execute(_ pass: SharedPass) async -> Bool {
        var progressed = false
        for (index, batch) in pass.batches.enumerated() {
            let live = batch.accounts.compactMap(lane(for:)).filter { !$0.halted }
            if live.isEmpty { continue }
            guard await waitUntilClear(retryAt: nil, waiter: Self.exportWaiter) else { break }
            let staged: StagedBatch
            if let prefetch {
                staged = await prefetch.value
                self.prefetch = nil
            } else {
                staged = await stage(batch.assetIDs, includingHidden: batch.includingHidden)
            }
            defer { staged.remove() }
            if shouldHalt { break }
            failExports(staged, owners: live)
            if index + 1 < pass.batches.count, staged.bytes < Self.bytesAhead, (Self.freeSpace() ?? .max) > Self.freeSpaceFloor {
                let next = pass.batches[index + 1]
                prefetch = Task { [weak self] in
                    await self?.stage(next.assetIDs, includingHidden: next.includingHidden) ?? StagedBatch(directory: StagingArea.root)
                }
            }
            let results = await sideBySide(live) { lane in await self.send(batch, staged: staged, lane: lane) }
            progressed = progressed || results.contains(true)
            saveAll()
        }
        if let prefetch {
            prefetch.cancel()
            (await prefetch.value).remove()
            self.prefetch = nil
        }
        guard !shouldHalt else { return progressed }
        let rest = lanes.filter { !$0.halted && !(pass.rest[$0.account] ?? []).isEmpty }
        let results = await sideBySide(rest) { lane in
            var moved = false
            for step in pass.rest[lane.account] ?? [] where !lane.halted && !self.shouldHalt {
                moved = await self.execute(step, lane: lane) || moved
            }
            return moved
        }
        return progressed || results.contains(true)
    }

    private func execute(_ step: PlannedStep, lane: EngineLane) async -> Bool {
        switch step {
        case let .upload(albumID, title, assetIDs):
            let staged = await stage(assetIDs, includingHidden: albumID == BackupPlanner.pickedAlbumID && lane.isPrimary)
            defer { staged.remove() }
            failExports(staged, owners: [lane])
            let share = SharedPass.Send(account: lane.account, albumID: albumID, albumTitle: title, assetIDs: assetIDs)
            return await send(share, staged: staged, lane: lane)
        case let .addToAlbum(albumID, title, assetIDs, _):
            guard !lane.failedAlbums.contains(albumID) else { return false }
            return await addToAlbum(assetIDs, albumID: albumID, title: title, lane: lane)
        case let .reupload(assetIDs):
            let changed = await checkEdits(assetIDs, lane: lane)
            guard !changed.isEmpty else { return false }
            lane.tally.planned(changed.count)
            syncStatus()
            let staged = await stage(changed, includingHidden: false)
            defer { staged.remove() }
            failExports(staged, owners: [lane])
            let share = SharedPass.Send(account: lane.account, albumID: "edits", albumTitle: nil, assetIDs: changed)
            return await send(share, staged: staged, lane: lane)
        }
    }

    private func sideBySide(_ lanes: [EngineLane], _ part: @escaping @MainActor (EngineLane) async -> Bool) async -> [Bool] {
        await withTaskGroup(of: Bool.self) { group in
            for lane in lanes { group.addTask { @MainActor in await part(lane) } }
            var results: [Bool] = []
            for await result in group { results.append(result) }
            return results
        }
    }

    // MARK: - Sending

    private func send(_ batch: SharedPass.Batch, staged: StagedBatch, lane: EngineLane) async -> Bool {
        var progressed = false
        for send in batch.sends(for: lane.account) where !lane.halted && !shouldHalt {
            progressed = await self.send(send, staged: staged, lane: lane) || progressed
        }
        return progressed
    }

    /// One account's share of a batch: its uploads, then its album step for
    /// what they committed (the bridge's upload request with an album).
    private func send(_ send: SharedPass.Send, staged: StagedBatch, lane: EngineLane) async -> Bool {
        let state = record(lane)
        let items = send.assetIDs.compactMap { staged.items[$0] }
            .filter { !lane.failedAssets.contains($0.assetID) }
            .map { $0.forced(state.forcedUploads?.contains($0.assetID) == true) }
        guard !items.isEmpty else { return false }
        lane.committedInSend = []
        let stamps = staged.stamps
        let end = await lane.upload.send(items, wait: { [weak self] until in
            await self?.waitUntilClear(retryAt: until, waiter: lane.account) ?? false
        }, report: { [weak self] id, outcome in
            await self?.recordOutcome(id, outcome, lane: lane, stamp: stamps[id], size: items.first { $0.assetID == id }?.size ?? 0)
        })
        let committed = lane.committedInSend
        save(lane)
        switch end {
        case let .halted(reason):
            halt(lane, Self.describe(reason))
            model.log(reason.kind == .auth ? .account : .network, Self.describe(reason), problem: true)
        case .stopped, .finished:
            break
        }
        var progressed = !committed.isEmpty
        if case .finished = end, let title = send.albumTitle, model.settings.mirrorAlbums, !lane.failedAlbums.contains(send.albumID),
           !committed.isEmpty {
            progressed = await albumStep(committed, albumID: send.albumID, title: title, lane: lane) || progressed
        }
        let exhausted = items.filter { failures[Self.row(lane.account, $0.assetID)]?.retryable == true }
        if !exhausted.isEmpty {
            model.log(.photos, "\(exhausted.count) item\(exhausted.count == 1 ? "" : "s") failed after "
                      + "\(RetryPolicy().maxAttempts) attempts; Activity shows what Google said.", problem: true)
        }
        return progressed
    }

    private func recordOutcome(_ id: String, _ outcome: ItemOutcome, lane: EngineLane, stamp: EditStamp?, size: Int64) {
        let row = Self.row(lane.account, id)
        switch outcome {
        case let .committed(mediaKey, existing):
            change(lane) { $0.recordUpload(assetID: id, mediaKey: mediaKey, existing: existing, stamp: stamp) }
            lane.tally.confirmed(id, existing: existing, bytes: size)
            lane.committedInSend.append(id)
            lane.failedAssets.remove(id)
            failures[row] = nil
            dirty.insert(lane.account)
            saveIfDue()
        case let .failed(message, retryable):
            lane.tally.failed(id)
            lane.failedAssets.insert(id)
            failures[row] = (lane.account, id, message, retryable)
        case .notSent:
            break
        }
        syncStatus()
    }

    // MARK: - Albums

    /// Adds the photos `assetIDs` stand for to the album, creating it when it
    /// has no Google album yet. True when anything went in or was found gone.
    private func albumStep(_ assetIDs: [String], albumID: String, title: String, lane: EngineLane) async -> Bool {
        let state = record(lane)
        let filed = state.mirrors[albumID]?.addedAssetIDs ?? []
        let pending = assetIDs.filter { state.uploaded[$0] != nil && !filed.contains($0) }
        guard !pending.isEmpty else { return false }
        let keys = pending.compactMap { state.uploaded[$0]?.mediaKey }
        let result = await AlbumMirroring.add(keys, to: state.mirrors[albumID]?.googleAlbumID, named: title, using: lane.client,
                                              sleep: { [weak self] seconds in await self?.sleepUnlessHalted(seconds) ?? false })
        let members = model.albums.first { $0.id == albumID }?.snapshot.visibleAssetIDs ?? []
        let applied = change(lane) { AlbumMirroring.apply(result, albumID: albumID, assetIDs: pending, members: members, to: &$0) }
            ?? AlbumMirroring.Applied()
        if applied.counted > 0 { lane.albumAddsThisRun[albumID, default: 0] += applied.counted }
        logForgotten(applied.forgotten, lane: lane)
        save(lane)
        if let error = result.error {
            switch error {
            case .rateLimited:
                // What went in is recorded; the rest goes again once the hold
                // is over, planned as an album add on the next pass.
                if await lane.upload.hitRateLimit() {
                    halt(lane, UploadLane.rateLimitGiveUp)
                    model.log(.network, UploadLane.rateLimitGiveUp, problem: true)
                }
            case .auth, .invalidCredential, .storageFull, .network:
                let reason = LaneHalt(kind: Self.haltKind(error), message: error.message)
                halt(lane, Self.describe(reason))
                model.log(reason.kind == .auth ? .account : .network, Self.describe(reason), problem: true)
            default:
                lane.failedAlbums.insert(albumID)
                status.lastError = "Backed up, but not added to a Google Photos album: \(error.message)"
                logAlbumRefused(title, error.message, lane: lane)
            }
        }
        return !result.added.isEmpty || !applied.forgotten.isEmpty
    }

    /// An album add the planner made on its own (photos Google already has):
    /// tried again after Google's hold, as the Mac's addToAlbum loop does.
    private func addToAlbum(_ assetIDs: [String], albumID: String, title: String, lane: EngineLane) async -> Bool {
        var progressed = false
        while !shouldHalt, !lane.halted, !lane.failedAlbums.contains(albumID) {
            guard await waitUntilClear(retryAt: await lane.upload.hold(at: Date()), waiter: lane.account) else { break }
            let moved = await albumStep(assetIDs, albumID: albumID, title: title, lane: lane)
            progressed = progressed || moved
            let state = record(lane)
            let filed = state.mirrors[albumID]?.addedAssetIDs ?? []
            let left = assetIDs.filter { state.uploaded[$0] != nil && !filed.contains($0) }
            if left.isEmpty || !moved, await lane.upload.hold(at: Date()) == nil { break }
        }
        return progressed
    }

    private func logForgotten(_ forgotten: [String], lane: EngineLane) {
        guard !forgotten.isEmpty else { return }
        let later = forgotten.filter { lane.tally.confirmedIDs.contains($0) }.count
        let now = forgotten.count - later
        var parts: [String] = []
        if now > 0 { parts.append("\(now) uploading again now") }
        if later > 0 { parts.append("\(later) on the next backup") }
        model.log(.photos, "Google Photos no longer had \(forgotten.count) backed-up \(forgotten.count == 1 ? "photo" : "photos")\(to(lane)): "
                  + parts.joined(separator: ", ") + ".")
    }

    private func logAlbumRefused(_ title: String, _ message: String, lane: EngineLane) {
        model.log(.photos, "Google Photos refused to add photos to an album (\(message)). Its Google album may have been "
                  + "deleted; nothing was sent again, and the next backup tries once more.", problem: true)
        model.log(.photos, "The album Google Photos refused is \"\(title)\"\(to(lane)).")
    }

    private func rebaselineUnknownMirrors(in albums: [AlbumSnapshot], lane: EngineLane) {
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

    private func holdAlbumAdds(in albums: [AlbumSnapshot], lane: EngineLane) {
        let held = BackupPlanner.heldAlbumAdds(albums: albums, state: record(lane), albumAddsThisRun: lane.albumAddsThisRun)
        let grown = held.filter { album in change(lane) { $0.holdAlbumAdds(album.albumID, assetIDs: album.assetIDs) } ?? false }
        if !grown.isEmpty { save(lane) }
        for album in grown where lane.heldAlbumsLogged.insert(album.albumID).inserted {
            let photos = Self.photos(album.assetIDs.count)
            model.log(.photos, "\(photos) waiting to be added to an album: more than \(BackupPlanner.linkedAlbumAddLimit) would have "
                      + "gone into a Google album that already exists, so none were sent.", problem: true)
            model.log(.photos, "Waiting for Add Them or Skip: \(photos) for \"\(album.title)\"\(to(lane)).")
        }
    }

    // MARK: - Edits

    private func stampEarlierUploads(in albums: [AlbumSnapshot], lane: EngineLane) {
        let unstamped = BackupPlanner.unstampedAssets(albums: albums, state: record(lane))
        guard !unstamped.isEmpty else { return }
        change(lane) { state in
            for (id, date) in unstamped { state.refreshStamp(assetID: id, EditStamp(modified: date, edited: nil)) }
        }
        save(lane)
    }

    /// The changed assets that need uploading; a change that left Google's
    /// copy right (a favourite, a keyword) only refreshes the stamp.
    private func checkEdits(_ assetIDs: [String], lane: EngineLane) async -> [String] {
        let states = await AssetExporter.editStates(of: assetIDs)
        var changed: [String] = []
        for id in assetIDs {
            guard let state = states[id], let modified = state.modified else {
                changed.append(id)
                continue
            }
            let was = record(lane).uploaded[id]?.editStamp
            switch BackupPlanner.editAction(was: was, isEdited: state.edited, editIdentity: state.identity) {
            case .refreshStamp:
                change(lane) { $0.refreshStamp(assetID: id, EditStamp(modified: modified, edited: state.edited, editIdentity: state.identity)) }
            case .upload:
                changed.append(id)
            }
        }
        save(lane)
        if !changed.isEmpty { model.log(.photos, "\(changed.count) edited photo\(changed.count == 1 ? "" : "s") to back up again") }
        return changed
    }

    // MARK: - Export

    /// Exports `assetIDs` once into a private folder and hashes each file.
    private func stage(_ assetIDs: [String], includingHidden: Bool) async -> StagedBatch {
        let directory = StagingArea.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        var batch = StagedBatch(directory: directory)
        var exported: [ExportedAsset] = []
        await AssetExporter().export(assetIDs, includingHidden: includingHidden, into: directory,
                                     shouldStop: { [weak self] in Task.isCancelled || self?.status.phase == .stopping },
                                     started: { [weak self] _, name in self?.status.currentFilename = name },
                                     finished: { id, result in
                                         switch result {
                                         case let .success(asset): exported.append(asset)
                                         case let .failure(error): batch.failures[id] = error.localizedDescription
                                         }
                                     })
        for asset in exported {
            let url = asset.url
            let hash = await Task.detached(priority: .utility) { try? ContentHash.sha1(of: url) }.value
            guard let hash else {
                batch.failures[asset.assetID] = "The exported file could not be read."
                continue
            }
            batch.items[asset.assetID] = StagedItem(assetID: asset.assetID, file: url, fileName: asset.filename, sha1: hash,
                                                    timestamp: asset.created ?? Date(), size: asset.size)
            if let stamp = asset.stamp { batch.stamps[asset.assetID] = stamp }
            batch.bytes += asset.size
        }
        return batch
    }

    /// A photo Photos would not hand over fails for each account that wanted it.
    private func failExports(_ staged: StagedBatch, owners: [EngineLane]) {
        for (id, message) in staged.failures {
            for lane in owners where !lane.failedAssets.contains(id) {
                lane.tally.failed(id)
                lane.failedAssets.insert(id)
                failures[Self.row(lane.account, id)] = (lane.account, id, message, true)
            }
        }
        if !staged.failures.isEmpty { syncStatus() }
    }

    private static func freeSpace() -> Int64? {
        let values = try? StagingArea.root.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    // MARK: - Waiting

    /// Holds before the next round while a condition, Google's hold or a
    /// retry's backoff says so; false when the run should not go on (stop,
    /// pause, or no network for two minutes in a run someone started).
    private func waitUntilClear(retryAt: Date?, waiter: String) async -> Bool {
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
                        let message = "No network connection, so this backup stopped; it starts again when you ask or automatically later."
                        status.lastError = message
                        model.log(.network, message, problem: true)
                        for lane in lanes { halt(lane, message) }
                        return false
                    }
                } else {
                    offlineSince = nil
                }
            } else if let retryAt, retryAt > now {
                let held = await lane(for: waiter)?.upload.hold(at: now)
                if let held, let lane = lane(for: waiter), announcedHolds[waiter] != held {
                    // The Mac engine's line when Google's hold starts or grows.
                    announcedHolds[waiter] = held
                    let seconds = Int(held.timeIntervalSince(now).rounded())
                    model.log(.network, "\(EventPhrase.rateLimited); uploads wait \(seconds) s and then carry on\(to(lane)).")
                }
                reason = held.map { .rateLimited(until: $0) } ?? .retrying(until: retryAt)
            } else {
                return true
            }
            enterWait(reason, for: waiter)
            let remaining = reason.until.map { $0.timeIntervalSince(now) } ?? 1
            guard await sleepUnlessHalted(min(1, max(0.05, remaining))) else { return false }
        }
        return false
    }

    /// Only having no network at all holds a run someone started; the "When
    /// to back up" switches hold automatic runs. A change mid-run holds the
    /// next round and clears by itself.
    private func holdingCondition() -> WaitReason? {
        guard let reason = model.conditions.blocking(for: model.settings) else { return nil }
        return overridesConditions && reason != .offline ? nil : reason
    }

    private func sleepUnlessHalted(_ seconds: TimeInterval) async -> Bool {
        do {
            try await Task.sleep(for: .seconds(seconds))
        } catch {
            return false
        }
        return !shouldHalt
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

    /// The run waits once everything sending waits; one account backing off
    /// while another uploads is still a running backup.
    private func showWaits() {
        let busy = max(1, lanes.filter { !$0.halted }.count)
        let shown: WaitReason? = waits.count >= busy || waits[Self.exportWaiter] != nil ? Self.leading(waits.values) : nil
        if let shown {
            if status.phase == .running || status.phase.isWaiting {
                if status.waitReason != shown, shown.until == nil, status.waitReason?.until != nil || status.waitReason == nil {
                    model.log(.network, "Uploads held: \(shown.title.lowercased())")
                }
                status.phase = .waiting(shown)
            }
        } else if status.phase.isWaiting {
            status.phase = .running
        }
        syncStatus()
    }

    private static func leading(_ reasons: some Collection<WaitReason>) -> WaitReason? {
        if let condition = reasons.first(where: { $0.until == nil }) { return condition }
        if let hold = reasons.first(where: { if case .rateLimited = $0 { true } else { false } }) { return hold }
        return reasons.min { ($0.until ?? .distantPast) < ($1.until ?? .distantPast) }
    }

    // MARK: - Records

    private func lane(for account: String) -> EngineLane? { lanes.first { $0.account == account } }

    private func record(_ lane: EngineLane) -> BackupState {
        model.record(of: lane.account) ?? BackupState()
    }

    @discardableResult
    private func change<T>(_ lane: EngineLane, _ body: (inout BackupState) -> T) -> T? {
        let result = model.modifyRecord(of: lane.account, body)
        dirty.insert(lane.account)
        return result
    }

    private func save(_ lane: EngineLane) {
        model.saveRecord(of: lane.account)
        dirty.remove(lane.account)
        lastSave = Date()
    }

    /// At most about once a second while keys arrive.
    private func saveIfDue() {
        if Date().timeIntervalSince(lastSave) >= 1 { saveAll() }
    }

    private func saveAll() {
        for account in dirty { model.saveRecord(of: account) }
        dirty = []
        lastSave = Date()
    }

    // MARK: - Status and the end of a run

    private func syncStatus() {
        status.runTotal = lanes.reduce(0) { $0 + $1.tally.total }
        status.runDone = lanes.reduce(0) { $0 + $1.tally.done }
        status.accounts = lanes.map { .init(account: $0.account, done: $0.tally.done, total: $0.tally.total) }
        status.failedCount = failures.count
        observer?.runProgressed(done: status.runDone, total: status.runTotal, waiting: status.waitReason)
    }

    private func announce() {
        guard !announced, status.runTotal > 0 else { return }
        announced = true
        let accounts = lanes.count > 1 ? " to \(lanes.count) accounts at the same time" : ""
        model.log(.run, "Started backing up \(status.runTotal) item\(status.runTotal == 1 ? "" : "s")\(accounts) (\(trigger.title))")
    }

    private func halt(_ lane: EngineLane, _ reason: String) {
        lane.halted = true
        lane.lastError = reason
        status.lastError = reason
    }

    private func finishRun() {
        saveAll()
        waits = [:]
        status.currentFilename = nil
        let stopping = status.phase == .stopping
        let paused = status.phase == .pausing || status.phase == .paused
        if lanes.isEmpty, let reason = unstartedReason {
            let record = RunRecord(kind: .photos, trigger: trigger, finishedAt: Date(), outcome: .failed(Redactor().redact(reason)),
                                   conditions: model.conditions.summary)
            finished(record, account: nil)
        }
        for lane in lanes {
            var record = lane.record
            record.uploaded = lane.tally.uploaded
            record.existing = lane.tally.existing
            record.failed = lane.tally.failed
            record.bytes = lane.tally.bytes
            record.finishedAt = Date()
            if stopping {
                record.outcome = .stopped
            } else if paused {
                record.outcome = .paused
            } else if lane.halted {
                record.outcome = .failed(Redactor().redact(lane.lastError ?? "The run ended early."))
            } else {
                record.outcome = .completed
            }
            finished(record, account: lane.account)
        }
        if expired { model.log(.run, "iOS ended the time it gave the app in the background; the next backup carries on.") }
        task = nil
        status.lastRun = Date()
        status.phase = paused && !stopping ? .paused : .idle
        let again = retryRequested && status.phase == .idle
        retryRequested = false
        observer?.runEnded()
        if again { start(destination, trigger: .retry) }
    }

    private func finished(_ record: RunRecord, account: String?) {
        let key = account ?? ""
        if !record.isIdle {
            let counts = "\(record.uploaded) uploaded, \(record.existing) already in Google Photos, \(record.failed) failed"
            switch record.outcome {
            case let .failed(reason):
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

    // MARK: - Words

    private func to(_ lane: EngineLane) -> String {
        lanes.count > 1 ? " (to \(lane.title))" : ""
    }

    private static func photos(_ count: Int) -> String {
        "\(count.formatted()) photo\(count == 1 ? "" : "s")"
    }

    static func row(_ account: String, _ assetID: String) -> String { "\(account)\u{1F}\(assetID)" }

    private static func haltKind(_ error: GooglePhotosError) -> LaneHalt.Kind {
        switch error {
        case .auth, .invalidCredential: .auth
        case .storageFull: .storageFull
        case .rateLimited: .rateLimit
        default: .network
        }
    }

    /// The Mac's AppModel.describe, for the native client's halts.
    static func describe(_ halt: LaneHalt) -> String {
        switch halt.kind {
        case .auth: "Google refused the account (\(halt.message)). Sign in again in Settings."
        case .network: "Google could not be reached (\(halt.message)). The next run retries."
        case .storageFull: "\(EventPhrase.storageFull) (\(halt.message)). Free up space or change the upload quality."
        case .rateLimit: halt.message
        }
    }
}

extension BackupEngineStatus.Phase {
    var isWaiting: Bool {
        if case .waiting = self { true } else { false }
    }
}
