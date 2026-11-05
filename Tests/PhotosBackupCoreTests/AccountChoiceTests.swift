import Foundation
import Testing
@testable import PhotosBackupCore

/// "Back up to: All accounts / Only the accounts I choose" and each
/// account's "Include in backups" (#49, the owner's request).
@Suite struct AccountChoiceTests {
    private func library(_ emails: String...) -> AccountLibrary {
        var library = AccountLibrary()
        for email in emails {
            library.adopting(account: email)
            library.confirmStorage(GoogleSignIn.normalizedEmail(email))
        }
        return library
    }

    @Test func allAccountsIsTheDefaultAndTakesAnAccountAddedLater() {
        var library = library("a@example.com", "b@example.com")
        #expect(library.choice == .all)
        #expect(library.included.map(\.id) == ["a@example.com", "b@example.com"])
        library.adopting(account: "c@example.com")
        #expect(library.isIncluded("c@example.com"), "All accounts means every account, one added later too")
        #expect(library.included.count == 3)
    }

    @Test func choosingStartsWithEveryAccountTicked() {
        var library = library("a@example.com", "b@example.com")
        library.choose(.chosen)
        #expect(library.choice == .chosen)
        #expect(library.included.map(\.id) == ["a@example.com", "b@example.com"], "switching alone changes nothing")
    }

    @Test func onlyTheChosenAccountsAndNotOneAddedLater() {
        var library = library("a@example.com", "b@example.com")
        library.choose(.chosen)
        library.include("a@example.com", false)
        #expect(library.included.map(\.id) == ["b@example.com"])
        #expect(!library.isIncluded("a@example.com"))
        library.adopting(account: "c@example.com")
        #expect(!library.isIncluded("c@example.com"), "an account added next to chosen ones waits to be ticked")
        library.include("c@example.com", true)
        #expect(library.included.map(\.id) == ["b@example.com", "c@example.com"])
    }

    @Test func untickingOneOfAllAccountsKeepsTheOthers() {
        var library = library("a@example.com", "b@example.com", "c@example.com")
        library.include("b@example.com", false)
        #expect(library.choice == .chosen)
        #expect(library.included.map(\.id) == ["a@example.com", "c@example.com"])
        // Ticking an account that is already in changes nothing.
        var all = self.library("a@example.com", "b@example.com")
        all.include("a@example.com", true)
        #expect(all.choice == .all)
    }

    @Test func backToAllAccountsIncludesEveryAccountAgain() {
        var library = library("a@example.com", "b@example.com")
        library.include("b@example.com", false)
        library.choose(.all)
        #expect(library.included.map(\.id) == ["a@example.com", "b@example.com"])
        // Choosing again starts from everything ticked, not the old ticks.
        library.choose(.chosen)
        #expect(library.isIncluded("b@example.com"))
    }

    /// The storage check's "Start Backing Up" asks for that account.
    @Test func confirmingTheStorageCheckTicksTheAccount() {
        var library = library("a@example.com")
        library.choose(.chosen)
        library.adopting(account: "b@example.com")
        #expect(!library.isIncluded("b@example.com"))
        library.confirmStorage("b@example.com")
        #expect(library.isIncluded("b@example.com"))
    }

    @Test func aRemovedAccountIsNeverIncludedAndKeepsItsTickForLater() {
        var library = library("a@example.com", "b@example.com")
        library.include("a@example.com", false)
        library.remove("b@example.com")
        #expect(!library.isIncluded("b@example.com"))
        #expect(library.included.isEmpty)
        let back = library.adopting(account: "b@example.com")
        #expect(back.account.chosen, "signing in again keeps the account's tick")
        #expect(library.included.map(\.id) == ["b@example.com"])
    }

    /// A brand-new account with no other signed in is ticked, so a fresh
    /// start backs up. An account someone left out stays left out, also as
    /// the only one and also after signing in again: a work account is never
    /// backed up because the others were removed.
    @Test func onlyABrandNewSoleAccountIsTickedForItself() {
        var fresh = AccountLibrary()
        fresh.choose(.chosen)
        fresh.adopting(account: "new@example.com")
        #expect(fresh.isIncluded("new@example.com"))

        var library = library("a@example.com", "work@example.com")
        library.include("work@example.com", false)
        library.remove("a@example.com")
        #expect(library.included.isEmpty, "removing the ticked account does not tick the one left out")
        library.remove("work@example.com")
        library.adopting(account: "work@example.com")
        #expect(!library.isIncluded("work@example.com"), "nor does signing in to it again")
    }

    @Test func theChoiceSurvivesAWriteAndARead() throws {
        var library = library("a@example.com", "b@example.com", "c@example.com")
        library.include("b@example.com", false)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("choice-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AccountsStore(directory: directory)
        try store.save(library.index)
        let loaded = store.load(legacyCredential: (false, nil)).library
        #expect(loaded.choice == .chosen)
        #expect(loaded.included.map(\.id) == ["a@example.com", "c@example.com"])
        #expect(loaded.index.accounts.map(\.chosen) == [true, false, true])
    }

    /// An accounts.json written before the choice existed (#51's shape)
    /// backs up to every account, as it did.
    @Test func anIndexFromBeforeTheChoiceIsAllAccounts() throws {
        let json = """
        {
          "accounts" : [
            { "addedAt" : "2026-11-05T07:00:00Z", "email" : "a@example.com", "id" : "a@example.com",
              "removed" : false, "stateFile" : "state.json", "storageChecked" : true },
            { "addedAt" : "2026-11-05T07:10:00Z", "email" : "b@example.com", "id" : "b@example.com",
              "removed" : false, "stateFile" : "state-0123456789abcdef.json", "storageChecked" : true }
          ],
          "selectedAlbumIDs" : [ "all-photos" ],
          "version" : 1
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let index = try decoder.decode(AccountsIndex.self, from: Data(json.utf8))
        #expect(index.backUpTo == .all)
        #expect(index.accounts.allSatisfy { !$0.chosen })
        let library = AccountLibrary(index: index)
        #expect(library.included.map(\.id) == ["a@example.com", "b@example.com"])
    }

    /// A value only a newer version knows narrows to the ticked accounts
    /// rather than setting the account list aside or widening the backup.
    @Test func anUnknownChoiceFromANewerVersionIsTheTickedAccounts() throws {
        let json = """
        {"accounts": [], "selectedAlbumIDs": [], "version": 1, "backUpTo": "some-future-mode"}
        """
        let index = try JSONDecoder().decode(AccountsIndex.self, from: Data(json.utf8))
        #expect(index.backUpTo == .chosen)
    }

    /// The migration from one account (state.json and the gpmc item) lands
    /// on "All accounts".
    @Test func anUpgradeFromOneAccountBacksUpToAllAccounts() {
        var legacy = BackupState()
        legacy.accountEmail = "a@example.com"
        let library = AccountLibrary.migrating(legacy: legacy, credentialEmail: "a@example.com", hasCredential: true)
        #expect(library.choice == .all)
        #expect(library.included.map(\.id) == ["a@example.com"])
    }

    /// The placeholder of the legacy credential and the same account added
    /// before a check named it are one account: a tick on either stays.
    @Test func aPlaceholderMergeKeepsTheTick() {
        var library = AccountLibrary.migrating(legacy: nil, credentialEmail: nil, hasCredential: true)
        library.adopting(account: "other@example.com")
        library.confirmStorage("other@example.com")
        library.choose(.chosen)
        library.adopting(account: "named@example.com")
        #expect(!library.isIncluded("named@example.com"))
        let id = library.credential(of: AccountLibrary.legacyKeychainAccount, belongsTo: "named@example.com")
        #expect(id == "named@example.com")
        #expect(library.isIncluded("named@example.com"), "the placeholder was ticked, so the account it turned out to be is")
    }
}
