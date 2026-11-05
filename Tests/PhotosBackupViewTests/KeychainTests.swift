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
        for account in keychain.accounts() { keychain.delete(account: account) }
        XCTAssertEqual(keychain.accounts(), [])
    }

    func testOneItemPerAccount() throws {
        try keychain.save("androidId=1&Email=a%40example.com&Token=aas_et%2Fa", account: "a@example.com")
        try keychain.save("androidId=2&Email=b%40example.com&Token=aas_et%2Fb", account: "b@example.com")
        XCTAssertEqual(keychain.accounts(), ["a@example.com", "b@example.com"])
        XCTAssertEqual(keychain.load(account: "a@example.com"), "androidId=1&Email=a%40example.com&Token=aas_et%2Fa")

        keychain.delete(account: "b@example.com")
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

    func testSavingAgainReplacesTheSecret() throws {
        try keychain.save("old", account: "a@example.com")
        try keychain.save("new", account: "a@example.com")
        XCTAssertEqual(keychain.load(account: "a@example.com"), "new")
        XCTAssertEqual(keychain.accounts(), ["a@example.com"])
    }
}
