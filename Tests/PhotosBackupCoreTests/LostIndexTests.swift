import Foundation
import Testing
@testable import PhotosBackupCore

/// PR #53 review, MAJOR 1: with accounts.json unreadable the index was
/// rebuilt from state.json, the app signed every keychain item in again in
/// keychain order, "Back up to" went back to All accounts, and a stray that
/// sorted before the primary was taken as storage-checked. The reviewer's
/// scenario (their LostIndexChoiceProbe): the primary zed.primary@gmail.com,
/// a work account a.work@corp.example.com left out.
@Suite struct LostIndexTests {
    private static let primary = "zed.primary@gmail.com"
    private static let work = "a.work@corp.example.com"
    private static let primaryID = "zedprimary@gmail.com"
    private static let workID = "a.work@corp.example.com"

    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lost-index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The reviewer's setup, saved as the app saves it: the primary migrated
    /// from one account with a record, the work account added, checked and
    /// left out. Returns the primary's record.
    private func leftOutWorkAccount(in store: AccountsStore) throws -> BackupState {
        var library = store.load(legacyCredential: (true, Self.primary)).library
        var primaryState = try #require(library.state(for: Self.primaryID))
        primaryState.recordUpload(assetID: "x", mediaKey: "k", existing: false)
        primaryState.recordAlbum("trip", googleAlbumID: "AF1QipTrip", added: ["x"])
        library.update(primaryState, for: Self.primaryID)
        library.adopting(account: Self.work)
        library.confirmStorage(Self.workID)
        library.include(Self.workID, false)
        #expect(library.choice == .chosen)
        #expect(library.included.map(\.id) == [Self.primaryID])
        for account in library.accounts {
            try store.save(try #require(library.storedState(for: account.id)), file: account.stateFile)
        }
        try store.save(library.index)
        return primaryState
    }

    /// The keychain's items, in its (sorted) order, as the app reads them.
    private let keychainEmails = [work, primary]
    private let keychainIDs: Set<String> = [workID, primaryID]

    @Test func anUnreadableIndexIsReadFromItsCopyWithTheChoiceIntact() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AccountsStore(directory: directory)
        let primaryState = try leftOutWorkAccount(in: store)
        #expect(FileManager.default.fileExists(atPath: store.indexCopyURL.path), "saving the index keeps a copy beside it")
        let saved = try Data(contentsOf: store.indexURL)
        #expect(try Data(contentsOf: store.indexCopyURL) == saved)

        try Data("{broken".utf8).write(to: store.indexURL)
        let loaded = store.load(legacyCredential: (false, nil))
        #expect(loaded.indexRestored)
        #expect(!loaded.indexLost && !loaded.migrated)
        #expect(loaded.indexChanged, "the restored index is written back")
        #expect(loaded.unreadable.isEmpty, "nothing was lost, so nothing is reported unreadable")
        #expect(!loaded.indexWasLost(keychainHasAccountItems: true))
        var library = loaded.library
        library.adoptingStrays([], indexLost: false, credentials: [Self.primaryID, Self.workID])
        #expect(library.choice == .chosen)
        #expect(library.accounts.map(\.id) == [Self.primaryID, Self.workID])
        #expect(library.included.map(\.id) == [Self.primaryID])
        #expect(library.account(Self.workID)?.storageChecked == true)
        #expect(library.state(for: Self.primaryID)?.uploaded.mapValues(\.mediaKey) == primaryState.uploaded.mapValues(\.mediaKey))
        #expect(library.state(for: Self.primaryID)?.mirrors == primaryState.mirrors)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(names.contains { $0.hasPrefix("accounts.json.") && $0.hasSuffix(".unreadable") }, "the damaged file is set aside")
    }

    /// A deleted accounts.json is read from its copy too.
    @Test func aMissingIndexIsReadFromItsCopy() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AccountsStore(directory: directory)
        _ = try leftOutWorkAccount(in: store)
        try FileManager.default.removeItem(at: store.indexURL)
        let loaded = store.load(legacyCredential: (false, nil))
        #expect(loaded.indexRestored && !loaded.migrated)
        #expect(loaded.library.choice == .chosen)
        #expect(loaded.library.included.map(\.id) == [Self.primaryID])
    }

    /// The reviewer's exact failure, with the copy unreadable too: before
    /// the fix choice=all, the work account included and storage-checked.
    /// With the work account's credential in the keychain nothing says the
    /// primary was the one backed up to (second round: the primary could
    /// have been the one left out), so nobody is ticked.
    @Test func aLostIndexAndCopyTickNobodyWhileAnotherAccountIsSignedIn() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AccountsStore(directory: directory)
        let primaryState = try leftOutWorkAccount(in: store)
        try Data("{broken".utf8).write(to: store.indexURL)
        try Data("{broken".utf8).write(to: store.indexCopyURL)

        let loaded = store.load(legacyCredential: (false, nil))
        #expect(loaded.indexLost && loaded.migrated && !loaded.indexRestored)
        #expect(loaded.unreadable.keys.sorted() == ["accounts.json", "accounts.json.bak"])
        let lost = loaded.indexWasLost(keychainHasAccountItems: true)
        #expect(lost)
        var rebuilt = loaded.library
        let chooseAgain = rebuilt.adoptingStrays(keychainEmails, indexLost: lost, credentials: keychainIDs,
                                                 stored: { store.readState($0) })

        #expect(chooseAgain, "the targets have to be chosen again")
        #expect(rebuilt.choice == .chosen)
        #expect(rebuilt.primary?.id == Self.primaryID)
        #expect(rebuilt.accounts.map(\.id) == [Self.primaryID, Self.workID])
        #expect(rebuilt.included.isEmpty, "nobody is backed up to until chosen")
        #expect(rebuilt.accounts.allSatisfy { !$0.storageChecked }, "each waits for its storage check")
        #expect(rebuilt.state(for: Self.primaryID)?.uploaded.mapValues(\.mediaKey) == primaryState.uploaded.mapValues(\.mediaKey))
        #expect(rebuilt.state(for: Self.primaryID)?.mirrors == primaryState.mirrors)
        #expect(rebuilt.account(Self.primaryID)?.stateFile == "state.json")
    }

    /// The second round's reproduction: the account state.json belongs to
    /// was left out and the other one chosen. Before the fix the rebuild
    /// ticked the left-out account, storage-checked, and backed up to it.
    @Test func aLostIndexNeverTicksTheStateJsonAccountThatWasLeftOut() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AccountsStore(directory: directory)
        var library = store.load(legacyCredential: (true, Self.primary)).library
        library.adopting(account: Self.work)
        library.confirmStorage(Self.workID)
        library.include(Self.primaryID, false)
        #expect(library.included.map(\.id) == [Self.workID])
        for account in library.accounts {
            try store.save(try #require(library.storedState(for: account.id)), file: account.stateFile)
        }
        try store.save(library.index)
        try Data("{broken".utf8).write(to: store.indexURL)
        try Data("{broken".utf8).write(to: store.indexCopyURL)

        let loaded = store.load(legacyCredential: (false, nil))
        var rebuilt = loaded.library
        let chooseAgain = rebuilt.adoptingStrays(keychainEmails, indexLost: loaded.indexWasLost(keychainHasAccountItems: true),
                                                 credentials: keychainIDs, stored: { store.readState($0) })
        #expect(chooseAgain)
        #expect(rebuilt.choice == .chosen)
        #expect(!rebuilt.isIncluded(Self.primaryID), "the account left out is not backed up to")
        #expect(rebuilt.included.isEmpty)
        #expect(rebuilt.account(Self.primaryID)?.storageChecked == false)
        #expect(rebuilt.account(Self.workID)?.storageChecked == false)
    }

    /// Only the account state.json belongs to has a credential: it is the
    /// one this Mac was backing up to, as before there were accounts.
    @Test func aLostIndexWithOnlyTheStateJsonAccountSignedInTicksIt() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AccountsStore(directory: directory)
        _ = try leftOutWorkAccount(in: store)
        try Data("{broken".utf8).write(to: store.indexURL)
        try Data("{broken".utf8).write(to: store.indexCopyURL)

        let loaded = store.load(legacyCredential: (false, nil))
        var rebuilt = loaded.library
        let chooseAgain = rebuilt.adoptingStrays([Self.primary], indexLost: loaded.indexWasLost(keychainHasAccountItems: true),
                                                 credentials: [Self.primaryID], stored: { store.readState($0) })
        #expect(!chooseAgain)
        #expect(rebuilt.choice == .chosen)
        #expect(rebuilt.included.map(\.id) == [Self.primaryID])
        #expect(rebuilt.account(Self.primaryID)?.storageChecked == true)
        #expect(rebuilt.account(Self.workID) == nil, "the work account signed out stays unknown until it signs in")
    }

    /// accounts.json gone with no copy (written before the copy existed),
    /// while the keychain holds account items: lost, decided by the items.
    @Test func aMissingIndexWithAccountItemsInTheKeychainIsLost() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AccountsStore(directory: directory)
        _ = try leftOutWorkAccount(in: store)
        try FileManager.default.removeItem(at: store.indexURL)
        try FileManager.default.removeItem(at: store.indexCopyURL)

        let loaded = store.load(legacyCredential: (false, nil))
        #expect(loaded.migrated && !loaded.indexLost)
        let lost = loaded.indexWasLost(keychainHasAccountItems: true)
        #expect(lost)
        var rebuilt = loaded.library
        let chooseAgain = rebuilt.adoptingStrays(keychainEmails, indexLost: lost, credentials: keychainIDs,
                                                 stored: { store.readState($0) })
        #expect(chooseAgain)
        #expect(rebuilt.choice == .chosen)
        #expect(rebuilt.included.isEmpty)
        #expect(rebuilt.account(Self.workID)?.storageChecked == false)
    }

    /// The real upgrade from one account (only the legacy item in the
    /// keychain) is not a lost index: All accounts, as before.
    @Test func theUpgradeFromOneAccountIsNotALostIndex() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        try BackupStore(url: directory.appendingPathComponent("state.json")).save(LegacyStateFixture.make())
        let loaded = AccountsStore(directory: directory).load(legacyCredential: (true, LegacyStateFixture.email))
        #expect(loaded.migrated && !loaded.indexLost && !loaded.indexRestored)
        let lost = loaded.indexWasLost(keychainHasAccountItems: false)
        #expect(!lost)
        var library = loaded.library
        library.adoptingStrays([], indexLost: lost, credentials: ["janeappleseed@gmail.com"])
        #expect(library.choice == .all)
        #expect(library.included.map(\.id) == ["janeappleseed@gmail.com"])
        #expect(library.index == loaded.library.index, "nothing to adopt changes nothing")
    }

    /// A credential stored before a crash kept the index from listing it
    /// (not a lost index): it is added as any account is, waiting for its
    /// storage check and its tick next to the others.
    @Test func aStrayNextToAKnownIndexIsAddedAsAnyAccountIs() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AccountsStore(directory: directory)
        let first = store.load(legacyCredential: (true, Self.primary))
        try store.save(first.library.index)
        let loaded = store.load(legacyCredential: (false, nil))
        var library = loaded.library
        library.adoptingStrays([Self.work], indexLost: loaded.indexWasLost(keychainHasAccountItems: true),
                               credentials: [Self.primaryID, Self.workID])
        #expect(library.choice == .all)
        #expect(library.account(Self.workID)?.storageChecked == false)
        #expect(library.accounts.map(\.id) == [Self.primaryID, Self.workID])
    }
}
