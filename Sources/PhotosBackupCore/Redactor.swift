import Foundation

/// Masks what must never reach the event timeline or a diagnostic report:
/// Google credentials, addresses, phone numbers and the home folder's name.
/// Applied to every event as it is written and to the whole report, so a
/// leak in one message (a gpmc error quoting a URL, a path) is caught too.
public struct Redactor: Sendable {
    /// The real home folder, shown as `~`.
    public let homeDirectory: String

    public init(homeDirectory: String = NSHomeDirectory()) {
        self.homeDirectory = homeDirectory
    }

    public func redact(_ text: String) -> String {
        var text = text
        for (pattern, template) in Self.secretPatterns {
            text = Self.replace(pattern, in: text, with: template)
        }
        text = Self.replaceMatches(Self.emailPattern, in: text) { Self.maskEmail(local: $0[1], domain: $0[2]) }
        text = Self.replaceMatches(Self.phonePattern, in: text) { Self.maskPhone($0[0]) }
        return redactHome(in: text)
    }

    /// `j***@gmail.com`: enough to tell two accounts apart, not to write to one.
    public static func maskEmail(_ email: String) -> String {
        guard let at = email.lastIndex(of: "@") else { return "***" }
        return maskEmail(local: String(email[..<at]), domain: String(email[email.index(after: at)...]))
    }

    // MARK: - Patterns

    /// Credentials first, so the address and number rules never see one.
    /// gpmc's auth_data is a form body: master token `aas_et/...`, OAuth
    /// `oauth2_4/...` and `ya29....` bearer tokens, `Token=`/`Auth=` fields,
    /// any of them possibly percent-encoded.
    private static let secretPatterns: [(String, String)] = [
        (#"aas_et(?:/|%2F)[A-Za-z0-9._~+/=%-]+"#, "aas_et/<redacted>"),
        (#"oauth2_4(?:/|%2F)[A-Za-z0-9._~+/=%-]+"#, "oauth2_4/<redacted>"),
        (#"ya29\.[A-Za-z0-9._~+/=-]+"#, "ya29.<redacted>"),
        (#"(?i)\b(Token|Auth|oauth_token|EncryptedPasswd|Passwd|access_token|refresh_token|androidId)=[^&\s"',;]+"#, "$1=<redacted>"),
        (#"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+"#, "Bearer <redacted>"),
        // An upload URL's id lets anyone holding it write into the session.
        (#"(?i)([?&](?:upload_id|key|sig)=)[^&\s"']+"#, "$1<redacted>"),
    ]

    /// The local part may be percent-encoded (`john%2Bwork%40example.com` in
    /// auth_data); the lazy match stops at the first `@` or `%40`.
    private static let emailPattern = #"([A-Za-z0-9](?:[A-Za-z0-9._+-]|%[0-9A-Fa-f]{2})*?)(?:@|%40)([A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,})"#

    /// International numbers with a leading +, and North American ones in
    /// their usual punctuation. Bare digit runs (byte counts, timestamps,
    /// media keys) and ISO dates are deliberately not matched.
    private static let phonePattern = #"(?:\+[0-9][0-9 ().-]{6,18}[0-9])|(?:\(?\b[0-9]{3}\)?[ .-][0-9]{3}[ .-][0-9]{4}\b)"#

    private static func maskEmail(local: String, domain: String) -> String {
        "\(local.first.map(String.init) ?? "")***@\(domain)"
    }

    private static func maskPhone(_ number: String) -> String {
        let digits = number.filter(\.isNumber)
        guard digits.count >= 7 else { return number }
        return "[phone ending \(digits.suffix(2))]"
    }

    private func redactHome(in text: String) -> String {
        let home = homeDirectory.hasSuffix("/") ? String(homeDirectory.dropLast()) : homeDirectory
        guard home.count > 1 else { return text }
        // Only a whole path component: /Users/ann must not eat /Users/anne.
        return Self.replaceMatches(NSRegularExpression.escapedPattern(for: home) + #"(?=/|$|[\s"'),;:])"#, in: text) { _ in "~" }
    }

    // MARK: - Regular expressions

    private static func replace(_ pattern: String, in text: String, with template: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
        return expression.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    /// Replaces each match with `transform(groups)`, where groups[0] is the
    /// whole match.
    private static func replaceMatches(_ pattern: String, in text: String, transform: ([String]) -> String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = ""
        var cursor = text.startIndex
        for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let whole = Range(match.range, in: text) else { continue }
            let groups = (0..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
            }
            result += text[cursor..<whole.lowerBound]
            result += transform(groups)
            cursor = whole.upperBound
        }
        result += text[cursor...]
        return result
    }
}
