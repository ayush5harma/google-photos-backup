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
    /// accounts.json and each account's record file.
    @ObservationIgnored private let accountsStore: AccountsStore
    @ObservationIgnored private let keychain = Keychain.app
    /// Every account's record. The active account's lives in `state` while
    /// it is active and is handed back here when another account becomes so.
    @ObservationIgnored private var accountLibrary: AccountLibrary
    /// Signed-in accounts in run order; the first is the primary.
    private(set) var accounts: [BackupAccount] = []
    /// Whose record `state` is and whose credential `authData` is: the
    /// account a run is going to, else the primary. It changes only while
    /// the engine is idle, so whatever a run confirms lands in its account.
    private(set) var activeAccountID: String?
    private(set) var accountStatuses: [String: AccountStatus] = [:]
    /// Accounts with a credential in the keychain, cached so that drawing a
    /// view never queries the keychain (which can prompt after a re-sign).
    private(set) var credentialAccounts: Set<String> = []
    /// The account the legacy keychain item belongs to when moving it
    /// failed this launch: it is read where it is until the next launch.
    @ObservationIgnored private var unmovedLegacyCredential: String?
    @ObservationIgnored private var accountSummaries: [String: (selection: Set<String>, summary: BackupSummary)] = [:]
    /// Picks made while a pass was on another account (see backUp(picked:)).
    @ObservationIgnored private var heldPicks: (ids: [String], files: [String: URL]) = ([], [:])
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var messagesScanGeneration = 0

    private(set) var albums: [LibraryAlbum] = [] {
        didSet {
            summaryCache = nil
            accountSummaries = [:]
        }
    }
    private(set) var albumsLoaded = false
    private(set) var photosStatus: PHAuthorizationStatus
    var state: BackupState { didSet { summaryCache = nil } }
    /// The summary walks every selected asset; the menu bar label and the
    /// panel read it many times per progress tick, so it is kept until the
    /// albums or the state change.
    @ObservationIgnored private var summaryCache: BackupSummary?
    var stateError: String?
    var settings: BackupSettings {
        didSet {
            settings.save()
            // Whoever changes it (a Settings switch, the guide, a link), the
            // Dock follows; the switches also bring their window back to front.
            if settings.showInDock != oldValue.showInDock {
                applyDockVisibility()
            }
        }
    }
    private(set) var connectState: ConnectState = .idle
    var showingSignIn = false
    private(set) var runtimeDescription = "Checking..."
    private(set) var messagesStatus: MessagesStatus = .off
    @ObservationIgnored lazy var engine = BackupEngine(model: self)
    /// Takes each backup through the accounts one after another.
    @ObservationIgnored lazy var runner = AccountRunner(model: self)
    @ObservationIgnored lazy var iCloud = ICloudSource(model: self)
    /// USB/Wi-Fi camera imports are separate from the Mac Photos library.
    @ObservationIgnored lazy var connectedDevice = ConnectedDeviceSource()
    /// The readable Messages archive (conversations, attachments, chat.db copies).
    @ObservationIgnored lazy var archive = MessagesArchiveController(model: self)
    /// Network and power, for the "pause on..." settings.
    let conditions = ConditionsMonitor()
    /// Run history, the event timeline, storage and the diagnostic report.
    @ObservationIgnored lazy var diagnostics = Diagnostics(paths: paths)
    @ObservationIgnored let notifier = Notifier()
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?

    init() {
        #if DEBUG
        E2EHooks.refuseUnsandboxedCopy()
        #endif
        let paths = AppPaths.standard
        let store = AccountsStore(directory: paths.support)
        accountsStore = store
        settings = BackupSettings.load()
        photosStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        // The single credential from before accounts, filed under its
        // account. Unreadable records are set aside by the store; starting
        // such an account empty costs gpmc hash checks, never duplicate
        // uploads.
        let keychain = Keychain.app
        let legacy = keychain.load(account: AccountLibrary.legacyKeychainAccount)
        let loaded = store.load(legacyCredential: (legacy != nil, legacy.flatMap(GoogleSignIn.email(inCredential:))))
        accountLibrary = loaded.library
        if !loaded.reassigned.isEmpty {
            stateError = "The backup record of \(loaded.reassigned.joined(separator: ", ")) held another account's history, "
                + "written by an older version of the app; it was kept for that account, and this one starts a record of its own."
        }
        if !loaded.unreadable.isEmpty {
            let names = loaded.unreadable.keys.sorted().joined(separator: ", ")
            stateError = "Backup history could not be read (\(names)); it was set aside with an .unreadable ending and those accounts start fresh."
        }
        var indexChanged = loaded.indexChanged
        if let target = loaded.legacyCredentialAccount, target != AccountLibrary.legacyKeychainAccount {
            do {
                try keychain.move(from: AccountLibrary.legacyKeychainAccount, to: target)
            } catch {
                unmovedLegacyCredential = target
            }
        }
        indexChanged = Self.adoptStrayCredentials(keychain: keychain, store: store, into: &accountLibrary) || indexChanged
        state = BackupState()
        // A crash mid-batch leaves exported copies behind, and picked hidden
        // photos copied out of the picker by an earlier launch.
        try? FileManager.default.removeItem(at: paths.staging)
        try? FileManager.default.removeItem(at: PickedFile.root)
        refreshCredentials()
        accounts = accountLibrary.accounts
        activeAccountID = accountLibrary.primary?.id
        state = currentRecord()
        if indexChanged { saveIndex() }
        for account in accounts where credentialAccounts.contains(account.id) {
            accountStatuses[account.id] = .connected(email: account.email)
        }
        // 2026-10-15: Version 0.1.0 saved settings only after a change. An
        // existing account or backup state without that blob is an upgrade,
        // so the welcome guide must not stop its automatic runs.
        if AppEnvironment.defaults.data(forKey: "settings") == nil,
           hasAuthData || !state.uploaded.isEmpty || !state.selectedAlbumIDs.isEmpty {
            settings.onboardingCompleted = true
        }
    }

    /// A credential in the keychain that accounts.json does not show signed
    /// in (the index was lost, or written before the keychain was): the
    /// credential says whose it is, and that account is signed in again with
    /// its record, if one is on disk.
    private static func adoptStrayCredentials(keychain: Keychain, store: AccountsStore, into library: inout AccountLibrary) -> Bool {
        var changed = false
        for id in keychain.accounts() where id != AccountLibrary.legacyKeychainAccount && library.account(id)?.removed != false {
            guard let credential = keychain.load(account: id) else { continue }
            let email = GoogleSignIn.email(inCredential: credential) ?? library.account(id)?.email ?? (id.contains("@") ? id : nil)
            guard let email, GoogleSignIn.normalizedEmail(email) == id else { continue }
            library.adopting(account: email, stored: { store.readState($0) })
            changed = true
        }
        return changed
    }

    /// The active account's credential: the one a run started now would use.
    var authData: String? { activeAccountID.flatMap(credential(for:)) }

    /// The primary account's credential, for what only one account takes
    /// (iCloud), whichever account a run is on.
    var primaryAuthData: String? { primaryAccount.flatMap { credential(for: $0.id) } }

    func credential(for id: String) -> String? {
        if let value = keychain.load(account: id) { return value }
        return id == unmovedLegacyCredential ? keychain.load(account: AccountLibrary.legacyKeychainAccount) : nil
    }

    /// The first signed-in account. It also takes what only one account
    /// can: Messages media, picked photos, device imports and iCloud.
    var primaryAccount: BackupAccount? { accounts.first }

    /// Whether any signed-in account has its credential.
    var hasAuthData: Bool { accounts.contains { credentialAccounts.contains($0.id) } }

    /// The primary account's status: what the menu bar and the window report.
    var account: AccountStatus { primaryAccount.map { status(of: $0.id) } ?? .missing }

    func status(of id: String) -> AccountStatus {
        accountStatuses[id] ?? (credentialAccounts.contains(id) ? .connected(email: accountLibrary.account(id)?.email) : .missing)
    }

    /// Accounts the next run goes to, in order: signed in, with a credential,
    /// and (for an added account) with its storage check confirmed.
    var runnableAccounts: [BackupAccount] {
        accounts.filter { $0.storageChecked && credentialAccounts.contains($0.id) }
    }

    /// An account's own backup record, the active one's included.
    func record(of id: String) -> BackupState? {
        id == activeAccountID ? state : accountLibrary.state(for: id)
    }

    /// The selection against one account's record: "backed up" per account.
    func summary(of id: String) -> BackupSummary {
        if id == activeAccountID { return summary }
        let albums = albums, selection = state.selectedAlbumIDs
        if let cached = accountSummaries[id], cached.selection == selection { return cached.summary }
        var record = accountLibrary.state(for: id) ?? BackupState()
        record.selectedAlbumIDs = selection
        let summary = BackupPlanner.summary(albums: albums.map(\.snapshot), state: record)
        accountSummaries[id] = (selection, summary)
        return summary
    }

    /// The selection against every account a run goes to, summed: with
    /// several accounts the selection is backed up only once each holds it,
    /// so the status, the ring and the percentage count every copy. With one
    /// account it is `summary`.
    var overallSummary: BackupSummary {
        let runnable = runnableAccounts
        guard accounts.count > 1, !runnable.isEmpty else { return summary }
        let each = runnable.map { summary(of: $0.id) }
        return BackupSummary(backedUp: each.reduce(0) { $0 + $1.backedUp }, pending: each.reduce(0) { $0 + $1.pending },
                             selectedAlbums: summary.selectedAlbums)
    }

    /// With several accounts, what is left in words that do not count an
    /// item twice: "1,234 items to go to one account"; nil otherwise.
    var accountsPendingPhrase: String? {
        guard accounts.count > 1 else { return nil }
        let behind = runnableAccounts.filter { summary(of: $0.id).pending > 0 }
        guard !behind.isEmpty else { return nil }
        let items = behind.reduce(0) { $0 + summary(of: $1.id).pending }
        return "\(items.formatted()) items to go to \(behind.count == 1 ? "one account" : "\(behind.count) accounts")"
    }

    /// What the selection asks of an added account's storage before its
    /// first run.
    func storageCheck(for id: String) -> StorageCheck {
        StorageCheck(items: summary(of: id).pending, averageItemBytes: StorageCheck.averageItemBytes(in: diagnostics.runs),
                     quality: settings.quality)
    }

    // MARK: - The active account

    /// Makes `id`'s record and credential the ones a run uses. Refused while
    /// the engine is running or paused: its results belong to the account
    /// it started with.
    @discardableResult
    func activate(_ id: String?) -> Bool {
        guard id != activeAccountID else { return true }
        guard !engine.isActive, engine.phase != .paused else { return false }
        syncActiveRecord()
        activeAccountID = id
        state = currentRecord()
        return true
    }

    /// Hands `state` back to the library, which then holds every record.
    private func syncActiveRecord() {
        accountLibrary.select(state.selectedAlbumIDs)
        if let id = activeAccountID, accountLibrary.account(id) != nil {
            accountLibrary.update(state, for: id)
            accountSummaries[id] = nil
        } else if accountLibrary.unclaimed != nil {
            accountLibrary.updateUnclaimed(state)
        }
    }

    /// The active account's record; with no account, the unclaimed record
    /// from before accounts or an empty one, with the selection either way.
    private func currentRecord() -> BackupState {
        if let id = activeAccountID, let record = accountLibrary.state(for: id) { return record }
        var record = accountLibrary.unclaimed ?? BackupState()
        record.selectedAlbumIDs = accountLibrary.selection
        return record
    }

    private func refreshCredentials() {
        var stored = Set(keychain.accounts())
        if let unmovedLegacyCredential, stored.contains(AccountLibrary.legacyKeychainAccount) { stored.insert(unmovedLegacyCredential) }
        credentialAccounts = stored
    }

    private func saveIndex() {
        do {
            try accountsStore.save(accountLibrary.index)
        } catch {
            stateError = "Could not save the accounts list: \(error.localizedDescription)"
        }
    }

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
        if hasAuthData { await checkAccounts() }
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
        guard settings.automatic, hasAuthData, engine.phase == .idle, !runner.isRunning else { return }
        // Automatic runs wait for the conditions; Back Up Now does not.
        guard conditions.blocking(for: settings) == nil else { return }
        runner.start(trigger: trigger, messages: true)
    }

    /// Every account in turn; Messages media too when it is on.
    func startBackupNow(trigger: RunTrigger = .manual) {
        runner.start(trigger: trigger, messages: true)
    }

    /// The selected albums to every account in turn.
    func backUpPhotosNow(trigger: RunTrigger) {
        runner.start(trigger: trigger, messages: false)
    }

    /// A busy engine, or a pass between two accounts.
    var isBackingUp: Bool { engine.isActive || runner.isRunning }

    /// False while a pass is on an added account: picks and device imports,
    /// which only the primary account takes, wait for it to come back.
    var isPrimaryActive: Bool { activeAccountID == primaryAccount?.id }

    /// Chosen photos go to the primary account only. A pick that arrives
    /// while a pass is on another account (an open picker, or a hidden
    /// photo still copying out of it) waits here for the primary.
    func backUp(picked ids: [String], files: [String: URL] = [:]) {
        guard isPrimaryActive else {
            heldPicks.ids.append(contentsOf: ids.filter { !heldPicks.ids.contains($0) })
            heldPicks.files.merge(files) { _, new in new }
            return
        }
        engine.backUp(picked: ids, files: files)
    }

    /// The picks that waited, once the primary is active again.
    func releaseHeldPicks() {
        guard isPrimaryActive, !heldPicks.ids.isEmpty else { return }
        let held = heldPicks
        heldPicks = ([], [:])
        engine.backUp(picked: held.ids, files: held.files)
    }

    /// Retry queues failed items on the active account. The failures of the
    /// primary's run include picks and Messages media, which must not go to
    /// another account, so Retry waits while a pass is on one.
    var canRetryFailures: Bool { isPrimaryActive }

    func canRetry(_ id: String) -> Bool { isPrimaryActive && engine.canRetry(id) }

    func retry(_ id: String) {
        guard isPrimaryActive else { return }
        engine.retry(id)
    }

    func retryFailed() {
        guard isPrimaryActive else { return }
        engine.retryFailed()
    }

    func backUpMessages(includingPhotos: Bool = false, trigger: RunTrigger = .manual) {
        Task { await scanMessages(includingPhotos: includingPhotos, trigger: trigger) }
    }

    /// Scans Messages and hands what the primary account lacks to the
    /// engine; returns once the engine has it (or nothing is to be done).
    func scanMessages(includingPhotos: Bool, trigger: RunTrigger) async {
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
        let result = await Task.detached(priority: .utility) {
            Result { try MessagesMediaScanner(configuration: configuration).scan() }
        }.value
        guard messagesScanGeneration == generation, settings.messagesMedia, hasAuthData else { return }
        switch result {
        case let .success(report):
            // Messages media goes to the primary account only; while a pass
            // is on another account, the items wait for the next one.
            guard activeAccountID == primaryAccount?.id else {
                messagesStatus = .idle
                return
            }
            let pending = report.items.filter { state.uploaded[$0.id] == nil }
            // 2026-10-14: after reaching the tail, rescan from row zero so an
            // attachment skipped while iCloud had not downloaded it can be found later.
            settings.messagesCursor = report.nextCursor ?? 0
            messagesStatus = .ready(found: pending.count, skipped: report.skipped, partial: report.nextCursor != nil)
            engine.backUp(messages: pending, includingPhotos: includingPhotos, trigger: trigger)
            if includingPhotos, pending.isEmpty, library.isAuthorized, engine.phase == .idle { engine.start(trigger: trigger) }
        case let .failure(error):
            messagesStatus = .failed(MessagesMediaScanner.describe(error))
            // A Messages scan is additive. Its failure must never prevent
            // a selected Photos-library backup from running.
            if includingPhotos, library.isAuthorized, engine.phase == .idle { engine.start(trigger: trigger) }
        }
    }

    /// Also re-applied after every photosbackup:// link: LaunchServices
    /// turns an app it delivers a URL to back into a Dock app (measured
    /// 2026-10-15: the policy read .accessory before `open -a ... <url>` and
    /// .regular half a second after; a link that skipped LaunchServices left
    /// it alone).
    func applyDockVisibility() {
        let policy: NSApplication.ActivationPolicy = settings.showInDock ? .regular : .accessory
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
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

    /// Stops the run and the rest of the pass: no other account starts.
    func stopBackup() {
        cancelMessagesScan()
        runner.stop()
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

    /// Writes the active account's record (as state.json was always written)
    /// and, when the selection changed, the shared selection in accounts.json.
    func saveState() {
        do {
            if let id = activeAccountID, let account = accountLibrary.account(id) {
                try accountsStore.save(state, file: account.stateFile)
            } else if accountLibrary.unclaimed != nil {
                accountLibrary.updateUnclaimed(state)
                try accountsStore.save(state, file: AccountLibrary.legacyStateFile)
            }
            if state.selectedAlbumIDs != accountLibrary.selection {
                accountLibrary.select(state.selectedAlbumIDs)
                try accountsStore.save(accountLibrary.index)
            }
            stateError = nil
        } catch {
            stateError = "Could not save the backup history: \(error.localizedDescription)"
        }
    }

    /// Changes one account's record, active or not, and writes it.
    private func changeRecord(of id: String, _ change: (inout BackupState) -> Void) {
        if id == activeAccountID {
            change(&state)
            saveState()
            return
        }
        guard let account = accountLibrary.account(id), var record = accountLibrary.storedState(for: id) else { return }
        change(&record)
        accountLibrary.update(record, for: id)
        accountSummaries[id] = nil
        do {
            try accountsStore.save(record, file: account.stateFile)
        } catch {
            stateError = "Could not save the backup history: \(error.localizedDescription)"
        }
    }

    /// One account's album links; nil means the primary account's.
    func forgetAlbumLinks(of id: String? = nil) {
        guard let id = id ?? primaryAccount?.id ?? activeAccountID else {
            state.mirrors = [:]
            return saveState()
        }
        changeRecord(of: id) { $0.mirrors = [:] }
    }

    /// One account's upload history; nil means the primary account's.
    func resetHistory(of id: String? = nil) {
        let target = id ?? primaryAccount?.id ?? activeAccountID
        if target == nil || target == primaryAccount?.id {
            // The Messages cursor belongs to the primary account's record.
            cancelMessagesScan()
            settings.messagesCursor = 0
        }
        guard let target else {
            state = state.clearingHistory()
            return saveState()
        }
        changeRecord(of: target) { $0 = $0.clearingHistory() }
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

    /// Checks a credential with Google before it is kept. Only a definite
    /// refusal is discarded: a credential Google could not be asked about
    /// (offline, Google overloaded) is kept, because a fresh sign-in cannot
    /// be repeated, and is checked again at the next launch.
    ///
    /// The address decides the account. One already known (signed in, or
    /// removed earlier) gets its new credential and keeps its record; any
    /// other is added next to the accounts there are, with a record of its
    /// own. No account's record is ever replaced, so signing in can no
    /// longer make a run recreate albums.
    private func connect(credential: String, email knownEmail: String?) async {
        let verification = await verify(credential)
        if case let .refused(message) = verification {
            connectState = .failed(message)
            return
        }
        guard let email = verification.email ?? knownEmail else {
            connectState = .failed("Google did not say which account this is, so it cannot be kept apart from other accounts. Sign in again once Google can be reached.")
            return
        }
        let primaryBefore = primaryAccount?.id
        syncActiveRecord()
        var candidate = accountLibrary
        let store = accountsStore
        let adoption = candidate.adopting(account: email, stored: { store.readState($0) })
        do {
            try keychain.save(credential, account: adoption.account.id)
            if adoption.account.id == unmovedLegacyCredential {
                // The fresh sign-in replaces the item that could not be moved;
                // left in place, it would overwrite this one at the next launch.
                keychain.delete(account: AccountLibrary.legacyKeychainAccount)
                unmovedLegacyCredential = nil
            }
        } catch {
            connectState = .failed("Could not store the account in the keychain: \(error.localizedDescription)")
            return
        }
        accountLibrary = candidate
        saveIndex()
        refreshCredentials()
        accounts = accountLibrary.accounts
        if activeAccountID == nil || accountLibrary.account(activeAccountID ?? "")?.removed == true {
            // The first account (or the first after the last was removed).
            activate(primaryAccount?.id)
        } else if activeAccountID == adoption.account.id {
            state = currentRecord()
        }
        primaryChanged(from: primaryBefore)
        switch verification {
        case let .unconfirmed(message): accountStatuses[adoption.account.id] = .failed(message)
        default: accountStatuses[adoption.account.id] = .connected(email: email)
        }
        connectState = .idle
        showingSignIn = false
        let added = adoption.isNew && accounts.count > 1
        log(.account, added ? "Added \(email); its first backup waits for a storage check" : "Connected \(email)")
        if adoption.account.storageChecked { automaticRun(trigger: .signIn) }
    }

    /// Signs one account out: its credential leaves the keychain and runs
    /// stop going to it. The other accounts are not touched, and its record
    /// stays, so signing in to it again carries on where it left off.
    func removeAccount(_ id: String) async {
        if activeAccountID == id, engine.isActive || engine.phase == .paused {
            if id == primaryAccount?.id { cancelMessagesScan() }
            runner.stop()
            await engine.stopAndWait()
            guard !engine.isActive else {
                log(.account, "\(accountLibrary.account(id)?.title ?? "The account") was not removed: the backup to it is still stopping.", problem: true)
                return
            }
        }
        let primaryBefore = primaryAccount?.id
        let title = accountLibrary.account(id)?.title ?? "an account"
        keychain.delete(account: id)
        if id == unmovedLegacyCredential {
            keychain.delete(account: AccountLibrary.legacyKeychainAccount)
            unmovedLegacyCredential = nil
        }
        syncActiveRecord()
        accountLibrary.remove(id)
        saveIndex()
        refreshCredentials()
        accounts = accountLibrary.accounts
        accountStatuses[id] = nil
        if activeAccountID == id { activate(primaryAccount?.id) }
        primaryChanged(from: primaryBefore)
        log(.account, "Removed \(title)")
    }

    /// Every account; the snapshot bundle's tidy-up.
    func removeAllAccounts() async {
        for account in accounts { await removeAccount(account.id) }
    }

    /// The Messages cursor and scan are the primary account's: a new primary
    /// starts its Messages media from the first row. When the primary was
    /// removed, Messages media (opt-in: it holds other people's media too)
    /// is switched off rather than sent to an account nobody chose for it,
    /// and anything still queued for the old primary is dropped.
    private func primaryChanged(from previous: String?) {
        guard primaryAccount?.id != previous else { return }
        cancelMessagesScan()
        settings.messagesCursor = 0
        guard previous != nil, let primary = primaryAccount else { return }
        if settings.messagesMedia {
            settings.messagesMedia = false
            messagesStatus = .off
            log(.messages, "Messages media is off: it went to the account that was removed. Turn it on in Settings to send it to \(primary.title).")
        }
        if !engine.isActive, engine.hasQueuedPrimaryOnlyWork { engine.stop() }
        heldPicks = ([], [:])
    }

    /// Settings, history rows and the timeline name an account by address;
    /// the run history keeps only a reference to it.
    func accountTitle(reference: String?) -> String? {
        accountLibrary.account(reference: reference)?.title
    }

    /// After the storage check, an added account joins the runs.
    func confirmStorage(for id: String) {
        guard let account = accountLibrary.account(id), !account.storageChecked else { return }
        syncActiveRecord()
        accountLibrary.confirmStorage(id)
        saveIndex()
        accounts = accountLibrary.accounts
        log(.account, "Backups to \(account.title) start")
        startBackupNow(trigger: .manual)
    }

    func checkAccounts() async {
        for account in accounts {
            await checkAccount(account.id)
        }
    }

    func checkAccount(_ id: String) async {
        guard let auth = credential(for: id) else { accountStatuses[id] = .missing; return }
        accountStatuses[id] = .checking
        let verification = await verify(auth)
        // A sign-in may have replaced the credential while this one was
        // being checked; its result is not about the account stored now.
        guard credential(for: id) == auth else { return }
        switch verification {
        case let .accepted(email):
            if let email, GoogleSignIn.normalizedEmail(email) != id {
                refile(id, as: email)
            } else {
                accountStatuses[id] = .connected(email: email ?? accountLibrary.account(id)?.email)
            }
        case let .refused(message), let .unconfirmed(message):
            accountStatuses[id] = .failed(message)
        }
    }

    /// The credential kept under `id` is `email`'s: the legacy item without
    /// an address learns it, or a credential that was filed under the wrong
    /// account moves to its own. Never while a run uses it.
    private func refile(_ id: String, as email: String) {
        guard activeAccountID != id || (!engine.isActive && engine.phase != .paused) else {
            accountStatuses[id] = .connected(email: email)
            return
        }
        syncActiveRecord()
        var candidate = accountLibrary
        let target = candidate.credential(of: id, belongsTo: email)
        do {
            if keychain.load(account: target) != nil {
                // The account signed in on its own since: its credential is
                // the newer one.
                keychain.delete(account: id)
            } else {
                try keychain.move(from: id, to: target)
            }
        } catch {
            accountStatuses[id] = .failed("This sign-in is for \(email) and could not be filed under it: \(error.localizedDescription)")
            return
        }
        accountLibrary = candidate
        saveIndex()
        refreshCredentials()
        accounts = accountLibrary.accounts
        accountStatuses[id] = nil
        accountStatuses[target] = .connected(email: email)
        if activeAccountID == id {
            activeAccountID = target
            state = currentRecord()
        }
        log(.account, "A sign-in turned out to be \(email)'s and is kept for that account")
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

    #if DEBUG
    struct FixtureAccount {
        var email: String
        var status: AccountStatus
        var storageChecked = true
        /// nil keeps whatever record the fixture sets as `state` later.
        var record: BackupState?
    }

    /// Snapshot fixtures only: a library, accounts and a runtime to draw,
    /// without PhotoKit, the keychain, the disk or the bridge.
    func applyFixture(albums: [LibraryAlbum], accounts fixture: [FixtureAccount], runtime: String, messages: MessagesStatus = .off) {
        self.albums = albums
        albumsLoaded = true
        photosStatus = .authorized
        var library = AccountLibrary()
        library.select(fixture.compactMap(\.record).first?.selectedAlbumIDs ?? [])
        for item in fixture {
            let id = library.adopting(account: item.email, storageChecked: item.storageChecked).account.id
            if let record = item.record { library.update(record, for: id) }
        }
        accountLibrary = library
        accounts = library.accounts
        credentialAccounts = Set(fixture.filter { $0.status != .missing }.map { GoogleSignIn.normalizedEmail($0.email) })
        accountStatuses = Dictionary(fixture.map { (GoogleSignIn.normalizedEmail($0.email), $0.status) }, uniquingKeysWith: { first, _ in first })
        activeAccountID = accounts.first?.id
        accountSummaries = [:]
        state = currentRecord()
        runtimeDescription = runtime
        messagesStatus = messages
    }
    #endif

    // MARK: - Hooks for the engine and the archive

    /// Every run ends here: it joins the history, with the account it went
    /// to, and may notify.
    func runFinished(_ record: RunRecord) {
        var record = record
        if record.kind != .messagesArchive, let id = activeAccountID {
            record.account = AccountLibrary.reference(for: id)
            runner.finished(record.outcome, for: id)
        }
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
