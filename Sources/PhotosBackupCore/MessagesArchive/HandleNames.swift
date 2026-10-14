import Foundation

/// Contact names for Messages handles. Messages stores handles canonical
/// ("+15551234567", "name@example.com") while address books hold whatever
/// was typed ("(555) 123-4567"), so both sides are reduced to a key first.
public struct HandleNames: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let name: String
        /// Phone numbers and email addresses as the contact card has them.
        public let handles: [String]

        public init(name: String, handles: [String]) {
            self.name = name
            self.handles = handles
        }
    }

    /// Ten digits is a national number in most plans; a card saved without
    /// the country code still matches the canonical "+1..." or "+91...".
    static let nationalDigits = 10

    private var exact: [String: String] = [:]
    private var national: [String: String] = [:]

    public init(_ entries: [Entry] = []) {
        for entry in entries where !entry.name.isEmpty {
            for handle in entry.handles {
                guard let key = Self.key(handle) else { continue }
                if exact[key] == nil { exact[key] = entry.name }
                if let tail = Self.nationalKey(key), national[tail] == nil { national[tail] = entry.name }
            }
        }
    }

    public var isEmpty: Bool { exact.isEmpty }

    public func name(for handle: String) -> String? {
        guard let key = Self.key(handle) else { return nil }
        if let name = exact[key] { return name }
        return Self.nationalKey(key).flatMap { national[$0] }
    }

    /// The name, else the handle as Messages has it.
    public func display(_ handle: String) -> String { name(for: handle) ?? handle }

    /// Emails lowercased; phone numbers as digits only; nil for neither.
    static func key(_ handle: String) -> String? {
        let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("@") { return trimmed.lowercased() }
        let digits = trimmed.filter(\.isASCII).filter(\.isNumber)
        return digits.count >= 3 ? digits : nil
    }

    private static func nationalKey(_ key: String) -> String? {
        guard !key.contains("@"), key.count >= nationalDigits else { return nil }
        return String(key.suffix(nationalDigits))
    }

    /// Stable across runs for the same names, so a conversation re-renders
    /// when a participant's name changes and only then.
    func fingerprint(for handles: [String]) -> String {
        handles.map { "\($0)=\(name(for: $0) ?? "")" }.joined(separator: "\n")
    }
}
