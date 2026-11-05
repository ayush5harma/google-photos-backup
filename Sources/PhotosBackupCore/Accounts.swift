import CryptoKit
import Foundation

/// One Google account the library is backed up to.
public struct BackupAccount: Codable, Equatable, Sendable, Identifiable {
    /// The account attribute of its keychain item and the key of its
    /// records: the normalized address, or `AccountLibrary.legacyKeychainAccount`
    /// for a credential from before accounts whose address is not known yet.
    public var id: String
    /// As Google spells it; nil only for that legacy credential.
    public var email: String?
    /// Its BackupState, a file name in the support directory.
    public var stateFile: String
    public var addedAt: Date
    /// Runs skip an account added next to another until someone has looked
    /// at what the selection needs there: a free 15 GB account fills up fast
    /// when uploads count against storage.
    public var storageChecked: Bool
    /// Signed out with Remove. Kept rather than deleted, so signing in again
    /// finds its records and album links instead of creating every album anew.
    public var removed: Bool
    /// "Include in backups" is ticked. Read only while backups go to
    /// `AccountsChoice.chosen` accounts; with `.all` every account is in.
    public var chosen: Bool

    public init(id: String, email: String?, stateFile: String, addedAt: Date, storageChecked: Bool, removed: Bool = false,
                chosen: Bool = false) {
        self.id = id
        self.email = email
        self.stateFile = stateFile
        self.addedAt = addedAt
        self.storageChecked = storageChecked
        self.removed = removed
        self.chosen = chosen
    }

    private enum CodingKeys: String, CodingKey {
        case id, email, stateFile, addedAt, storageChecked, removed, chosen
    }

    /// An accounts.json from before the choice has no `chosen`; nothing
    /// was chosen then, and every account was backed up.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        email = try container.decodeIfPresent(String.self, forKey: .email)
        stateFile = try container.decode(String.self, forKey: .stateFile)
        addedAt = try container.decode(Date.self, forKey: .addedAt)
        storageChecked = try container.decode(Bool.self, forKey: .storageChecked)
        removed = try container.decode(Bool.self, forKey: .removed)
        chosen = try container.decodeIfPresent(Bool.self, forKey: .chosen) ?? false
    }

    /// The address for people to read.
    public var title: String { email ?? "Google account" }
}

/// Which accounts a backup goes to when nobody names one: Back Up Now,
/// automatic runs and photosbackup://backup.
public enum AccountsChoice: String, Codable, Equatable, Sendable, CaseIterable {
    /// Every signed-in account, an account added later included.
    case all
    /// Only the accounts whose "Include in backups" is ticked.
    case chosen
}

/// What `accounts.json` holds: the accounts in the order runs visit them,
/// the album selection they share, and which of them backups go to.
public struct AccountsIndex: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version = AccountsIndex.currentVersion
    public var accounts: [BackupAccount] = []
    public var selectedAlbumIDs: Set<String> = []
    public var backUpTo: AccountsChoice = .all

    public init(accounts: [BackupAccount] = [], selectedAlbumIDs: Set<String> = [], backUpTo: AccountsChoice = .all) {
        self.accounts = accounts
        self.selectedAlbumIDs = selectedAlbumIDs
        self.backUpTo = backUpTo
    }

    private enum CodingKeys: String, CodingKey {
        case version, accounts, selectedAlbumIDs, backUpTo
    }

    /// The choice is an addition older files lack: they back up to every
    /// account, as they always did. An older build reading a newer file
    /// ignores the key, so the version stays 1.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        accounts = try container.decode([BackupAccount].self, forKey: .accounts)
        selectedAlbumIDs = try container.decode(Set<String>.self, forKey: .selectedAlbumIDs)
        if let raw = try container.decodeIfPresent(String.self, forKey: .backUpTo) {
            // A choice only a newer version knows: the ticked accounts, never
            // more, rather than setting the whole list aside as unreadable.
            backUpTo = AccountsChoice(rawValue: raw) ?? .chosen
        } else {
            backUpTo = .all
        }
    }
}

/// Every account's backup record, in memory. An account's record is only
/// ever selected or created, never replaced by another's: each account's
/// media keys and albums exist only in that account, and losing its album
/// links would make the next run create every album again as a duplicate.
public struct AccountLibrary: Equatable, Sendable {
    /// The keychain account attribute of the one credential kept before
    /// there were accounts.
    public static let legacyKeychainAccount = "gpmc"
    /// The record from before there were accounts. Never moved: it stays
    /// the record of the account it belongs to, so its bytes are that
    /// account's state, and an older version of the app still finds it.
    public static let legacyStateFile = "state.json"

    public private(set) var index: AccountsIndex
    /// By account id, removed accounts included.
    private var states: [String: BackupState]
    /// state.json when nobody is known to own it: history recorded before
    /// accounts were, whose credential is gone. The first account to sign in
    /// takes it, as signing in did before.
    public private(set) var unclaimed: BackupState?

    public init(index: AccountsIndex = AccountsIndex(), states: [String: BackupState] = [:], unclaimed: BackupState? = nil) {
        self.index = index
        self.states = states
        self.unclaimed = unclaimed
    }

    /// Signed-in accounts, in run order.
    public var accounts: [BackupAccount] { index.accounts.filter { !$0.removed } }
    /// The first account: it also takes what only one account can have
    /// (Messages media, picked photos, device imports, iCloud).
    public var primary: BackupAccount? { accounts.first }
    public var selection: Set<String> { index.selectedAlbumIDs }

    // MARK: - Which accounts backups go to

    /// Which accounts a backup that names none goes to.
    public var choice: AccountsChoice { index.backUpTo }

    /// Whether a backup that names no account goes to this one: any
    /// signed-in account with "All accounts", a ticked one otherwise.
    public func isIncluded(_ id: String) -> Bool {
        account(id).map { Self.includes(index.backUpTo, $0) } ?? false
    }

    /// The signed-in accounts a backup that names none goes to, in run order.
    public var included: [BackupAccount] { accounts.filter { Self.includes(index.backUpTo, $0) } }

    /// "Back up to". Choosing accounts starts with every signed-in account
    /// ticked, so switching alone changes nothing until one is unticked.
    public mutating func choose(_ choice: AccountsChoice) {
        guard choice != index.backUpTo else { return }
        if choice == .chosen {
            for account in accounts { setChosen(account.id, true) }
        }
        index.backUpTo = choice
    }

    /// One account's "Include in backups". Unticking an account while
    /// backups go to all of them switches to choosing, with every other
    /// account kept: "All accounts" then no longer holds, and an account
    /// added later waits to be ticked.
    public mutating func include(_ id: String, _ included: Bool) {
        guard let account = account(id), !account.removed else { return }
        if index.backUpTo == .all {
            guard !included else { return }
            choose(.chosen)
        }
        setChosen(account.id, included)
    }

    /// The rule, for a copy of the account list kept elsewhere (the app's
    /// observable one).
    public static func includes(_ choice: AccountsChoice, _ account: BackupAccount) -> Bool {
        !account.removed && (choice == .all || account.chosen)
    }

    public func account(_ id: String) -> BackupAccount? {
        index.accounts.first { $0.id == id }
    }

    /// The account for this address, signed in or removed.
    public func account(matching email: String) -> BackupAccount? {
        let id = GoogleSignIn.normalizedEmail(email)
        return index.accounts.first { $0.id == id || $0.email.map { GoogleSignIn.sameAccount($0, email) } == true }
    }

    /// The account's record with the shared selection; nil for an id the
    /// library does not know.
    public func state(for id: String) -> BackupState? {
        guard var state = states[id] else { return nil }
        state.selectedAlbumIDs = index.selectedAlbumIDs
        return state
    }

    /// The record as last kept, selection included, for writing it back.
    public func storedState(for id: String) -> BackupState? { states[id] }

    // MARK: - Migration

    /// The library for a Mac that has only the single-account record and
    /// credential. state.json becomes, untouched, the record of the account
    /// it belongs to: the one recorded in it or, for history from before
    /// accounts were recorded, the one whose credential wrote it (the rule
    /// signing in always used).
    ///
    /// - Parameters:
    ///   - legacy: state.json, if there is one.
    ///   - credentialEmail: the address inside the stored credential.
    ///   - hasCredential: whether the legacy keychain item exists.
    public static func migrating(legacy: BackupState?, credentialEmail: String?, hasCredential: Bool, now: Date = Date()) -> AccountLibrary {
        var library = AccountLibrary(index: AccountsIndex(selectedAlbumIDs: legacy?.selectedAlbumIDs ?? []))
        let credentialEmail = hasCredential ? credentialEmail : nil
        if let legacy {
            if let owner = legacy.accountEmail ?? credentialEmail {
                let id = GoogleSignIn.normalizedEmail(owner)
                library.index.accounts.append(BackupAccount(id: id, email: owner, stateFile: legacyStateFile, addedAt: now,
                                                            storageChecked: true, removed: true))
                library.states[id] = legacy
            } else if hasCredential {
                // Neither the record nor the credential names the account.
                // The record goes with the credential, which keeps the legacy
                // keychain item until Google says whose it is.
                library.index.accounts.append(BackupAccount(id: legacyKeychainAccount, email: nil, stateFile: legacyStateFile,
                                                            addedAt: now, storageChecked: true, removed: true))
                library.states[legacyKeychainAccount] = legacy
            } else {
                library.unclaimed = legacy
            }
        }
        if hasCredential {
            _ = library.fileLegacyCredential(email: credentialEmail, now: now)
        }
        return library
    }

    /// Where the legacy keychain item belongs, which marks that account
    /// signed in: the account its address names, else the account of the
    /// record it has always gone with, else (no address anywhere) the
    /// legacy item's own placeholder account until a check with Google
    /// names it. The Mac was already backing up to it, so no storage check.
    /// - Returns: the account id to store the credential under.
    public mutating func fileLegacyCredential(email: String?, now: Date = Date(),
                                              stored: (String) -> BackupState? = { _ in nil }) -> String {
        if let email {
            return adopting(account: email, now: now, storageChecked: true, stored: stored).account.id
        }
        if let only = index.accounts.first(where: { $0.stateFile == Self.legacyStateFile }) {
            setRemoved(only.id, false)
            return only.id
        }
        let id = Self.legacyKeychainAccount
        if account(id) == nil {
            let takesUnclaimed = unclaimed != nil && unclaimed?.accountEmail == nil
            let file = takesUnclaimed || (unclaimed == nil && !isFileTaken(Self.legacyStateFile))
                ? Self.legacyStateFile : Self.stateFile(for: id)
            index.accounts.append(BackupAccount(id: id, email: nil, stateFile: file, addedAt: now, storageChecked: true,
                                                chosen: accounts.isEmpty))
            states[id] = takesUnclaimed ? unclaimed : BackupState()
            if takesUnclaimed { unclaimed = nil }
        }
        setRemoved(id, false)
        return id
    }

    // MARK: - Signing in and out

    public struct Adoption: Equatable, Sendable {
        public let account: BackupAccount
        /// The account's own record, with the shared selection.
        public let state: BackupState
        /// The account was not known before: its record starts empty.
        public let isNew: Bool
    }

    /// The account `email` signs in to, made a signed-in account. Its record
    /// is the one the library already keeps for it (selected, never wiped);
    /// an account never seen starts from nothing but the shared selection,
    /// or takes the unclaimed record, or `stored` (its own record file left
    /// on disk).
    ///
    /// - Parameter storageChecked: for a new account; nil means checked only
    ///   when no other account is signed in (the first account runs at once,
    ///   as a single account always did).
    @discardableResult
    public mutating func adopting(account email: String, now: Date = Date(), storageChecked: Bool? = nil,
                                  stored: (String) -> BackupState? = { _ in nil }) -> Adoption {
        if var known = account(matching: email) {
            // The spelling first recorded stays: "Me@Gmail.com" and
            // "me@googlemail.com" are one account, and rewriting its record
            // for a capital letter would gain nothing.
            known.email = known.email ?? email
            known.removed = false
            // Its tick stays as it was, even as the only account: one that was
            // left out (a work account, say) is not backed up for signing in
            // again. The status says when no account is included.
            replace(known)
            var state = states[known.id] ?? BackupState()
            if state.accountEmail == nil { state.accountEmail = email }
            states[known.id] = state
            return Adoption(account: known, state: self.state(for: known.id) ?? state, isNew: false)
        }
        let id = GoogleSignIn.normalizedEmail(email)
        let checked = storageChecked ?? accounts.isEmpty
        var state = BackupState()
        let file: String
        if let unclaimed, unclaimed.accountEmail.map({ GoogleSignIn.sameAccount($0, email) }) ?? true {
            // History recorded before accounts were, or a state.json no
            // account refers to that names this one.
            state = unclaimed
            file = Self.legacyStateFile
            self.unclaimed = nil
        } else if unclaimed == nil, !isFileTaken(Self.legacyStateFile) {
            // The first account of a fresh install: state.json, as ever.
            file = Self.legacyStateFile
        } else {
            file = Self.stateFile(for: id)
            // A record left on disk for this account (say, after accounts.json
            // was lost) is picked up again; one that names another account
            // never is.
            if let kept = stored(file), kept.accountEmail.map({ GoogleSignIn.sameAccount($0, email) }) ?? true { state = kept }
        }
        state.accountEmail = email
        // Ticked only as the sole account: with accounts chosen, one added
        // next to others waits to be ticked (or its storage check confirmed).
        let account = BackupAccount(id: id, email: email, stateFile: file, addedAt: now, storageChecked: checked,
                                    chosen: accounts.isEmpty)
        index.accounts.append(account)
        states[id] = state
        return Adoption(account: account, state: self.state(for: id) ?? state, isNew: true)
    }

    /// Signs in again the accounts whose credentials the keychain holds but
    /// the index does not show signed in: the index was written before the
    /// keychain (a crash between the two), or it was lost. Each takes its
    /// record back from disk if one is there (`stored`).
    ///
    /// - Parameters:
    ///   - indexLost: the index that listed them is gone, so nothing says
    ///     which of them backups went to or which passed its storage check.
    ///     With one credential, its account is the first account, ticked and
    ///     checked as a first account always is. With several, the account
    ///     state.json belongs to may have been left out as easily as any (PR
    ///     #53 review, second round: it was, and the rebuild backed the
    ///     library up to it), so nobody is ticked and every account waits for
    ///     a tick and its storage check, as an added one does. Looking that
    ///     account up before the adoptions missed one taking an unclaimed
    ///     state.json, and a single account stopped. Taking "All accounts" and keychain
    ///     order instead backed up the library to a work account that had
    ///     been left out, without a storage check (PR #53 review).
    ///   - credentials: the accounts the keychain holds a credential for,
    ///     readable this launch or not, the legacy item under the account it
    ///     is filed to.
    /// - Returns: the index was lost and accounts are signed in, but none is
    ///   ticked: the backup targets have to be chosen again.
    @discardableResult
    public mutating func adoptingStrays(_ emails: [String], indexLost: Bool, credentials: Set<String>, now: Date = Date(),
                                        stored: (String) -> BackupState? = { _ in nil }) -> Bool {
        // One credential is the one account signed in: the first account,
        // ticked and storage-checked by the rule every first account follows.
        let sole = indexLost && credentials.count == 1 ? credentials.first : nil
        for email in emails {
            let first = sole == GoogleSignIn.normalizedEmail(email)
            adopting(account: email, now: now, storageChecked: indexLost && !first ? false : nil, stored: stored)
        }
        guard indexLost else { return false }
        index.backUpTo = .chosen
        // Only after the adoptions: an account signing in takes a state.json
        // nobody was known to own.
        let owner = index.accounts.first { $0.stateFile == Self.legacyStateFile }?.id
        let ticked = sole ?? (credentials.isEmpty ? owner : nil)
        for account in index.accounts {
            setChosen(account.id, account.id == ticked)
            if ticked == nil, credentials.contains(account.id) { setStorageChecked(account.id, false) }
        }
        return !accounts.isEmpty && included.isEmpty
    }

    /// Signs the account out of the run order. Its record stays.
    public mutating func remove(_ id: String) {
        setRemoved(id, true)
    }

    /// The credential stored under `id` turned out to belong to `email`:
    /// the legacy item's placeholder learns its address, or an account whose
    /// item held another account's credential hands it over. Returns the id
    /// the credential belongs under.
    public mutating func credential(of id: String, belongsTo email: String, now: Date = Date()) -> String {
        let target = GoogleSignIn.normalizedEmail(email)
        guard target != id else { return id }
        if id == Self.legacyKeychainAccount, account(matching: email) == nil,
           let position = index.accounts.firstIndex(where: { $0.id == id }) {
            // The placeholder becomes the account, in its place in the run
            // order: same record, real key.
            index.accounts[position].id = target
            index.accounts[position].email = email
            var state = states.removeValue(forKey: id) ?? BackupState()
            state.accountEmail = email
            states[target] = state
            return target
        }
        if id == Self.legacyKeychainAccount, var added = account(matching: email), let placeholder = account(id),
           states[added.id].map({ $0.uploaded.isEmpty && $0.mirrors.isEmpty }) ?? true {
            // The same account was added (as new, empty) before a check named
            // the placeholder: the placeholder's record is its record. It takes
            // it, the placeholder's file and place; its own empty one is
            // dropped. Leaving it empty would make its next run recreate every
            // album the placeholder's record links.
            var state = states.removeValue(forKey: id) ?? BackupState()
            state.accountEmail = state.accountEmail ?? email
            states[added.id] = state
            added.stateFile = placeholder.stateFile
            added.storageChecked = added.storageChecked || placeholder.storageChecked
            added.chosen = added.chosen || placeholder.chosen
            added.removed = false
            index.accounts.removeAll { $0.id == added.id }
            if let position = index.accounts.firstIndex(where: { $0.id == id }) { index.accounts[position] = added }
            return added.id
        }
        // Otherwise both records are kept: the account the credential names
        // signs in with its own, the other is signed out with its own.
        let previous = account(id)
        let adopted = adopting(account: email, now: now, storageChecked: previous?.storageChecked)
        // The tick was given to this credential's slot: a new account it
        // turns out to be keeps it.
        if adopted.isNew, previous?.chosen == true { setChosen(adopted.account.id, true) }
        remove(id)
        return adopted.account.id
    }

    public mutating func update(_ state: BackupState, for id: String) {
        guard account(id) != nil else { return }
        states[id] = state
    }

    public mutating func select(_ albumIDs: Set<String>) {
        index.selectedAlbumIDs = albumIDs
    }

    /// "Start Backing Up" on the storage check: the account joins the runs,
    /// ticked too when accounts are chosen, since that click asks for it.
    public mutating func confirmStorage(_ id: String) {
        guard var account = account(id) else { return }
        account.storageChecked = true
        account.chosen = true
        replace(account)
    }

    /// The unclaimed record, while there is no account to hold it.
    public mutating func updateUnclaimed(_ state: BackupState) {
        guard unclaimed != nil else { return }
        unclaimed = state
    }

    // MARK: - Files

    /// A record file that names nobody: a hash of the id.
    public static func stateFile(for id: String) -> String {
        "state-\(reference(for: id)).json"
    }

    /// The account as the run history refers to it: history.json is kept
    /// free of addresses, like the timeline, and the app shows the address
    /// by looking the reference up among its accounts.
    public static func reference(for id: String) -> String {
        String(SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16))
    }

    /// The account a history reference names, signed in or removed.
    public func account(reference: String?) -> BackupAccount? {
        guard let reference else { return nil }
        return index.accounts.first { Self.reference(for: $0.id) == reference }
    }

    private func isFileTaken(_ file: String) -> Bool {
        index.accounts.contains { $0.stateFile == file }
    }

    private mutating func setChosen(_ id: String, _ chosen: Bool) {
        guard var account = account(id) else { return }
        account.chosen = chosen
        replace(account)
    }

    private mutating func setStorageChecked(_ id: String, _ checked: Bool) {
        guard var account = account(id) else { return }
        account.storageChecked = checked
        replace(account)
    }

    private mutating func setRemoved(_ id: String, _ removed: Bool) {
        guard var account = account(id) else { return }
        account.removed = removed
        replace(account)
    }

    private mutating func replace(_ account: BackupAccount) {
        guard let position = index.accounts.firstIndex(where: { $0.id == account.id }) else { return }
        index.accounts[position] = account
    }
}
