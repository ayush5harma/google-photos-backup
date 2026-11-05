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
        model.runner.turn = { turn, trigger in
            let id = turn.account
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
        XCTAssertEqual(runs.compactMap { model.accountTitle(reference: $0.account) }, [Self.second, Self.first],
                       "each run is recorded with its account (newest first)")
        let history = try String(contentsOf: support.appendingPathComponent("history.json"), encoding: .utf8)
        XCTAssertFalse(history.contains("example.com"), "history.json names accounts by reference only")

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
        XCTAssertEqual(model.accountTitle(reference: model.diagnostics.runs.first?.account), Self.first)
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

    private static let third = "e2e.third@example.com"

    /// Each turn hands the engine `batch` as stand-ins for the selected
    /// albums (no Photos library here), and records what the turn was.
    private func recordTurns(_ model: AppModel, batch: @escaping () -> [MessagesMediaItem]) -> () -> [AccountRunner.Turn] {
        var turns: [AccountRunner.Turn] = []
        model.runner.turn = { turn, trigger in
            turns.append(turn)
            XCTAssertEqual(model.activeAccountID, turn.account, "the engine runs with the account whose turn it is")
            XCTAssertEqual(model.activeTakesSelection, turn.photos, "the engine plans the albums exactly when the turn takes them")
            model.engine.backUp(messages: batch(), includingPhotos: false, trigger: trigger)
        }
        return {
            defer { turns = [] }
            return turns
        }
    }

    private func uploaded(_ items: [MessagesMediaItem], in model: AppModel, _ id: String) -> Bool {
        let record = model.record(of: id)?.uploaded ?? [:]
        return items.allSatisfy { record[$0.id] != nil }
    }

    private func untouched(_ items: [MessagesMediaItem], in model: AppModel, _ id: String) -> Bool {
        let record = model.record(of: id)?.uploaded ?? [:]
        return items.allSatisfy { record[$0.id] == nil }
    }

    /// "Back up to": all accounts (an account added later included), then
    /// only the chosen ones, and one-off runs to one account or to all that
    /// never change the choice; the choice is in accounts.json.
    func testBackupsGoToTheChosenAccountsAndAOneOffLeavesTheChoiceAlone() async throws {
        let firstID = GoogleSignIn.normalizedEmail(Self.first)
        let secondID = GoogleSignIn.normalizedEmail(Self.second)
        let thirdID = GoogleSignIn.normalizedEmail(Self.third)
        try scenario(["per_account": true])
        let model = try await twoAccounts()
        XCTAssertEqual(model.accountsChoice, .all)
        var batch = try items(2, tag: "all")
        let turns = recordTurns(model) { batch }

        model.startBackupNow()
        try await settle(model)
        XCTAssertEqual(turns().map(\.account), [firstID, secondID], "All accounts: every account, in order")
        XCTAssertTrue(uploaded(batch, in: model, firstID) && uploaded(batch, in: model, secondID))

        // Leave the primary out: backups go to the second account only.
        model.setIncluded(firstID, false)
        XCTAssertEqual(model.accountsChoice, .chosen)
        XCTAssertEqual(model.targetAccounts.map(\.id), [secondID])
        batch = try items(2, tag: "chosen")
        model.startBackupNow()
        try await settle(model)
        XCTAssertEqual(turns().map(\.account), [secondID])
        XCTAssertTrue(uploaded(batch, in: model, secondID))
        XCTAssertTrue(untouched(batch, in: model, firstID), "an account left out gets nothing from Back Up Now")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let saved = try decoder.decode(AccountsIndex.self, from: Data(contentsOf: support.appendingPathComponent("accounts.json")))
        XCTAssertEqual(saved.backUpTo, .chosen, "the choice is stored beside the selection")
        XCTAssertEqual(saved.accounts.map(\.chosen), [false, true])

        // A one-off to the account left out goes there, and only there.
        model.startBackupNow(to: .only(firstID))
        try await settle(model)
        XCTAssertEqual(turns(), [AccountRunner.Turn(account: firstID, photos: true, messages: false)])
        XCTAssertTrue(uploaded(batch, in: model, firstID))
        XCTAssertEqual(model.accountsChoice, .chosen, "a one-off does not change the choice")
        XCTAssertFalse(model.isIncluded(firstID))

        // "All accounts" in the Back Up Now menu, also a one-off.
        batch = try items(1, tag: "every")
        model.startBackupNow(to: .every)
        try await settle(model)
        XCTAssertEqual(turns().map(\.account), [firstID, secondID])
        XCTAssertEqual(model.targetAccounts.map(\.id), [secondID])

        // A relaunch reads the same choice.
        let relaunched = AppModel()
        XCTAssertEqual(relaunched.accountsChoice, .chosen)
        XCTAssertEqual(relaunched.targetAccounts.map(\.id), [secondID])

        // Back to all accounts; one added later joins once its storage
        // check is confirmed.
        model.chooseAccounts(.all)
        await model.connect(pasted: Self.credential(Self.third))
        XCTAssertTrue(model.isIncluded(thirdID))
        XCTAssertEqual(model.targetAccounts.map(\.id), [firstID, secondID], "still waiting for its storage check")
        batch = try items(1, tag: "added-later")
        model.confirmStorage(for: thirdID)
        try await settle(model)
        XCTAssertEqual(turns().map(\.account), [firstID, secondID, thirdID])
        XCTAssertTrue(uploaded(batch, in: model, thirdID))
        XCTAssertTrue(try uploads().allSatisfy { ($0["saver"] as? Bool) == false && ($0["use_quota"] as? Bool) == false },
                      "every account, one-offs included, goes up as Original quality (Pixel XL)")
    }

    /// photosbackup://backup keeps meaning the saved choice; ?account=
    /// names one account exactly, and an address no account has is logged
    /// and ignored, never matched to another.
    func testALinkBacksUpToTheAccountItNamesAndNeverGuesses() async throws {
        let firstID = GoogleSignIn.normalizedEmail(Self.first)
        let secondID = GoogleSignIn.normalizedEmail(Self.second)
        try scenario(["per_account": true])
        let model = try await twoAccounts()
        model.setIncluded(secondID, false)
        let batch = try items(1, tag: "link")
        let turns = recordTurns(model) { batch }
        func follow(_ link: String) async throws {
            model.perform(try XCTUnwrap(AutomationCommand(url: try XCTUnwrap(URL(string: link)))))
            try await settle(model)
        }

        try await follow("photosbackup://backup")
        XCTAssertEqual(turns().map(\.account), [firstID], "the saved choice")

        // Named as typed, in another case: the account left out, one-off.
        try await follow("photosbackup://backup?account=E2E.Second%40Example.COM")
        XCTAssertEqual(turns().map(\.account), [secondID])
        XCTAssertEqual(model.accountsChoice, .chosen)
        XCTAssertFalse(model.isIncluded(secondID), "a link does not change the choice")
        let runs = model.diagnostics.runs.prefix(1)
        XCTAssertEqual(runs.first?.trigger, .automation)

        try await follow("photosbackup://backup?account=nobody@example.com")
        XCTAssertEqual(turns(), [], "an unknown account is ignored")
        // The timeline masks addresses (n***@example.com), as it always has.
        XCTAssertTrue(model.diagnostics.events.contains { $0.message.contains("@example.com, which is not an account signed in here") && $0.isProblem },
                      "and the timeline says so")
        // An address that differs from a signed-in one by one letter is
        // still unknown: it is never matched to the nearest account.
        try await follow("photosbackup://backup?account=e2e.secnd@example.com")
        XCTAssertEqual(turns(), [])
    }

    /// Picks, Messages media and device imports go only to the primary,
    /// also when the choice leaves the primary out of photo backups: its
    /// turn then carries Messages media alone, and outside a pass a run on
    /// it never plans the selected albums.
    func testAPrimaryLeftOutStillTakesWhatOnlyItTakes() async throws {
        let firstID = GoogleSignIn.normalizedEmail(Self.first)
        let secondID = GoogleSignIn.normalizedEmail(Self.second)
        try scenario(["per_account": true])
        let model = try await twoAccounts()
        model.settings.messagesMedia = true
        model.setIncluded(firstID, false)
        typealias Turn = AccountRunner.Turn
        XCTAssertEqual(model.runner.plan(.chosen, messages: true),
                       [Turn(account: firstID, photos: false, messages: true), Turn(account: secondID, photos: true, messages: false)])
        XCTAssertEqual(model.runner.plan(.chosen, messages: false), [Turn(account: secondID, photos: true, messages: false)],
                       "a photos-only backup does not visit the primary")
        XCTAssertEqual(model.runner.plan(.only(secondID), messages: true), [Turn(account: secondID, photos: true, messages: false)],
                       "Messages media never goes to another account")
        XCTAssertEqual(model.runner.plan(.only(firstID), messages: true), [Turn(account: firstID, photos: true, messages: true)])
        XCTAssertEqual(model.activeAccountID, firstID)
        XCTAssertFalse(model.activeTakesSelection, "a pick or a device import on the primary left out plans no albums")

        let messages = try items(3, tag: "messages")
        let photos = try items(2, tag: "photos")
        var turns: [Turn] = []
        model.runner.turn = { turn, trigger in
            turns.append(turn)
            XCTAssertEqual(model.activeTakesSelection, turn.photos)
            model.engine.backUp(messages: turn.messages ? messages : photos, includingPhotos: turn.photos, trigger: trigger)
        }
        model.startBackupNow()
        try await settle(model)
        XCTAssertEqual(turns, [Turn(account: firstID, photos: false, messages: true), Turn(account: secondID, photos: true, messages: false)])
        XCTAssertTrue(uploaded(messages, in: model, firstID), "Messages media went to the primary")
        XCTAssertTrue(untouched(messages, in: model, secondID))
        XCTAssertTrue(uploaded(photos, in: model, secondID))
        XCTAssertTrue(untouched(photos, in: model, firstID))
        XCTAssertEqual(model.activeAccountID, firstID)
    }

    /// With every account left out, nothing runs and the status says why,
    /// instead of "Everything is backed up".
    func testNoAccountIncludedRunsNothingAndSaysSo() async throws {
        let firstID = GoogleSignIn.normalizedEmail(Self.first)
        let secondID = GoogleSignIn.normalizedEmail(Self.second)
        try scenario(["per_account": true])
        let model = try await twoAccounts()
        model.setIncluded(firstID, false)
        model.setIncluded(secondID, false)
        XCTAssertTrue(model.noAccountIncluded)
        XCTAssertEqual(model.targetAccounts, [])
        let turns = recordTurns(model) { [] }
        model.startBackupNow()
        try await settle(model)
        XCTAssertEqual(turns(), [])
        XCTAssertTrue(model.diagnostics.events.contains { $0.message.contains("no Google account is included in backups") })
        XCTAssertEqual(model.overallSummary.total, 0)
        XCTAssertEqual(model.status.kind, .attention)
        XCTAssertTrue(model.attention.contains { $0.id == "no-account" })
    }

    /// A primary run that halts (here Google refuses the primary's sign-in)
    /// leaves its Messages media queued in the engine. Found in review: the
    /// next account's run sent all of it to the second account. Nothing that
    /// only the primary takes may reach another account, and the other
    /// accounts still back up (the second review: holding the queue stopped
    /// them for as long as the primary failed).
    func testWorkLeftQueuedByThePrimaryNeverGoesToAnotherAccount() async throws {
        let firstID = GoogleSignIn.normalizedEmail(Self.first)
        let secondID = GoogleSignIn.normalizedEmail(Self.second)
        try scenario(["per_account": true])
        let model = try await twoAccounts()

        try scenario(["per_account": true, "refuse_accounts": [Self.first]])
        let queued = try items(4, tag: "primary-only")
        // The app's own turns: Messages media to the primary, the photo run
        // (nothing to plan here, no Photos library) to every account.
        model.runner.turn = { turn, trigger in
            let id = turn.account
            if id == firstID {
                model.engine.backUp(messages: queued, includingPhotos: true, trigger: trigger)
            } else {
                model.engine.start(trigger: trigger)
            }
        }
        let runsBefore = model.diagnostics.runs.count
        model.startBackupNow()
        try await settle(model)
        XCTAssertEqual(model.record(of: secondID)?.uploaded.count, 0, "the second account got the primary's Messages media")
        XCTAssertFalse(try uploads().contains { ($0["account"] as? String) == Self.second })
        let newRuns = model.diagnostics.runs.prefix(model.diagnostics.runs.count - runsBefore)
        XCTAssertTrue(newRuns.contains { model.accountTitle(reference: $0.account) == Self.second },
                      "the second account still had its run while the primary failed")
        XCTAssertFalse(model.engine.hasQueuedPrimaryOnlyWork, "the queue came out of the engine before the second account's run")
        XCTAssertEqual(model.activeAccountID, firstID)

        // The primary's sign-in works again; a scan finds the items again,
        // and they go to the primary, and only there.
        try scenario(["per_account": true])
        model.runner.turn = { turn, trigger in
            let id = turn.account
            if id == firstID {
                model.engine.backUp(messages: queued, includingPhotos: true, trigger: trigger)
            } else {
                model.engine.start(trigger: trigger)
            }
        }
        model.startBackupNow()
        try await settle(model)
        let primary = Set(model.record(of: firstID)?.uploaded.keys.map { $0 } ?? [])
        XCTAssertTrue(Set(queued.map(\.id)).isSubset(of: primary))
        XCTAssertFalse(model.engine.hasQueuedPrimaryOnlyWork)
        XCTAssertEqual(model.record(of: secondID)?.uploaded.count, 0)
    }
}
