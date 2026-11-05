import Foundation
import PhotosBackupCore

/// Takes one backup to the accounts it goes to, all at the same time (issue
/// #66). Through 0.6.1 it went through them one after another; measured
/// 2026-11-05, Google takes about 4 to 6 upload commits at once from one
/// account (at 16, 58 of 100 photos failed with 500/503) while the uplink had
/// room for several times that, and each account has its own limit. The
/// engine runs one part per account (AccountLane): its own bridge process,
/// upload parallelism, retries, album work and record, with each photo
/// exported from Photos once for all of them. Original quality is the same
/// path for each. A failure on one account (an expired sign-in, a full
/// account) ends that account's part and the others carry on; Stop ends the
/// whole pass, Pause holds it.
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
        /// Messages media goes along: the primary's part only.
        let messages: Bool
    }

    private(set) var isRunning = false

    @ObservationIgnored private unowned let model: AppModel
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var stopped = false
    /// What a pass hands the engine once it knows where the pass goes; nil
    /// is the app's own (Messages media to the primary account, then the
    /// selected albums to every account of the pass). The integration test,
    /// which has no Photos library, hands it files instead.
    @ObservationIgnored var turn: ((_ turns: [Turn], _ trigger: RunTrigger) -> Void)?

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
        isRunning = true
        task = Task { [weak self] in
            await self?.run(messages: messages, to: destination, trigger: trigger)
            self?.task = nil
            self?.isRunning = false
        }
    }

    /// The pass does not start if it has not yet; the engine's own Stop
    /// ends a run in progress.
    func stop() {
        stopped = true
    }

    /// The parts of a pass, in run order. Messages media goes only to the
    /// primary, and goes there whenever a pass that is not a one-off to
    /// another account takes it along, even if the choice leaves the primary
    /// out of photo backups: its part then carries Messages media alone.
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

    private func run(messages: Bool, to destination: Destination, trigger: RunTrigger) async {
        // A run already going (picks, a Retry) finishes first.
        await settled()
        guard !stopped else { return }
        // Planned now, not when asked: an account removed, signed out or
        // left out meanwhile is not in it.
        let turns = plan(destination, messages: messages)
        guard !turns.isEmpty else { return }
        let plans = turns.map { LanePlan(account: $0.account, photos: $0.photos, followsChoice: destination == .chosen) }
        let primaryTurn = turns.first { $0.account == model.primaryAccount?.id }
        model.engine.prepare(plans)
        if let hook = self.turn {
            hook(turns, trigger)
        } else if primaryTurn?.messages == true {
            await model.scanMessages(includingPhotos: turns.contains(where: \.photos), trigger: trigger)
        } else if model.library.isAuthorized {
            model.engine.start(trigger: trigger)
        }
        await settled()
        // Nothing started (no Messages media found and no Photos access):
        // the next run started by itself goes to the active account again.
        if !model.engine.isActive, model.engine.phase != .paused { model.engine.prepare(nil) }
        model.releaseHeldPicks()
    }

    /// Until the engine is idle: not running, stopping, waiting or paused.
    private func settled() async {
        while model.engine.isActive || model.engine.phase == .paused {
            try? await Task.sleep(for: Self.pollInterval)
        }
    }
}
