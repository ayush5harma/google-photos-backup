import Foundation

/// accounts.json and each account's record file, side by side in the
/// support directory. Loading never writes: the caller saves the index once
/// the credential it files is safely in the keychain, so a crash between
/// the two only makes the next launch file it again.
public struct AccountsStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public var indexURL: URL { directory.appendingPathComponent("accounts.json") }

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

        /// Whether the index has to be written.
        public var indexChanged: Bool { migrated || legacyCredentialAccount != nil || !unreadable.isEmpty }
    }

    /// - Parameters:
    ///   - legacyCredential: whether the keychain item from before accounts
    ///     still exists, and the address inside it.
    public func load(legacyCredential: (exists: Bool, email: String?), now: Date = Date()) -> Loaded {
        var unreadable: [String: String] = [:]
        var library: AccountLibrary
        var migrated = false
        if let index = readIndex(&unreadable) {
            var states: [String: BackupState] = [:]
            for account in index.accounts {
                states[account.id] = readState(account.stateFile, &unreadable) ?? BackupState()
            }
            let referenced = index.accounts.contains { $0.stateFile == AccountLibrary.legacyStateFile }
            let unclaimed = referenced ? nil : readState(AccountLibrary.legacyStateFile, &unreadable)
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
        return Loaded(library: library, migrated: migrated, legacyCredentialAccount: legacyAccount, unreadable: unreadable)
    }

    public func save(_ index: AccountsIndex) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encoder.encode(index).write(to: indexURL, options: .atomic)
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

    private func readIndex(_ unreadable: inout [String: String]) -> AccountsIndex? {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return nil }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(AccountsIndex.self, from: Data(contentsOf: indexURL))
        } catch {
            // Rebuilt from state.json; every other account's record file
            // stays on disk under its id's name and is found again when that
            // account signs in.
            unreadable[indexURL.lastPathComponent] = error.localizedDescription
            setAside(indexURL)
            return nil
        }
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
