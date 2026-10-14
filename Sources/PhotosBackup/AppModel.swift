import Foundation
import AppKit
import Observation
import Photos
import PhotosBackupCore

struct BackupSettings: Codable, Equatable {
    var quality: UploadQuality = .original
    /// gpmc upload threads per batch.
    var threads = 2
    /// Assets exported and handed to gpmc per bridge run; also how much
    /// staging space a run needs at once.
    var batchSize = 20
    var mirrorAlbums = true
    var automatic = true
    /// Messages is a distinct library that may contain other people's media.
    /// It stays opt-in even when automatic Photos backups are enabled.
    var messagesMedia = false
    /// The attachment ROWID reached by the last bounded Messages scan.
    var messagesCursor = 0

    // General
    var showInDock = true
    var menuBarShowsProgress = true
    var notifyWhenFinished = true
    var notifyAboutProblems = true
    /// False only for a fresh install; settings saved before onboarding
    /// existed decode as true, so people already set up never see it.
    var onboardingCompleted = false

    // When to hold uploads. A Mac on a phone's hotspot or in Low Data Mode
    // is the Mac's version of the iOS app's "Wi-Fi only".
    var pauseOnExpensiveNetwork = true
    var pauseInLowDataMode = true
    var pauseOnBattery = false
    var pauseInLowPowerMode = true

    /// Upload the edited version again when a photo is edited after its
    /// backup, as the iOS app does.
    var reuploadEdits = true

    // Messages archive: a readable copy of every conversation, written to a
    // folder on this Mac. Opt-in for the same reason as Messages media.
    var messagesArchive = false
    /// nil means the default, ~/Documents/Messages Archive.
    var archiveFolder: String?
    var archiveAutomatically = true
    var archiveAttachments = true
    var archiveContactNames = true
    /// Dated copies of chat.db kept beside the readable archive; 0 keeps none.
    var archiveSnapshotsToKeep = 7

    init() {}

    private enum CodingKeys: String, CodingKey {
        case quality, threads, batchSize, mirrorAlbums, automatic, messagesMedia, messagesCursor
        case showInDock, menuBarShowsProgress, notifyWhenFinished, notifyAboutProblems, onboardingCompleted
        case pauseOnExpensiveNetwork, pauseInLowDataMode, pauseOnBattery, pauseInLowPowerMode
        case reuploadEdits
        case messagesArchive, archiveFolder, archiveAutomatically, archiveAttachments, archiveContactNames, archiveSnapshotsToKeep
    }

    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try values.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        quality = try value(.quality, quality)
        threads = Self.threadRange.clamp(try value(.threads, threads))
        batchSize = Self.batchRange.clamp(try value(.batchSize, batchSize))
        mirrorAlbums = try value(.mirrorAlbums, mirrorAlbums)
        automatic = try value(.automatic, automatic)
        messagesMedia = try value(.messagesMedia, messagesMedia)
        messagesCursor = max(0, try value(.messagesCursor, messagesCursor))
        showInDock = try value(.showInDock, showInDock)
        menuBarShowsProgress = try value(.menuBarShowsProgress, menuBarShowsProgress)
        notifyWhenFinished = try value(.notifyWhenFinished, notifyWhenFinished)
        notifyAboutProblems = try value(.notifyAboutProblems, notifyAboutProblems)
        onboardingCompleted = try value(.onboardingCompleted, true)
        pauseOnExpensiveNetwork = try value(.pauseOnExpensiveNetwork, pauseOnExpensiveNetwork)
        pauseInLowDataMode = try value(.pauseInLowDataMode, pauseInLowDataMode)
        pauseOnBattery = try value(.pauseOnBattery, pauseOnBattery)
        pauseInLowPowerMode = try value(.pauseInLowPowerMode, pauseInLowPowerMode)
        reuploadEdits = try value(.reuploadEdits, reuploadEdits)
        messagesArchive = try value(.messagesArchive, messagesArchive)
        archiveFolder = try values.decodeIfPresent(String.self, forKey: .archiveFolder)
        archiveAutomatically = try value(.archiveAutomatically, archiveAutomatically)
        archiveAttachments = try value(.archiveAttachments, archiveAttachments)
        archiveContactNames = try value(.archiveContactNames, archiveContactNames)
        archiveSnapshotsToKeep = Self.snapshotRange.clamp(try value(.archiveSnapshotsToKeep, archiveSnapshotsToKeep))
    }

    /// The bridge accepts 1-8 threads; batches outside 5-100 either thrash
    /// the uploader start-up or stage too much at once.
    static let threadRange = 1...8
    static let batchRange = 5...100
    static let snapshotRange = 0...30

    private static let key = "settings"

    static func load() -> BackupSettings {
        guard let data = AppEnvironment.defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(BackupSettings.self, from: data) else { return BackupSettings() }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { AppEnvironment.defaults.set(data, forKey: Self.key) }
    }
}

extension ClosedRange where Bound == Int {
    func clamp(_ value: Int) -> Int { Swift.min(Swift.max(value, lowerBound), upperBound) }
}

struct AppPaths {
    let support: URL
    let state: URL
    let logs: URL
    let staging: URL

    var bridgeLog: URL { logs.appendingPathComponent("bridge.log") }
    /// The last runs (RunRecord JSON array).
    var history: URL { support.appendingPathComponent("history.json") }
    /// The event timeline (EventRecord JSON array).
    var events: URL { support.appendingPathComponent("events.json") }
    /// What the Messages archive last wrote, mirrored from its manifest.
    var archiveOverview: URL { support.appendingPathComponent("messages-archive.json") }

    static let standard: AppPaths = {
        let support = AppEnvironment.supportDirectory
        return AppPaths(support: support,
                        state: support.appendingPathComponent("state.json"),
                        logs: support.appendingPathComponent("Logs", isDirectory: true),
                        staging: AppEnvironment.cachesDirectory.appendingPathComponent("Staging", isDirectory: true))
    }()
}

enum MessagesStatus: Equatable {
    case off
    case idle
    case scanning
    case ready(found: Int, skipped: Int, partial: Bool)
    case failed(String)

    var menuTitle: String {
        switch self {
        case .off: "Messages media: off"
        case .idle: "Messages media: ready to scan"
        case .scanning: "Messages media: scanning…"
        case let .ready(found, skipped, partial):
            "Messages media: \(found) ready\(partial ? ", more remain" : "")\(skipped > 0 ? ", \(skipped) unavailable" : "")"
        case let .failed(reason): "Messages media: \(reason)"
        }
    }
}

enum AccountStatus: Equatable {
    case missing
    case checking
    case connected(email: String?)
    case failed(String)
}

/// An attempt to connect an account, by signing in or by pasting.
enum ConnectState: Equatable {
    case idle
    case signingIn
    case connecting
    case failed(String)
}

/// What Google said about a credential before the app keeps it.
private enum Verification {
    case accepted(email: String?)
    /// Google answered no; the credential is useless.
    case refused(String)
    /// No definite answer (network, a missing runtime); keeping the
    /// credential costs nothing and a fresh sign-in is single-use.
    case unconfirmed(String)

    var email: String? {
        if case let .accepted(email) = self { email } else { nil }
    }
}

/// The one object the views read: library, persisted state, settings, the
/// account, and the engine that does the backing up.
@MainActor
@Observable
final class AppModel {
    let library = PhotoLibrary()
    let paths = AppPaths.standard
    @ObservationIgnored private let store: BackupStore
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var messagesScanGeneration = 0

    private(set) var albums: [LibraryAlbum] = [] { didSet { summaryCache = nil } }
    private(set) var albumsLoaded = false
    private(set) var photosStatus: PHAuthorizationStatus
    var state: BackupState { didSet { summaryCache = nil } }
    /// The summary walks every selected asset; the menu bar label and the
    /// panel read it many times per progress tick, so it is kept until the
    /// albums or the state change.
    @ObservationIgnored private var summaryCache: BackupSummary?
    var stateError: String?
    var settings: BackupSettings { didSet { settings.save() } }
    private(set) var account: AccountStatus = .missing
    private(set) var connectState: ConnectState = .idle
    var showingSignIn = false
    /// Whether the keychain holds auth_data, cached so that drawing a view
    /// never queries the keychain (which can prompt after a re-sign).
    private(set) var hasAuthData = false
    private(set) var runtimeDescription = "Checking..."
    private(set) var messagesStatus: MessagesStatus = .off
    @ObservationIgnored lazy var engine = BackupEngine(model: self)
    /// The readable Messages archive (conversations, attachments, chat.db copies).
    @ObservationIgnored lazy var archive = MessagesArchiveController(model: self)
    /// Network and power, for the "pause on..." settings.
    let conditions = ConditionsMonitor()
    /// Run history, the event timeline, storage and the diagnostic report.
    @ObservationIgnored lazy var diagnostics = Diagnostics(paths: paths)
    @ObservationIgnored let notifier = Notifier()
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?

    init() {
        let paths = AppPaths.standard
        let store = BackupStore(url: paths.state)
        self.store = store
        settings = BackupSettings.load()
        photosStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        do {
            state = try store.load()
        } catch {
            // Keep the unreadable file for inspection; starting empty only
            // costs gpmc hash checks, never duplicate uploads.
            state = BackupState()
            stateError = "The backup history could not be read (\(error.localizedDescription)); starting fresh."
            try? FileManager.default.moveItem(at: paths.state, to: paths.state.appendingPathExtension("unreadable"))
        }
        // A crash mid-batch leaves exported copies behind.
        try? FileManager.default.removeItem(at: paths.staging)
        hasAuthData = Keychain.load() != nil
        if hasAuthData { account = .connected(email: nil) }
    }

    var authData: String? { Keychain.load() }

    var summary: BackupSummary {
        // Read both first so a view that only ever hits the cache still
        // observes the changes that invalidate it.
        let albums = albums, state = state
        if let summaryCache { return summaryCache }
        let summary = BackupPlanner.summary(albums: albums.map(\.snapshot), state: state)
        summaryCache = summary
        return summary
    }

    var visibleMessagesStatus: MessagesStatus { settings.messagesMedia ? messagesStatus : .off }
    var isMessagesScanning: Bool { messagesStatus == .scanning }

    var selectedAlbums: [LibraryAlbum] { albums.filter { state.selectedAlbumIDs.contains($0.id) } }

    func progress(of album: LibraryAlbum) -> AlbumProgress { BackupPlanner.progress(of: album.snapshot, state: state) }

    // MARK: - Lifecycle

    func launch() async {
        library.onChange = { [weak self] in self?.libraryChanged() }
        await checkRuntime()
        #if DEBUG
        // The screenshot bundle is UI-only: it must not observe a real Photos
        // library, account, timer, or Messages source from persisted settings.
        if Snapshots.isRequested { return }
        #endif
        log(.app, "Launched")
        conditions.onChange = { [weak self] in self?.conditionsChanged() }
        conditions.start(settings: settings)
        if library.isAuthorized { await connectLibrary() }
        if case .connected = account { await checkAccount() }
        timer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.automaticRun(trigger: .timer) }
        }
        // A Mac that slept through the timer catches up shortly after waking,
        // once the network is back.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(30))
                self?.automaticRun(trigger: .wake)
            }
        }
        automaticRun(trigger: .launch)
    }

    /// The run itself holds while a condition blocks it; this only starts
    /// one that was never started because of it.
    private func conditionsChanged() {
        if conditions.blocking(for: settings) == nil { automaticRun(trigger: .conditions) }
    }

    func requestPhotosAccess() async {
        photosStatus = await library.requestAccess()
        if library.isAuthorized { await connectLibrary() }
    }

    private func connectLibrary() async {
        photosStatus = library.status
        library.startObserving()
        await reloadAlbums()
        if state.selectedAlbumIDs.isEmpty, !albums.isEmpty {
            // First launch: start with the whole library, like the iOS app.
            state.selectedAlbumIDs = [PhotoLibrary.allPhotosID]
            saveState()
        }
    }

    func reloadAlbums() async {
        guard library.isAuthorized else { return }
        albums = await PhotoLibrary.loadAlbums()
        albumsLoaded = true
    }

    /// Photos reports changes in bursts (an import, an iCloud sync), so wait
    /// for it to settle before re-reading the library.
    private func libraryChanged() {
        refreshTask?.cancel()
        refreshTask = Task {
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            await reloadAlbums()
            automaticRun(trigger: .libraryChange)
        }
    }

    func automaticRun(trigger: RunTrigger = .timer) {
        #if DEBUG
        if Snapshots.isRequested { return }
        #endif
        // Granting Photos access selects All Photos and signing in would
        // start it; nothing runs by itself until the welcome guide (where
        // the albums are chosen) is finished or skipped.
        guard settings.onboardingCompleted else { return }
        if settings.messagesArchive, settings.archiveAutomatically { archive.runIfDue(trigger: trigger) }
        guard settings.automatic, hasAuthData, engine.phase == .idle else { return }
        // Automatic runs wait for the conditions; Back Up Now does not.
        guard conditions.blocking(for: settings) == nil else { return }
        if settings.messagesMedia {
            backUpMessages(includingPhotos: true, trigger: trigger)
        } else if library.isAuthorized {
            engine.start(trigger: trigger)
        }
    }

    func startBackupNow(trigger: RunTrigger = .manual) {
        if settings.messagesMedia { backUpMessages(includingPhotos: true, trigger: trigger) }
        else if library.isAuthorized { engine.start(trigger: trigger) }
    }

    func backUpMessages(includingPhotos: Bool = false, trigger: RunTrigger = .manual) {
        #if DEBUG
        // Snapshot runs must never inherit a real user's Messages access from
        // persisted settings. They render the UI without touching private data.
        if Snapshots.isRequested { return }
        #endif
        guard settings.messagesMedia else {
            messagesStatus = .off
            return
        }
        guard hasAuthData else {
            messagesStatus = .failed("sign in before backing up Messages media")
            return
        }
        guard messagesStatus != .scanning else { return }
        messagesStatus = .scanning
        let generation = messagesScanGeneration
        let root = MessagesMediaScanner.defaultConfiguration()
        let configuration = MessagesMediaScanner.Configuration(attachmentsRoot: root.attachmentsRoot, database: root.database,
                                                               homeDirectory: root.homeDirectory, cursor: settings.messagesCursor)
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                Result { try MessagesMediaScanner(configuration: configuration).scan() }
            }.value
            guard let self else { return }
            guard self.messagesScanGeneration == generation, self.settings.messagesMedia, self.hasAuthData else { return }
            switch result {
            case let .success(report):
                let pending = report.items.filter { self.state.uploaded[$0.id] == nil }
                // 2026-10-14: after reaching the tail, rescan from row zero so an
                // attachment skipped while iCloud had not downloaded it can be found later.
                self.settings.messagesCursor = report.nextCursor ?? 0
                self.messagesStatus = .ready(found: pending.count, skipped: report.skipped, partial: report.nextCursor != nil)
                self.engine.backUp(messages: pending, includingPhotos: includingPhotos, trigger: trigger)
                if includingPhotos, pending.isEmpty, self.library.isAuthorized, self.engine.phase == .idle { self.engine.start(trigger: trigger) }
            case let .failure(error):
                self.messagesStatus = .failed(MessagesMediaScanner.describe(error))
                // A Messages scan is additive. Its failure must never prevent
                // a selected Photos-library backup from running.
                if includingPhotos, self.library.isAuthorized, self.engine.phase == .idle { self.engine.start(trigger: trigger) }
            }
        }
    }

    func refreshNow() {
        Task { @MainActor in
            await reloadAlbums()
            if settings.messagesMedia { backUpMessages(includingPhotos: true) }
            else if library.isAuthorized, hasAuthData, engine.phase == .idle { engine.start(trigger: .manual) }
        }
    }

    func openFullDiskAccess() {
        guard let pane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(pane)
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    func setMessagesMedia(_ enabled: Bool) {
        messagesScanGeneration += 1
        settings.messagesMedia = enabled
        messagesStatus = enabled ? .idle : .off
        if !enabled {
            settings.messagesCursor = 0
            engine.stop()
        }
    }

    func cancelMessagesScan() {
        messagesScanGeneration += 1
        if settings.messagesMedia { messagesStatus = .idle }
    }

    func stopBackup() {
        cancelMessagesScan()
        engine.stop()
    }

    // MARK: - State

    func toggle(_ album: LibraryAlbum) {
        if state.selectedAlbumIDs.contains(album.id) {
            state.selectedAlbumIDs.remove(album.id)
        } else {
            state.selectedAlbumIDs.insert(album.id)
        }
        saveState()
        if state.selectedAlbumIDs.contains(album.id) { automaticRun(trigger: .albumSelected) }
    }

    func saveState() {
        do {
            try store.save(state)
            stateError = nil
        } catch {
            stateError = "Could not save the backup history: \(error.localizedDescription)"
        }
    }

    func forgetAlbumLinks() {
        state.mirrors = [:]
        saveState()
    }

    func resetHistory() {
        cancelMessagesScan()
        settings.messagesCursor = 0
        state = state.clearingHistory()
        saveState()
    }

    // MARK: - Account and runtime

    func beginSignIn() {
        // A second sign-in while one is exchanging would race it.
        if connectState != .connecting { connectState = .signingIn }
        showingSignIn = true
    }

    func cancelSignIn() {
        showingSignIn = false
        if connectState != .connecting { connectState = .idle }
    }

    /// The Embedded Setup cookie, straight from the sign-in sheet or pasted.
    func signIn(oauthToken: String) async {
        guard connectState != .connecting else { return }
        connectState = .connecting
        do {
            let linked = try await GoogleAccountLink.link(oauthToken: oauthToken)
            await connect(credential: linked.credential, email: linked.email)
        } catch {
            connectState = .failed(error.localizedDescription)
        }
    }

    /// Settings' paste field takes either a cookie or a whole auth_data.
    func connect(pasted value: String) async {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if GoogleSignIn.looksLikeAuthData(trimmed) {
            guard connectState != .connecting else { return }
            connectState = .connecting
            await connect(credential: trimmed, email: GoogleSignIn.email(inCredential: trimmed))
        } else {
            await signIn(oauthToken: trimmed)
        }
    }

    /// Checks a credential with Google before it replaces the stored one.
    /// Only a definite refusal is discarded: a credential Google could not
    /// be asked about (offline, Google overloaded) is kept, because a fresh
    /// sign-in cannot be repeated, and is checked again at the next launch.
    private func connect(credential: String, email knownEmail: String?) async {
        let verification = await verify(credential)
        if case let .refused(message) = verification {
            connectState = .failed(message)
            return
        }
        let email = verification.email ?? knownEmail
        // The account the history belongs to: recorded, or for history from
        // before accounts were recorded, the one in the credential it used.
        // (History from then with no credential left, after Remove, is
        // assumed to be the new account's.)
        let previous = state.accountEmail ?? authData.flatMap(GoogleSignIn.email(inCredential:))
        let switching = email.map { new in previous.map { !GoogleSignIn.sameAccount($0, new) } ?? false } ?? false
        if switching {
            cancelMessagesScan()
            settings.messagesCursor = 0
            // Let the running backup finish with the old account first, or
            // its last items would be recorded against the new one.
            await engine.stopAndWait()
            guard !engine.isActive else {
                connectState = .failed("The backup is still stopping. Sign in again in a moment.")
                automaticRun(trigger: .signIn)
                return
            }
        }
        do {
            try Keychain.save(credential)
        } catch {
            connectState = .failed("Could not store the account in the keychain: \(error.localizedDescription)")
            return
        }
        hasAuthData = true
        if let email {
            if state.accountEmail == nil { state.accountEmail = previous }
            state = state.adopting(account: email)
            saveState()
        }
        switch verification {
        case let .unconfirmed(message): account = .failed(message)
        default: account = .connected(email: email)
        }
        connectState = .idle
        showingSignIn = false
        log(.account, "Connected \(email ?? "an account")")
        automaticRun(trigger: .signIn)
    }

    func removeAuthData() {
        stopBackup()
        Keychain.delete()
        hasAuthData = false
        account = .missing
    }

    func checkAccount() async {
        guard let auth = authData else { account = .missing; return }
        account = .checking
        let verification = await verify(auth)
        // A sign-in may have replaced the credential while this one was
        // being checked; its result is not about the account stored now.
        guard authData == auth else { return }
        switch verification {
        case let .accepted(email):
            account = .connected(email: email)
            if let email {
                state = state.adopting(account: email)
                saveState()
            }
        case let .refused(message), let .unconfirmed(message):
            account = .failed(message)
        }
    }

    private func verify(_ credential: String) async -> Verification {
        guard let runtime = BridgeRuntime.locate() else { return .unconfirmed("The uploader runtime is missing from the app bundle.") }
        var result = Verification.unconfirmed("The uploader did not answer.")
        do {
            _ = try await BridgeProcess().run(.checkAuth(credential), runtime: runtime, workDirectory: paths.logs, log: paths.bridgeLog) { event in
                switch event {
                case let .auth(email): result = .accepted(email: email)
                case let .fatal(.auth, message): result = .refused(Self.describe(.auth, message))
                case let .fatal(kind, message): result = .unconfirmed(Self.describe(kind, message))
                default: break
                }
            }
        } catch {
            result = .unconfirmed(error.localizedDescription)
        }
        return result
    }

    private func checkRuntime() async {
        guard let runtime = BridgeRuntime.locate() else {
            runtimeDescription = "Missing: build the app with scripts/build-app.sh"
            return
        }
        var description = "Did not answer"
        _ = try? await BridgeProcess().run(.version, runtime: runtime, workDirectory: paths.logs, log: paths.bridgeLog) { event in
            if case let .version(_, gpmc, python) = event {
                description = "gpmc \(gpmc ?? "not installed") on Python \(python ?? "?")"
            }
        }
        runtimeDescription = description
    }

    // MARK: - Hooks for the engine and the archive

    /// Every run ends here: it joins the history and may notify.
    func runFinished(_ record: RunRecord) {
        diagnostics.record(record)
        notifier.runFinished(record, settings: settings)
    }

    /// A line in the event timeline (never a token or message text).
    func log(_ category: EventCategory, _ message: String, problem: Bool = false) {
        diagnostics.log(category, message, problem: problem)
        if problem { notifier.problem(message, category: category, settings: settings) }
    }

    static func describe(_ kind: FatalKind, _ message: String) -> String {
        switch kind {
        case .auth: "Google refused the account (\(message)). Sign in again in Settings."
        case .network: "Google could not be reached (\(message)). The next run retries."
        case .rateLimit: "Google asked the app to slow down (\(message)). Uploads resume by themselves."
        case .storageFull: "Your Google account is out of storage (\(message)). Free up space or change the upload quality."
        case .request: "The app sent the uploader a bad request: \(message)"
        case .internal, .unknown: "The uploader failed: \(message)"
        }
    }
}
