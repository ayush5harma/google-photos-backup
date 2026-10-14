import Contacts
import Foundation
import PhotosBackupCore

/// Names for the archive's handles, from the address book. Access is asked
/// for only when a person clicks a button: a background archive run never
/// raises the Contacts prompt, it falls back to phone numbers and emails.
enum ContactsDirectory {
    enum Access: Equatable {
        case notDetermined, allowed, denied
    }

    static var access: Access {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized: .allowed
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    static func requestAccess() async -> Bool {
        (try? await CNContactStore().requestAccess(for: .contacts)) ?? false
    }

    /// Every card with a phone number or email; empty without access.
    static func names() async -> HandleNames {
        guard access == .allowed else { return HandleNames() }
        return await Task.detached(priority: .utility) { readNames() }.value
    }

    private static func readNames() -> HandleNames {
        let keys: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
        ]
        var entries: [HandleNames.Entry] = []
        let request = CNContactFetchRequest(keysToFetch: keys)
        try? CNContactStore().enumerateContacts(with: request) { contact, _ in
            let handles = contact.phoneNumbers.map(\.value.stringValue) + contact.emailAddresses.map { $0.value as String }
            guard !handles.isEmpty else { return }
            let name = CNContactFormatter.string(from: contact, style: .fullName) ?? contact.organizationName
            entries.append(HandleNames.Entry(name: name, handles: handles))
        }
        return HandleNames(entries)
    }
}
