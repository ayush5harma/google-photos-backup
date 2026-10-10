import Foundation
import Observation
import PhotosBackupCore

struct ActivityItem: Identifiable, Equatable {
    enum Status: Equatable {
        case exporting, hashing, checking
        case uploading(Double)
        case finalizing, uploaded, existing, stopped
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
            case let .failed(message): message
            }
        }
    }

    let id: String
    var filename: String
    var size: Int64?
    var status: Status
}

/// Runs backups: plans from the selected albums, exports each batch from
/// Photos, uploads it through the bridge and records what Google confirmed.
@MainActor
@Observable
final class BackupEngine {
    enum Phase: Equatable {
        case idle, running, pausing, paused, stopping
    }

    private(set) var phase: Phase = .idle
    private(set) var activity: [ActivityItem] = []
    /// Assets this run set out to upload, and how many have an outcome.
    private(set) var runTotal = 0
    private(set) var runDone = 0
    private(set) var lastError: String?
    private(set) var lastRun: Date?

    @ObservationIgnored private unowned let model: AppModel
    @ObservationIgnored private let bridge = BridgeProcess()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var picked: [String] = []
    @ObservationIgnored private var failedAssets = Set<String>()
    @ObservationIgnored private var failedAlbums = Set<String>()

    private static let activityLimit = 2000

    init(model: AppModel) {
        self.model = model
    }

    var remaining: Int { max(0, runTotal - runDone) }
    var runFraction: Double { runTotal == 0 ? 0 : Double(runDone) / Double(runTotal) }
    var isActive: Bool { phase == .running || phase == .pausing || phase == .stopping }

    // MARK: - Controls

    func start() {
        guard task == nil else {
            if phase == .pausing { phase = .running }
            return
        }
        phase = .running
        task = Task { [weak self] in
            await self?.run()
            guard let self else { return }
            self.task = nil
            self.lastRun = Date()
            if self.phase != .paused { self.phase = .idle }
            // Photos picked while the last pass was finishing were never
            // planned; failed picks were dropped by run(), so this ends.
            if self.phase == .idle, !self.picked.isEmpty, self.lastError == nil { self.start() }
        }
    }

    /// A hand-picked selection, uploaded ahead of the albums.
    func backUp(picked ids: [String]) {
        picked.append(contentsOf: ids.filter { !picked.contains($0) })
        start()
    }

    func pauseAfterCurrent() {
        if phase == .running { phase = .pausing }
    }

    func resume() {
        if phase == .paused { phase = .idle }
        start()
    }

    /// The run keeps reading the bridge until it exits, so every item Google
    /// confirmed before the stop is still recorded; cancelling the task would
    /// end that read early.
    func stop() {
        picked = []
        guard task != nil else {
            phase = .idle
            return
        }
        phase = .stopping
        bridge.terminate()
    }

    func clearFinished() {
        activity.removeAll { $0.status.isFinished }
    }

    // MARK: - The run

    private var shouldHalt: Bool {
        phase == .stopping || phase == .pausing
    }

    private func run() async {
        lastError = nil
        failedAssets = []
        failedAlbums = []
        runTotal = 0
        runDone = 0
        guard let runtime = BridgeRuntime.locate() else {
            lastError = "The uploader runtime is missing; build the app with scripts/build-app.sh."
            return
        }
        guard let auth = model.authData else {
            lastError = "Add your gpmc auth_data in Settings to start backing up."
            return
        }
        defer { picked.removeAll { model.state.uploaded[$0] != nil || failedAssets.contains($0) } }

        // Passes repeat because one pass can make work for the next: an asset
        // uploaded for All Photos may also belong to a mirrored album.
        while !shouldHalt {
            await model.reloadAlbums()
            let settings = model.settings
            picked.removeAll { model.state.uploaded[$0] != nil || failedAssets.contains($0) }
            let steps = BackupPlanner.plan(picked: picked, state: model.state, batchSize: settings.batchSize)
                + BackupPlanner.plan(albums: model.albums.map(\.snapshot), state: model.state, mirrorAlbums: settings.mirrorAlbums,
                                     batchSize: settings.batchSize, excludingAssets: failedAssets.union(picked), excludingAlbums: failedAlbums)
            guard !steps.isEmpty else { break }
            runTotal += steps.reduce(0) { total, step in
                if case let .upload(_, _, ids) = step { total + ids.count } else { total }
            }

            var progressed = false
            for step in steps {
                if shouldHalt { break }
                switch await execute(step, auth: auth, runtime: runtime, settings: settings) {
                case .progressed: progressed = true
                case .nothing: break
                case .halt: return
                }
            }
            if !progressed { break }
        }
        if phase == .pausing { phase = .paused }
    }

    private enum Outcome { case progressed, nothing, halt }

    private func execute(_ step: PlannedStep, auth: String, runtime: BridgeRuntime, settings: BackupSettings) async -> Outcome {
        // An album call that failed may still have created the album on
        // Google's side (a lost response), so the rest of this run leaves the
        // album alone rather than create it again; the next run retries.
        switch step {
        case let .upload(albumID, albumTitle, assetIDs):
            let title = failedAlbums.contains(albumID) ? nil : albumTitle
            return await upload(assetIDs, albumID: albumID, albumTitle: title, auth: auth, runtime: runtime, settings: settings)
        case let .addToAlbum(albumID, albumTitle, assetIDs, mediaKeys):
            if failedAlbums.contains(albumID) { return .nothing }
            return await addToAlbum(assetIDs, mediaKeys: mediaKeys, albumID: albumID, albumTitle: albumTitle, auth: auth, runtime: runtime)
        }
    }

    private func upload(_ assetIDs: [String], albumID: String, albumTitle: String?, auth: String,
                        runtime: BridgeRuntime, settings: BackupSettings) async -> Outcome {
        let batch = model.paths.staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: batch) }

        var items: [BridgeItem] = []
        await AssetExporter().export(assetIDs, into: batch, shouldStop: { self.phase == .stopping }, started: { id, filename in
            self.show(id, filename: filename, status: .exporting)
        }, finished: { id, result in
            switch result {
            case let .success(file):
                items.append(BridgeItem(id: id, path: file.url.path, filename: file.filename))
                self.update(id) { $0.size = file.size; $0.status = .hashing }
            case let .failure(error):
                self.fail(id, error.localizedDescription)
            }
        })
        if phase == .stopping {
            markStopped(items.map(\.id))
            return .halt
        }
        guard !items.isEmpty else { return .nothing }

        // Resolved now, not at planning: an earlier batch of this run may
        // have just created the album.
        let target = albumTitle.map { model.state.albumTarget(for: albumID, title: $0) }
        var confirmed: [String] = []
        var answered = Set<String>()
        var fatal: (FatalKind, String)?
        let request = BridgeRequest.upload(auth, items: items, quality: settings.quality, threads: settings.threads, album: target)
        let exit: Int32
        do {
            exit = try await bridge.run(request, runtime: runtime, workDirectory: model.paths.logs, log: model.paths.bridgeLog) { event in
                switch event {
                case let .progress(id?, phase, completed, total):
                    self.update(id) { $0.status = Self.status(for: phase, completed: completed, total: total, current: $0.status) }
                case let .item(id, mediaKey, existing):
                    self.model.state.recordUpload(assetID: id, mediaKey: mediaKey, existing: existing)
                    confirmed.append(id)
                    answered.insert(id)
                    self.runDone += 1
                    self.update(id) { $0.status = existing ? .existing : .uploaded }
                case let .itemFailed(id, message):
                    answered.insert(id)
                    self.fail(id, message)
                case let .album(googleID, _):
                    self.model.state.recordAlbum(albumID, googleAlbumID: googleID, added: confirmed)
                case let .albumFailed(message):
                    self.failedAlbums.insert(albumID)
                    self.lastError = "Backed up, but not added to the album \u{201C}\(albumTitle ?? "")\u{201D}: \(message)"
                case let .fatal(kind, message):
                    fatal = (kind, message)
                default:
                    break
                }
            }
        } catch {
            lastError = error.localizedDescription
            markStopped(items.map(\.id))
            return .halt
        }
        model.saveState()

        let unanswered = items.map(\.id).filter { !answered.contains($0) }
        if let (kind, message) = fatal {
            lastError = AppModel.describe(kind, message)
            markStopped(unanswered)
            return .halt
        }
        if phase == .stopping {
            markStopped(unanswered)
            return .halt
        }
        if exit != 0 || !unanswered.isEmpty {
            lastError = "The uploader stopped unexpectedly (exit \(exit)); see the log in Settings."
            unanswered.forEach { fail($0, "No answer from the uploader") }
        }
        return confirmed.isEmpty ? .nothing : .progressed
    }

    private func addToAlbum(_ assetIDs: [String], mediaKeys: [String], albumID: String, albumTitle: String,
                            auth: String, runtime: BridgeRuntime) async -> Outcome {
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
            lastError = error.localizedDescription
            return .halt
        }
        model.saveState()
        if let (kind, message) = fatal {
            if kind == .auth || kind == .network {
                lastError = AppModel.describe(kind, message)
                return .halt
            }
            failedAlbums.insert(albumID)
            lastError = "Could not add photos to the album \u{201C}\(albumTitle)\u{201D}: \(message)"
        }
        return added ? .progressed : .nothing
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

    private func show(_ id: String, filename: String, status: ActivityItem.Status) {
        activity.removeAll { $0.id == id }
        activity.insert(ActivityItem(id: id, filename: filename, size: nil, status: status), at: 0)
        if activity.count > Self.activityLimit { activity.removeLast(activity.count - Self.activityLimit) }
    }

    private func update(_ id: String, _ change: (inout ActivityItem) -> Void) {
        guard let index = activity.firstIndex(where: { $0.id == id }) else { return }
        change(&activity[index])
    }

    private func fail(_ id: String, _ message: String) {
        failedAssets.insert(id)
        runDone += 1
        if activity.contains(where: { $0.id == id }) {
            update(id) { $0.status = .failed(message) }
        } else {
            show(id, filename: "Photo", status: .failed(message))
        }
    }

    private func markStopped(_ ids: [String]) {
        for id in ids { update(id) { $0.status = .stopped } }
    }
}
