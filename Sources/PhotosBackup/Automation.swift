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
        case .backUp(.everything):
            startBackupNow(trigger: trigger)
        case .backUp(.photos):
            guard hasAuthData, canReadPhotos else { return log(.app, "Link could not back up photos: sign in and allow Photos access first", problem: true) }
            engine.start(trigger: trigger)
        case .backUp(.messagesMedia):
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
            engine.retryFailed()
        case let .open(section):
            AppRouter.shared.openMain(section: section.map(AppSection.init))
        case let .settings(tab):
            AppRouter.shared.openSettings(tab)
        }
    }
}

extension AutomationCommand {
    /// For the event timeline.
    var logTitle: String {
        switch self {
        case let .backUp(scope): "back up (\(scope.rawValue))"
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
