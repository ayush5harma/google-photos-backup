import Foundation
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

    private static let key = "settings"

    static func load() -> BackupSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(BackupSettings.self, from: data) else { return BackupSettings() }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

struct AppPaths {
    let state: URL
    let logs: URL
    let staging: URL

    var bridgeLog: URL { logs.appendingPathComponent("bridge.log") }

    static let standard: AppPaths = {
        let files = FileManager.default
        let name = Bundle.main.bundleIdentifier ?? "PhotosBackup"
        let support = files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(name, isDirectory: true)
        let caches = files.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(name, isDirectory: true)
        return AppPaths(state: support.appendingPathComponent("state.json"),
                        logs: support.appendingPathComponent("Logs", isDirectory: true),
                        staging: caches.appendingPathComponent("Staging", isDirectory: true))
    }()
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

    private(set) var albums: [LibraryAlbum] = []
    private(set) var albumsLoaded = false
    private(set) var photosStatus: PHAuthorizationStatus
    var state: BackupState
    var stateError: String?
    var settings: BackupSettings { didSet { settings.save() } }
    private(set) var account: AccountStatus = .missing
    private(set) var connectState: ConnectState = .idle
    var showingSignIn = false
    /// Whether the keychain holds auth_data, cached so that drawing a view
    /// never queries the keychain (which can prompt after a re-sign).
    private(set) var hasAuthData = false
    private(set) var runtimeDescription = "Checking..."
    @ObservationIgnored lazy var engine = BackupEngine(model: self)

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

    var summary: BackupSummary { BackupPlanner.summary(albums: albums.map(\.snapshot), state: state) }

    var selectedAlbums: [LibraryAlbum] { albums.filter { state.selectedAlbumIDs.contains($0.id) } }

    func progress(of album: LibraryAlbum) -> AlbumProgress { BackupPlanner.progress(of: album.snapshot, state: state) }

    // MARK: - Lifecycle

    func launch() async {
        library.onChange = { [weak self] in self?.libraryChanged() }
        await checkRuntime()
        if library.isAuthorized { await connectLibrary() }
        if case .connected = account { await checkAccount() }
        timer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.automaticRun() }
        }
        automaticRun()
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
            automaticRun()
        }
    }

    func automaticRun() {
        guard settings.automatic, library.isAuthorized, hasAuthData, engine.phase == .idle else { return }
        #if DEBUG
        if Snapshots.isRequested { return }
        #endif
        engine.start()
    }

    // MARK: - State

    func toggle(_ album: LibraryAlbum) {
        if state.selectedAlbumIDs.contains(album.id) {
            state.selectedAlbumIDs.remove(album.id)
        } else {
            state.selectedAlbumIDs.insert(album.id)
        }
        saveState()
        if state.selectedAlbumIDs.contains(album.id) { automaticRun() }
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
        let previous = state.accountEmail ?? authData.flatMap(GoogleSignIn.email(inCredential:))
        let switching = email.map { new in previous.map { !GoogleSignIn.sameAccount($0, new) } ?? false } ?? false
        if switching {
            // Let the running backup finish with the old account first, or
            // its last items would be recorded against the new one.
            await engine.stopAndWait()
            guard !engine.isActive else {
                connectState = .failed("The backup is still stopping. Sign in again in a moment.")
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
        automaticRun()
    }

    func removeAuthData() {
        engine.stop()
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

    static func describe(_ kind: FatalKind, _ message: String) -> String {
        switch kind {
        case .auth: "Google refused the account (\(message)). Sign in again in Settings."
        case .network: "Google could not be reached (\(message)). The next run retries."
        case .request: "The app sent the uploader a bad request: \(message)"
        case .internal, .unknown: "The uploader failed: \(message)"
        }
    }
}
