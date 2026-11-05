import Foundation
@testable import PhotosBackup
import XCTest

/// Against a throwaway service of its own: never the app's service, so the
/// real (or the sandbox) Google credential is never read or written.
final class KeychainTests: XCTestCase {
    private var keychain: Keychain!

    override func setUp() {
        keychain = Keychain(service: "PhotosBackupTests.keychain.\(UUID().uuidString)")
        XCTAssertFalse(keychain.service.hasPrefix(AppEnvironment.bundleID + ".auth-data"))
    }

    override func tearDown() {
        Keychain.refusedDeletesForTesting = []
        for account in keychain.accounts() { try? keychain.delete(account: account) }
        XCTAssertEqual(keychain.accounts(), [])
    }

    func testOneItemPerAccount() throws {
        try keychain.save("androidId=1&Email=a%40example.com&Token=aas_et%2Fa", account: "a@example.com")
        try keychain.save("androidId=2&Email=b%40example.com&Token=aas_et%2Fb", account: "b@example.com")
        XCTAssertEqual(keychain.accounts(), ["a@example.com", "b@example.com"])
        XCTAssertEqual(keychain.load(account: "a@example.com"), "androidId=1&Email=a%40example.com&Token=aas_et%2Fa")

        try keychain.delete(account: "b@example.com")
        XCTAssertEqual(keychain.accounts(), ["a@example.com"])
        XCTAssertNotNil(keychain.load(account: "a@example.com"), "removing one account never touches another")
    }

    func testTheLegacyItemMovesToItsAccount() throws {
        let credential = "androidId=1&Email=me%40gmail.com&Token=aas_et%2Fx"
        try keychain.save(credential, account: "gpmc")
        try keychain.move(from: "gpmc", to: "me@gmail.com")
        XCTAssertNil(keychain.load(account: "gpmc"))
        XCTAssertEqual(keychain.load(account: "me@gmail.com"), credential)
        // Moving again (a crash after the copy, before the delete) is harmless.
        try keychain.move(from: "gpmc", to: "me@gmail.com")
        XCTAssertEqual(keychain.accounts(), ["me@gmail.com"])
    }

    /// Review of PR #53, MINOR 2: a delete the keychain refuses was ignored.
    func testADeleteTheKeychainRefusesThrowsAndAMissingItemDoesNot() throws {
        try keychain.save("secret", account: "a@example.com")
        Keychain.refusedDeletesForTesting = ["a@example.com"]
        XCTAssertThrowsError(try keychain.delete(account: "a@example.com"))
        XCTAssertEqual(keychain.load(account: "a@example.com"), "secret", "the item is still there")
        Keychain.refusedDeletesForTesting = []
        try keychain.delete(account: "a@example.com")
        XCTAssertNoThrow(try keychain.delete(account: "a@example.com"), "an item already gone counts as deleted")
    }

    /// Review of PR #53, MINOR 3: a move whose delete fails throws, so the
    /// app keeps reading the legacy item where it is.
    func testAMoveWhoseDeleteFailsThrowsWithTheCopyMade() throws {
        let credential = "androidId=1&Email=me%40gmail.com&Token=aas_et%2Fx"
        try keychain.save(credential, account: "gpmc")
        Keychain.refusedDeletesForTesting = ["gpmc"]
        XCTAssertThrowsError(try keychain.move(from: "gpmc", to: "me@gmail.com"))
        XCTAssertEqual(keychain.load(account: "gpmc"), credential)
        XCTAssertEqual(keychain.load(account: "me@gmail.com"), credential)
    }

    /// Review of PR #53, MINOR 3: the legacy item left behind by a failed
    /// delete was copied over a sign-in made since, at the next launch.
    func testAMoveNeverReplacesASignInMadeSince() throws {
        try keychain.save("stale", account: "gpmc")
        try waitForTheKeychainClock()
        try keychain.save("fresh", account: "me@gmail.com")
        try keychain.move(from: "gpmc", to: "me@gmail.com")
        XCTAssertEqual(keychain.load(account: "me@gmail.com"), "fresh")
        XCTAssertNil(keychain.load(account: "gpmc"), "only the old item goes")

        // Its delete refused as well: the sign-in still stands, and it throws.
        try keychain.save("stale", account: "gpmc")
        try waitForTheKeychainClock()
        try keychain.save("fresh again", account: "me@gmail.com")
        Keychain.refusedDeletesForTesting = ["gpmc"]
        XCTAssertThrowsError(try keychain.move(from: "gpmc", to: "me@gmail.com"))
        XCTAssertEqual(keychain.load(account: "me@gmail.com"), "fresh again")
    }

    /// An older version signed in again after a downgrade: its item is the
    /// newer one and still moves over the account's.
    func testALegacyItemWrittenLaterStillMoves() throws {
        try keychain.save("before the downgrade", account: "me@gmail.com")
        try waitForTheKeychainClock()
        try keychain.save("signed in on the older version", account: "gpmc")
        try keychain.move(from: "gpmc", to: "me@gmail.com")
        XCTAssertEqual(keychain.load(account: "me@gmail.com"), "signed in on the older version")
        XCTAssertNil(keychain.load(account: "gpmc"))
    }

    /// The file keychain keeps modification dates to the second.
    private func waitForTheKeychainClock() throws {
        Thread.sleep(forTimeInterval: 1.1)
    }

    func testSavingAgainReplacesTheSecret() throws {
        try keychain.save("old", account: "a@example.com")
        try keychain.save("new", account: "a@example.com")
        XCTAssertEqual(keychain.load(account: "a@example.com"), "new")
        XCTAssertEqual(keychain.accounts(), ["a@example.com"])
    }
}
