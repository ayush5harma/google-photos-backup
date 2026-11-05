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

    func delete(account: String) {
        SecItemDelete(query(account) as CFDictionary)
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
    /// leaves the credential where it was, to be moved at the next launch.
    func move(from old: String, to new: String) throws {
        guard old != new, let value = load(account: old) else { return }
        try save(value, account: new)
        guard load(account: new) == value else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(errSecDecode),
                          userInfo: [NSLocalizedDescriptionKey: "The moved sign-in did not read back the same."])
        }
        delete(account: old)
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}
