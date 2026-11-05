import Foundation
import PhotosBackupCore

/// Takes one backup through the accounts one after another. The engine
/// backs up to one account at a time, with that account's credential and
/// record, exactly as it always ran for the single account: one bridge
/// process at a time, the same upload settings and the same Original
/// quality path, so memory and the upload thread budget stay what they were.
/// A failure on one account (an expired sign-in, a full account) moves on
/// to the next; Stop ends the whole pass, Pause holds it.
@MainActor
@Observable
final class AccountRunner {
    /// The account the pass is backing up to now.
    private(set) var current: String?
    private(set) var isRunning = false

    @ObservationIgnored private unowned let model: AppModel
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var stopped = false
    /// How each account's last run in this pass ended.
    @ObservationIgnored private var outcomes: [String: RunOutcome] = [:]
    /// What one account's turn hands the engine, once that account is
    /// active; nil is the app's own (Messages media to the primary account,
    /// then the selected albums). The integration test, which has no Photos
    /// library, hands it files instead.
    @ObservationIgnored var turn: ((_ account: String, _ trigger: RunTrigger) -> Void)?

    /// The engine reports a phase change at most this late to the pass.
    private static let pollInterval: Duration = .milliseconds(250)

    init(model: AppModel) {
        self.model = model
    }

    /// - Parameter messages: Messages media goes along to the primary account.
    func start(trigger: RunTrigger, messages: Bool) {
        // A run asked for in person goes ahead on a metered network or on
        // battery, as it would have had it started the pass.
        if trigger.overridesConditions, model.engine.isActive { model.engine.start(trigger: trigger) }
        guard task == nil else { return }
        let order = model.runnableAccounts.map(\.id)
        guard !order.isEmpty else { return }
        stopped = false
        outcomes = [:]
        isRunning = true
        task = Task { [weak self] in
            await self?.run(order, trigger: trigger, messages: messages)
            self?.task = nil
            self?.isRunning = false
        }
    }

    /// No further account starts; the engine's own Stop ends the current one.
    func stop() {
        stopped = true
    }

    func finished(_ outcome: RunOutcome?, for id: String) {
        outcomes[id] = outcome
    }

    private func run(_ order: [String], trigger: RunTrigger, messages: Bool) async {
        for id in order {
            await settled()
            if stopped { break }
            // A primary run that halted leaves its picks, Messages media or
            // device import queued, and any run sends the queue first: the
            // other accounts wait until the primary has taken it.
            if id != model.primaryAccount?.id, model.engine.hasQueuedPrimaryOnlyWork {
                let primary = model.primaryAccount?.title ?? "the primary account"
                model.log(.run, "Backups to the other accounts wait: items for \(primary) are still queued after its backup stopped early.",
                          problem: true)
                break
            }
            // Removed, signed out or not yet storage-checked meanwhile.
            guard model.runnableAccounts.contains(where: { $0.id == id }), model.activate(id) else { continue }
            current = id
            outcomes[id] = nil
            if let turn {
                turn(id, trigger)
            } else if messages, id == model.primaryAccount?.id, model.settings.messagesMedia {
                await model.scanMessages(includingPhotos: true, trigger: trigger)
            } else if model.library.isAuthorized {
                model.engine.start(trigger: trigger)
            }
            await settled()
            if case .stopped = outcomes[id] { break }
        }
        current = nil
        await settled()
        model.activate(model.primaryAccount?.id)
    }

    /// Until the engine is idle: not running, stopping, waiting or paused.
    private func settled() async {
        while model.engine.isActive || model.engine.phase == .paused {
            try? await Task.sleep(for: Self.pollInterval)
        }
    }
}
