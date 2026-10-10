import Foundation

/// Turning a Google sign-in into the credential gpmc needs.
///
/// The flow, constants and field sets follow xob0t/gotohp (MIT),
/// core/googleauth.go: signing in on Google's Embedded Setup page (the one
/// Android's setup wizard shows) leaves an `oauth_token` cookie; posting that
/// to Google's Android auth endpoint, as Google Play services would, returns a
/// master token for a fresh Android ID; the credential is then the request
/// Google Photos for Android makes with that token, which is what gpmc calls
/// auth_data.
public enum GoogleSignIn {
    public static let embeddedSetupURL = URL(string: "https://accounts.google.com/EmbeddedSetup")!
    public static let cookieName = "oauth_token"

    /// gotohp's endpoint first; the second is the one gpmc signs in with.
    /// Both answer the exchange identically (checked 2026-10-11 with a
    /// bogus token: `Error=BadAuthentication`, HTTP 403, from each), and
    /// some networks reach only one of them.
    public static let exchangeEndpoints = [
        URL(string: "https://android.clients.google.com/auth")!,
        URL(string: "https://android.googleapis.com/auth")!,
    ]

    static let emailHint = "oauth-token@example.com"
    static let playServicesSignature = "38918a453d07199354f8b19af05ec6562ced5788"
    static let photosPackage = "com.google.android.apps.photos"
    static let photosSignature = "24bb24c05e47e0aefa68a58a766179d9b613a600"
    static let photosService = "oauth2:openid https://www.googleapis.com/auth/mobileapps.native https://www.googleapis.com/auth/photos.native"
    static let playServicesVersion = "240913000"

    public struct Failure: LocalizedError, Equatable {
        public let errorDescription: String?

        init(_ message: String) {
            errorDescription = message
        }
    }

    public struct Account: Equatable, Sendable {
        public let email: String
        public let masterToken: String
    }

    /// Accepts the cookie's value, with or without its `oauth_token=` name.
    public static func normalizedOAuthToken(_ value: String) throws -> String {
        var token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.hasPrefix("\(cookieName)=") { token.removeFirst(cookieName.count + 1) }
        guard (16...8192).contains(token.count), !token.contains(where: \.isNewline) else {
            throw Failure("That is not an oauth_token cookie from Google's sign-in page.")
        }
        return token
    }

    /// A pasted full credential rather than a cookie.
    public static func looksLikeAuthData(_ value: String) -> Bool {
        let fields = Set(value.split(separator: "&").compactMap { $0.split(separator: "=", maxSplits: 1).first.map(String.init) })
        return fields.contains("androidId") && fields.contains("Token")
    }

    /// 8 random bytes in hex, the shape of an Android ID.
    public static func newAndroidID() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<8).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
    }

    public static func exchangeForm(oauthToken: String, androidID: String) -> String {
        formEncoded([
            "accountType": "HOSTED_OR_GOOGLE",
            "Email": emailHint,
            "has_permission": "1",
            "add_account": "1",
            "ACCESS_TOKEN": "1",
            "Token": oauthToken,
            "service": "ac2dm",
            "source": "android",
            "androidId": androidID,
            "device_country": "us",
            "operatorCountry": "us",
            "lang": "en",
            "sdk_version": "17",
            "google_play_services_version": playServicesVersion,
            "client_sig": playServicesSignature,
            "callerSig": playServicesSignature,
            "droidguard_results": "dummy123",
        ])
    }

    /// The endpoint answers `Key=Value` lines; an `Error` line means no.
    public static func parseExchange(_ body: String) throws -> Account {
        var values: [String: String] = [:]
        for line in body.split(whereSeparator: \.isNewline) {
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
            if parts.count == 2 { values[String(parts[0])] = String(parts[1]) }
        }
        if let error = values["Error"] {
            switch error {
            case "BadAuthentication": throw Failure("Google did not accept the sign-in. Sign in again; each sign-in works only once.")
            case "NeedsBrowser": throw Failure("Google wants the sign-in finished in a browser. Sign in again.")
            case "MissingDroidguard": throw Failure("Google refused the device check for this sign-in.")
            default: throw Failure("Google refused the sign-in (\(error)).")
            }
        }
        guard let token = values["Token"], !token.isEmpty else { throw Failure("Google's answer held no account token.") }
        guard let email = values["Email"], isPlausibleEmail(email) else { throw Failure("Google's answer held no account address.") }
        return Account(email: email, masterToken: token)
    }

    /// The auth_data gpmc reads (it uses every one of these fields).
    public static func credential(for account: Account, androidID: String) -> String {
        formEncoded([
            "androidId": androidID,
            "app": photosPackage,
            "callerPkg": photosPackage,
            "callerSig": photosSignature,
            "client_sig": photosSignature,
            "device_country": "us",
            "Email": account.email,
            "google_play_services_version": playServicesVersion,
            "lang": "en_US",
            "oauth2_foreground": "1",
            "operatorCountry": "us",
            "sdk_version": "33",
            "service": photosService,
            "source": "android",
            "Token": account.masterToken,
        ])
    }

    static func isPlausibleEmail(_ value: String) -> Bool {
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".") && !value.contains(where: \.isWhitespace)
    }

    /// application/x-www-form-urlencoded with keys in byte order, as Go's
    /// url.Values.Encode writes it: gpmc's own field lookups take the first
    /// pair whose text contains "Email" or "lang", and that order puts the
    /// real ones first.
    static func formEncoded(_ fields: [String: String]) -> String {
        fields.keys.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
            .map { "\(escape($0))=\(escape(fields[$0]!))" }
            .joined(separator: "&")
    }

    private static let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    static func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved.union(.init(charactersIn: " ")))!
            .replacingOccurrences(of: " ", with: "+")
    }
}
