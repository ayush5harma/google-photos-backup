import Foundation
import Testing
@testable import PhotosBackupCore

@Suite struct GooglePhotosProtobufTests {
    @Test(arguments: [UInt64(0), 1, 127, 128, 300, 46_000_000, UInt64(UInt32.max), UInt64.max])
    func varintsRoundTrip(value: UInt64) throws {
        let fields = try ProtobufWire.decode(ProtobufWire.int(7, value))
        #expect(fields == [.init(number: 7, value: .varint(value))])
    }

    @Test func knownEncodingsMatchTheSpec() {
        // protobuf.dev's own examples: 150 in field 1, "testing" in field 2.
        #expect(ProtobufWire.int(1, 150) == Data([0x08, 0x96, 0x01]))
        #expect(ProtobufWire.string(2, "testing") == Data([0x12, 0x07]) + Data("testing".utf8))
        // blackboxprotobuf writes a negative "int" as ten bytes.
        #expect(ProtobufWire.int(1, signed: -1) == Data([0x08] + [UInt8](repeating: 0xFF, count: 9) + [0x01]))
    }

    @Test func nestedMessagesRoundTrip() throws {
        let inner = ProtobufWire.string(1, "AF1QipKey") + ProtobufWire.int(2, 9)
        let message = ProtobufWire.bytes(1, ProtobufWire.bytes(3, inner)) + ProtobufWire.bytes(1, Data())
        #expect(try ProtobufWire.string(at: [1, 3, 1], in: message) == "AF1QipKey")
        #expect(try ProtobufWire.allBytes(1, in: message).count == 2)
        #expect(try ProtobufWire.firstVarint(2, in: inner) == 9)
        #expect(try ProtobufWire.string(at: [1, 4, 1], in: message) == nil)
    }

    @Test func fixedWidthFieldsAreReadNotSkippedBlindly() throws {
        let data = Data([0x09, 1, 0, 0, 0, 0, 0, 0, 0, 0x15, 2, 0, 0, 0])
        #expect(try ProtobufWire.decode(data) == [.init(number: 1, value: .fixed64(1)), .init(number: 2, value: .fixed32(2))])
    }

    static let malformed: [[UInt8]] = [
        [0x08],                                   // varint value missing
        [0x08, 0x80],                             // varint never ends
        [0x12, 0x05, 0x61],                       // length past the end
        [0x00, 0x01],                             // field number 0
        [0x0B],                                   // group start: never sent by Google Photos
        [0x0F, 0x00],                             // wire type 7 does not exist
        [0x09, 0x01],                             // fixed64 cut short
        [0x08, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01],  // varint over 64 bits
    ]

    @Test(arguments: malformed)
    func malformedInputIsRejected(bytes: [UInt8]) {
        #expect(throws: ProtobufWire.Malformed.self) { try ProtobufWire.decode(Data(bytes)) }
    }

    @Test func emptyInputIsAnEmptyMessage() throws {
        #expect(try ProtobufWire.decode(Data()).isEmpty)
    }
}
