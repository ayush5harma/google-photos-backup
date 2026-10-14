import Foundation
import Testing
@testable import PhotosBackupCore

/// NSArchiver is how Messages writes attributedBody. It is deprecated, so the
/// fixtures reach it through a protocol witness, which keeps the build free
/// of warnings without hiding the call.
protocol LegacyArchiving { static func archive(_ object: Any) -> Data }
enum LegacyArchiver: LegacyArchiving {
    @available(macOS, deprecated: 10.13)
    static func archive(_ object: Any) -> Data { NSArchiver.archivedData(withRootObject: object) }
}

func typedStream(_ text: String, mutable: Bool = false) -> Data {
    func archived<T: LegacyArchiving>(_ type: T.Type, _ object: Any) -> Data { T.archive(object) }
    let string: NSAttributedString = mutable ? NSMutableAttributedString(string: text) : NSAttributedString(string: text)
    return archived(LegacyArchiver.self, string)
}

@Suite struct TypedStreamTests {
    @Test(arguments: [
        "Hello",
        "",
        "Unicode: caf\u{E9}, \u{65E5}\u{672C}, \u{1F600}",
        "Line one\nline two\ttabbed",
        String(repeating: "long ", count: 40),
        String(repeating: "x", count: 70_000),
    ])
    func decodesArchivedAttributedStrings(text: String) {
        #expect(TypedStream.plainText(from: typedStream(text)) == text)
        #expect(TypedStream.plainText(from: typedStream(text, mutable: true)) == text)
    }

    @Test func dropsAttachmentPlaceholders() {
        #expect(TypedStream.plainText(from: typedStream("\u{FFFC}Look at this\u{FFFC}")) == "Look at this")
    }

    @Test func refusesWhatIsNotATypedStream() throws {
        #expect(TypedStream.plainText(from: Data()) == nil)
        #expect(TypedStream.plainText(from: Data("streamtyped but not really".utf8)) == nil)
        // A truncated stream must not read past its end.
        let whole = typedStream("Truncated text here")
        let textStart = try #require(whole.range(of: Data("Truncated".utf8))).lowerBound
        #expect(TypedStream.plainText(from: whole.prefix(textStart + 5)) == nil)
    }
}

@Suite struct AppleTimeTests {
    @Test func readsNanosecondsAndSecondsFromTheSameEpoch() throws {
        // 2026-10-14 00:00:00 UTC, 813,628,800 s after 2001-01-01.
        let expected = Date(timeIntervalSince1970: 1_791_936_000)
        #expect(AppleTime.date(813_628_800) == expected)
        #expect(AppleTime.date(813_628_800_000_000_000) == expected)
        let early = try #require(AppleTime.date(60))
        #expect(early == Date(timeIntervalSinceReferenceDate: 60))
    }

    @Test func zeroAndNullMeanUnset() {
        #expect(AppleTime.date(0) == nil)
        #expect(AppleTime.date(nil) == nil)
    }
}
