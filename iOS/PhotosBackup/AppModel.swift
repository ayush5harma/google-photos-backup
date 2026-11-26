import Foundation
import Observation
import Photos
import PhotosBackupCore
import UIKit

enum AppTab: String, CaseIterable, Identifiable {
    case overview, albums, activity, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .albums: "Albums"
        case .activity: "Activity"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .albums: "rectangle.stack"
        case .activity: "clock.arrow.circlepath"
        case .settings: "gear"
        }
    }
}

/// The pages under the Settings tab.
enum SettingsPage: Hashable {
    case account(String)
    case backup
    case whenToBackUp
    case notifications
    case advanced
    case about
}

enum AccountStatus: Equatable {
    case missing
    case checking
    case connected(email: String?)
    case failed(String)

    var isFailed: Bool {
        if case .failed = self { true } else { false }
    }
}

/// An attempt to connect an account by signing in.
enum ConnectState: Equatable {
    case idle
    case signingIn
    case connecting
    case failed(String)
}

/// The one object the views read: the library, the accounts and their
/// records, settings, and the engine seam. The account and record handling
/// is the Mac AppModel's (Sources/PhotosBackup/AppModel.swift) on the same
/// Core types, so accounts.json and state-<hash>.json mean the same on
/// both; the Mac-only sources (Messages, iCloud, connected devices) are left
/// out.
@MainActor
@Observable
final class AppModel {
    let library = PhotoLibrary()
    let conditions = ConditionsMonitor()
    let diagnostics: Diagnostics
    let isFixture: Bool
    @ObservationIgnored let notifier: Notifier
    /// The app is in front: a change in Photos starts a run only then; in
    /// the background the processing task does.
    @ObservationIgnored var isInFront = true
    /// An automatic run a condition held back; conditionsChanged starts it.
    @ObservationIgnored private var automaticRunHeld = false

    @ObservationIgnored private let accountsStore: AccountsStore
    @ObservationIgnored private let keychain = Keychain(service: AppEnvironment.keychainService)
    @ObservationIgnored private var accountLibrary = AccountLibrary()
    @ObservationIgnored private var accountSummaries: [String: (selection: Set<String>, summary: BackupSummary)] = [:]
    @ObservationIgnored private var summaryCache: BackupSummary?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private(set) var unlistedAlbums: [AlbumSnapshot] = []
    /// Set at the end of init: the engine reports back to the model.
    @ObservationIgnored private(set) var engine: (any BackupEngine)!

    /// Signed-in accounts in run order; the first is the primary.
    private(set) var accounts: [BackupAccount] = []
    private(set) var accountsChoice: AccountsChoice = .all
    /// Whose record `state` is: the primary. The engine changes any
    /// account's record through modifyRecord(of:_:), so no switch is needed.
    private(set) var activeAccountID: String?
    private(set) var accountStatuses: [String: AccountStatus] = [:]
    /// Accounts with a Keychain item, cached so drawing never queries it.
    private(set) var credentialAccounts: Set<String> = []

    private(set) var albums: [LibraryAlbum] = [] {
        didSet {
            summaryCache = nil
            accountSummaries = [:]
        }
    }
    private(set) var albumsLoaded = false
    private(set) var photosStatus: PHAuthorizationStatus
    var state = BackupState() {
        didSet { summaryCache = nil }
    }
    var settings: BackupSettings {
        didSet {
            guard !isFixture else { return }
            settings.save()
            let turnedOn = (settings.notifyWhenFinished && !oldValue.notifyWhenFinished)
                || (settings.notifyAboutProblems && !oldValue.notifyAboutProblems)
            if turnedOn { Task { await notifier.requestAuthorization() } }
        }
    }
    private(set) var connectState: ConnectState = .idle
    var showingSignIn = false
    var showingOnboarding = false
    var tab: AppTab = .overview
    /// The Settings tab's navigation, so a banner or a link can open a page.
    var settingsPath: [SettingsPage] = []
    private var saveFailure: String?
    private var launchNotice: String?
    var stateError: String? {
        let messages = [saveFailure, launchNotice].compactMap { $0 }
        return messages.isEmpty ? nil : messages.joined(separator: " ")
    }

    init(fixture: Bool = AppEnvironment.isFixture) {
        isFixture = fixture
        notifier = Notifier(enabled: !fixture)
        let support = AppEnvironment.supportDirectory
        accountsStore = AccountsStore(directory: support)
        if fixture {
            settings = BackupSettings()
            photosStatus = .authorized
            diagnostics = Diagnostics(directory: nil)
        } else {
            try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            settings = BackupSettings.load()
            photosStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            diagnostics = Diagnostics(directory: support)
            loadAccounts()
            StagingArea.clear()
        }
        let engine = NativeBackupEngine(model: self) { credential in
            GooglePhotosClient(credential: credential, endpoints: AppEnvironment.googleEndpoints)
        }
        engine.observer = BackgroundCoordinator.shared
        self.engine = engine
        if !fixture {
            // Here, not in launch(): a launch for a background task may have
            // no scene, so the root view's .task (launch) may never run, or
            // run after the task's handler (review finding 1). The handler
            // needs the model and the monitor from the first moment.
            BackgroundCoordinator.shared.attach(self)
            conditions.onChange = { [weak self] in self?.conditionsChanged() }
            conditions.start()
        }
        if let tab = AppEnvironment.requestedTab { self.tab = tab }
    }

    /// accounts.json and each account's record, as the Mac loads them. The
    /// iOS app never had a credential from before accounts, so there is no
    /// legacy item to move.
    private func loadAccounts() {
        let loaded = accountsStore.load(legacyCredential: (false, nil))
        accountLibrary = loaded.library
        var problems: [String] = []
        let records = loaded.unreadable.keys.filter { $0 != AccountsStore.indexFile && $0 != AccountsStore.indexCopyFile }
        if !records.isEmpty {
            problems.append("Backup history could not be read (\(records.sorted().joined(separator: ", "))); it was set aside with an .unreadable ending and those accounts start fresh.")
        }
        if loaded.indexRestored {
            problems.append("The accounts list could not be read, so the copy kept beside it was used; nothing about the accounts was lost.")
        }
        let (indexLost, chooseAgain) = adoptStrayCredentials(loaded: loaded)
        if chooseAgain {
            problems.append("The accounts list could not be read and was rebuilt. Nothing says which accounts backups went to, "
                + "so none is backed up until you choose them again in Settings > Accounts.")
        } else if indexLost {
            problems.append("The accounts list could not be read and was rebuilt from the accounts signed in on this device.")
        }
        launchNotice = problems.isEmpty ? nil : problems.joined(separator: " ")
        refreshCredentials()
        publishAccounts()
        activeAccountID = accountLibrary.primary?.id
        state = currentRecord()
        if loaded.indexChanged || indexLost || accountLibrary.index != loaded.library.index { saveIndex() }
        for account in accounts where credentialAccounts.contains(account.id) {
            accountStatuses[account.id] = .connected(email: account.email)
        }
        for problem in problems { log(.account, problem, problem: true) }
    }

    /// A Keychain item accounts.json does not show signed in (the index was
    /// lost): the credential says whose it is, and that account is signed in
    /// again with its record if one is on disk. The Mac's rule.
    private func adoptStrayCredentials(loaded: AccountsStore.Loaded) -> (lost: Bool, chooseAgain: Bool) {
        let items = keychain.accounts()
        let strays = items.filter { $0 != AccountLibrary.legacyKeychainAccount && accountLibrary.account($0)?.removed != false }
        let indexLost = loaded.indexWasLost(keychainHasAccountItems: !strays.isEmpty)
        let emails: [String] = strays.compactMap { id in
            guard let credential = keychain.load(account: id) else { return nil }
            let email = GoogleSignIn.email(inCredential: credential) ?? accountLibrary.account(id)?.email ?? (id.contains("@") ? id : nil)
            guard let email, GoogleSignIn.normalizedEmail(email) == id else { return nil }
            return email
        }
        let store = accountsStore
        let chooseAgain = accountLibrary.adoptingStrays(emails, indexLost: indexLost, credentials: Set(items),
                                                        stored: { store.readState($0) })
        return (indexLost, chooseAgain)
    }

    // MARK: - Accounts

    var primaryAccount: BackupAccount? { accounts.first }
    var hasAuthData: Bool { accounts.contains { credentialAccounts.contains($0.id) } }
    var account: AccountStatus { primaryAccount.map { status(of: $0.id) } ?? .missing }

    func status(of id: String) -> AccountStatus {
        accountStatuses[id] ?? (credentialAccounts.contains(id) ? .connected(email: accountLibrary.account(id)?.email) : .missing)
    }

    /// An account's own record, the active one's included.
    func record(of id: String) -> BackupState? {
        id == activeAccountID ? state : accountLibrary.state(for: id)
    }

    func credential(for id: String) -> String? {
        isFixture ? nil : keychain.load(account: id)
    }

    var runnableAccounts: [BackupAccount] {
        accounts.filter { $0.storageChecked && credentialAccounts.contains($0.id) }
    }

    func isIncluded(_ id: String) -> Bool {
        accounts.first { $0.id == id }.map { AccountLibrary.includes(accountsChoice, $0) } ?? false
    }

    var includedAccounts: [BackupAccount] { accounts.filter { AccountLibrary.includes(accountsChoice, $0) } }
    var targetAccounts: [BackupAccount] { runnableAccounts.filter { AccountLibrary.includes(accountsChoice, $0) } }
    var noAccountIncluded: Bool { !accounts.isEmpty && includedAccounts.isEmpty }
    var showsAccountChoice: Bool { accounts.count > 1 || includedAccounts.count < accounts.count }

    func chooseAccounts(_ choice: AccountsChoice) {
        guard choice != accountsChoice else { return }
        syncActiveRecord()
        accountLibrary.choose(choice)
        saveIndex()
        publishAccounts()
        log(.account, choice == .all ? "Backups go to all accounts" : "Backups go only to the accounts chosen in Settings")
    }

    func setIncluded(_ id: String, _ included: Bool) {
        guard let account = accountLibrary.account(id), !account.removed, isIncluded(id) != included else { return }
        syncActiveRecord()
        accountLibrary.include(id, included)
        saveIndex()
        publishAccounts()
        log(.account, included ? "\(account.title) is included in backups" : "\(account.title) is left out of backups")
    }

    /// After the storage check, an added account joins the runs.
    func confirmStorage(for id: String) {
        guard let account = accountLibrary.account(id), !account.storageChecked else { return }
        syncActiveRecord()
        accountLibrary.confirmStorage(id)
        saveIndex()
        publishAccounts()
        log(.account, "Backups to \(account.title) start")
        backUpNow(to: .only(id), trigger: .manual)
    }

    func storageCheck(for id: String) -> StorageCheck {
        StorageCheck(items: summary(of: id).pending, averageItemBytes: StorageCheck.averageItemBytes(in: diagnostics.runs),
                     quality: settings.quality)
    }

    func accountTitle(reference: String?) -> String? {
        accountLibrary.account(reference: reference)?.title
    }

    private func publishAccounts() {
        accounts = accountLibrary.accounts
        accountsChoice = accountLibrary.choice
    }

    private func syncActiveRecord() {
        accountLibrary.select(state.selectedAlbumIDs)
        if let id = activeAccountID, accountLibrary.account(id) != nil {
            accountLibrary.update(state, for: id)
            accountSummaries[id] = nil
        } else if accountLibrary.unclaimed != nil {
            accountLibrary.updateUnclaimed(state)
        }
    }

    private func currentRecord() -> BackupState {
        if let id = activeAccountID, let record = accountLibrary.state(for: id) { return record }
        var record = accountLibrary.unclaimed ?? BackupState()
        record.selectedAlbumIDs = accountLibrary.selection
        return record
    }

    private func refreshCredentials() {
        credentialAccounts = Set(keychain.accounts())
    }

    private func saveIndex() {
        guard !isFixture else { return }
        do {
            try accountsStore.save(accountLibrary.index)
        } catch {
            saveFailure = "Could not save the accounts list: \(error.localizedDescription)"
        }
    }

    // MARK: - Sign-in

    func beginSignIn() {
        if connectState != .connecting { connectState = .signingIn }
        showingSignIn = true
    }

    func cancelSignIn() {
        showingSignIn = false
        if connectState != .connecting { connectState = .idle }
    }

    /// The Embedded Setup cookie from the sign-in sheet, exchanged at once
    /// (it works once and expires within minutes). The token is passed on
    /// and dropped; it is never logged or stored.
    func signIn(oauthToken: String) async {
        guard connectState != .connecting else { return }
        connectState = .connecting
        do {
            let linked = try await GoogleAccountLink.link(oauthToken: oauthToken)
            connect(credential: linked.credential, email: linked.email)
        } catch {
            Log.account.error("Sign-in exchange failed")
            connectState = .failed(error.localizedDescription)
        }
    }

    /// The exchange itself is Google's answer that the account is good, so
    /// unlike the Mac (which also asks gpmc) nothing more is checked here.
    /// The address decides the account: a known one keeps its record, any
    /// other is added beside the accounts there are.
    private func connect(credential: String, email: String) {
        syncActiveRecord()
        var candidate = accountLibrary
        let store = accountsStore
        let adoption = candidate.adopting(account: email, stored: { store.readState($0) })
        do {
            try keychain.save(credential, account: adoption.account.id)
        } catch {
            connectState = .failed("Could not store the account in the Keychain: \(error.localizedDescription)")
            return
        }
        accountLibrary = candidate
        saveIndex()
        refreshCredentials()
        publishAccounts()
        if activeAccountID == nil || accountLibrary.account(activeAccountID ?? "")?.removed == true {
            activeAccountID = primaryAccount?.id
            state = currentRecord()
        } else if activeAccountID == adoption.account.id {
            state = currentRecord()
        }
        accountStatuses[adoption.account.id] = .connected(email: email)
        connectState = .idle
        showingSignIn = false
        let added = adoption.isNew && accounts.count > 1
        log(.account, added ? "Added \(email); its first backup waits for a storage check" : "Connected \(email)")
        if adoption.account.storageChecked { automaticRun(trigger: .signIn) }
    }

    #if DEBUG
    /// E2EHooks: the sign-in path after the exchange, with no network.
    func connectForTesting(credential: String, email: String) {
        connect(credential: credential, email: email)
    }
    #endif

    /// Signs one account out: its Keychain item goes and runs stop going to
    /// it. Its record stays, so signing in again carries on where it left off.
    func removeAccount(_ id: String) async {
        let title = accountLibrary.account(id)?.title ?? "an account"
        // The Mac's guard (review finding 2): a run going to this account
        // stops as a whole, and its Keychain item goes only once the run has
        // ended, so no lane keeps uploading with the removed sign-in.
        if engine.isSending(to: id) || (activeAccountID == id && (status.isActive || status.phase == .paused)) {
            await engine.stopAndWait()
            guard !engine.isSending(to: id), !status.isActive else {
                log(.account, "\(title) was not removed: the backup to it is still stopping.", problem: true)
                return
            }
        }
        if !isFixture {
            do {
                try keychain.delete(account: id)
            } catch {
                refreshCredentials()
                log(.account, "\(title) was not removed: its sign-in could not be deleted from the Keychain "
                    + "(\(error.localizedDescription)). Try Remove again.", problem: true)
                return
            }
        }
        syncActiveRecord()
        accountLibrary.remove(id)
        saveIndex()
        if !isFixture { refreshCredentials() } else { credentialAccounts.remove(id) }
        publishAccounts()
        accountStatuses[id] = nil
        if activeAccountID == id {
            activeAccountID = primaryAccount?.id
            state = currentRecord()
        }
        log(.account, "Removed \(title)")
    }

    // MARK: - Library and selection

    var canReadPhotos: Bool { photosStatus == .authorized || photosStatus == .limited }

    /// The scene's first appearance (the root view's .task): the work that
    /// needs a person looking. Background execution is set up in init.
    func launch() async {
        guard !isFixture else { return }
        log(.app, "Launched")
        await notifier.refresh()
        library.onChange = { [weak self] in self?.libraryChanged() }
        if library.isAuthorized { await connectLibrary() }
        #if DEBUG
        if await E2EHooks.apply(to: self) { return }
        #endif
        if !settings.onboardingCompleted { showingOnboarding = true }
        // A scene connected during a background launch is not the person
        // opening the app: the background task's own run takes that time.
        if isInFront, UIApplication.shared.applicationState != .background, !BackgroundCoordinator.shared.isAwaitingRun {
            automaticRun(trigger: .launch)
        }
    }

    /// The scene came to the front or left it.
    func sceneChanged(active: Bool) {
        guard !isFixture else { return }
        isInFront = active
        BackgroundCoordinator.shared.sceneChanged(active: active)
        if active { Task { await refreshPhotosStatus() } }
    }

    /// The processing task's run: an automatic one, held by the same
    /// conditions as any other.
    func backgroundRun() {
        Task { await reloadAlbums() }
        automaticRun(trigger: .background)
    }

    func requestPhotosAccess() async {
        photosStatus = await library.requestAccess()
        log(.photos, "Photos access: \(Self.describe(photosStatus))")
        if library.isAuthorized { await connectLibrary() }
    }

    /// The app came back to the front: access may have changed in Settings.
    func refreshPhotosStatus() async {
        guard !isFixture else { return }
        let now = library.status
        guard now != photosStatus else { return }
        photosStatus = now
        if library.isAuthorized { await connectLibrary() }
    }

    private func connectLibrary() async {
        photosStatus = library.status
        library.startObserving()
        await reloadAlbums()
        if state.selectedAlbumIDs.isEmpty, !albums.isEmpty {
            // First launch: start with the whole library, as the Mac does.
            state.selectedAlbumIDs = [PhotoLibrary.allPhotosID]
            saveState()
        }
    }

    func reloadAlbums() async {
        guard !isFixture, library.isAuthorized else { return }
        let listing = await PhotoLibrary.loadAlbums()
        unlistedAlbums = listing.unlisted
        albums = listing.albums
        albumsLoaded = true
    }

    /// Photos reports changes in bursts, so wait for it to settle; only
    /// while the app is in front (in the background the processing task runs).
    private func libraryChanged() {
        refreshTask?.cancel()
        refreshTask = Task {
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            await reloadAlbums()
            if isInFront { automaticRun(trigger: .libraryChange) }
        }
    }

    /// Only starts a run a condition held back, as the Mac's does: the
    /// first network report on every launch must not start one of its own.
    /// A background task waiting for its run gets it, under its own trigger.
    private func conditionsChanged() {
        guard automaticRunHeld || BackgroundCoordinator.shared.isAwaitingRun,
              conditions.blocking(for: settings) == nil else { return }
        automaticRunHeld = false
        automaticRun(trigger: BackgroundCoordinator.shared.isAwaitingRun ? .background : .conditions)
    }

    var selectedAlbums: [LibraryAlbum] { albums.filter { state.selectedAlbumIDs.contains($0.id) } }

    func toggle(_ album: LibraryAlbum) {
        if state.selectedAlbumIDs.contains(album.id) {
            state.selectedAlbumIDs.remove(album.id)
        } else {
            state.selectedAlbumIDs.insert(album.id)
        }
        saveState()
        if state.selectedAlbumIDs.contains(album.id) { automaticRun(trigger: .albumSelected) }
    }

    /// Writes the active account's record and, when the selection changed,
    /// the shared selection in accounts.json (selectedAlbumIDs), as the Mac does.
    func saveState() {
        guard !isFixture else { return }
        do {
            if let id = activeAccountID, let account = accountLibrary.account(id) {
                try accountsStore.save(state, file: account.stateFile)
            }
            if state.selectedAlbumIDs != accountLibrary.selection {
                accountLibrary.select(state.selectedAlbumIDs)
                try accountsStore.save(accountLibrary.index)
            }
            saveFailure = nil
        } catch {
            saveFailure = "Could not save the backup history: \(error.localizedDescription)"
        }
    }

    func progress(of album: LibraryAlbum) -> AlbumProgress {
        BackupPlanner.progress(of: album.snapshot, state: state, includingHidden: true)
    }

    var summary: BackupSummary {
        let albums = albums, state = state
        if let summaryCache { return summaryCache }
        let summary = BackupPlanner.summary(albums: albums.map(\.snapshot), state: state, includingHidden: true)
        summaryCache = summary
        return summary
    }

    /// The selection against one account's record. Hidden photos count for
    /// the primary only, as on the Mac: no other account is sent one.
    func summary(of id: String) -> BackupSummary {
        if id == activeAccountID { return summary }
        let albums = albums, selection = state.selectedAlbumIDs
        if let cached = accountSummaries[id], cached.selection == selection { return cached.summary }
        var record = accountLibrary.state(for: id) ?? BackupState()
        record.selectedAlbumIDs = selection
        let summary = BackupPlanner.summary(albums: albums.map(\.snapshot), state: record, includingHidden: false)
        accountSummaries[id] = (selection, summary)
        return summary
    }

    /// The selection against every account a run goes to, summed.
    var overallSummary: BackupSummary {
        let targets = targetAccounts
        if targets.isEmpty {
            let shown = accounts.isEmpty || includedAccounts.contains { $0.id == activeAccountID }
            return shown ? summary : BackupSummary(backedUp: 0, pending: 0, selectedAlbums: summary.selectedAlbums)
        }
        if targets.count == 1, targets[0].id == activeAccountID { return summary }
        let each = targets.map { summary(of: $0.id) }
        return BackupSummary(backedUp: each.reduce(0) { $0 + $1.backedUp }, pending: each.reduce(0) { $0 + $1.pending },
                             selectedAlbums: summary.selectedAlbums)
    }

    var leadingSummary: BackupSummary {
        let targets = targetAccounts
        if targets.isEmpty || targets.contains(where: { $0.id == activeAccountID }) { return summary }
        return summary(of: targets[0].id)
    }

    /// One account's upload history; the next backup checks everything again.
    func resetHistory(of id: String) {
        changeRecord(of: id) { $0 = $0.clearingHistory() }
        log(.account, "\(accountLibrary.account(id)?.title ?? "An account")'s backups will be checked again")
    }

    func forgetAlbumLinks(of id: String) {
        changeRecord(of: id) { $0.mirrors = [:] }
        log(.account, "\(accountLibrary.account(id)?.title ?? "An account")'s album links were forgotten")
    }

    /// Changes one account's record in memory, active or not, as a run going
    /// to several accounts at once does; saveRecord(of:) writes it. nil when
    /// the account has no record.
    @discardableResult
    func modifyRecord<T>(of id: String, _ change: (inout BackupState) -> T) -> T? {
        if id == activeAccountID { return change(&state) }
        guard let result = accountLibrary.modifyState(for: id, change) else { return nil }
        accountSummaries[id] = nil
        return result
    }

    /// Writes one account's record, as saveState() writes the active one's.
    func saveRecord(of id: String) {
        if id == activeAccountID { return saveState() }
        guard !isFixture, let account = accountLibrary.account(id), let record = accountLibrary.storedState(for: id) else { return }
        do {
            try accountsStore.save(record, file: account.stateFile)
        } catch {
            saveFailure = "Could not save the backup history: \(error.localizedDescription)"
        }
    }

    private func changeRecord(of id: String, _ change: (inout BackupState) -> Void) {
        if id == activeAccountID {
            change(&state)
            return saveState()
        }
        guard let account = accountLibrary.account(id), var record = accountLibrary.storedState(for: id) else { return }
        change(&record)
        accountLibrary.update(record, for: id)
        accountSummaries[id] = nil
        guard !isFixture else { return }
        do {
            try accountsStore.save(record, file: account.stateFile)
        } catch {
            saveFailure = "Could not save the backup history: \(error.localizedDescription)"
        }
    }

    // MARK: - Backing up (through the engine seam)

    var status: BackupEngineStatus { engine.status }

    /// - Parameter overridingConditions: nil means the trigger's own rule:
    ///   Back Up Now in the app goes ahead whatever "When to back up" says.
    func backUpNow(to destination: BackupDestination = .chosen, trigger: RunTrigger = .manual, overridingConditions: Bool? = nil) {
        engine.backUpNow(to: destination, trigger: trigger, overridingConditions: overridingConditions ?? trigger.overridesConditions)
    }

    /// An automatic run: only with automatic backups on, someone signed in,
    /// Photos readable and nothing holding it.
    func automaticRun(trigger: RunTrigger) {
        guard settings.automatic, settings.onboardingCompleted, hasAuthData, canReadPhotos, !status.isActive else { return }
        if let reason = conditions.blocking(for: settings, startedByPerson: trigger.overridesConditions), !trigger.overridesConditions {
            automaticRunHeld = true
            return log(.run, "Automatic backup waits: \(reason.title)")
        }
        engine.backUpNow(to: .chosen, trigger: trigger, overridingConditions: trigger.overridesConditions)
    }

    func pause() { engine.pause() }
    func resume() { engine.resume() }
    func stop() { engine.stop() }
    func retryFailed() { engine.retryFailed() }

    func finishOnboarding() {
        settings.onboardingCompleted = true
        showingOnboarding = false
        automaticRun(trigger: .launch)
    }

    // MARK: - Diagnostics

    func clearActivity() {
        diagnostics.clearActivity()
        log(.app, "Activity was cleared")
    }

    func report() -> String {
        var snapshot = DiagnosticSnapshot()
        snapshot.appVersion = AppEnvironment.version
        snapshot.macOSVersion = "iOS " + ProcessInfo.processInfo.operatingSystemVersionString
        snapshot.uploader = "Native client (gpmc 0.9.0 protocol)"
        snapshot.settings = [
            .init("Quality", settings.quality.title),
            .init("Recreate albums", onOff(settings.mirrorAlbums)),
            .init("Back up automatically", onOff(settings.automatic)),
            .init("Upload edited photos again", onOff(settings.reuploadEdits)),
            .init("Wi-Fi only", onOff(settings.pauseOnExpensiveNetwork)),
            .init("Pause in Low Data Mode", onOff(settings.pauseInLowDataMode)),
            .init("Only while charging", onOff(settings.pauseOnBattery)),
            .init("Pause in Low Power Mode", onOff(settings.pauseInLowPowerMode)),
            .init("Selected albums", "\(state.selectedAlbumIDs.count)"),
        ]
        switch account {
        case .missing: snapshot.accountStatus = "Not signed in"
        case .checking: snapshot.accountStatus = "Checking"
        case let .connected(email):
            snapshot.accountStatus = "Connected"
            snapshot.account = email
        case let .failed(message): snapshot.accountStatus = "Problem: \(message)"
        }
        snapshot.account = snapshot.account ?? primaryAccount?.email
        if accounts.count > 1 {
            snapshot.accountStatus += " (primary; \(accounts.count - 1) more account\(accounts.count == 2 ? "" : "s"))"
        }
        snapshot.photosAccess = switch photosStatus {
        case .authorized: .full
        case .limited: .limited
        case .denied: .denied
        case .restricted: .restricted
        default: .notDetermined
        }
        snapshot.automaticBackups = settings.automatic
        snapshot.backedUp = summary.backedUp
        snapshot.pending = summary.pending
        snapshot.failed = status.failedCount
        snapshot.runActive = status.isActive
        snapshot.conditions = conditions.summary
        snapshot.holding = status.waitReason
        snapshot.lastError = status.lastError ?? stateError ?? diagnostics.saveError
        return diagnostics.report(snapshot)
    }

    private func onOff(_ value: Bool) -> String { value ? "On" : "Off" }

    static func describe(_ status: PHAuthorizationStatus) -> String {
        switch status {
        case .authorized: "full library"
        case .limited: "limited to chosen photos"
        case .denied: "denied"
        case .restricted: "restricted"
        default: "not asked yet"
        }
    }

    // MARK: - Fixture

    #if DEBUG
    struct FixtureAccount {
        var email: String
        var status: AccountStatus
        var storageChecked = true
        var included = true
        var record: BackupState?
    }

    /// Fixture mode only: a library, accounts, records, a run and activity
    /// to draw, without PhotoKit, the Keychain, the disk or the network.
    func applyFixture(albums: [LibraryAlbum], accounts fixture: [FixtureAccount], choice: AccountsChoice,
                      engine fixtureEngine: BackupEngineStatus, runs: [RunRecord], events: [(EventCategory, String, Bool)]) {
        self.albums = albums
        albumsLoaded = true
        photosStatus = .authorized
        var library = AccountLibrary()
        library.select(fixture.compactMap(\.record).first?.selectedAlbumIDs ?? [])
        for item in fixture {
            let id = library.adopting(account: item.email, storageChecked: item.storageChecked).account.id
            if let record = item.record { library.update(record, for: id) }
        }
        library.choose(choice)
        for item in fixture { library.include(GoogleSignIn.normalizedEmail(item.email), item.included) }
        accountLibrary = library
        publishAccounts()
        credentialAccounts = Set(fixture.filter { $0.status != .missing }.map { GoogleSignIn.normalizedEmail($0.email) })
        accountStatuses = Dictionary(fixture.map { (GoogleSignIn.normalizedEmail($0.email), $0.status) }, uniquingKeysWith: { first, _ in first })
        activeAccountID = accounts.first?.id
        accountSummaries = [:]
        state = currentRecord()
        engine = FixtureBackupEngine(status: fixtureEngine)
        for run in runs { diagnostics.record(run) }
        for (category, message, problem) in events { diagnostics.log(category, message, problem: problem) }
        var settings = BackupSettings()
        settings.onboardingCompleted = true
        self.settings = settings
        conditions.use(network: NetworkConditions(online: true, expensive: false, constrained: false, interface: .wifi),
                       power: PowerConditions(onBattery: false, lowPowerMode: false))
    }
    #endif
}

extension AppModel: BackupEngineHost {
    /// A line in the event timeline (never a token; addresses are masked by
    /// Redactor on the way in).
    func log(_ category: EventCategory, _ message: String, problem: Bool = false) {
        diagnostics.log(category, message, problem: problem)
        if problem { notifier.problem(Redactor().redact(message), category: category, settings: settings) }
    }

    func runFinished(_ record: RunRecord, account: String?) {
        var record = record
        if let id = account ?? activeAccountID { record.account = AccountLibrary.reference(for: id) }
        diagnostics.record(record)
        notifier.runFinished(record, settings: settings)
    }
}
