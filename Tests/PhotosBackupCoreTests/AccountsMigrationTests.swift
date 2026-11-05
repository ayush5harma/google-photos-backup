import Foundation
import Testing
@testable import PhotosBackupCore

/// A reproducible generator, so the fixture is the same on every run.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A state.json shaped like the owner's on 2026-11-05: about 27,700 uploads
/// (Photos assets, a few Messages items, some edited, some already in
/// Google), 188 linked albums with their members, a few forced re-uploads,
/// and the account it belongs to.
enum LegacyStateFixture {
    static let uploads = 27_700
    static let albums = 188
    static let email = "Jane.Appleseed@gmail.com"

    static func make(email: String? = Self.email) -> BackupState {
        var random = SplitMix64(state: 49)
        func token(_ count: Int) -> String {
            let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
            return String((0..<count).map { _ in alphabet[Int(random.next() % UInt64(alphabet.count))] })
        }
        func assetID() -> String {
            let hex = (0..<32).map { _ in String(format: "%X", Int(random.next() % 16)) }.joined()
            let uuid = [hex.prefix(8), hex.dropFirst(8).prefix(4), hex.dropFirst(12).prefix(4), hex.dropFirst(16).prefix(4), hex.dropFirst(20)]
                .map(String.init).joined(separator: "-")
            return "\(uuid)/L0/001"
        }
        let start = Date(timeIntervalSince1970: 1_760_000_000)
        var state = BackupState()
        state.accountEmail = email
        var assetIDs: [String] = []
        for index in 0..<uploads {
            let messages = index % 97 == 0
            let id = messages ? "messages:" + (0..<64).map { _ in String(format: "%x", Int(random.next() % 16)) }.joined() : assetID()
            let date = start.addingTimeInterval(Double(index * 37))
            var stamp: EditStamp?
            if !messages {
                let edited = index % 11 == 0
                stamp = EditStamp(modified: date.addingTimeInterval(-86_400), edited: index % 5 == 0 ? nil : edited,
                                  editIdentity: edited ? token(43) : nil)
            }
            state.uploaded[id] = BackupRecord(mediaKey: "AF1Qip" + token(38), date: date, existing: index % 7 == 0, editStamp: stamp)
            assetIDs.append(id)
        }
        for album in 0..<albums {
            let count = 1 + Int(random.next() % 400)
            let offset = Int(random.next() % UInt64(uploads - count))
            let members = Set(assetIDs[offset..<(offset + count)].filter { !$0.hasPrefix("messages:") })
            state.mirrors["\(assetID().dropLast(7))/L0/040-album-\(album)"] = AlbumMirror(googleAlbumID: "AF1Qip" + token(52), addedAssetIDs: members)
        }
        state.forcedUploads = Set(assetIDs.prefix(12))
        state.selectedAlbumIDs = Set(["all-photos"] + state.mirrors.keys.sorted().prefix(30))
        return state
    }
}

@Suite struct AccountsMigrationTests {
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("accounts-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func encoded(_ state: BackupState) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(state)
    }

    /// state.json with every Set's array sorted. Swift writes a Set in hash
    /// order, which differs between two equal sets (measured here: the same
    /// state re-encoded in one process put addedAssetIDs in another order),
    /// so no two saves of state.json, before accounts or after, ever had the
    /// same bytes. Only the JSON arrays come from Sets.
    private func canonical(_ data: Data) throws -> Data {
        func sorted(_ value: Any) -> Any {
            switch value {
            case let object as [String: Any]: return object.mapValues(sorted)
            case let strings as [String]: return strings.sorted()
            case let array as [Any]: return array.map(sorted)
            default: return value
            }
        }
        return try JSONSerialization.data(withJSONObject: sorted(try JSONSerialization.jsonObject(with: data)), options: [.sortedKeys])
    }

    /// The upgrade from one account: the record comes out as the first
    /// account's, byte for byte, and stays so through adding, switching and
    /// saving, because losing a single album link would recreate that album
    /// as a duplicate in Google Photos.
    @Test func singleAccountStateBecomesTheFirstAccountsByteForByte() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacyURL = directory.appendingPathComponent("state.json")
        try BackupStore(url: legacyURL).save(LegacyStateFixture.make())
        let before = try Data(contentsOf: legacyURL)
        let original = try BackupStore(url: legacyURL).load()
        #expect(original.uploaded.count == LegacyStateFixture.uploads)
        #expect(original.mirrors.count == LegacyStateFixture.albums)
        #expect(original.mirrors.values.allSatisfy { $0.googleAlbumID != nil && !$0.addedAssetIDs.isEmpty })

        let store = AccountsStore(directory: directory)
        var loaded = store.load(legacyCredential: (exists: true, email: "jane.appleseed@gmail.com"))
        #expect(loaded.migrated)
        #expect(loaded.unreadable.isEmpty)
        #expect(loaded.legacyCredentialAccount == "janeappleseed@gmail.com")
        try store.save(loaded.library.index)

        // Migrating wrote accounts.json and nothing else.
        #expect(try Data(contentsOf: legacyURL) == before)
        let first = try #require(loaded.library.primary)
        #expect(first.id == "janeappleseed@gmail.com")
        #expect(first.email == LegacyStateFixture.email)
        #expect(first.stateFile == "state.json")
        #expect(first.storageChecked)
        #expect(loaded.library.accounts.count == 1)
        #expect(loaded.library.selection == original.selectedAlbumIDs)
        let migrated = try #require(loaded.library.state(for: first.id))
        #expect(migrated == original)
        #expect(try canonical(encoded(migrated)) == canonical(before))
        #expect(migrated.mirrors.mapValues(\.googleAlbumID) == original.mirrors.mapValues(\.googleAlbumID))
        #expect(migrated.mirrors.mapValues(\.addedAssetIDs) == original.mirrors.mapValues(\.addedAssetIDs))

        // A second account starts empty with the shared selection and waits
        // for its storage check.
        let second = loaded.library.adopting(account: "family.photos@gmail.com")
        #expect(second.isNew)
        #expect(second.state.uploaded.isEmpty && second.state.mirrors.isEmpty && second.state.forcedUploads == nil)
        #expect(second.state.selectedAlbumIDs == original.selectedAlbumIDs)
        #expect(!second.account.storageChecked)
        #expect(second.account.stateFile != "state.json")

        // Coming back to the first account selects its record; nothing wiped.
        let back = loaded.library.adopting(account: "jane.appleseed@googlemail.com")
        #expect(!back.isNew)
        #expect(back.state == original)
        #expect(back.state.mirrors == original.mirrors)
        #expect(back.state.forcedUploads == original.forcedUploads)

        // Saved through the new store (as every run saves) and loaded again:
        // the same record, its arrays in sorted order.
        for account in loaded.library.accounts {
            try store.save(try #require(loaded.library.storedState(for: account.id)), file: account.stateFile)
        }
        try store.save(loaded.library.index)
        #expect(try canonical(Data(contentsOf: legacyURL)) == canonical(before))
        loaded = store.load(legacyCredential: (exists: false, email: nil))
        #expect(!loaded.migrated)
        #expect(loaded.library.accounts.map(\.id) == ["janeappleseed@gmail.com", "familyphotos@gmail.com"])
        #expect(loaded.library.state(for: "janeappleseed@gmail.com") == original)
        #expect(loaded.library.state(for: "familyphotos@gmail.com")?.uploaded.isEmpty == true)
    }

    /// History written before accounts were recorded belongs to the account
    /// whose credential wrote it, exactly as signing in assumed.
    @Test func historyWithoutAnAccountGoesToTheCredentialsAccount() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacyURL = directory.appendingPathComponent("state.json")
        try BackupStore(url: legacyURL).save(LegacyStateFixture.make(email: nil))
        let before = try Data(contentsOf: legacyURL)

        let loaded = AccountsStore(directory: directory).load(legacyCredential: (exists: true, email: "me@example.com"))
        let first = try #require(loaded.library.primary)
        #expect(first.id == "me@example.com" && first.stateFile == "state.json")
        #expect(loaded.library.state(for: first.id)?.uploaded.count == LegacyStateFixture.uploads)
        #expect(loaded.library.state(for: first.id)?.mirrors.count == LegacyStateFixture.albums)
        #expect(try Data(contentsOf: legacyURL) == before)
    }

    @Test func aFreshInstallHasNoAccountsAndNoRecord() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let loaded = AccountsStore(directory: directory).load(legacyCredential: (exists: false, email: nil))
        #expect(loaded.migrated)
        #expect(loaded.library.accounts.isEmpty && loaded.library.unclaimed == nil)
        #expect(loaded.legacyCredentialAccount == nil)
    }

    @Test func anUnreadableRecordIsSetAsideNotDeleted() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("{not json".utf8).write(to: directory.appendingPathComponent("state.json"))
        let loaded = AccountsStore(directory: directory).load(legacyCredential: (exists: true, email: "me@example.com"))
        #expect(loaded.unreadable["state.json"] != nil)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("state.json.unreadable").path))
        #expect(loaded.library.primary?.id == "me@example.com")
    }

    /// Review finding: downgraded, the single-account version signed in to
    /// another account rewrites state.json with that account's history.
    /// Upgraded again, that history is not taken for the first account's:
    /// the account it names takes it, the first one carries on in its own file.
    @Test func aStateFileRewrittenForAnotherAccountIsNotTakenForThisOne() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AccountsStore(directory: directory)
        let first = store.load(legacyCredential: (exists: true, email: "a@example.com"))
        try store.save(first.library.index)
        #expect(first.library.primary?.stateFile == "state.json")

        var other = BackupState()
        other.accountEmail = "b@example.com"
        other.recordUpload(assetID: "x", mediaKey: "key-b", existing: false)
        other.recordAlbum("trip", googleAlbumID: "album-b", added: ["x"])
        try BackupStore(url: directory.appendingPathComponent("state.json")).save(other)

        let loaded = store.load(legacyCredential: (exists: true, email: "b@example.com"))
        #expect(loaded.reassigned == ["a@example.com"])
        #expect(loaded.indexChanged)
        #expect(loaded.library.account("a@example.com")?.stateFile == AccountLibrary.stateFile(for: "a@example.com"))
        #expect(loaded.library.state(for: "a@example.com")?.uploaded.isEmpty == true)
        #expect(loaded.legacyCredentialAccount == "b@example.com")
        #expect(loaded.library.account("b@example.com")?.stateFile == "state.json")
        #expect(loaded.library.state(for: "b@example.com")?.mirrors["trip"]?.googleAlbumID == "album-b")
    }

    /// A lost accounts.json is rebuilt from state.json, and an added
    /// account's record, still on disk under its id's name, is found again
    /// when that account signs in.
    @Test func aLostIndexFindsEachAccountsRecordAgain() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AccountsStore(directory: directory)
        var library = store.load(legacyCredential: (exists: true, email: "a@example.com")).library
        var second = library.adopting(account: "b@example.com").state
        second.recordUpload(assetID: "x", mediaKey: "AF1QipX", existing: false)
        second.recordAlbum("trip", googleAlbumID: "AF1QipAlbum", added: ["x"])
        library.update(second, for: "b@example.com")
        for account in library.accounts {
            try store.save(try #require(library.storedState(for: account.id)), file: account.stateFile)
        }
        try store.save(library.index)
        try FileManager.default.removeItem(at: store.indexURL)
        // Its copy too: otherwise the index is simply read from the copy.
        try FileManager.default.removeItem(at: store.indexCopyURL)

        var rebuilt = store.load(legacyCredential: (exists: false, email: nil)).library
        let again = rebuilt.adopting(account: "b@example.com", stored: { store.readState($0) })
        #expect(again.state.uploaded["x"]?.mediaKey == "AF1QipX")
        #expect(again.state.mirrors["trip"]?.googleAlbumID == "AF1QipAlbum")
    }
}
