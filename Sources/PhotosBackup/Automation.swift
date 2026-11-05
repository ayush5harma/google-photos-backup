import Foundation
import PhotosBackupCore

/// photosbackup:// links (see AutomationCommand for the list), run the way
/// the matching button would run them. Every run a link starts is recorded
/// with the `.automation` trigger, so it is never announced as automatic.
extension AppModel {
    func perform(_ command: AutomationCommand) {
        let trigger = AutomationCommand.trigger
        log(.app, "Link: \(command.logTitle)")
        switch command {
        case let .backUp(scope, account?):
            guard let id = linkTarget(account) else { return }
            if isBackingUp {
                return log(.app, "Link could not back up to \(accounts.first { $0.id == id }?.title ?? account): a backup is running; try again once it ends")
            }
            switch scope {
            case .everything:
                startBackupNow(to: .only(id), trigger: trigger)
            case .photos:
                guard canReadPhotos else { return log(.app, "Link could not back up photos: allow Photos access first", problem: true) }
                backUpPhotosNow(to: .only(id), trigger: trigger)
            case .messagesMedia:
                // Not a link AutomationCommand reads: only the primary takes it.
                break
            }
        case .backUp(.everything, nil):
            guard hasAuthData else { return log(.app, "Link could not back up: sign in first", problem: true) }
            startBackupNow(trigger: trigger)
        case .backUp(.photos, nil):
            guard hasAuthData, canReadPhotos else { return log(.app, "Link could not back up photos: sign in and allow Photos access first", problem: true) }
            backUpPhotosNow(trigger: trigger)
        case .backUp(.messagesMedia, nil):
            guard hasAuthData else { return log(.app, "Link could not back up Messages media: sign in first", problem: true) }
            backUpMessages(includingPhotos: false, trigger: trigger)
        case .archive:
            guard settings.messagesArchive else { return log(.archive, "Link asked to archive Messages, but the archive is off") }
            archive.start(trigger: trigger)
        case .pause:
            engine.pauseAfterCurrent()
        case .resume:
            // Resume on an idle engine would start a new run; a link that
            // says resume only continues one that was paused.
            if engine.phase == .paused || engine.phase == .pausing { engine.resume() }
        case .stop:
            stopBackup()
        case .retryFailed:
            retryFailed()
        case let .open(section):
            AppRouter.shared.openMain(section: section.map(AppSection.init))
        case let .settings(tab):
            AppRouter.shared.openSettings(tab)
        }
    }

    /// The signed-in account a link names, ready to back up to; nil, with a
    /// line in the timeline, otherwise. Matched only by the normalized
    /// address: an address no account has is never taken for another.
    private func linkTarget(_ address: String) -> String? {
        guard let account = accounts.first(where: { $0.id == address }) else {
            log(.app, "Link named \(address), which is not an account signed in here; nothing was backed up", problem: true)
            return nil
        }
        guard runnableAccounts.contains(where: { $0.id == account.id }) else {
            let reason = credentialAccounts.contains(account.id) ? "waits for its storage check in Settings > Account" : "is signed out"
            log(.app, "Link named \(account.title), which \(reason); nothing was backed up", problem: true)
            return nil
        }
        return account.id
    }
}

extension AutomationCommand {
    /// For the event timeline.
    var logTitle: String {
        switch self {
        case let .backUp(scope, account?): "back up (\(scope.rawValue)) to \(account)"
        case let .backUp(scope, nil): "back up (\(scope.rawValue))"
        case .archive: "archive Messages"
        case .pause: "pause"
        case .resume: "resume"
        case .stop: "stop"
        case .retryFailed: "retry failed items"
        case let .open(section): "open \(section?.rawValue ?? "window")"
        case let .settings(tab): "open Settings\(tab.map { " (\($0.rawValue))" } ?? "")"
        }
    }
}
