import Foundation

/// accounts.json and each account's record file, side by side in the
/// support directory. Loading never writes the index or a record: the caller
/// saves the index once the credential it files is safely in the keychain,
/// so a crash between the two only makes the next launch file it again.
/// (It does move an unreadable file aside, never to be read back.)
public struct AccountsStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static let indexFile = "accounts.json"
    /// The index as last written in full, beside it. Rebuilding a lost index
    /// from state.json cannot know which accounts backups went to or which
    /// passed their storage check (PR #53 review), so a damaged or missing
    /// accounts.json is read from here first.
    public static let indexCopyFile = "accounts.json.bak"

    public var indexURL: URL { directory.appendingPathComponent(Self.indexFile) }
    public var indexCopyURL: URL { directory.appendingPathComponent(Self.indexCopyFile) }

    public func url(of file: String) -> URL { directory.appendingPathComponent(file) }

    public struct Loaded: Equatable, Sendable {
        public var library: AccountLibrary
        /// There was no accounts.json: the library was made from state.json.
        public var migrated: Bool
        /// The account the legacy keychain item belongs under, when it exists.
        public var legacyCredentialAccount: String?
        /// Files that could not be read, renamed `.unreadable` for inspection,
        /// with the reason; their accounts start from an empty record.
        public var unreadable: [String: String]
        /// Accounts whose record file (state.json) turned out to hold another
        /// account's history; they carry on in a file of their own.
        public var reassigned: [String] = []
        /// accounts.json could not be used and its copy was: nothing about
        /// the accounts was lost.
        public var indexRestored = false
        /// accounts.json was there and could not be used, nor could its
        /// copy: the library was rebuilt from state.json, so nothing says
        /// which accounts backups went to or which passed their storage check.
        public var indexLost = false

        /// Whether the index has to be written.
        public var indexChanged: Bool {
            migrated || legacyCredentialAccount != nil || !unreadable.isEmpty || !reassigned.isEmpty || indexRestored
        }

        /// Whether the accounts whose credentials the keychain holds were
        /// listed in an index that is gone: it could not be read, or there is
        /// none while the keychain holds items of accounts (a Mac upgrading
        /// from one account has only the legacy item).
        public func indexWasLost(keychainHasAccountItems: Bool) -> Bool {
            indexLost || (migrated && keychainHasAccountItems)
        }
    }

    /// - Parameters:
    ///   - legacyCredential: whether the keychain item from before accounts
    ///     still exists, and the address inside it.
    public func load(legacyCredential: (exists: Bool, email: String?), now: Date = Date()) -> Loaded {
        var unreadable: [String: String] = [:]
        var library: AccountLibrary
        var migrated = false
        var reassigned: [String] = []
        var indexRestored = false
        var indexLost = false
        if var index = readIndex(&unreadable, restored: &indexRestored, lost: &indexLost, now: now) {
            var states: [String: BackupState] = [:]
            var unclaimed: BackupState?
            for position in index.accounts.indices {
                let account = index.accounts[position]
                let state = readState(account.stateFile, &unreadable)
                if let state, let owner = state.accountEmail, account.id != AccountLibrary.legacyKeychainAccount,
                   !GoogleSignIn.sameAccount(owner, account.email ?? account.id), account.stateFile == AccountLibrary.legacyStateFile {
                    // state.json holds another account's history: an older
                    // version, signed in to that account after a downgrade,
                    // rewrote it. It is that account's (unclaimed until it
                    // signs in); this account carries on in a file of its own.
                    reassigned.append(account.title)
                    unclaimed = state
                    index.accounts[position].stateFile = AccountLibrary.stateFile(for: account.id)
                    states[account.id] = readState(index.accounts[position].stateFile, &unreadable) ?? BackupState()
                    continue
                }
                states[account.id] = state ?? BackupState()
            }
            let referenced = index.accounts.contains { $0.stateFile == AccountLibrary.legacyStateFile }
            if unclaimed == nil, !referenced { unclaimed = readState(AccountLibrary.legacyStateFile, &unreadable) }
            library = AccountLibrary(index: index, states: states, unclaimed: unclaimed)
        } else {
            let legacy = readState(AccountLibrary.legacyStateFile, &unreadable)
            library = .migrating(legacy: legacy, credentialEmail: legacyCredential.email,
                                 hasCredential: legacyCredential.exists, now: now)
            migrated = true
        }
        var legacyAccount: String?
        if legacyCredential.exists {
            legacyAccount = migrated
                ? library.fileLegacyCredential(email: legacyCredential.email, now: now)
                : library.fileLegacyCredential(email: legacyCredential.email, now: now, stored: { readState($0) })
        }
        return Loaded(library: library, migrated: migrated, legacyCredentialAccount: legacyAccount, unreadable: unreadable,
                      reassigned: reassigned, indexRestored: indexRestored, indexLost: indexLost)
    }

    public func save(_ index: AccountsIndex) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(index)
        try data.write(to: indexURL, options: .atomic)
        // Only after the index itself, so the copy is always an index that
        // was written in full.
        try data.write(to: indexCopyURL, options: .atomic)
    }

    /// Written exactly as BackupStore always wrote state.json.
    public func save(_ state: BackupState, file: String) throws {
        try BackupStore(url: url(of: file)).save(state)
    }

    /// An account's record file, nil when there is none or it cannot be read.
    public func readState(_ file: String) -> BackupState? {
        let url = url(of: file)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? BackupStore(url: url).load()
    }

    private func readState(_ file: String, _ unreadable: inout [String: String]) -> BackupState? {
        let url = url(of: file)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try BackupStore(url: url).load()
        } catch {
            unreadable[file] = error.localizedDescription
            setAside(url)
            return nil
        }
    }

    /// accounts.json, else its copy. With neither usable the library is
    /// rebuilt from state.json; every other account's record file stays on
    /// disk under its id's name and is found again when that account signs in.
    private func readIndex(_ unreadable: inout [String: String], restored: inout Bool, lost: inout Bool,
                           now: Date) -> AccountsIndex? {
        let fileManager = FileManager.default
        var damaged = false
        if fileManager.fileExists(atPath: indexURL.path) {
            do {
                return try Self.decodeIndex(at: indexURL)
            } catch {
                unreadable[Self.indexFile] = error.localizedDescription
                setAside(indexURL)
                damaged = true
            }
        }
        guard fileManager.fileExists(atPath: indexCopyURL.path) else {
            lost = damaged
            return nil
        }
        do {
            let index = try Self.decodeIndex(at: indexCopyURL)
            // Set aside, but nothing is lost: not reported as unreadable.
            unreadable[Self.indexFile] = nil
            restored = true
            return index
        } catch {
            unreadable[Self.indexCopyFile] = error.localizedDescription
            setAside(indexCopyURL)
            lost = true
            return nil
        }
    }

    private static func decodeIndex(at url: URL) throws -> AccountsIndex {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AccountsIndex.self, from: Data(contentsOf: url))
    }

    private func setAside(_ url: URL) {
        let aside = url.appendingPathExtension("unreadable")
        try? FileManager.default.removeItem(at: aside)
        try? FileManager.default.moveItem(at: url, to: aside)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return encoder
    }()
}

/// What backing up the selection to an added account asks of its storage,
/// shown before its first run. Google's free-storage figure is not part of
/// it: gpmc 0.9.0 has no call for an account's quota, so the check links to
/// Google's own storage page for the account instead.
public struct StorageCheck: Equatable, Sendable {
    /// Selected items the account does not have yet.
    public let items: Int
    /// The average size of items this Mac has uploaded, from the run
    /// history; nil before anything was uploaded.
    public let averageItemBytes: Int64?
    public let quality: UploadQuality

    public init(items: Int, averageItemBytes: Int64?, quality: UploadQuality) {
        self.items = items
        self.averageItemBytes = averageItemBytes
        self.quality = quality
    }

    public var estimatedBytes: Int64? { averageItemBytes.map { $0 * Int64(items) } }

    /// Only "Original quality, uses storage" commits as a device whose
    /// uploads count; the Pixel XL and Pixel 2 profiles do not.
    public var countsAgainstStorage: Bool { quality == .quota }

    /// Bytes sent per item uploaded, across the runs in the history.
    public static func averageItemBytes(in history: [RunRecord]) -> Int64? {
        let runs = history.filter { $0.kind != .messagesArchive && $0.uploaded > 0 && $0.bytes > 0 }
        let items = runs.reduce(0) { $0 + $1.uploaded }
        guard items > 0 else { return nil }
        return runs.reduce(Int64(0)) { $0 + $1.bytes } / Int64(items)
    }

    /// Google One's storage page, opened as this account.
    public static func storagePage(for email: String) -> URL {
        // "+" stays literal in a query and would reach Google as a space.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "@._-"))
        let user = email.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return URL(string: "https://one.google.com/storage?authuser=\(user)") ?? URL(string: "https://one.google.com/storage")!
    }
}
