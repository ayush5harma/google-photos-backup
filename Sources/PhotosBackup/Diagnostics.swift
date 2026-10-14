import Foundation
import Observation
import Photos
import PhotosBackupCore

/// Owns the run history (last 40) and the event timeline (400 events, 14
/// days), both persisted under Application Support, plus storage use, clean
/// up, and the shareable diagnostic report.
@MainActor
@Observable
final class Diagnostics {
    private(set) var runs: [RunRecord] = []
    private(set) var events: [EventRecord] = []
    /// Set by the engine for the length of a run, so clean-up never deletes
    /// a batch it is exporting into or uploading from.
    var runActive = false
    /// The last time the history or timeline could not be written.
    private(set) var saveError: String?

    @ObservationIgnored private let paths: AppPaths
    @ObservationIgnored private let redactor = Redactor()
    @ObservationIgnored private let historyStore: RecordStore<RunHistory>
    @ObservationIgnored private let eventStore: RecordStore<EventLog>
    @ObservationIgnored private var history = RunHistory()
    @ObservationIgnored private var timeline = EventLog()

    /// gpmc appends to this in its working directory (Logs) and never trims it.
    nonisolated private static let gpmcFailureLog = "failed_skipped_files.log"
    nonisolated private static let gpmcFailureLogLimit: Int64 = 1_000_000

    init(paths: AppPaths) {
        self.paths = paths
        historyStore = RecordStore(url: paths.history)
        eventStore = RecordStore(url: paths.events)
        var unreadable: [String] = []
        switch eventStore.load() {
        case let .loaded(log): timeline = EventLog(events: log.events)
        case let .unreadable(setAside, _): unreadable.append(setAside.lastPathComponent)
        case .missing: break
        }
        switch historyStore.load() {
        case let .loaded(loaded): history = loaded
        case let .unreadable(setAside, _): unreadable.append(setAside.lastPathComponent)
        case .missing: break
        }
        runs = history.runs
        events = timeline.events
        for name in unreadable {
            log(.app, "A diagnostics file could not be read and was set aside as \(name); it starts empty.", problem: true)
        }
    }

    func record(_ run: RunRecord) {
        history.add(run)
        runs = history.runs
        save(history, to: historyStore)
    }

    func log(_ category: EventCategory, _ message: String, problem: Bool) {
        timeline.append(EventRecord(category: category, message: message, isProblem: problem), redactor: redactor)
        events = timeline.events
        save(timeline, to: eventStore)
    }

    func clearTimeline() {
        timeline.removeAll()
        events = []
        save(timeline, to: eventStore)
    }

    private func save<Value: Codable & Sendable>(_ value: Value, to store: RecordStore<Value>) {
        do {
            try store.save(value)
            saveError = nil
        } catch {
            // Nowhere better to report it: the timeline is what failed.
            saveError = "Could not save \(store.url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    // MARK: - Storage

    func usage() async -> StorageUsage {
        let paths = paths
        return await Task.detached(priority: .utility) { Self.measure(paths) }.value
    }

    /// Removes staging leftovers (only while no run is active), rotated
    /// logs and an oversized gpmc failure log; returns the bytes freed.
    func cleanUp() async -> Int64 {
        var freed: Int64 = 0
        // On the main actor, like the engine, so no run can start between
        // the check and the removal.
        if !runActive {
            freed += Self.size(of: paths.staging)
            try? FileManager.default.removeItem(at: paths.staging)
        }
        let logs = paths.logs
        freed += await Task.detached(priority: .utility) { () -> Int64 in
            let files = FileManager.default
            var freed: Int64 = 0
            let names = (try? files.contentsOfDirectory(atPath: logs.path)) ?? []
            for name in names {
                let url = logs.appendingPathComponent(name)
                let size = Self.size(of: url)
                let rotated = name.hasSuffix(".1")
                let bloated = name == Self.gpmcFailureLog && size > Self.gpmcFailureLogLimit
                guard rotated || bloated, (try? files.removeItem(at: url)) != nil else { continue }
                freed += size
            }
            return freed
        }.value
        return freed
    }

    nonisolated private static func measure(_ paths: AppPaths) -> StorageUsage {
        StorageUsage(staging: size(of: paths.staging), logs: size(of: paths.logs), state: size(of: paths.state),
                     history: size(of: paths.history) + size(of: paths.events))
    }

    /// A file's size, or everything under a folder.
    nonisolated private static func size(of url: URL) -> Int64 {
        let files = FileManager.default
        var isDirectory: ObjCBool = false
        guard files.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        guard isDirectory.boolValue else {
            return (try? files.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        }
        var total: Int64 = 0
        let enumerator = files.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        while let item = enumerator?.nextObject() as? URL {
            guard let values = try? item.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    // MARK: - Report

    /// A redacted plain-text report with a "What stands out" summary first.
    func report(model: AppModel) -> String {
        DiagnosticReport.build(snapshot(model: model), redactor: redactor)
    }

    private func snapshot(model: AppModel) -> DiagnosticSnapshot {
        let settings = model.settings
        let engine = model.engine
        let summary = model.summary
        var snapshot = DiagnosticSnapshot()
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "development build"
        snapshot.appVersion = (info?["CFBundleVersion"] as? String).map { "\(version) (\($0))" } ?? version
        snapshot.macOSVersion = ProcessInfo.processInfo.operatingSystemVersionString
        snapshot.uploader = model.runtimeDescription
        snapshot.settings = [
            .init("Quality", settings.quality.title),
            .init("Parallel uploads", "\(settings.threads)"),
            .init("Items per batch", "\(settings.batchSize)"),
            .init("Recreate albums", onOff(settings.mirrorAlbums)),
            .init("Back up automatically", onOff(settings.automatic)),
            .init("Upload edited photos again", onOff(settings.reuploadEdits)),
            .init("Pause on a metered network", onOff(settings.pauseOnExpensiveNetwork)),
            .init("Pause in Low Data Mode", onOff(settings.pauseInLowDataMode)),
            .init("Pause on battery", onOff(settings.pauseOnBattery)),
            .init("Pause in Low Power Mode", onOff(settings.pauseInLowPowerMode)),
            .init("Messages media", onOff(settings.messagesMedia)),
            .init("Messages archive", onOff(settings.messagesArchive)),
            .init("Selected albums", "\(model.state.selectedAlbumIDs.count)"),
        ]
        switch model.account {
        case .missing: snapshot.accountStatus = "Not signed in"
        case .checking: snapshot.accountStatus = "Checking"
        case let .connected(email):
            snapshot.accountStatus = "Connected"
            snapshot.account = email
        case let .failed(message): snapshot.accountStatus = "Problem: \(message)"
        }
        snapshot.account = snapshot.account ?? model.state.accountEmail
        snapshot.photosAccess = switch model.photosStatus {
        case .authorized: .full
        case .limited: .limited
        case .denied: .denied
        case .restricted: .restricted
        default: .notDetermined
        }
        snapshot.messagesFeatureOn = settings.messagesMedia || settings.messagesArchive
        if snapshot.messagesFeatureOn { snapshot.fullDiskAccess = Self.hasFullDiskAccess() }
        snapshot.automaticBackups = settings.automatic
        snapshot.backedUp = summary.backedUp
        snapshot.pending = summary.pending
        snapshot.failed = engine.failedCount
        snapshot.runActive = engine.isActive
        snapshot.runs = runs
        snapshot.events = events
        snapshot.storage = Self.measure(paths)
        snapshot.conditions = model.conditions.summary
        snapshot.holding = engine.waitReason
        snapshot.holdingSince = engine.waitingSince
        snapshot.failureMessages = engine.failureMessages
        snapshot.lastError = engine.lastError ?? model.stateError ?? saveError
        return snapshot
    }

    private func onOff(_ value: Bool) -> String { value ? "On" : "Off" }

    /// Opening chat.db (never reading it) tells whether macOS granted Full
    /// Disk Access: without it the open fails with EPERM. nil when there is
    /// no chat.db to tell by.
    private static func hasFullDiskAccess() -> Bool? {
        let path = NSHomeDirectory() + "/Library/Messages/chat.db"
        let descriptor = open(path, O_RDONLY)
        if descriptor >= 0 {
            close(descriptor)
            return true
        }
        return errno == ENOENT ? nil : false
    }
}
