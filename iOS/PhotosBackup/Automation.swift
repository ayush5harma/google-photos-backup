import Foundation
import PhotosBackupCore

/// photosbackup:// links, parsed by Core's AutomationCommand exactly as on
/// the Mac and run through the same calls as the buttons. Messages and the
/// archive are Mac-only: those links are logged and ignored.
extension AppModel {
    func open(_ url: URL) {
        guard let command = AutomationCommand(url: url) else {
            return log(.app, "A link was not understood and nothing was done", problem: true)
        }
        perform(command)
    }

    func perform(_ command: AutomationCommand) {
        let trigger = AutomationCommand.trigger
        log(.app, "Link: \(command.logTitle)")
        switch command {
        case let .backUp(scope, account):
            guard scope != .messagesMedia else { return log(.app, "Link asked for Messages media, which only the Mac app backs up") }
            guard hasAuthData, canReadPhotos else { return log(.app, "Link could not back up: sign in and allow Photos access first", problem: true) }
            if let account {
                guard runnableAccounts.contains(where: { $0.id == account }) else {
                    return log(.app, "Link named \(account), which is not an account ready to back up here; nothing was backed up", problem: true)
                }
                backUpNow(to: .only(account), trigger: trigger)
            } else {
                backUpNow(to: .chosen, trigger: trigger)
            }
        case .archive:
            log(.app, "Link asked to archive Messages, which only the Mac app does")
        case .pause:
            pause()
        case .resume:
            // Resume only continues a paused run; it never starts a new one.
            if status.phase == .paused || status.phase == .pausing { resume() }
        case .stop:
            stop()
        case .retryFailed:
            retryFailed()
        case let .open(section):
            switch section {
            case .overview, nil: tab = .overview
            case .albums: tab = .albums
            case .activity: tab = .activity
            case .messages: tab = .overview
            }
        case let .settings(page):
            tab = .settings
            switch page {
            case .backup: settingsPath = [.backup]
            case .advanced: settingsPath = [.advanced]
            case .general, .account, .messages, nil: settingsPath = []
            }
        }
    }
}

extension AutomationCommand {
    /// For the event timeline; an address in it is masked by Redactor.
    var logTitle: String {
        switch self {
        case let .backUp(scope, account?): "back up (\(scope.rawValue)) to \(account)"
        case let .backUp(scope, nil): "back up (\(scope.rawValue))"
        case .archive: "archive Messages"
        case .pause: "pause"
        case .resume: "resume"
        case .stop: "stop"
        case .retryFailed: "retry failed items"
        case let .open(section): "open \(section?.rawValue ?? "app")"
        case let .settings(tab): "open Settings\(tab.map { " (\($0.rawValue))" } ?? "")"
        }
    }
}
