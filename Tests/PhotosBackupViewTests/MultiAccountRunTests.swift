import CryptoKit
import Foundation
@testable import PhotosBackup
import PhotosBackupCore
import XCTest

/// The whole app path for several accounts, against the fake gpmc: the
/// upgrade from one account (state.json and the "gpmc" keychain item),
/// adding an account, its storage check, runs that go through the accounts
/// one after another with the real engine and bridge, Stop, Remove and
/// signing in again.
///
/// Runs only from scripts/verify-accounts.sh, which gives the test process a
/// scratch PHOTOS_BACKUP_SANDBOX and a fake runtime: AppModel then keeps its
/// records, settings and keychain items in the sandbox (the keychain service
/// and settings suite are named after the xctest tool, not the app), never in
/// the app's own. No Photos library: Messages-style files stand in for items.
@MainActor
final class MultiAccountRunTests: XCTestCase {
    private static let first = "e2e.tester@example.com"
    private static let second = "e2e.second@example.com"

    private static func credential(_ email: String) -> String {
        "androidId=0123456789abcdef&app=com.google.android.apps.photos&client_sig=0&Email="
            + email.replacingOccurrences(of: "@", with: "%40") + "&service=oauth2&Token=aas_et/E2E-FAKE-TOKEN-NOT-A-SECRET"
    }

    private var support: URL { AppEnvironment.supportDirectory }
    private var runtime: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["PHOTOS_BACKUP_BRIDGE"] ?? "/").deletingLastPathComponent() }
    private var keychain: Keychain { Keychain.app }

    override func setUpWithError() throws {
        try XCTSkipUnless(AppEnvironment.isSandboxed && ProcessInfo.processInfo.environment["PHOTOS_BACKUP_BRIDGE"] != nil,
                          "Run through scripts/verify-accounts.sh: it needs a scratch sandbox and the fake gpmc runtime.")
        XCTAssertFalse(AppEnvironment.keychainService.contains("ayush5harma"), "never the app's own keychain service")
        XCTAssertFalse(support.path.contains("Library/Application Support"), "never the app's own support directory")
        clean()
    }

    override func tearDown() {
        guard AppEnvironment.isSandboxed else { return }
        clean()
    }

    private func clean() {
        for account in keychain.accounts() { keychain.delete(account: account) }
        try? FileManager.default.removeItem(at: support)
        try? FileManager.default.removeItem(at: runtime.appendingPathComponent("fake_gpmc_ledger.json"))
        AppEnvironment.defaults.removePersistentDomain(forName: AppEnvironment.bundleID + ".sandbox")
    }

    private func scenario(_ values: [String: Any]) throws {
        var values = values
        values["ledger"] = runtime.appendingPathComponent("fake_gpmc_ledger.json").path
        try JSONSerialization.data(withJSONObject: values).write(to: runtime.appendingPathComponent("fake_gpmc_scenario.json"))
    }

    private func uploads() throws -> [[String: Any]] {
        let url = runtime.appendingPathComponent("fake_gpmc_ledger.json")
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else { return [] }
        return object["uploads"] as? [[String: Any]] ?? []
    }

    /// Files the engine uploads as it would Messages attachments.
    private func items(_ count: Int, tag: String) throws -> [MessagesMediaItem] {
        let folder = support.deletingLastPathComponent().appendingPathComponent("files", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try (0..<count).map { index in
            let bytes = Data("\(tag)-\(index)-\(UUID().uuidString)".utf8)
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            let url = folder.appendingPathComponent("\(tag)-\(index).jpg")
            try bytes.write(to: url)
            return MessagesMediaItem(id: "messages:\(digest)", path: url.path, filename: "Messages-\(digest.prefix(12)).jpg")
        }
    }

    private func settle(_ model: AppModel, timeout: TimeInterval = 90) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        // Give a pass that was just asked for the moment it takes to start.
        try await Task.sleep(for: .milliseconds(300))
        while model.runner.isRunning || model.engine.isActive {
            XCTAssertLessThan(Date(), deadline, "the pass did not end")
            if Date() > deadline { return }
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    func testSeveralAccountsGetTheSameItemsOneAfterAnother() async throws {
        let firstID = GoogleSignIn.normalizedEmail(Self.first)
        let secondID = GoogleSignIn.normalizedEmail(Self.second)

        // A Mac from before accounts: one record, one credential.
        var legacy = BackupState()
        legacy.accountEmail = Self.first
        legacy.selectedAlbumIDs = ["all-photos"]
        legacy.recordUpload(assetID: "asset-1", mediaKey: "legacy-key", existing: false)
        legacy.recordAlbum("album-1", googleAlbumID: "fake-album-legacy", added: ["asset-1"])
        let legacyURL = support.appendingPathComponent("state.json")
        try BackupStore(url: legacyURL).save(legacy)
        let legacyBytes = try Data(contentsOf: legacyURL)
        try keychain.save(Self.credential(Self.first), account: AccountLibrary.legacyKeychainAccount)
        try scenario(["per_account": true])

        let model = AppModel()
        model.settings.automatic = false
        XCTAssertEqual(model.accounts.map(\.id), [firstID])
        XCTAssertEqual(model.primaryAccount?.stateFile, "state.json")
        XCTAssertEqual(keychain.accounts(), [firstID], "the gpmc item moved to its account")
        XCTAssertEqual(keychain.load(account: firstID), Self.credential(Self.first))
        XCTAssertEqual(try Data(contentsOf: legacyURL), legacyBytes, "state.json is untouched by the upgrade")
        XCTAssertTrue(FileManager.default.fileExists(atPath: support.appendingPathComponent("accounts.json").path))
        XCTAssertEqual(model.state.mirrors["album-1"]?.googleAlbumID, "fake-album-legacy")

        // A second account, signed in through the same path as Settings.
        await model.connect(pasted: Self.credential(Self.second))
        XCTAssertEqual(model.connectState, .idle)
        XCTAssertEqual(model.accounts.map(\.id), [firstID, secondID])
        XCTAssertEqual(model.status(of: secondID), .connected(email: Self.second))
        XCTAssertEqual(model.accounts.last?.storageChecked, false)
        XCTAssertEqual(model.runnableAccounts.map(\.id), [firstID], "an added account waits for its storage check")
        XCTAssertEqual(model.activeAccountID, firstID)
        XCTAssertEqual(keychain.accounts(), [firstID, secondID].sorted())

        let batch = try items(3, tag: "same-library")
        var turns: [String] = []
        model.runner.turn = { id, trigger in
            turns.append(id)
            XCTAssertEqual(model.activeAccountID, id, "the engine runs with the account whose turn it is")
            model.engine.backUp(messages: batch, includingPhotos: false, trigger: trigger)
        }

        model.startBackupNow()
        try await settle(model)
        XCTAssertEqual(turns, [firstID])
        XCTAssertEqual(Set(batch.map(\.id)).subtracting(model.record(of: firstID)?.uploaded.keys.map { $0 } ?? []), [])
        XCTAssertEqual(model.record(of: secondID)?.uploaded.count, 0)

        // The storage check: the same items, now to the second account too.
        model.confirmStorage(for: secondID)
        try await settle(model)
        XCTAssertEqual(turns, [firstID, firstID, secondID], "accounts in order, one after another")
        let firstRecord = try XCTUnwrap(model.record(of: firstID))
        let secondRecord = try XCTUnwrap(model.record(of: secondID))
        for item in batch {
            let firstKey = try XCTUnwrap(firstRecord.uploaded[item.id]?.mediaKey)
            let secondKey = try XCTUnwrap(secondRecord.uploaded[item.id]?.mediaKey)
            XCTAssertNotEqual(firstKey, secondKey, "each account records its own media key")
        }
        XCTAssertEqual(secondRecord.mirrors.count, 0)
        XCTAssertEqual(firstRecord.mirrors["album-1"]?.googleAlbumID, "fake-album-legacy", "the first account's album link survives")
        XCTAssertEqual(firstRecord.uploaded["asset-1"]?.mediaKey, "legacy-key")
        XCTAssertEqual(model.activeAccountID, firstID, "the primary is active again after the pass")

        let sent = try uploads().filter { ($0["status"] as? String) == "uploaded" }
        XCTAssertEqual(sent.filter { ($0["account"] as? String) == Self.first }.count, 3)
        XCTAssertEqual(sent.filter { ($0["account"] as? String) == Self.second }.count, 3)
        XCTAssertTrue(try uploads().allSatisfy { ($0["saver"] as? Bool) == false && ($0["use_quota"] as? Bool) == false },
                      "every account goes up as Original quality: saver and use_quota false (Pixel XL)")
        let runs = model.diagnostics.runs.filter { $0.kind == .messagesMedia }
        XCTAssertEqual(runs.compactMap(\.account), [Self.second, Self.first], "each run is recorded with its account (newest first)")

        // Stop ends the whole pass: the second account gets none of these.
        try scenario(["per_account": true, "delay": 0.4])
        let later = try items(6, tag: "stopped")
        model.runner.turn = { _, trigger in model.engine.backUp(messages: later, includingPhotos: false, trigger: trigger) }
        model.startBackupNow()
        let deadline = Date().addingTimeInterval(30)
        while !(model.engine.isActive && model.runner.current == firstID), Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        model.stopBackup()
        try await settle(model)
        XCTAssertTrue(later.allSatisfy { model.record(of: secondID)?.uploaded[$0.id] == nil }, "no account starts after Stop")
        XCTAssertEqual(model.diagnostics.runs.first?.outcome, .stopped)
        XCTAssertEqual(model.diagnostics.runs.first?.account, Self.first)
        try scenario(["per_account": true])

        // Remove signs one account out and touches nothing else.
        let firstBefore = model.record(of: firstID)
        await model.removeAccount(secondID)
        XCTAssertEqual(model.accounts.map(\.id), [firstID])
        XCTAssertEqual(keychain.accounts(), [firstID])
        XCTAssertEqual(model.record(of: firstID), firstBefore)
        let secondFile = support.appendingPathComponent(AccountLibrary.stateFile(for: secondID))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondFile.path), "its record stays for a later sign-in")

        // Signing in again picks its record back up: nothing to upload twice.
        await model.connect(pasted: Self.credential(Self.second))
        XCTAssertEqual(model.accounts.map(\.id), [firstID, secondID])
        XCTAssertEqual(model.accounts.last?.storageChecked, true)
        XCTAssertEqual(model.record(of: secondID)?.uploaded.count, 3)

        // A relaunch reads the same accounts and records.
        let relaunched = AppModel()
        XCTAssertEqual(relaunched.accounts.map(\.id), [firstID, secondID])
        XCTAssertEqual(relaunched.record(of: secondID)?.uploaded.count, 3)
        XCTAssertEqual(relaunched.record(of: firstID)?.mirrors["album-1"]?.googleAlbumID, "fake-album-legacy")
    }

    /// Two signed-in accounts, both through their storage check, no run yet.
    private func twoAccounts() async throws -> AppModel {
        let model = AppModel()
        model.settings.automatic = false
        await model.connect(pasted: Self.credential(Self.first))
        await model.connect(pasted: Self.credential(Self.second))
        model.confirmStorage(for: GoogleSignIn.normalizedEmail(Self.second))
        try await settle(model)
        XCTAssertEqual(model.runnableAccounts.map(\.id), [Self.first, Self.second].map(GoogleSignIn.normalizedEmail))
        return model
    }

    /// A primary run that halts (here Google refuses the primary's sign-in)
    /// leaves its Messages media queued in the engine. Found in review: the
    /// next account's run sent all of it to the second account. Nothing that
    /// only the primary takes may reach another account; it waits for the
    /// primary instead.
    func testWorkLeftQueuedByThePrimaryNeverGoesToAnotherAccount() async throws {
        let firstID = GoogleSignIn.normalizedEmail(Self.first)
        let secondID = GoogleSignIn.normalizedEmail(Self.second)
        try scenario(["per_account": true])
        let model = try await twoAccounts()

        try scenario(["per_account": true, "refuse_accounts": [Self.first]])
        let queued = try items(4, tag: "primary-only")
        // The app's own turns: Messages media to the primary, the photo run
        // (nothing to plan here, no Photos library) to every account.
        model.runner.turn = { id, trigger in
            if id == firstID {
                model.engine.backUp(messages: queued, includingPhotos: true, trigger: trigger)
            } else {
                model.engine.start(trigger: trigger)
            }
        }
        model.startBackupNow()
        try await settle(model)
        XCTAssertEqual(model.record(of: secondID)?.uploaded.count, 0, "the second account got the primary's Messages media")
        XCTAssertFalse(try uploads().contains { ($0["account"] as? String) == Self.second })
        XCTAssertTrue(model.engine.hasQueuedPrimaryOnlyWork, "the items wait for the primary")
        XCTAssertEqual(model.activeAccountID, firstID)

        // The primary's sign-in works again: they go to the primary, and only there.
        try scenario(["per_account": true])
        model.runner.turn = { _, trigger in model.engine.start(trigger: trigger) }
        model.startBackupNow()
        try await settle(model)
        let primary = Set(model.record(of: firstID)?.uploaded.keys.map { $0 } ?? [])
        XCTAssertTrue(Set(queued.map(\.id)).isSubset(of: primary))
        XCTAssertFalse(model.engine.hasQueuedPrimaryOnlyWork)
        XCTAssertEqual(model.record(of: secondID)?.uploaded.count, 0)
    }
}
