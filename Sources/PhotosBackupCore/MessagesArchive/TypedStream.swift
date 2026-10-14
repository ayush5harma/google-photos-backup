import Foundation

/// Reads the text out of a message's `attributedBody`, an NSArchiver
/// "typedstream" of an NS(Mutable)AttributedString. On macOS 27 nearly every
/// message keeps its text only there (128,243 of 128,318 rows on the
/// developer's Mac had it, 3,262 had a NULL `text`).
///
/// NSUnarchiver could decode it, but it instantiates whatever classes the
/// stream names, from bytes another person's device produced; this reads the
/// one string and nothing else.
public enum TypedStream {
    /// Object-replacement characters stand in for attachments inline.
    static let objectReplacement: Character = "\u{FFFC}"

    public static func plainText(from data: Data) -> String? {
        let bytes = [UInt8](data)
        guard bytes.count > 16, bytes[1] == 0x0B, Array(bytes[2..<13]) == Array("streamtyped".utf8) else { return nil }
        // The archived string is the stream's first value of C type "+"
        // (bytes with a length); its introduction is the new-type tag 0x84
        // followed by the one-byte type string "+". It always follows the
        // NSString class record, which keeps a stray match out.
        guard let classEnd = find(Array("NSString".utf8), in: bytes, from: 13),
              let valueStart = find([0x84, 0x01, 0x2B], in: bytes, from: classEnd) else { return nil }
        var index = valueStart
        guard let length = readInteger(bytes, &index), length >= 0, index + length <= bytes.count else { return nil }
        guard let text = String(bytes: bytes[index..<index + length], encoding: .utf8) else { return nil }
        return text.filter { $0 != objectReplacement }
    }

    /// Typedstream integers: a byte in -110...127 is the value itself;
    /// 0x81 and 0x82 introduce a little-endian Int16 and Int32.
    private static func readInteger(_ bytes: [UInt8], _ index: inout Int) -> Int? {
        guard index < bytes.count else { return nil }
        let tag = bytes[index]
        index += 1
        switch tag {
        case 0x81:
            guard index + 2 <= bytes.count else { return nil }
            let value = Int(UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8)
            index += 2
            return value
        case 0x82:
            guard index + 4 <= bytes.count else { return nil }
            var value: UInt32 = 0
            for offset in 0..<4 { value |= UInt32(bytes[index + offset]) << (8 * offset) }
            index += 4
            return Int(value)
        case 0x00...0x7F:
            return Int(tag)
        default:
            return nil
        }
    }

    /// The index just past the first occurrence of `needle`.
    private static func find(_ needle: [UInt8], in haystack: [UInt8], from start: Int) -> Int? {
        guard needle.count <= haystack.count, start <= haystack.count - needle.count else { return nil }
        var index = start
        while index <= haystack.count - needle.count {
            if haystack[index] == needle[0], Array(haystack[index..<index + needle.count]) == needle { return index + needle.count }
            index += 1
        }
        return nil
    }
}

/// Messages stores dates as time since 2001-01-01 (the reference date):
/// nanoseconds on modern macOS, seconds on old databases. Zero means unset.
public enum AppleTime {
    /// 1e12 seconds is 31,000 years; 1e12 nanoseconds is 17 minutes past
    /// 2001. Nothing real lands on the wrong side of it.
    static let nanosecondThreshold: Int64 = 1_000_000_000_000

    public static func date(_ raw: Int64?) -> Date? {
        guard let raw, raw != 0 else { return nil }
        // magnitude, not abs: abs(Int64.min) traps, and one damaged date
        // must not take the app down.
        let seconds = raw.magnitude >= UInt64(nanosecondThreshold) ? Double(raw) / 1_000_000_000 : Double(raw)
        return Date(timeIntervalSinceReferenceDate: seconds)
    }
}
