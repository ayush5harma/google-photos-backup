import Foundation

/// A parsed auth_data: the form-encoded credential GoogleSignIn.credential
/// produces and the Mac app keeps in the Keychain. Holds the master token, so
/// it is never printed: `description` names only the address.
public struct GooglePhotosCredential: Sendable, Equatable, CustomStringConvertible {
    /// The fields gpmc 0.9.0's Api._get_auth_token reads (it raises KeyError
    /// without any of them), in the order it sends them. `app` and
    /// `callerPkg` are not read from the credential: gpmc writes them itself.
    static let requiredFields = [
        "androidId", "client_sig", "callerSig", "device_country", "Email", "google_play_services_version",
        "lang", "oauth2_foreground", "sdk_version", "service", "Token",
    ]
    static let photosPackage = "com.google.android.apps.photos"

    let values: [String: String]

    public init(authData: String) throws(GooglePhotosError) {
        values = Self.parse(authData.trimmingCharacters(in: .whitespacesAndNewlines))
        let missing = Self.requiredFields.filter { values[$0, default: ""].isEmpty }
        guard missing.isEmpty else {
            throw .invalidCredential("The saved sign-in lacks \(missing.joined(separator: ", ")). Sign in again.")
        }
    }

    public var email: String? {
        guard let email = values["Email"], !email.isEmpty else { return nil }
        return email
    }

    var androidID: String { values["androidId"] ?? "" }

    public var description: String {
        "GooglePhotosCredential(\(email.map(Redactor.maskEmail) ?? "no address"))"
    }

    /// The auth request body, byte for byte what requests makes of gpmc's
    /// dict: its field order, and urlencode's quote_plus (space as "+",
    /// only letters, digits and "_.-~" left as they are).
    var authForm: Data {
        let fields: [(String, String)] = [
            ("androidId", values["androidId"]!),
            ("app", Self.photosPackage),
            ("client_sig", values["client_sig"]!),
            ("callerPkg", Self.photosPackage),
            ("callerSig", values["callerSig"]!),
            ("device_country", values["device_country"]!),
            ("Email", values["Email"]!),
            ("google_play_services_version", values["google_play_services_version"]!),
            ("lang", values["lang"]!),
            ("oauth2_foreground", values["oauth2_foreground"]!),
            ("sdk_version", values["sdk_version"]!),
            ("service", values["service"]!),
            ("Token", values["Token"]!),
        ]
        return Data(fields.map { "\(Self.quotePlus($0.0))=\(Self.quotePlus($0.1))" }.joined(separator: "&").utf8)
    }

    /// Python's dict(parse_qsl(text)): "+" is a space, percent escapes are
    /// decoded, a pair without "=" is dropped and a repeated key keeps its
    /// last value. By hand, as GoogleSignIn.email(inCredential:) does: the
    /// text may be anything a person pasted.
    static func parse(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        // Only "&": parse_qsl stopped splitting on ";" in Python 3.9.2.
        for pair in text.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            values[unquotePlus(parts[0])] = unquotePlus(parts[1])
        }
        return values
    }

    private static func unquotePlus(_ text: Substring) -> String {
        let spaced = text.replacingOccurrences(of: "+", with: " ")
        return spaced.removingPercentEncoding ?? spaced
    }

    private static let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-~".utf8)

    static func quotePlus(_ text: String) -> String {
        var out = ""
        for byte in text.utf8 {
            if unreserved.contains(byte) {
                out.unicodeScalars.append(Unicode.Scalar(byte))
            } else if byte == 0x20 {
                out += "+"
            } else {
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }
}
