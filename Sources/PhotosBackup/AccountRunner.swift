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
    /// Where a pass goes.
    enum Destination: Equatable {
        /// The accounts "Back up to" includes: Back Up Now, automatic runs,
        /// photosbackup://backup.
        case chosen
        /// Every account ready for backups, whatever the choice. A one-off:
        /// the choice is not changed.
        case every
        /// This account only (an id), whatever the choice. A one-off too.
        case only(String)
    }

    /// One account's part of a pass.
    struct Turn: Equatable {
        let account: String
        /// The album selection goes to it.
        let photos: Bool
        /// Messages media goes along: the primary's turn only.
        let messages: Bool
    }

    /// The turn in progress, and so the account the pass is backing up to.
    private(set) var currentTurn: Turn?
    var current: String? { currentTurn?.account }
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
    @ObservationIgnored var turn: ((_ turn: Turn, _ trigger: RunTrigger) -> Void)?

    /// The engine reports a phase change at most this late to the pass.
    private static let pollInterval: Duration = .milliseconds(250)

    init(model: AppModel) {
        self.model = model
    }

    /// - Parameters:
    ///   - messages: Messages media goes along to the primary account.
    ///   - destination: the saved choice, or a one-off.
    func start(trigger: RunTrigger, messages: Bool, to destination: Destination = .chosen) {
        // A run asked for in person goes ahead on a metered network or on
        // battery, as it would have had it started the pass.
        if trigger.overridesConditions, model.engine.isActive { model.engine.start(trigger: trigger) }
        guard task == nil else { return }
        let turns = plan(destination, messages: messages)
        guard !turns.isEmpty else {
            if destination == .chosen, model.noAccountIncluded, !trigger.isAutomatic {
                model.log(.account, "Nothing was backed up: no Google account is included in backups. Choose one in Settings > Account.")
            }
            return
        }
        stopped = false
        outcomes = [:]
        isRunning = true
        task = Task { [weak self] in
            await self?.run(turns, to: destination, trigger: trigger)
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

    /// The turns of a pass, in run order. Messages media goes only to the
    /// primary, and goes there whenever a pass that is not a one-off to
    /// another account takes it along, even if the choice leaves the primary
    /// out of photo backups: its turn then carries Messages media alone.
    func plan(_ destination: Destination, messages: Bool) -> [Turn] {
        let ready = model.runnableAccounts.map(\.id)
        let photos: Set<String> = switch destination {
        case .chosen: Set(model.targetAccounts.map(\.id))
        case .every: Set(ready)
        case let .only(id): ready.contains(id) ? [id] : []
        }
        let primary = model.primaryAccount?.id
        let messagesGo = switch destination {
        case let .only(id): id == primary
        case .chosen, .every: true
        }
        let withMessages = messages && messagesGo && model.settings.messagesMedia
        return ready.compactMap { id in
            let turn = Turn(account: id, photos: photos.contains(id), messages: withMessages && id == primary)
            return turn.photos || turn.messages ? turn : nil
        }
    }

    private func run(_ turns: [Turn], to destination: Destination, trigger: RunTrigger) async {
        for planned in turns {
            await settled()
            if stopped { break }
            let id = planned.account
            // A primary run that halted leaves its picks, Messages media or
            // device import queued, and any run sends the queue first: it
            // comes out of the engine before another account's turn.
            if id != model.primaryAccount?.id, model.engine.hasQueuedPrimaryOnlyWork {
                model.setAsidePrimaryOnlyWork()
            }
            // Removed, signed out or not yet storage-checked meanwhile; for
            // the saved choice, also left out meanwhile.
            guard model.runnableAccounts.contains(where: { $0.id == id }) else { continue }
            let turn = Turn(account: id,
                            photos: planned.photos && (destination != .chosen || model.isIncluded(id)),
                            messages: planned.messages && id == model.primaryAccount?.id && model.settings.messagesMedia)
            guard turn.photos || turn.messages, model.activate(id) else { continue }
            currentTurn = turn
            outcomes[id] = nil
            if let hook = self.turn {
                hook(turn, trigger)
            } else if turn.messages {
                await model.scanMessages(includingPhotos: turn.photos, trigger: trigger)
            } else if model.library.isAuthorized {
                model.engine.start(trigger: trigger)
            }
            await settled()
            if case .stopped = outcomes[id] { break }
        }
        currentTurn = nil
        await settled()
        model.activate(model.primaryAccount?.id)
        model.releaseHeldPicks()
    }

    /// Until the engine is idle: not running, stopping, waiting or paused.
    private func settled() async {
        while model.engine.isActive || model.engine.phase == .paused {
            try? await Task.sleep(for: Self.pollInterval)
        }
    }
}
