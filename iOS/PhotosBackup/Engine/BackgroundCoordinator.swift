import BackgroundTasks
import Foundation
import PhotosBackupCore
import UIKit

/// Keeps a backup going when the app is not in front, within what iOS
/// allows:
///
/// - A run the person started: on iOS 26 and later a continued-processing
///   task (BGContinuedProcessingTaskRequest), so it carries on with the
///   system's progress UI after they leave the app; earlier, a background
///   task (beginBackgroundTask) long enough to finish the commits in flight
///   and save.
/// - Automatic backups: a processing task (network required, external power
///   only with "Only while charging"), scheduled when the app goes to the
///   background, that runs a pass and saves when iOS takes the time back.
/// - The screen stays awake only during a run the person started while the
///   app is in front.
///
/// Task identifiers are read from Info.plist at run time: sideloading tools
/// re-sign the app under another bundle id and rewrite them (technique from
/// g8row/PhotosBackup, MIT: AutomaticBackupCoordinator and ContinuedBackup).
@MainActor
final class BackgroundCoordinator: BackupRunObserver {
    static let shared = BackgroundCoordinator()

    /// The automatic backup's identifier: the permitted one without a wildcard.
    let processingID: String?
    /// "<bundle id>.continued-backup." or whatever the installer rewrote it to.
    let continuedPrefix: String?

    private weak var model: AppModel?
    private var registered = false
    private var processingTask: BGProcessingTask?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var personStarted = false
    private var isActive = true
    private var continued: AnyObject?

    init(info: [String: Any]? = Bundle.main.infoDictionary) {
        let permitted = info?["BGTaskSchedulerPermittedIdentifiers"] as? [String] ?? []
        processingID = permitted.first { !$0.hasSuffix("*") }
        continuedPrefix = permitted.first { $0.hasSuffix(".continued-backup.*") }.map { String($0.dropLast()) }
    }

    /// Before the app finishes launching, as BGTaskScheduler requires.
    func register() {
        guard !registered, let processingID else { return }
        registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: processingID, using: nil) { task in
            guard let task = task as? BGProcessingTask else { return task.setTaskCompleted(success: false) }
            Task { @MainActor in BackgroundCoordinator.shared.handle(task) }
        }
        if !registered { Log.app.error("The background backup task could not be registered") }
    }

    func attach(_ model: AppModel) {
        self.model = model
    }

    // MARK: - Scene

    func sceneChanged(active: Bool) {
        isActive = active
        updateIdleTimer()
        guard let model else { return }
        if active {
            endBackgroundTask()
            return
        }
        model.engine.saveNow()
        scheduleProcessing()
        if model.status.isActive, continued == nil { beginBackgroundTask() }
    }

    /// The next automatic backup in the background; iOS picks the moment.
    func scheduleProcessing() {
        guard registered, let processingID, let model, model.settings.automatic, model.hasAuthData else { return }
        let request = BGProcessingTaskRequest(identifier: processingID)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = model.settings.pauseOnBattery
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            Log.app.notice("The background backup could not be scheduled: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func handle(_ task: BGProcessingTask) {
        task.expirationHandler = {
            Task { @MainActor in BackgroundCoordinator.shared.model?.engine.expire() }
        }
        guard let model, !model.status.isActive else {
            // A run is already going (the person's, or one still finishing).
            task.setTaskCompleted(success: true)
            return
        }
        processingTask = task
        scheduleProcessing()
        model.backgroundRun()
        if !model.status.isActive {
            processingTask = nil
            task.setTaskCompleted(success: true)
        }
    }

    // MARK: - Runs

    func runStarted(personStarted: Bool) {
        self.personStarted = personStarted
        updateIdleTimer()
        guard personStarted, let continuedPrefix else { return }
        if #available(iOS 26, *) {
            let session = ContinuedRun()
            do {
                try session.start(prefix: continuedPrefix) { [weak self] in self?.model?.engine.expire() }
                continued = session
            } catch {
                Log.app.notice("Continued processing was not granted: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func runProgressed(done: Int, total: Int, waiting: WaitReason?) {
        if #available(iOS 26, *), let session = continued as? ContinuedRun {
            session.update(done: done, total: total, waiting: waiting)
        }
    }

    func runEnded() {
        personStarted = false
        updateIdleTimer()
        if #available(iOS 26, *), let session = continued as? ContinuedRun { session.finish() }
        continued = nil
        if let processingTask {
            self.processingTask = nil
            processingTask.setTaskCompleted(success: true)
        }
        endBackgroundTask()
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = personStarted && isActive && (model?.status.isActive ?? false)
    }

    // MARK: - Before iOS 26

    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Finish the backup in progress") {
            Task { @MainActor in
                let coordinator = BackgroundCoordinator.shared
                coordinator.model?.engine.expire()
                coordinator.endBackgroundTask()
            }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}

/// One person-started run continued in the background with the system's
/// progress UI (iOS 26). Progress is reported in thousandths of an item
/// and nudged every few seconds, because iOS ends a continued task whose
/// progress stops moving (the reference's measurement).
@available(iOS 26, *)
@MainActor
private final class ContinuedRun {
    static let title = "Backing up to Google Photos"
    private static let unitsPerItem: Int64 = 1000

    private var identifier: String?
    private var task: BGContinuedProcessingTask?
    private var heartbeat: Task<Void, Never>?
    private var done: Int64 = 0
    private var total: Int64 = 0
    private var reported: Int64 = 0

    func start(prefix: String, onExpired: @escaping @MainActor () -> Void) throws {
        let identifier = prefix + UUID().uuidString
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { [weak self] task in
            guard let task = task as? BGContinuedProcessingTask else { return task.setTaskCompleted(success: false) }
            task.expirationHandler = { Task { @MainActor in onExpired() } }
            Task { @MainActor [weak self] in
                guard let self, self.identifier == identifier else { return task.setTaskCompleted(success: false) }
                self.adopt(task)
            }
        }
        guard registered else { throw BGTaskScheduler.Error(.notPermitted) }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: Self.title, subtitle: "Starting")
        request.strategy = .fail
        self.identifier = identifier
        try BGTaskScheduler.shared.submit(request)
    }

    func update(done: Int, total: Int, waiting: WaitReason?) {
        self.done = Int64(done)
        self.total = Int64(total)
        report(nudge: false)
        task?.updateTitle(Self.title, subtitle: waiting?.phoneTitle ?? "\(done.formatted()) of \(total.formatted()) done")
    }

    func finish() {
        heartbeat?.cancel()
        heartbeat = nil
        identifier = nil
        task?.expirationHandler = nil
        task?.setTaskCompleted(success: true)
        task = nil
    }

    private func adopt(_ task: BGContinuedProcessingTask) {
        self.task = task
        report(nudge: false)
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                self?.report(nudge: true)
            }
        }
    }

    /// Within the current item's thousand units, so a nudge never reads as
    /// an item finished.
    private func report(nudge: Bool) {
        guard let task else { return }
        let floor = done * Self.unitsPerItem
        let ceiling = max(floor, min((done + 1) * Self.unitsPerItem - 1, total * Self.unitsPerItem))
        reported = min(max(max(reported, floor) + (nudge ? 1 : 0), floor), ceiling)
        task.progress.totalUnitCount = max(1, total * Self.unitsPerItem)
        task.progress.completedUnitCount = reported
    }
}
