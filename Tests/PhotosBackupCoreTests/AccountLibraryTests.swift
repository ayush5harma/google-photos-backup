import Foundation
import Testing
@testable import PhotosBackupCore

@Suite struct AccountLibraryTests {
    private func record(_ email: String?, assets: [String] = ["a"]) -> BackupState {
        var state = BackupState()
        state.accountEmail = email
        state.selectedAlbumIDs = ["all-photos"]
        for asset in assets { state.recordUpload(assetID: asset, mediaKey: "key-\(asset)", existing: false) }
        state.recordAlbum("trip", googleAlbumID: "album-\(email ?? "none")", added: assets)
        return state
    }

    @Test func theFirstAccountRunsAtOnceAndAnAddedOneWaitsForItsStorageCheck() {
        var library = AccountLibrary()
        let first = library.adopting(account: "a@example.com")
        let second = library.adopting(account: "b@example.com")
        #expect(first.account.storageChecked)
        #expect(first.account.stateFile == AccountLibrary.legacyStateFile)
        #expect(!second.account.storageChecked)
        #expect(second.account.stateFile == AccountLibrary.stateFile(for: "b@example.com"))
        library.confirmStorage("b@example.com")
        #expect(library.account("b@example.com")?.storageChecked == true)
        #expect(library.primary?.id == "a@example.com")
    }

    @Test func recordFileNamesNameNobody() {
        let file = AccountLibrary.stateFile(for: "someone@example.com")
        #expect(!file.contains("someone"))
        #expect(file == AccountLibrary.stateFile(for: "someone@example.com"))
        #expect(file != AccountLibrary.stateFile(for: "other@example.com"))
    }

    /// Remove signs one account out; its record waits for it, and the others
    /// are not touched.
    @Test func removingAndSigningInAgainRestoresTheRecord() {
        var library = AccountLibrary.migrating(legacy: record("a@example.com"), credentialEmail: "a@example.com", hasCredential: true)
        var second = library.adopting(account: "b@example.com").state
        second.recordUpload(assetID: "b1", mediaKey: "kb", existing: false)
        library.update(second, for: "b@example.com")
        library.confirmStorage("b@example.com")

        library.remove("b@example.com")
        #expect(library.accounts.map(\.id) == ["a@example.com"])
        #expect(library.state(for: "a@example.com")?.uploaded.count == 1)

        let back = library.adopting(account: "B@Example.com")
        #expect(!back.isNew)
        #expect(back.state.uploaded["b1"]?.mediaKey == "kb")
        #expect(back.account.storageChecked)
        #expect(library.accounts.map(\.id) == ["a@example.com", "b@example.com"])
    }

    @Test func theSelectionIsSharedByEveryAccount() {
        var library = AccountLibrary()
        library.adopting(account: "a@example.com")
        library.adopting(account: "b@example.com")
        library.select(["all-photos", "trip"])
        #expect(library.state(for: "a@example.com")?.selectedAlbumIDs == ["all-photos", "trip"])
        #expect(library.state(for: "b@example.com")?.selectedAlbumIDs == ["all-photos", "trip"])
    }

    /// A credential with no address, next to a record with none: the record
    /// goes with it, under the legacy item, until Google names the account;
    /// then the placeholder takes the real key in its place in the order.
    @Test func aCredentialWithoutAnAddressIsNamedLater() {
        var library = AccountLibrary.migrating(legacy: record(nil), credentialEmail: nil, hasCredential: true)
        #expect(library.primary?.id == AccountLibrary.legacyKeychainAccount)
        #expect(library.primary?.email == nil)
        library.adopting(account: "b@example.com")

        let id = library.credential(of: AccountLibrary.legacyKeychainAccount, belongsTo: "Me@Gmail.com")
        #expect(id == "me@gmail.com")
        #expect(library.accounts.map(\.id) == ["me@gmail.com", "b@example.com"])
        #expect(library.primary?.email == "Me@Gmail.com")
        #expect(library.state(for: "me@gmail.com")?.uploaded.count == 1)
        #expect(library.state(for: "me@gmail.com")?.mirrors["trip"]?.googleAlbumID == "album-none")
        #expect(library.account(AccountLibrary.legacyKeychainAccount) == nil)
    }

    /// Review finding: the same account added through Add Account before a
    /// check named the placeholder used to keep its new empty record while
    /// the placeholder's history was signed out with it, and its next run
    /// recreated every album. The added account takes the history.
    @Test func addingThePlaceholdersOwnAccountTakesItsRecord() {
        var library = AccountLibrary.migrating(legacy: record(nil), credentialEmail: nil, hasCredential: true)
        library.adopting(account: "me@gmail.com")
        #expect(library.accounts.map(\.id) == [AccountLibrary.legacyKeychainAccount, "me@gmail.com"])

        let id = library.credential(of: AccountLibrary.legacyKeychainAccount, belongsTo: "Me@Gmail.com")
        #expect(id == "me@gmail.com")
        #expect(library.accounts.map(\.id) == ["me@gmail.com"])
        #expect(library.primary?.stateFile == AccountLibrary.legacyStateFile)
        #expect(library.primary?.storageChecked == true)
        #expect(library.state(for: "me@gmail.com")?.mirrors["trip"]?.googleAlbumID == "album-none")
        #expect(library.state(for: "me@gmail.com")?.uploaded.count == 1)
        #expect(library.account(AccountLibrary.legacyKeychainAccount) == nil)
    }

    /// When both hold history, neither is merged or dropped.
    @Test func aPlaceholderAndAnAccountWithHistoryKeepTheirOwn() {
        var library = AccountLibrary.migrating(legacy: record(nil), credentialEmail: nil, hasCredential: true)
        var own = library.adopting(account: "me@gmail.com").state
        own.recordUpload(assetID: "mine", mediaKey: "k-mine", existing: false)
        library.update(own, for: "me@gmail.com")

        _ = library.credential(of: AccountLibrary.legacyKeychainAccount, belongsTo: "me@gmail.com")
        #expect(library.state(for: "me@gmail.com")?.uploaded.keys.sorted() == ["mine"])
        #expect(library.account(AccountLibrary.legacyKeychainAccount)?.removed == true)
        #expect(library.state(for: AccountLibrary.legacyKeychainAccount)?.mirrors["trip"]?.googleAlbumID == "album-none")
    }

    @Test func historyNamesAccountsByReferenceOnly() {
        var library = AccountLibrary()
        library.adopting(account: "a@example.com")
        let reference = AccountLibrary.reference(for: "a@example.com")
        #expect(!reference.contains("example"))
        #expect(library.account(reference: reference)?.id == "a@example.com")
        #expect(library.account(reference: "0000000000000000") == nil)
        #expect(AccountLibrary.stateFile(for: "a@example.com") == "state-\(reference).json")
    }

    /// The record names one account and the credential another: both are
    /// kept, each with its own record, and only the credential's runs.
    @Test func aRecordForAnotherAccountIsKeptForIt() {
        let library = AccountLibrary.migrating(legacy: record("old@example.com"), credentialEmail: "new@example.com", hasCredential: true)
        #expect(library.accounts.map(\.id) == ["new@example.com"])
        #expect(library.state(for: "new@example.com")?.uploaded.isEmpty == true)
        #expect(library.state(for: "old@example.com")?.uploaded.count == 1)
        #expect(library.account("old@example.com")?.removed == true)
        #expect(library.account("old@example.com")?.stateFile == AccountLibrary.legacyStateFile)
        #expect(library.account("new@example.com")?.stateFile != AccountLibrary.legacyStateFile)
    }

    /// Signed out before upgrading: the record waits for its account.
    @Test func aRecordWithNoCredentialWaitsForItsAccount() {
        var library = AccountLibrary.migrating(legacy: record("a@example.com"), credentialEmail: nil, hasCredential: false)
        #expect(library.accounts.isEmpty)
        let other = library.adopting(account: "b@example.com")
        #expect(other.state.uploaded.isEmpty)
        let back = library.adopting(account: "a@example.com")
        #expect(back.state.uploaded.count == 1)
        #expect(back.account.stateFile == AccountLibrary.legacyStateFile)
    }

    /// An unreferenced state.json naming one account is never handed to another.
    @Test func anUnclaimedRecordForSomeoneElseIsNotTaken() {
        var library = AccountLibrary(unclaimed: record("a@example.com"))
        let other = library.adopting(account: "b@example.com")
        #expect(other.state.uploaded.isEmpty)
        #expect(other.account.stateFile != AccountLibrary.legacyStateFile)
        #expect(library.unclaimed != nil)
        #expect(library.adopting(account: "a@example.com").state.uploaded.count == 1)
    }

    @Test func aStoredRecordNamingAnotherAccountIsNotPickedUp() {
        var library = AccountLibrary()
        library.adopting(account: "a@example.com")
        let added = library.adopting(account: "b@example.com", stored: { _ in self.record("c@example.com") })
        #expect(added.state.uploaded.isEmpty)
    }

    @Test func aCredentialFoundUnderAnotherAccountMovesToItsOwn() {
        var library = AccountLibrary()
        library.adopting(account: "a@example.com")
        let id = library.credential(of: "a@example.com", belongsTo: "c@example.com")
        #expect(id == "c@example.com")
        #expect(library.accounts.map(\.id) == ["c@example.com"])
        #expect(library.account("a@example.com")?.removed == true)
    }
}

@Suite struct StorageCheckTests {
    @Test func onlyTheQuotaProfileCountsAgainstStorage() {
        #expect(!StorageCheck(items: 10, averageItemBytes: nil, quality: .original).countsAgainstStorage)
        #expect(!StorageCheck(items: 10, averageItemBytes: nil, quality: .saver).countsAgainstStorage)
        #expect(StorageCheck(items: 10, averageItemBytes: nil, quality: .quota).countsAgainstStorage)
    }

    @Test func theEstimateUsesTheAverageUploadedItem() {
        let history = [
            RunRecord(kind: .photos, trigger: .timer, uploaded: 10, existing: 5, bytes: 30_000_000),
            RunRecord(kind: .photos, trigger: .timer, uploaded: 0, existing: 9, bytes: 0),
            RunRecord(kind: .messagesMedia, trigger: .timer, uploaded: 10, bytes: 10_000_000),
            RunRecord(kind: .messagesArchive, trigger: .timer, uploaded: 1, bytes: 999_000_000),
        ]
        let average = StorageCheck.averageItemBytes(in: history)
        #expect(average == 2_000_000)
        #expect(StorageCheck(items: 1_000, averageItemBytes: average, quality: .quota).estimatedBytes == 2_000_000_000)
        #expect(StorageCheck.averageItemBytes(in: []) == nil)
    }

    @Test func theStoragePageOpensAsTheAccount() {
        let url = StorageCheck.storagePage(for: "family+photos@gmail.com")
        #expect(url.host == "one.google.com")
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "family+photos@gmail.com")
    }
}
