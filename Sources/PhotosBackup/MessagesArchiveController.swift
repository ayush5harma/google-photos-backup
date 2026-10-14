import AppKit
import Foundation
import Observation
import PhotosBackupCore

/// Runs the Messages archive (Core's MessagesArchiver) off the main actor
/// and keeps what the menu bar, Settings and the Messages section show.
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
    private(set) var contactsAccess = ContactsDirectory.access

    @ObservationIgnored private unowned let model: AppModel
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Bumped by every start; a run that finishes under an older one (the
    /// folder changed, the archive was turned off) is ignored.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var overviewLoaded = false
    /// The last automatic attempt that failed; the timer runs every 30
    /// minutes and must not turn one missing permission into a stream of
    /// notifications.
    @ObservationIgnored private var lastFailure: Date?
    #if DEBUG
    @ObservationIgnored private var fixtureTranscripts: [String: [ArchivedMessage]]?
    #endif

    nonisolated static let interval: TimeInterval = 24 * 60 * 60
    nonisolated static let failureRetry: TimeInterval = 6 * 60 * 60
    /// The preview shows the end of a conversation; the browser page has it all.
    nonisolated static let previewLimit = 200

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

    var lastArchived: Date? { overview?.lastArchived }

    // MARK: - Running

    /// Archive now, whatever the schedule says.
    func start(trigger: RunTrigger) {
        guard model.settings.messagesArchive else {
            status = .off
            return
        }
        guard !isRunning else { return }
        #if DEBUG
        if Snapshots.isRequested || fixtureTranscripts != nil { return }
        #endif
        generation += 1
        let generation = generation
        let settings = model.settings
        let folder = folder
        let started = Date()
        status = .running(phase: MessagesArchiver.Phase.copying.rawValue, done: 0, total: 0)
        model.log(.archive, "Messages archive started (\(trigger.title))")
        let report: @Sendable (MessagesArchiver.Phase, Int, Int) -> Void = { [weak self] phase, done, total in
            guard let self else { return }
            Task { @MainActor in self.progressed(generation, phase, done, total) }
        }
        task = Task { [weak self] in
            let names = settings.archiveContactNames ? await ContactsDirectory.names() : HandleNames()
            var configuration = MessagesArchiver.Configuration.standard(folder: folder)
            configuration.archiveAttachments = settings.archiveAttachments
            configuration.snapshotsToKeep = settings.archiveSnapshotsToKeep
            configuration.names = names
            let archiver = MessagesArchiver(configuration: configuration)
            let work = Task.detached(priority: .utility) {
                try archiver.run(progress: report)
            }
            let result = await withTaskCancellationHandler { await work.result } onCancel: { work.cancel() }
            self?.finished(generation, result, trigger: trigger, started: started)
        }
    }

    /// Archive if the archive is on and the last one is a day old.
    func runIfDue(trigger: RunTrigger) {
        guard model.settings.messagesArchive, !isRunning else { return }
        Task {
            await loadOverviewIfNeeded()
            guard model.settings.messagesArchive, !isRunning else { return }
            if trigger.isAutomatic, let lastFailure, Date().timeIntervalSince(lastFailure) < Self.failureRetry { return }
            if let last = overview?.lastArchived, Date().timeIntervalSince(last) < Self.interval { return }
            start(trigger: trigger)
        }
    }

    func cancel() {
        task?.cancel()
    }

    /// Turning the archive on from the Messages section starts the first run.
    func turnOn() {
        model.settings.messagesArchive = true
        start(trigger: .manual)
    }

    func turnOff() {
        generation += 1
        task?.cancel()
        model.settings.messagesArchive = false
        status = .off
    }

    private func progressed(_ generation: Int, _ phase: MessagesArchiver.Phase, _ done: Int, _ total: Int) {
        guard generation == self.generation, isRunning else { return }
        status = .running(phase: phase.rawValue, done: done, total: total)
    }

    private func finished(_ generation: Int, _ result: Result<MessagesArchiver.Report, Error>, trigger: RunTrigger, started: Date) {
        guard generation == self.generation else { return }
        task = nil
        var record = RunRecord(kind: .messagesArchive, trigger: trigger, startedAt: started, finishedAt: Date())
        switch result {
        case let .success(report):
            lastFailure = nil
            overview = report.overview
            saveOverview(report.overview)
            status = .finished(report.overview.lastArchived ?? Date())
            record.uploaded = report.newMessages
            record.bytes = report.bytesCopied
            record.outcome = .completed
            model.log(.archive, "Archived \(report.newMessages) new messages in \(report.conversationsWritten) conversations; "
                + "\(report.attachmentsCopied) attachments copied, \(report.overview.missingAttachmentCount) not on this Mac"
                + (report.decodeFailures > 0 ? ", \(report.decodeFailures) unreadable" : "")
                + (report.rebuilt ? " (rebuilt after the Messages database was replaced)" : ""))
        case let .failure(error) where error is CancellationError:
            status = overview?.lastArchived.map { .finished($0) } ?? .idle
            record.outcome = .stopped
            model.log(.archive, "Messages archive stopped")
        case let .failure(error):
            lastFailure = Date()
            let archiveError = error as? MessagesArchiveError
            let reason = archiveError?.description ?? error.localizedDescription
            status = archiveError == .needsFullDiskAccess ? .needsFullDiskAccess : .failed(reason)
            record.outcome = .failed(reason)
            model.log(.archive, "Messages archive failed: \(reason)", problem: true)
        }
        model.runFinished(record)
    }

    // MARK: - Overview

    /// Re-reads the overview from disk (launch, after a run).
    func loadOverview() async {
        overviewLoaded = true
        contactsAccess = ContactsDirectory.access
        let url = model.paths.archiveOverview
        let loaded = await Task.detached(priority: .utility) { () -> MessagesArchiveOverview? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? Self.decoder.decode(MessagesArchiveOverview.self, from: data)
        }.value
        if let loaded { overview = loaded }
        guard !isRunning else { return }
        if !model.settings.messagesArchive { status = .off }
        else if case .needsFullDiskAccess = status {}
        else if case .failed = status {}
        else { status = overview?.lastArchived.map { .finished($0) } ?? .idle }
    }

    func loadOverviewIfNeeded() async {
        if !overviewLoaded { await loadOverview() }
    }

    private func saveOverview(_ overview: MessagesArchiveOverview) {
        let url = model.paths.archiveOverview
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.encoder.encode(overview).write(to: url, options: [.atomic])
        } catch {
            model.log(.archive, "Could not save the archive summary: \(error.localizedDescription)", problem: true)
        }
    }

    private nonisolated static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private nonisolated static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// The end of a conversation, for the preview, from its messages.json.
    func recentMessages(in conversation: ArchivedConversation) async -> [ArchivedMessage] {
        #if DEBUG
        if let fixtureTranscripts { return fixtureTranscripts[conversation.id] ?? [] }
        #endif
        let url = folder.appendingPathComponent(conversation.relativePath).appendingPathComponent("messages.json")
        return await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url), let transcript = try? ConversationTranscript.decode(data) else { return [] }
            return Array(transcript.messages.suffix(Self.previewLimit))
        }.value
    }

    func fileURL(_ relative: String, in conversation: ArchivedConversation) -> URL {
        folder.appendingPathComponent(conversation.relativePath).appendingPathComponent(relative)
    }

    // MARK: - Contacts

    /// Asked from a button only. A yes re-renders the archive with names.
    func requestContactsAccess() async {
        _ = await ContactsDirectory.requestAccess()
        contactsAccess = ContactsDirectory.access
        if contactsAccess == .allowed, model.settings.archiveContactNames { start(trigger: .manual) }
    }

    func openContactsSettings() {
        if let pane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts") { NSWorkspace.shared.open(pane) }
    }

    // MARK: - Folder

    /// NSOpenPanel for a new folder; saves it in settings.
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Folder for the Messages Archive"
        panel.message = "Your conversations are written to this folder. The archive in the current folder stays where it is."
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url, url.standardizedFileURL != folder.standardizedFileURL else { return }
        generation += 1
        task?.cancel()
        model.settings.archiveFolder = url.path
        overview = nil
        try? FileManager.default.removeItem(at: model.paths.archiveOverview)
        status = model.settings.messagesArchive ? .idle : .off
        start(trigger: .manual)
    }

    func revealInFinder() {
        if FileManager.default.fileExists(atPath: folder.path) {
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        } else {
            NSWorkspace.shared.open(folder.deletingLastPathComponent())
        }
    }

    /// Opens the archive's index.html in the default browser.
    func openInBrowser() {
        open(folder.appendingPathComponent("index.html"))
    }

    func openInBrowser(_ conversation: ArchivedConversation) {
        open(folder.appendingPathComponent(conversation.relativePath).appendingPathComponent("index.html"))
    }

    func revealInFinder(_ conversation: ArchivedConversation) {
        let url = folder.appendingPathComponent(conversation.relativePath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.path) else { return revealInFinder() }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func open(_ page: URL) {
        guard FileManager.default.fileExists(atPath: page.path) else { return }
        NSWorkspace.shared.open(page)
    }

    #if DEBUG
    /// Snapshot renderer only: show synthetic data without a run.
    func applyFixture(overview: MessagesArchiveOverview?, status: Status, transcripts: [String: [ArchivedMessage]] = [:]) {
        generation += 1
        task?.cancel()
        overviewLoaded = true
        fixtureTranscripts = transcripts
        self.overview = overview
        self.status = status
    }
    #endif
}
