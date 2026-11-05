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
        Keychain.refusedDeletesForTesting = []
        for account in keychain.accounts() { try? keychain.delete(account: account) }
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
    /// `prefix` "photo:" makes them stand in for library photos where a test
    /// needs failures: BackupEngine.fail records a "messages:" id only for an
    /// item in its Messages queue, so a stand-in that fails with that prefix
    /// leaves nothing for Retry.
    private func items(_ count: Int, tag: String, prefix: String = "messages:") throws -> [MessagesMediaItem] {
        let folder = support.deletingLastPathComponent().appendingPathComponent("files", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try (0..<count).map { index in
            let bytes = Data("\(tag)-\(index)-\(UUID().uuidString)".utf8)
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            let url = folder.appendingPathComponent("\(tag)-\(index).jpg")
            try bytes.write(to: url)
            return MessagesMediaItem(id: "\(prefix)\(digest)", path: url.path, filename: "Messages-\(digest.prefix(12)).jpg")
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

    func testSeveralAccountsGetTheSameItemsAtTheSameTime() async throws {
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
        var batchToSend = batch
        var passes: [[String]] = []
        model.runner.turn = { turns, trigger in
            passes.append(turns.map(\.account))
            XCTAssertEqual(model.activeAccountID, firstID, "the primary stays active: each account's part has its own record")
            model.engine.standInsForTesting = batchToSend
            model.engine.start(trigger: trigger)
        }

        model.startBackupNow()
        try await settle(model)
        XCTAssertEqual(passes, [[firstID]])
        XCTAssertEqual(Set(batch.map(\.id)).subtracting(model.record(of: firstID)?.uploaded.keys.map { $0 } ?? []), [])
        XCTAssertEqual(model.record(of: secondID)?.uploaded.count, 0)

        // The storage check: the same items, now to the second account too.
        model.confirmStorage(for: secondID)
        try await settle(model)
        XCTAssertEqual(passes, [[firstID], [firstID, secondID]], "both accounts in one pass")
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
        XCTAssertEqual(model.activeAccountID, firstID, "the primary is active after the pass")

        let sent = try uploads().filter { ($0["status"] as? String) == "uploaded" }
        XCTAssertEqual(sent.filter { ($0["account"] as? String) == Self.first }.count, 3)
        XCTAssertEqual(sent.filter { ($0["account"] as? String) == Self.second }.count, 3)
        XCTAssertTrue(try uploads().allSatisfy { ($0["saver"] as? Bool) == false && ($0["use_quota"] as? Bool) == false },
                      "every account goes up as Original quality: saver and use_quota false (Pixel XL)")
        let runs = model.diagnostics.runs.filter { $0.kind == .photos && $0.uploaded > 0 }
        XCTAssertEqual(runs.compactMap { model.accountTitle(reference: $0.account) }, [Self.second, Self.first],
                       "each account's part is recorded with its account (newest first)")
        let history = try String(contentsOf: support.appendingPathComponent("history.json"), encoding: .utf8)
        XCTAssertFalse(history.contains("example.com"), "history.json names accounts by reference only")

        // Issue #66: new items for both accounts go up at the same time,
        // each exported once, each account through its own bridge.
        let both = try items(4, tag: "side-by-side")
        batchToSend = both
        let exportsBefore = model.engine.standInExportsForTesting
        model.startBackupNow()
        try await settle(model)
        XCTAssertEqual(passes.last, [firstID, secondID])
        XCTAssertTrue(uploaded(both, in: model, firstID) && uploaded(both, in: model, secondID))
        XCTAssertEqual(model.engine.standInExportsForTesting - exportsBefore, both.count, "each item exported once for both accounts")
        XCTAssertEqual(model.engine.mostAccountsSendingForTesting, 2, "both accounts had a request in flight at once")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: model.paths.staging.path).isEmpty,
                      "the staged files went once both accounts were done with them")

        // Stop ends the whole pass, every account's part at once.
        try scenario(["per_account": true, "delay": 0.4])
        let later = try items(6, tag: "stopped")
        batchToSend = later
        let runsBefore = model.diagnostics.runs.count
        model.startBackupNow()
        let deadline = Date().addingTimeInterval(30)
        // The counter still holds the last pass's 2 until start() resets it.
        while !model.engine.isActive, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        while model.engine.mostAccountsSendingForTesting < 2, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        model.stopBackup()
        try await settle(model)
        XCTAssertFalse(uploaded(later, in: model, firstID) && uploaded(later, in: model, secondID), "Stop ended the pass early")
        let stoppedRuns = model.diagnostics.runs.prefix(model.diagnostics.runs.count - runsBefore)
        XCTAssertEqual(stoppedRuns.map(\.outcome), [.stopped, .stopped])
        XCTAssertEqual(Set(stoppedRuns.compactMap { model.accountTitle(reference: $0.account) }), [Self.first, Self.second])
        XCTAssertFalse(model.engine.isActive)
        try scenario(["per_account": true])

        // Remove signs one account out and touches nothing else.
        let firstBefore = model.record(of: firstID)
        let secondUploads = try XCTUnwrap(model.record(of: secondID)?.uploaded.count)
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
        XCTAssertEqual(model.record(of: secondID)?.uploaded.count, secondUploads)

        // A relaunch reads the same accounts and records.
        let relaunched = AppModel()
        XCTAssertEqual(relaunched.accounts.map(\.id), [firstID, secondID])
        XCTAssertEqual(relaunched.record(of: secondID)?.uploaded.count, secondUploads)
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

    /// Each pass hands the engine `batch` as stand-ins for the selected
    /// albums (no Photos library here), planned for every account the pass
    /// takes the albums to, and records the pass's parts.
    private func recordTurns(_ model: AppModel, batch: @escaping () -> [MessagesMediaItem]) -> () -> [AccountRunner.Turn] {
        var turns: [AccountRunner.Turn] = []
        model.runner.turn = { passTurns, trigger in
            turns += passTurns
            XCTAssertEqual(model.engine.preparedPlansForTesting?.map(\.account), passTurns.map(\.account),
                           "one run goes to every account of the pass")
            XCTAssertEqual(model.engine.preparedPlansForTesting?.map(\.photos), passTurns.map(\.photos),
                           "the engine plans the albums exactly for the parts that take them")
            model.engine.standInsForTesting = batch()
            model.engine.start(trigger: trigger)
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
        model.runner.turn = { passTurns, trigger in
            turns += passTurns
            // The app's own order: Messages media found for the primary
            // starts the one run, which takes the albums to the second.
            model.engine.standInsForTesting = photos
            model.engine.backUp(messages: messages, includingPhotos: passTurns.contains(where: \.photos), trigger: trigger)
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

    /// The engine's own planning, the step every run takes before it
    /// uploads: the album is planned only for an account the run takes it
    /// to. A primary left out plans its pick and never the album; in a pass,
    /// the turn decides (a one-off to it takes the album), and unticking an
    /// account during its turn drops the album from the next pass. Read
    /// without exporting: exports reach PhotoKit, which this test process
    /// must never ask for access.
    func testTheEnginePlansTheAlbumsOnlyForAnAccountTheRunTakesThemTo() async throws {
        let firstID = GoogleSignIn.normalizedEmail(Self.first)
        let secondID = GoogleSignIn.normalizedEmail(Self.second)
        try scenario(["per_account": true])
        let model = try await twoAccounts()
        model.settings.reuploadEdits = false
        let albumAssets: Set<String> = ["asset-a", "asset-b", "asset-c"]
        model.useAlbumsForTesting([LibraryAlbum(snapshot: AlbumSnapshot(id: "trip", title: "Trip", kind: .user, assetIDs: albumAssets.sorted()),
                                                symbol: "rectangle.stack")])
        model.state.selectedAlbumIDs = ["trip"]
        func planned() -> Set<String> {
            Set(model.engine.planPass(settings: model.settings).flatMap { step -> [String] in
                if case let .upload(_, _, ids) = step { return ids }
                return []
            })
        }

        model.engine.setPickedForTesting(["picked-1"])
        XCTAssertEqual(planned(), albumAssets.union(["picked-1"]), "an included primary: the pick, then the album")
        model.setIncluded(firstID, false)
        XCTAssertEqual(model.activeAccountID, firstID)
        XCTAssertEqual(planned(), ["picked-1"], "a primary left out: the pick and never the album")
        // No pick may be left queued: a pass ends by handing held picks to
        // the engine, whose run would export them.
        model.engine.setPickedForTesting([])

        model.settings.messagesMedia = true
        var seen: [String: Set<String>] = [:]
        model.runner.turn = { _, _ in seen = self.plannedUploads(self.planEachPart(model)) }
        model.startBackupNow()
        try await settle(model)
        XCTAssertEqual(seen[firstID], [], "the primary's Messages-only part plans no album")
        XCTAssertEqual(seen[secondID], albumAssets)

        seen = [:]
        model.startBackupNow(to: .only(firstID))
        try await settle(model)
        XCTAssertEqual(seen[firstID], albumAssets, "a one-off to the primary left out takes the album")
        XCTAssertNil(seen[secondID])

        // Unticked during the run: the next pass plans no album for it.
        model.setIncluded(firstID, true)
        var duringRun: [Set<String>] = []
        model.runner.turn = { _, _ in
            duringRun.append(self.plannedUploads(self.planEachPart(model))[secondID] ?? [])
            model.setIncluded(secondID, false)
            duringRun.append(self.plannedUploads(self.planEachPart(model))[secondID] ?? [])
        }
        model.startBackupNow()
        try await settle(model)
        XCTAssertEqual(duringRun, [albumAssets, []])
    }

    /// Each account's plan for one pass of the run AccountRunner prepared,
    /// all planned together as the run plans them, without exporting:
    /// exports reach PhotoKit, which this test process must never ask for
    /// access.
    private func planEachPart(_ model: AppModel) -> [String: [PlannedStep]] {
        model.engine.planPassForTesting(model.engine.preparedPlansForTesting ?? [], settings: model.settings).steps
    }

    private func plannedUploads(_ steps: [String: [PlannedStep]]) -> [String: Set<String>] {
        steps.mapValues { steps in
            Set(steps.flatMap { step -> [String] in
                if case let .upload(_, _, ids) = step { return ids }
                return []
            })
        }
    }

    /// Guard B (0.6.0): a hidden photo the albums list goes to the primary's
    /// library (never an album) and to no other account, which never counts
    /// it as still to back up either. Planned per turn without exporting.
    func testAHiddenPhotoNeverGoesToAnAccountButThePrimary() async throws {
        let firstID = GoogleSignIn.normalizedEmail(Self.first)
        let secondID = GoogleSignIn.normalizedEmail(Self.second)
        try scenario(["per_account": true])
        let model = try await twoAccounts()
        model.settings.reuploadEdits = false
        model.useAlbumsForTesting([
            LibraryAlbum(snapshot: AlbumSnapshot(id: "trip", title: "Trip", kind: .user, assetIDs: ["asset-a", "hidden-h", "asset-b"],
                                                 hiddenAssetIDs: ["hidden-h"]), symbol: "rectangle.stack"),
            LibraryAlbum(snapshot: AlbumSnapshot(id: PhotoLibrary.allPhotosID, title: "All Photos", kind: .allPhotos,
                                                 assetIDs: ["asset-a", "hidden-h", "asset-b", "asset-c"], hiddenAssetIDs: ["hidden-h"]),
                         symbol: "photo"),
        ])
        model.state.selectedAlbumIDs = ["trip", PhotoLibrary.allPhotosID]
        model.saveState()

        var seen: [String: [PlannedStep]] = [:]
        var pass: SharedPass?
        model.runner.turn = { _, _ in
            let planned = model.engine.planPassForTesting(model.engine.preparedPlansForTesting ?? [], settings: model.settings)
            seen = planned.steps
            pass = planned.pass
        }
        model.startBackupNow()
        try await settle(model)
        // Both accounts planned for one pass: the batches they share never
        // give the second account the hidden photo, nor put it in an album.
        let sends = try XCTUnwrap(pass).batches.flatMap(\.sends)
        XCTAssertFalse(sends.contains { $0.account == secondID && $0.assetIDs.contains("hidden-h") })
        XCTAssertFalse(sends.contains { $0.albumTitle != nil && $0.assetIDs.contains("hidden-h") })
        XCTAssertEqual(try XCTUnwrap(pass).batches.flatMap(\.assetIDs).filter { $0 == "hidden-h" }.count, 1, "exported once")
        XCTAssertEqual(seen[firstID], [
            .upload(albumID: "trip", albumTitle: "Trip", assetIDs: ["asset-a", "asset-b"]),
            .upload(albumID: "trip", albumTitle: nil, assetIDs: ["hidden-h"]),
            .upload(albumID: PhotoLibrary.allPhotosID, albumTitle: nil, assetIDs: ["asset-c"]),
        ], "the primary: the hidden photo to its library only")
        XCTAssertEqual(seen[secondID], [
            .upload(albumID: "trip", albumTitle: "Trip", assetIDs: ["asset-a", "asset-b"]),
            .upload(albumID: PhotoLibrary.allPhotosID, albumTitle: nil, assetIDs: ["asset-c"]),
        ], "another account is never sent the hidden photo")

        XCTAssertEqual(model.activeAccountID, firstID)
        XCTAssertEqual(model.summary(of: firstID).pending, 4)
        XCTAssertEqual(model.summary(of: secondID).pending, 3, "another account never counts a hidden photo as to back up")
        XCTAssertEqual(model.overallSummary.pending, 7)
    }

    /// Guard C (1), the 2026-11-05 incident on an added account: its album
    /// linked, every member backed up, the member record cleared. Its turn
    /// re-baselines the album instead of re-adding everything, says so in
    /// the timeline, and keeps the new record; the primary, whose album is
    /// new, still creates it with every member.
    func testALinkedAlbumWithNoRecordIsReBaselinedNotRefilled() async throws {
        let firstID = GoogleSignIn.normalizedEmail(Self.first)
        let secondID = GoogleSignIn.normalizedEmail(Self.second)
        try scenario(["per_account": true])
        let model = try await twoAccounts()
        model.settings.reuploadEdits = false
        let members = ["asset-a", "asset-b", "asset-c"]
        model.useAlbumsForTesting([LibraryAlbum(snapshot: AlbumSnapshot(id: "shared", title: "Shared With Family", kind: .user,
                                                                        assetIDs: members), symbol: "rectangle.stack")],
                                  unlisted: [AlbumSnapshot(id: "emptied", title: "Emptied", kind: .user, assetIDs: [])])
        model.state.selectedAlbumIDs = ["shared", "emptied"]
        model.saveState()

        var seen: [String: [PlannedStep]] = [:]
        model.runner.turn = { _, _ in
            model.modifyRecord(of: secondID) { state in
                for id in members { state.recordUpload(assetID: id, mediaKey: "second-\(id)", existing: false) }
                state.mirrors["shared"] = AlbumMirror(googleAlbumID: "fake-album-shared", addedAssetIDs: [])
                state.mirrors["emptied"] = AlbumMirror(googleAlbumID: "fake-album-emptied", addedAssetIDs: [])
            }
            // Both accounts planned together, as one pass of the run plans them.
            seen = self.planEachPart(model)
        }
        model.startBackupNow()
        try await settle(model)
        XCTAssertEqual(seen[firstID], [.upload(albumID: "shared", albumTitle: "Shared With Family", assetIDs: members)],
                       "a brand-new album is created with every member")
        XCTAssertEqual(seen[secondID], [], "nothing is re-added to the linked album")
        XCTAssertEqual(model.record(of: secondID)?.mirrors["shared"]?.knownAssetIDs, Set(members))
        XCTAssertEqual(model.record(of: secondID)?.mirrors["emptied"]?.knownAssetIDs, [],
                       "an album with nothing to list gets an empty record, so photos added later go in")
        let saved = try BackupStore(url: support.appendingPathComponent(AccountLibrary.stateFile(for: secondID))).load()
        XCTAssertEqual(saved.mirrors["shared"]?.knownAssetIDs, Set(members), "the new baseline is on disk")
        // Problems reach the shareable report: counts only, the title in a plain line (review MAJOR 4).
        let problems = model.diagnostics.events.filter { $0.isProblem && $0.message.contains("had no record") }
        XCTAssertEqual(problems.count, 2, "one per album re-baselined")
        XCTAssertTrue(problems.contains { $0.message.contains("its 3 photos") }, problems.map(\.message).joined(separator: " / "))
        XCTAssertFalse(model.diagnostics.events.contains { $0.isProblem && $0.message.contains("Shared With Family") },
                       "an album title in a problem line")
        XCTAssertTrue(model.diagnostics.events.contains { !$0.isProblem && $0.message.contains("Shared With Family") })
    }

    /// Guard C (2) on an added account: two albums it linked earlier have 30
    /// and 26 photos it has backed up but not filed. Nothing goes into
    /// either; the timeline and the Overview say so per album and account;
    /// "Add them" sends one album's photos on that account's next turn and
    /// "Skip" records the other's as known, both kept on disk. The primary,
    /// whose albums are new, still creates them with every member.
    func testBulkAddsToALinkedAlbumWaitForTheOwner() async throws {
        let firstID = GoogleSignIn.normalizedEmail(Self.first)
        let secondID = GoogleSignIn.normalizedEmail(Self.second)
        try scenario(["per_account": true])
        let model = try await twoAccounts()
        model.settings.reuploadEdits = false
        let old = (0..<5).map { "old-\($0)" }
        let shared = (0..<30).map { "shared-\($0)" }, other = (0..<26).map { "other-\($0)" }
        model.useAlbumsForTesting([
            LibraryAlbum(snapshot: AlbumSnapshot(id: "shared", title: "Shared With Family", kind: .user, assetIDs: shared + old),
                         symbol: "rectangle.stack"),
            LibraryAlbum(snapshot: AlbumSnapshot(id: "other", title: "Other", kind: .user, assetIDs: other + old), symbol: "rectangle.stack"),
        ])
        model.state.selectedAlbumIDs = ["shared", "other"]
        model.saveState()

        var seen: [String: [PlannedStep]] = [:]
        model.runner.turn = { _, _ in
            if model.record(of: secondID)?.mirrors.isEmpty == true {
                model.modifyRecord(of: secondID) { state in
                    for id in old + shared + other { state.recordUpload(assetID: id, mediaKey: "second-\(id)", existing: false) }
                    state.mirrors["shared"] = AlbumMirror(googleAlbumID: "fake-album-shared", addedAssetIDs: Set(old))
                    state.mirrors["other"] = AlbumMirror(googleAlbumID: "fake-album-other", addedAssetIDs: Set(old))
                }
            }
            // Both accounts planned together, as one pass of the run plans them.
            seen = self.planEachPart(model)
        }
        model.startBackupNow()
        try await settle(model)
        let intoAlbums = (seen[firstID] ?? []).flatMap { step -> [String] in
            if case let .upload(albumID, title?, ids) = step { return ids.map { "\(albumID)/\(title)/\($0)" } }
            return []
        }
        XCTAssertEqual(intoAlbums, (shared + old).map { "shared/Shared With Family/\($0)" } + other.map { "other/Other/\($0)" },
                       "brand-new albums take every member")
        XCTAssertEqual(seen[secondID], [], "nothing goes into either linked album")
        let notices = model.heldAlbumAdds
        XCTAssertEqual(notices.map(\.account), [secondID, secondID])
        XCTAssertEqual(notices.map(\.held.albumID), ["shared", "other"])
        XCTAssertEqual(notices.map(\.count), [30, 26])
        XCTAssertEqual(notices.first?.accountTitle, Self.second, "with several accounts, the notice names its account")
        let problems = model.diagnostics.events.filter { $0.isProblem && $0.message.contains("waiting to be added to") }
        XCTAssertEqual(problems.count, 2)
        XCTAssertTrue(problems.contains { $0.message.hasPrefix("30 photos waiting to be added to an album") })
        XCTAssertFalse(model.diagnostics.events.contains { $0.isProblem && ($0.message.contains("Shared With Family") || $0.message.contains("\"Other\"")) },
                       "an album title in a problem line")
        XCTAssertTrue(model.diagnostics.events.contains { !$0.isProblem && $0.message.contains("\"Shared With Family\"") })

        let addShared = try XCTUnwrap(notices.first { $0.held.albumID == "shared" })
        let skipOther = try XCTUnwrap(notices.first { $0.held.albumID == "other" })
        model.skipHeldPhotos(skipOther)
        seen = [:]
        model.addHeldPhotos(addShared)
        try await settle(model)
        XCTAssertEqual(seen[secondID], [.addToAlbum(albumID: "shared", albumTitle: "Shared With Family", assetIDs: shared,
                                                    mediaKeys: shared.map { "second-\($0)" })],
                       "Add them sends that album's photos, on that account, and nothing for the skipped album")
        XCTAssertNil(seen[firstID], "Add them runs only the account the photos wait for")
        XCTAssertTrue(model.heldAlbumAdds.isEmpty)
        let saved = try BackupStore(url: support.appendingPathComponent(AccountLibrary.stateFile(for: secondID))).load()
        XCTAssertEqual(saved.mirrors["shared"]?.approvedAssetIDs, Set(shared))
        XCTAssertEqual(saved.mirrors["other"]?.knownAssetIDs, Set(other))
        XCTAssertEqual(saved.mirrors["other"]?.addedAssetIDs, Set(old), "skipped photos are not taken for added")
    }

    /// Review of feat/53-guards, minor 7: a hold the engine makes is kept and
    /// shown until the owner chooses. Here 26 photos are held on the added
    /// account; two are then taken out of the Apple album, which leaves 24,
    /// under the limit, and they still wait instead of going in by themselves.
    func testAHoldIsKeptUntilTheOwnerChooses() async throws {
        let secondID = GoogleSignIn.normalizedEmail(Self.second)
        try scenario(["per_account": true])
        let model = try await twoAccounts()
        model.settings.reuploadEdits = false
        let old = (0..<3).map { "old-\($0)" }, new = (0..<26).map { "new-\($0)" }
        func album(_ members: [String]) -> LibraryAlbum {
            LibraryAlbum(snapshot: AlbumSnapshot(id: "shared", title: "Shared", kind: .user, assetIDs: members), symbol: "rectangle.stack")
        }
        model.useAlbumsForTesting([album(new + old)])
        model.state.selectedAlbumIDs = ["shared"]
        model.saveState()

        var seen: [[PlannedStep]] = []
        model.runner.turn = { turns, _ in
            XCTAssertEqual(turns.map(\.account), [secondID])
            if model.record(of: secondID)?.mirrors.isEmpty == true {
                model.modifyRecord(of: secondID) { state in
                    for id in old + new { state.recordUpload(assetID: id, mediaKey: "second-\(id)", existing: false) }
                    state.mirrors["shared"] = AlbumMirror(googleAlbumID: "fake-album-shared", addedAssetIDs: Set(old))
                }
            }
            seen.append(self.planEachPart(model)[secondID] ?? [])
        }
        model.startBackupNow(to: .only(secondID))
        try await settle(model)
        XCTAssertEqual(seen, [[]])

        model.useAlbumsForTesting([album(Array(new.dropFirst(2)) + old)])
        XCTAssertEqual(model.heldAlbumAdds.map(\.count), [24], "the hold is still shown")
        model.startBackupNow(to: .only(secondID))
        try await settle(model)
        XCTAssertEqual(seen, [[], []], "the 24 left still wait for Add Them or Skip")
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

    /// A primary whose part halts (here Google refuses the primary's
    /// sign-in) leaves its Messages media queued in the engine. Found in
    /// review of 0.6.0: the next account's run sent all of it to the second
    /// account. Nothing that only the primary takes may reach another
    /// account, and the other accounts still back up, at the same time, while
    /// the primary fails (issue #66: its part ends, theirs carry on).
    func testWorkLeftQueuedByThePrimaryNeverGoesToAnotherAccount() async throws {
        let firstID = GoogleSignIn.normalizedEmail(Self.first)
        let secondID = GoogleSignIn.normalizedEmail(Self.second)
        try scenario(["per_account": true])
        let model = try await twoAccounts()

        try scenario(["per_account": true, "refuse_accounts": [Self.first]])
        let queued = try items(4, tag: "primary-only")
        let photos = try items(2, tag: "albums")
        // The app's own order: Messages media found for the primary starts
        // the one run, which takes the albums to every account.
        model.runner.turn = { _, trigger in
            model.engine.standInsForTesting = photos
            model.engine.backUp(messages: queued, includingPhotos: true, trigger: trigger)
        }
        let runsBefore = model.diagnostics.runs.count
        model.startBackupNow()
        try await settle(model)
        XCTAssertTrue(untouched(queued, in: model, secondID), "the second account got the primary's Messages media")
        XCTAssertFalse(try uploads().contains { ($0["account"] as? String) == Self.second && queued.map(\.filename).contains($0["filename"] as? String ?? "") })
        XCTAssertTrue(uploaded(photos, in: model, secondID), "the second account still backed up while the primary failed")
        let newRuns = model.diagnostics.runs.prefix(model.diagnostics.runs.count - runsBefore)
        XCTAssertEqual(newRuns.count, 2, "one run, a record per account")
        XCTAssertTrue(newRuns.contains { model.accountTitle(reference: $0.account) == Self.second && $0.outcome == .completed })
        XCTAssertTrue(newRuns.contains { run in
            guard case .failed = run.outcome else { return false }
            return model.accountTitle(reference: run.account) == Self.first
        }, "the primary's part ended early")
        XCTAssertTrue(model.engine.hasQueuedPrimaryOnlyWork, "the queue waits in the engine for the primary's next run")
        XCTAssertEqual(model.activeAccountID, firstID)

        // The primary's sign-in works again: its next run sends the queue to
        // the primary, and only there.
        try scenario(["per_account": true])
        model.startBackupNow()
        try await settle(model)
        let primary = Set(model.record(of: firstID)?.uploaded.keys.map { $0 } ?? [])
        XCTAssertTrue(Set(queued.map(\.id)).isSubset(of: primary))
        XCTAssertFalse(model.engine.hasQueuedPrimaryOnlyWork)
        XCTAssertTrue(untouched(queued, in: model, secondID))
    }

    /// Review finding (PR #53, MAJOR 1), the reviewer's own scenario: the
    /// primary zed.primary@gmail.com, a work account a.work@corp.example.com
    /// left out, then accounts.json unreadable. The index was rebuilt from
    /// state.json and each keychain item signed in again in keychain order,
    /// so the work account (sorting first) came back included, under "All
    /// accounts", and past its storage check. Now the copy kept beside the
    /// index restores it as it was; with the copy unreadable too, nothing
    /// says which accounts backups went to, so none is backed up until they
    /// are chosen again (second round: the account state.json belongs to
    /// may be the one left out).
    func testALostAccountsListNeverIncludesAnAccountThatWasLeftOut() async throws {
        let primary = "zed.primary@gmail.com", work = "a.work@corp.example.com"
        let primaryID = GoogleSignIn.normalizedEmail(primary), workID = GoogleSignIn.normalizedEmail(work)
        try scenario(["per_account": true])
        let model = AppModel()
        model.settings.automatic = false
        await model.connect(pasted: Self.credential(primary))
        await model.connect(pasted: Self.credential(work))
        model.confirmStorage(for: workID)
        try await settle(model)
        model.setIncluded(workID, false)
        XCTAssertEqual(model.accountsChoice, .chosen)
        XCTAssertEqual(model.primaryAccount?.stateFile, "state.json")
        XCTAssertEqual(keychain.accounts(), [workID, primaryID], "the work account's item sorts before the primary's")
        let batch = try items(2, tag: "before-loss")
        let turns = recordTurns(model) { batch }
        model.startBackupNow()
        try await settle(model)
        XCTAssertEqual(turns().map(\.account), [primaryID])
        XCTAssertTrue(uploaded(batch, in: model, primaryID))

        let index = support.appendingPathComponent("accounts.json")
        try Data("{broken".utf8).write(to: index)
        let restored = AppModel()
        restored.settings.automatic = false
        XCTAssertEqual(restored.accountsChoice, .chosen, "the choice was forgotten")
        XCTAssertEqual(restored.accounts.map(\.id), [primaryID, workID])
        XCTAssertFalse(restored.isIncluded(workID), "the work account left out came back included")
        XCTAssertEqual(restored.targetAccounts.map(\.id), [primaryID])
        XCTAssertEqual(restored.accounts.last?.storageChecked, true, "restored exactly as it was")
        XCTAssertTrue(uploaded(batch, in: restored, primaryID))

        // The list and its copy both unreadable: rebuilt from state.json.
        try Data("{broken".utf8).write(to: index)
        try Data("{broken".utf8).write(to: support.appendingPathComponent("accounts.json.bak"))
        let rebuilt = AppModel()
        rebuilt.settings.automatic = false
        XCTAssertEqual(rebuilt.primaryAccount?.id, primaryID)
        XCTAssertEqual(Set(rebuilt.accounts.map(\.id)), [primaryID, workID], "both are signed in again from the keychain")
        XCTAssertEqual(rebuilt.accountsChoice, .chosen)
        XCTAssertFalse(rebuilt.isIncluded(workID), "a rebuilt list included the work account")
        XCTAssertEqual(rebuilt.accounts.first { $0.id == workID }?.storageChecked, false, "it waits for its storage check again")
        XCTAssertEqual(rebuilt.targetAccounts.map(\.id), [], "nobody is backed up to until chosen again")
        XCTAssertTrue(rebuilt.noAccountIncluded)
        XCTAssertTrue(uploaded(batch, in: rebuilt, primaryID), "the primary's record is state.json, untouched")
        XCTAssertTrue(untouched(batch, in: rebuilt, workID))
        XCTAssertTrue(rebuilt.stateError?.contains("choose them again") == true, "the rebuild is reported: \(rebuilt.stateError ?? "nil")")

        // What the rebuild decided is saved: a further launch keeps it.
        let after = AppModel()
        XCTAssertEqual(after.accountsChoice, .chosen)
        XCTAssertEqual(after.targetAccounts.map(\.id), [])
        XCTAssertNil(after.stateError)
    }

    /// PR #53 review, second round (the reviewer's probe): the account
    /// state.json belongs to was left out and only the other one chosen,
    /// then accounts.json and its copy were both damaged. The rebuild ticked
    /// the state.json account, storage-checked, and backed up to it. With
    /// another account signed in, nothing says which was chosen: nobody is.
    func testALostAccountsListNeverTicksTheStateJsonAccountThatWasLeftOut() async throws {
        let firstID = GoogleSignIn.normalizedEmail(Self.first), secondID = GoogleSignIn.normalizedEmail(Self.second)
        try scenario(["per_account": true])
        let model = try await twoAccounts()
        let batch = try items(1, tag: "owner-left-out")
        _ = recordTurns(model) { batch }
        model.startBackupNow()
        try await settle(model)
        XCTAssertTrue(FileManager.default.fileExists(atPath: support.appendingPathComponent("state.json").path))
        model.setIncluded(firstID, false)
        model.setIncluded(secondID, true)
        XCTAssertEqual(model.accountsChoice, .chosen)
        XCTAssertEqual(model.targetAccounts.map(\.id), [secondID])
        XCTAssertEqual(model.primaryAccount?.stateFile, "state.json")
        try Data("{broken".utf8).write(to: support.appendingPathComponent("accounts.json"))
        try Data("{broken".utf8).write(to: support.appendingPathComponent("accounts.json.bak"))

        let rebuilt = AppModel()
        rebuilt.settings.automatic = false
        XCTAssertFalse(rebuilt.targetAccounts.map(\.id).contains(firstID), "the left-out state.json account is a target after the rebuild")
        XCTAssertEqual(rebuilt.targetAccounts.map(\.id), [])
        XCTAssertEqual(rebuilt.accountsChoice, .chosen)
        XCTAssertEqual(Set(rebuilt.accounts.map(\.id)), [firstID, secondID])
        XCTAssertTrue(rebuilt.accounts.allSatisfy { !$0.storageChecked }, "each waits for its storage check")
        XCTAssertTrue(rebuilt.stateError?.contains("choose them again") == true, "\(rebuilt.stateError ?? "nil")")

        // Second round, MINOR c: the notice lived in stateError, which the
        // first successful save cleared, and never reached the timeline.
        rebuilt.saveState()
        XCTAssertTrue(rebuilt.stateError?.contains("choose them again") == true, "a save cleared the launch notice")
        XCTAssertTrue(rebuilt.diagnostics.events.contains { $0.category == .account && $0.isProblem
            && $0.message.contains("choose them again") }, "the launch problem is in the timeline")
    }

    /// A single-account record the size of the owner's (about 27,700
    /// uploads, 188 album links).
    private func realShapeState(email: String?) -> BackupState {
        var state = BackupState()
        state.accountEmail = email
        var ids: [String] = []
        for i in 0..<27_700 {
            let id = String(format: "%08X-0000-0000-0000-%012X/L0/001", i, i)
            state.uploaded[id] = BackupRecord(mediaKey: "AF1Qip\(i)", date: Date(timeIntervalSince1970: 1_760_000_000 + Double(i)),
                                              existing: i % 7 == 0)
            ids.append(id)
        }
        for a in 0..<188 {
            state.mirrors["album-\(a)/L0/040"] = AlbumMirror(googleAlbumID: "AF1QipAlbum\(a)",
                                                             addedAssetIDs: Set(ids[(a * 100)..<(a * 100 + 50)]))
        }
        return state
    }

    /// PR #53 review, second round, MINOR a (the reviewer's companion
    /// probe): one account, its credential already under its own id, and no
    /// accounts.json or copy (the first save after the move failed). With a
    /// state.json from before accountEmail was recorded the rebuild ticked
    /// nobody, and the Mac stopped backing up.
    func testASingleAccountWhoseIndexWasNeverSavedKeepsBackingUp() throws {
        try singleAccountWithoutIndex(email: nil)
    }

    func testASingleAccountWhoseIndexWasNeverSavedKeepsBackingUpWithItsAddressRecorded() throws {
        try singleAccountWithoutIndex(email: "Real.Owner@gmail.com")
    }

    private func singleAccountWithoutIndex(email: String?) throws {
        let owner = "Real.Owner@gmail.com"
        let id = GoogleSignIn.normalizedEmail(owner)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let stateURL = support.appendingPathComponent("state.json")
        try BackupStore(url: stateURL).save(realShapeState(email: email))
        try keychain.save(Self.credential(owner), account: id)
        try scenario(["per_account": true])
        let model = AppModel()
        model.settings.automatic = false
        XCTAssertEqual(model.record(of: id)?.uploaded.count, 27_700)
        XCTAssertEqual(model.record(of: id)?.mirrors.count, 188)
        XCTAssertEqual(model.primaryAccount?.stateFile, "state.json")
        XCTAssertEqual(model.targetAccounts.map(\.id), [id], "the single account stops backing up")
    }

    /// Review of PR #53, MINOR 2: Remove ignored a failed keychain delete
    /// and marked the account removed; the item left behind signed it back
    /// in at the next launch. Now it stays signed in and says why.
    func testRemoveThatCannotDeleteTheSignInLeavesTheAccountSignedIn() async throws {
        let secondID = GoogleSignIn.normalizedEmail(Self.second)
        try scenario(["per_account": true])
        let model = try await twoAccounts()
        Keychain.refusedDeletesForTesting = [secondID]
        await model.removeAccount(secondID)
        XCTAssertTrue(model.accounts.contains { $0.id == secondID }, "marked removed with its sign-in still in the keychain")
        XCTAssertNotNil(keychain.load(account: secondID))
        XCTAssertEqual(model.status(of: secondID), .connected(email: Self.second))
        XCTAssertTrue(model.diagnostics.events.contains { $0.isProblem && $0.message.contains("was not removed") })
        XCTAssertTrue(AppModel().accounts.contains { $0.id == secondID }, "a launch agrees: still signed in")

        Keychain.refusedDeletesForTesting = []
        await model.removeAccount(secondID)
        XCTAssertFalse(model.accounts.contains { $0.id == secondID })
        XCTAssertNil(keychain.load(account: secondID))
        XCTAssertFalse(AppModel().accounts.contains { $0.id == secondID }, "and stays removed after a launch")
    }

    /// Review of PR #53, MINOR 3: the legacy "gpmc" item, its delete
    /// refused at the upgrade and again at a fresh sign-in, was moved over
    /// that newer sign-in at the next launch. Now the move throws (the item
    /// is read where it is) and never replaces the newer credential.
    func testALegacyItemThatCannotBeDeletedNeverReplacesANewerSignIn() async throws {
        let firstID = GoogleSignIn.normalizedEmail(Self.first)
        let stale = Self.credential(Self.first)
        let fresh = stale.replacingOccurrences(of: "E2E-FAKE-TOKEN", with: "E2E-FRESH-TOKEN")
        var legacy = BackupState()
        legacy.accountEmail = Self.first
        try BackupStore(url: support.appendingPathComponent("state.json")).save(legacy)
        try keychain.save(stale, account: AccountLibrary.legacyKeychainAccount)
        try scenario(["per_account": true])
        Keychain.refusedDeletesForTesting = [AccountLibrary.legacyKeychainAccount]

        let model = AppModel()
        model.settings.automatic = false
        XCTAssertEqual(model.accounts.map(\.id), [firstID])
        XCTAssertEqual(model.credential(for: firstID), stale)
        XCTAssertNotNil(keychain.load(account: AccountLibrary.legacyKeychainAccount), "its delete was refused")

        // The keychain keeps modification dates to the second.
        try await Task.sleep(for: .milliseconds(1100))
        await model.connect(pasted: fresh)
        XCTAssertEqual(model.connectState, .idle, "the sign-in itself succeeds")
        XCTAssertEqual(keychain.load(account: firstID), fresh)
        XCTAssertTrue(model.diagnostics.events.contains { $0.isProblem && $0.message.contains("could not be deleted") })

        let relaunched = AppModel()
        XCTAssertEqual(keychain.load(account: firstID), fresh, "the left-over legacy item replaced the newer sign-in")
        XCTAssertEqual(relaunched.credential(for: firstID), fresh)
        XCTAssertEqual(relaunched.accounts.map(\.id), [firstID])

        Keychain.refusedDeletesForTesting = []
        _ = AppModel()
        XCTAssertNil(keychain.load(account: AccountLibrary.legacyKeychainAccount), "deleted once the keychain allows it")
        XCTAssertEqual(keychain.load(account: firstID), fresh)
    }

    /// Review of PR #53, MINOR 6: Retry once queued another account's
    /// failure on the primary. With the accounts side by side (issue #66),
    /// each failure is that account's row, and Retry sends it to that
    /// account again and to no other; Retry Failed covers every account.
    func testRetrySendsEachFailureBackToItsOwnAccountOnly() async throws {
        let firstID = GoogleSignIn.normalizedEmail(Self.first)
        let secondID = GoogleSignIn.normalizedEmail(Self.second)
        try scenario(["per_account": true])
        let model = try await twoAccounts()
        let shared = try items(1, tag: "shared", prefix: "photo:")
        let failsOnFirst = try items(1, tag: "fails-on-first", prefix: "photo:")[0]
        let failsOnSecond = try items(1, tag: "fails-on-second", prefix: "photo:")[0]
        // Each account already has the other's item, so its plan has only
        // the shared item and its own.
        model.modifyRecord(of: firstID) { $0.recordUpload(assetID: failsOnSecond.id, mediaKey: "first-has-it", existing: false) }
        model.saveRecord(of: firstID)
        model.modifyRecord(of: secondID) { $0.recordUpload(assetID: failsOnFirst.id, mediaKey: "second-has-it", existing: false) }
        model.saveRecord(of: secondID)
        let refused = "400 Client Error: Bad Request for url: https://photos.example.invalid/commit"
        try scenario(["per_account": true, "fail": [failsOnFirst.filename: refused, failsOnSecond.filename: refused]])
        model.runner.turn = { _, trigger in
            model.engine.standInsForTesting = shared + [failsOnFirst, failsOnSecond]
            model.engine.start(trigger: trigger)
        }
        model.startBackupNow()
        try await settle(model)
        XCTAssertEqual(model.activeAccountID, firstID)
        XCTAssertTrue(uploaded(shared, in: model, firstID) && uploaded(shared, in: model, secondID))
        let secondRow = BackupEngine.row(secondID, failsOnSecond.id), firstRow = BackupEngine.row(firstID, failsOnFirst.id)
        XCTAssertTrue(model.engine.activity.contains { $0.id == secondRow && $0.isFailed && $0.account == secondID })
        XCTAssertFalse(model.engine.activity.contains { $0.id == BackupEngine.row(firstID, failsOnSecond.id) },
                       "no row of the second account's item for the primary")

        XCTAssertTrue(model.canRetry(secondRow), "the second account's failure retries, on the second account")
        XCTAssertTrue(model.canRetry(firstRow))
        XCTAssertEqual(model.engine.failedCount, 2, "Retry Failed covers every account")

        // Uploads succeed again: a Retry that went to the wrong account
        // would now land an item in the other account's record.
        try scenario(["per_account": true])
        model.retry(secondRow)
        model.retryFailed()
        try await settle(model)
        XCTAssertEqual(model.record(of: firstID)?.uploaded[failsOnSecond.id]?.mediaKey, "first-has-it", "the primary's record untouched")
        XCTAssertNotEqual(model.record(of: secondID)?.uploaded[failsOnSecond.id]?.mediaKey, nil)
        XCTAssertEqual(model.record(of: secondID)?.uploaded[failsOnFirst.id]?.mediaKey, "second-has-it")
        XCTAssertNotEqual(model.record(of: firstID)?.uploaded[failsOnFirst.id]?.mediaKey, nil)
        // The ledger lists failed attempts too: neither account ever tried the other's.
        let tried = try uploads()
        func filenames(_ email: String) -> [String] { tried.filter { ($0["account"] as? String) == email }.compactMap { $0["filename"] as? String } }
        XCTAssertFalse(filenames(Self.first).contains(failsOnSecond.filename), "Google got the second account's item as the primary's")
        XCTAssertFalse(filenames(Self.second).contains(failsOnFirst.filename))
        XCTAssertEqual(model.diagnostics.runs.first?.trigger, .retry)
        XCTAssertEqual(model.engine.failedCount, 0)
    }
}
