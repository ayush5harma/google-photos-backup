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
/// What the handler needs of a BGProcessingTask: a seam, so the debug E2E
/// hook can drive the same handler (the simulator cannot submit a real
/// request: BGTaskScheduler answers "not available on this platform",
/// measured on the iOS 27.0 simulator, 2026-11-26).
protocol BackgroundProcessingTask: AnyObject {
    var expirationHandler: (() -> Void)? { get set }
    func setTaskCompleted(success: Bool)
}

extension BGProcessingTask: BackgroundProcessingTask {}

@MainActor
final class BackgroundCoordinator: BackupRunObserver {
    static let shared = BackgroundCoordinator()

    /// The automatic backup's identifier: the permitted one without a wildcard.
    let processingID: String?
    /// "<bundle id>.continued-backup." or whatever the installer rewrote it to.
    let continuedPrefix: String?

    private weak var model: AppModel?
    private var registered = false
    private var processingTask: (any BackgroundProcessingTask)?
    /// How long a task launched before the network is reported waits for
    /// NWPathMonitor's first update before deciding (finding 6).
    private static let networkReportWait: Duration = .seconds(5)
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
        // The main queue, so the handler can act at once: a hop through a
        // Task let the root view's own launch run start first (finding 1).
        registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: processingID, using: .main) { task in
            onMainNow {
                guard let task = task as? BGProcessingTask else { return task.setTaskCompleted(success: false) }
                BackgroundCoordinator.shared.handle(task)
            }
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

    /// The time iOS gives belongs to a run: the one this starts, or one
    /// already going (a launch's, a person's), which the task then keeps
    /// open until it ends or iOS takes the time back. The next one is
    /// scheduled first, whatever happens after.
    func handle(_ task: any BackgroundProcessingTask) {
        scheduleProcessing()
        task.expirationHandler = {
            onMainNow {
                let coordinator = BackgroundCoordinator.shared
                coordinator.model?.engine.expire()
                coordinator.completeProcessingTask(success: false)
            }
        }
        guard let model else {
            // Cannot happen since AppModel.init attaches itself; kept so a
            // task is never left open.
            Log.app.error("A background backup task arrived before the model existed")
            return task.setTaskCompleted(success: false)
        }
        processingTask = task
        if !model.status.isActive { model.backgroundRun() }
        guard !model.status.isActive else { return }
        guard model.conditions.network == nil else { return completeProcessingTask(success: true) }
        // A cold launch reaches here before the path monitor has spoken, and
        // an automatic run waits for it: give it a moment, then decide.
        // conditionsChanged may start the run meanwhile; the task owns it too.
        Task { @MainActor in
            let deadline = ContinuousClock.now + Self.networkReportWait
            while model.conditions.network == nil, !model.status.isActive, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if !model.status.isActive { model.backgroundRun() }
            if !model.status.isActive { self.completeProcessingTask(success: true) }
        }
    }

    #if DEBUG
    func logForTesting(_ message: String) { model?.log(.app, message) }
    #endif

    /// A processing task is open and its run has not started (it waits for
    /// the first network report): other paths leave the run to it.
    var isAwaitingRun: Bool { processingTask != nil && !(model?.status.isActive ?? false) }

    private func completeProcessingTask(success: Bool) {
        guard let processingTask else { return }
        self.processingTask = nil
        processingTask.setTaskCompleted(success: success)
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
        completeProcessingTask(success: true)
        endBackgroundTask()
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = personStarted && isActive && (model?.status.isActive ?? false)
    }

    // MARK: - Before iOS 26

    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        // UIKit calls this expiration handler synchronously on the main
        // thread; the save and the end must happen before it returns, or
        // iOS suspends the app first (finding 8).
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Finish the backup in progress") {
            onMainNow {
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
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            onMainNow {
                guard let task = task as? BGContinuedProcessingTask else { return task.setTaskCompleted(success: false) }
                task.expirationHandler = { onMainNow { onExpired() } }
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

/// Runs `body` on the main actor before returning. The task handlers are
/// registered on the main queue and UIKit calls a background task's
/// expiration handler on the main thread, so this is normally the
/// assumeIsolated branch; an expiration handler BGTaskScheduler calls on
/// another queue (its documentation does not say which) waits on main
/// instead, so the save is still done when the handler returns (finding 8).
nonisolated func onMainNow(_ body: @MainActor () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated(body)
    } else {
        DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
    }
}
