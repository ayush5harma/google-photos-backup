import Foundation

/// The protobuf wire format, by hand: gpmc 0.9.0 sends schema-less messages
/// through blackboxprotobuf, so there is no .proto to generate from, and
/// Core takes no package dependencies. The encoder writes fields in the
/// order they are appended, which is the order blackboxprotobuf writes a
/// dict's keys; GooglePhotosGolden holds the result byte-equal to gpmc.
///
/// Technique adapted from g8row/PhotosBackup (MIT), GPMC/Core/Protobuf.swift:
/// one scanner that owns every bounds check, readers built on top of it.
enum ProtobufWire {
    struct Malformed: Error, Equatable {}

    enum Value: Equatable, Sendable {
        case varint(UInt64)
        case fixed64(UInt64)
        case bytes(Data)
        case fixed32(UInt32)
    }

    struct Field: Equatable, Sendable {
        let number: Int
        let value: Value
    }

    // MARK: - Encoding

    static func varint(_ value: UInt64) -> Data {
        var remaining = value
        var bytes = Data()
        while remaining > 0x7F {
            bytes.append(UInt8(remaining & 0x7F) | 0x80)
            remaining >>= 7
        }
        bytes.append(UInt8(remaining))
        return bytes
    }

    static func tag(_ field: Int, wireType: UInt64) -> Data {
        varint(UInt64(field) << 3 | wireType)
    }

    static func int(_ field: Int, _ value: UInt64) -> Data {
        tag(field, wireType: 0) + varint(value)
    }

    /// A signed int as blackboxprotobuf's "int" type writes it: a negative
    /// value as its ten-byte two's complement.
    static func int(_ field: Int, signed value: Int64) -> Data {
        int(field, UInt64(bitPattern: value))
    }

    static func bytes(_ field: Int, _ value: Data) -> Data {
        tag(field, wireType: 2) + varint(UInt64(value.count)) + value
    }

    static func string(_ field: Int, _ value: String) -> Data {
        bytes(field, Data(value.utf8))
    }

    // MARK: - Decoding

    /// Every field of one message level, in wire order. Throws on anything
    /// a well-formed message cannot contain: a truncated varint or length,
    /// a length past the end, field number 0, or the group wire types.
    static func decode(_ data: Data) throws(Malformed) -> [Field] {
        let bytes = [UInt8](data)
        var index = 0
        var fields: [Field] = []

        func readVarint() throws(Malformed) -> UInt64 {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while true {
                guard index < bytes.count, shift < 64 else { throw Malformed() }
                let byte = bytes[index]
                index += 1
                // The tenth byte may only carry the top bit of a 64-bit value.
                if shift == 63, byte > 1 { throw Malformed() }
                value |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
            }
        }

        func take(_ count: Int) throws(Malformed) -> [UInt8] {
            guard count >= 0, count <= bytes.count - index else { throw Malformed() }
            defer { index += count }
            return Array(bytes[index..<index + count])
        }

        while index < bytes.count {
            let key = try readVarint()
            let number = key >> 3
            guard number > 0, number <= 536_870_911 else { throw Malformed() }
            let value: Value
            switch key & 7 {
            case 0:
                value = .varint(try readVarint())
            case 1:
                value = .fixed64(try take(8).reversed().reduce(0) { $0 << 8 | UInt64($1) })
            case 2:
                let length = try readVarint()
                guard length <= UInt64(bytes.count - index) else { throw Malformed() }
                value = .bytes(Data(try take(Int(length))))
            case 5:
                value = .fixed32(try take(4).reversed().reduce(0) { $0 << 8 | UInt32($1) })
            default:
                throw Malformed()
            }
            fields.append(Field(number: Int(number), value: value))
        }
        return fields
    }

    /// Every length-delimited value at `field`, in wire order.
    static func allBytes(_ field: Int, in data: Data) throws(Malformed) -> [Data] {
        try decode(data).compactMap { entry in
            guard entry.number == field, case .bytes(let payload) = entry.value else { return nil }
            return payload
        }
    }

    static func firstBytes(_ field: Int, in data: Data) throws(Malformed) -> Data? {
        try allBytes(field, in: data).first
    }

    static func firstVarint(_ field: Int, in data: Data) throws(Malformed) -> UInt64? {
        for entry in try decode(data) where entry.number == field {
            if case .varint(let number) = entry.value { return number }
        }
        return nil
    }

    /// The bytes at a path of nested first occurrences, or nil when any
    /// step is missing.
    static func bytes(at path: [Int], in data: Data) throws(Malformed) -> Data? {
        var current = data
        for field in path {
            guard let next = try firstBytes(field, in: current) else { return nil }
            current = next
        }
        return current
    }

    /// A non-empty UTF-8 string at a path; nil when absent, empty or not text.
    static func string(at path: [Int], in data: Data) throws(Malformed) -> String? {
        guard let raw = try bytes(at: path, in: data),
              let text = String(data: raw, encoding: .utf8), !text.isEmpty else { return nil }
        return text
    }
}
