import Foundation
import Security

/// The gpmc auth_data lives in the login keychain: it embeds a long-lived
/// Google master token ("aas_et/..."), which is a password in all but name.
/// One item per Google account: the app's service, and as the account
/// attribute the normalized address (an AccountLibrary id). Before there
/// were accounts the one item's attribute was "gpmc"; it is moved to its
/// account at launch.
struct Keychain {
    let service: String

    static let app = Keychain(service: AppEnvironment.keychainService)

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func load(account: String) -> String? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(account)
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            try check(SecItemAdd(item as CFDictionary, nil))
        } else {
            try check(status)
        }
    }

    /// An item that is already gone counts as deleted. Anything else that
    /// leaves it in place throws (a denied keychain prompt, a locked
    /// keychain): an item left behind signs its account back in at the next
    /// launch, so callers must not record the account as signed out.
    func delete(account: String) throws {
        #if DEBUG
        if Self.refusedDeletesForTesting.contains(account) { try check(errSecAuthFailed) }
        #endif
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status != errSecItemNotFound else { return }
        try check(status)
    }

    #if DEBUG
    /// Tests only: accounts whose delete fails as a denied keychain prompt
    /// does, leaving the item in place.
    static var refusedDeletesForTesting: Set<String> = []
    #endif

    /// When the item was last written. Attributes only, like `accounts()`.
    func modified(account: String) -> Date? {
        var request = query(account)
        request[kSecReturnAttributes as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let attributes = result as? [String: Any] else { return nil }
        return attributes[kSecAttrModificationDate as String] as? Date
    }

    /// The account attribute of every item under the service. Attributes
    /// only: reading them never asks for the keychain password, which
    /// reading a secret can after the app is re-signed.
    func accounts() -> [String] {
        let request: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                      kSecAttrService as String: service,
                                      kSecReturnAttributes as String: true,
                                      kSecMatchLimit as String: kSecMatchLimitAll]
        var result: AnyObject?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }

    /// Moves a credential to another account attribute. The new item is
    /// written and read back before the old one is deleted, so any failure
    /// leaves the credential where it was, to be moved at the next launch;
    /// a delete that fails throws too, so the caller keeps reading the old
    /// item where it is.
    ///
    /// A target item written since the old one (the account signed in
    /// again while the old item could not be deleted) is the newer
    /// credential: it is kept and only the old item goes. Copying over it
    /// put a stale sign-in back at the next launch (PR #53 review). An old
    /// item written later (an older version signed in again after a
    /// downgrade) still moves.
    func move(from old: String, to new: String) throws {
        guard old != new else { return }
        // Without a date to compare (none was ever missing when measured,
        // 2026-11-05) the old item moves, as it always did.
        if let oldModified = modified(account: old), let newModified = modified(account: new), newModified >= oldModified {
            try delete(account: old)
            return
        }
        guard let value = load(account: old) else { return }
        try save(value, account: new)
        guard load(account: new) == value else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(errSecDecode),
                          userInfo: [NSLocalizedDescriptionKey: "The moved sign-in did not read back the same."])
        }
        try delete(account: old)
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}
