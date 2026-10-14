import Foundation
import Testing
@testable import PhotosBackupCore

private func command(_ string: String) -> AutomationCommand? {
    URL(string: string).flatMap(AutomationCommand.init(url:))
}

@Suite struct AutomationCommandTests {
    @Test func readsEveryDocumentedCommand() {
        #expect(command("photosbackup://backup") == .backUp(.everything))
        #expect(command("photosbackup://backup/photos") == .backUp(.photos))
        #expect(command("photosbackup://backup/messages-media") == .backUp(.messagesMedia))
        #expect(command("photosbackup://archive") == .archive)
        #expect(command("photosbackup://pause") == .pause)
        #expect(command("photosbackup://resume") == .resume)
        #expect(command("photosbackup://stop") == .stop)
        #expect(command("photosbackup://retry-failed") == .retryFailed)
        #expect(command("photosbackup://open") == .open(nil))
        #expect(command("photosbackup://settings") == .settings(nil))
    }

    @Test func opensEachSectionAndSettingsTab() {
        #expect(command("photosbackup://open/overview") == .open(.overview))
        #expect(command("photosbackup://open/albums") == .open(.albums))
        #expect(command("photosbackup://open/messages") == .open(.messages))
        #expect(command("photosbackup://open/activity") == .open(.activity))
        // The sidebar's first section was called Home before it was Overview.
        #expect(command("photosbackup://open/home") == .open(.overview))
        #expect(command("photosbackup://settings/backup") == .settings(.backup))
        #expect(command("photosbackup://settings/advanced") == .settings(.advanced))
    }

    // Shortcuts' "Open URL" passes what was typed; people type these by hand.
    @Test func toleratesHowPeopleTypeURLs() {
        #expect(command("PhotosBackup://Backup/Photos") == .backUp(.photos))
        #expect(command("photosbackup://backup/") == .backUp(.everything))
        #expect(command("photosbackup:backup/photos") == .backUp(.photos))
        #expect(command("photosbackup:///pause") == .pause)
        #expect(command("photosbackup://stop?from=shortcut") == .stop)
    }

    @Test func refusesAnythingElse() {
        #expect(command("https://backup") == nil)
        #expect(command("photosbackup://") == nil)
        #expect(command("photosbackup://delete-everything") == nil)
        #expect(command("photosbackup://backup/videos") == nil)
        #expect(command("photosbackup://backup/photos/now") == nil)
        #expect(command("photosbackup://pause/now") == nil)
        #expect(command("photosbackup://open/trash") == nil)
        #expect(command("photosbackup://settings/secrets") == nil)
    }

    // A manual run's trigger, so the history and notifications treat it as
    // something a person asked for.
    @Test func automationRunsAreNotAutomatic() {
        #expect(AutomationCommand.trigger == .automation)
        #expect(!AutomationCommand.trigger.isAutomatic)
    }
}
