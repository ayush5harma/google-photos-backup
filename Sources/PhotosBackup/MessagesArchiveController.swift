import AppKit
import Foundation
import Observation
import PhotosBackupCore

/// STUB (foundation commit): the Messages archive piece replaces this file.
/// The API below is the contract the menu bar, Settings and the Messages
/// section are written against; keep every member, add freely.
@MainActor
@Observable
final class MessagesArchiveController {
    enum Status: Equatable {
        case off
        case idle
        /// Phase in words ("Reading conversations"), and counts when known.
        case running(phase: String, done: Int, total: Int)
        case finished(Date)
        case needsFullDiskAccess
        case failed(String)
    }

    private(set) var status: Status = .off
    /// What the archive holds; nil until it has run once.
    private(set) var overview: MessagesArchiveOverview?

    @ObservationIgnored private unowned let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    var isRunning: Bool { if case .running = status { true } else { false } }

    /// The folder the archive is written to (the setting, else the default).
    var folder: URL {
        if let path = model.settings.archiveFolder { return URL(fileURLWithPath: path, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Messages Archive", isDirectory: true)
    }

    /// Archive now, whatever the schedule says.
    func start(trigger: RunTrigger) {}
    /// Archive if the archive is on and the last one is a day old.
    func runIfDue(trigger: RunTrigger) {}
    func cancel() {}
    /// NSOpenPanel for a new folder; saves it in settings.
    func chooseFolder() {}
    func revealInFinder() {}
    /// Opens the archive's index.html in the default browser.
    func openInBrowser() {}
    /// Re-reads the overview from disk (launch, after a run).
    func loadOverview() async {}
}
