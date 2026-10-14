import Foundation
import Testing
@testable import PhotosBackupCore

/// What a conversation's messages.json says, built from synthetic chat.db rows.
@Suite struct MessagesArchiveTranscriptTests {
    typealias Fixture = MessagesArchiveFixture

    /// One one-to-one chat (handle 1) and one unnamed group (handles 1-3).
    private func twoChats(_ fixture: Fixture) throws {
        try fixture.addHandle(1, "+15551234567")
        try fixture.addHandle(2, "sam@example.com")
        try fixture.addHandle(3, "+447700900123")
        try fixture.addChat(1, guid: "iMessage;-;+15551234567", identifier: "+15551234567", handles: [1])
        try fixture.addChat(2, guid: "iMessage;+;chat123456789", identifier: "chat123456789", group: true, handles: [1, 2, 3])
    }

    private func conversation(_ report: MessagesArchiver.Report, _ guid: String) throws -> ArchivedConversation {
        try #require(report.overview.conversations.first { $0.id == guid })
    }

    @Test func decodesTextFromEitherColumn() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try twoChats(fixture)
        try fixture.add(.init(rowID: 1, chat: 1, text: "Plain text column", date: Fixture.time(0), handle: 1))
        try fixture.add(.init(rowID: 2, chat: 1, text: nil, body: typedStream("Only in attributedBody"), date: Fixture.time(1), fromMe: true))
        try fixture.add(.init(rowID: 3, chat: 1, text: nil, body: Data("garbage".utf8), date: Fixture.time(2), handle: 1))
        let report = try fixture.archiver().run()
        let messages = try fixture.transcript(conversation(report, "iMessage;-;+15551234567")).messages
        #expect(messages.map(\.text) == ["Plain text column", "Only in attributedBody", ""])
        #expect(report.decodeFailures == 1)
        #expect(messages[1].isFromMe && messages[1].senderName == "You" && messages[1].sender == nil)
    }

    @Test func readsDatesInNanosecondsAndSeconds() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try twoChats(fixture)
        try fixture.add(.init(rowID: 1, chat: 1, text: "old Mac", date: 400_000_000, handle: 1))
        try fixture.add(.init(rowID: 2, chat: 1, text: "new Mac", date: 813_661_200_000_000_000, handle: 1))
        let report = try fixture.archiver().run()
        let dates = try fixture.transcript(conversation(report, "iMessage;-;+15551234567")).messages.map(\.date)
        #expect(dates == [Date(timeIntervalSinceReferenceDate: 400_000_000), Date(timeIntervalSinceReferenceDate: 813_661_200)])
    }

    @Test func titlesOneToOneAndGroupConversations() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try twoChats(fixture)
        try fixture.addChat(3, guid: "iMessage;+;chat999", identifier: "chat999", name: "Book Club", group: true, handles: [2, 3])
        for chat in Int64(1)...3 { try fixture.add(.init(rowID: chat, chat: chat, text: "hi", date: Fixture.time(Int(chat)), handle: 2)) }

        let plain = try fixture.archiver().run()
        #expect(try conversation(plain, "iMessage;-;+15551234567").title == "+15551234567")
        #expect(try conversation(plain, "iMessage;-;+15551234567").isGroup == false)

        // A card typed without the country code still matches.
        let names = HandleNames([.init(name: "Alex Doe", handles: ["(555) 123-4567"]), .init(name: "Sam", handles: ["SAM@example.com"])])
        let named = try fixture.archiver(names: names).run()
        #expect(try conversation(named, "iMessage;-;+15551234567").title == "Alex Doe")
        let group = try conversation(named, "iMessage;+;chat123456789")
        #expect(group.isGroup)
        #expect(group.title == "Alex Doe, Sam & +447700900123")
        #expect(group.participants == ["Alex Doe", "Sam", "+447700900123"])
        #expect(try conversation(named, "iMessage;+;chat999").title == "Book Club")
    }

    @Test func tapbacksAttachToTheirTargetAndRemovalsCancel() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try twoChats(fixture)
        try fixture.add(.init(rowID: 1, chat: 2, text: "Dinner at eight?", date: Fixture.time(0), fromMe: true))
        try fixture.add(.init(rowID: 2, chat: 2, text: nil, date: Fixture.time(1), handle: 1, associatedGUID: "p:0/guid-1", associatedType: 2000))
        // Sam likes, then takes it back.
        try fixture.add(.init(rowID: 3, chat: 2, text: nil, date: Fixture.time(2), handle: 2, associatedGUID: "p:0/guid-1", associatedType: 2001))
        try fixture.add(.init(rowID: 4, chat: 2, text: nil, date: Fixture.time(3), handle: 2, associatedGUID: "p:0/guid-1", associatedType: 3001))
        // A removal naming a tapback the sender never left changes nothing.
        try fixture.add(.init(rowID: 5, chat: 2, text: nil, date: Fixture.time(4), handle: 1, associatedGUID: "p:0/guid-1", associatedType: 3003))
        try fixture.add(.init(rowID: 6, chat: 2, text: nil, date: Fixture.time(5), handle: 3, associatedGUID: "bp:guid-1", associatedType: 2006,
                              emoji: "\u{1F37D}\u{FE0F}"))
        let report = try fixture.archiver().run()
        let messages = try fixture.transcript(conversation(report, "iMessage;+;chat123456789")).messages
        #expect(messages.count == 1)
        #expect(messages[0].reactions.map(\.kind) == ["love", "emoji"])
        #expect(messages[0].reactions.map(\.sender) == ["+15551234567", "+447700900123"])
        #expect(messages[0].reactions[1].emoji == "\u{1F37D}\u{FE0F}")
        #expect(try conversation(report, "iMessage;+;chat123456789").messageCount == 1)
    }

    @Test func aNewTapbackReplacesTheSendersEarlierOne() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try twoChats(fixture)
        try fixture.add(.init(rowID: 1, chat: 1, text: "Passed the exam", date: Fixture.time(0), handle: 1))
        try fixture.add(.init(rowID: 2, chat: 1, text: nil, date: Fixture.time(1), fromMe: true, associatedGUID: "p:0/guid-1", associatedType: 2001))
        try fixture.add(.init(rowID: 3, chat: 1, text: nil, date: Fixture.time(2), fromMe: true, associatedGUID: "p:0/guid-1", associatedType: 2004))
        let report = try fixture.archiver().run()
        let reactions = try fixture.transcript(conversation(report, "iMessage;-;+15551234567")).messages[0].reactions
        #expect(reactions.map(\.kind) == ["emphasize"])
        #expect(reactions[0].isFromMe && reactions[0].senderName == "You")
    }

    @Test func repliesEditsUnsendsAndEffects() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try twoChats(fixture)
        try fixture.add(.init(rowID: 1, chat: 1, text: "Original question", date: Fixture.time(0), handle: 1))
        try fixture.add(.init(rowID: 2, chat: 1, text: "An answer", date: Fixture.time(1), fromMe: true, replyTo: "guid-1",
                              edited: Fixture.time(3), effect: "com.apple.MobileSMS.expressivesend.impact"))
        try fixture.add(.init(rowID: 3, chat: 1, text: nil, date: Fixture.time(2), handle: 1, retracted: Fixture.time(4)))
        let report = try fixture.archiver().run()
        let chat = try conversation(report, "iMessage;-;+15551234567")
        let messages = try fixture.transcript(chat).messages
        #expect(messages[1].replyTo == "guid-1")
        #expect(messages[1].edited && !messages[1].unsent)
        #expect(messages[1].effect == "Slam")
        #expect(messages[2].unsent && messages[2].text.isEmpty)
        let page = try fixture.page(chat)
        #expect(page.contains("href=\"#m-guid-1\""))
        #expect(page.contains("Original question"))
        #expect(page.contains(">Edited<"))
        #expect(page.contains("+15551234567 unsent a message."))
        #expect(page.contains("Sent with Slam"))
    }

    @Test func systemEventsAreDescribed() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try twoChats(fixture)
        let names = HandleNames([.init(name: "Sam", handles: ["sam@example.com"])])
        try fixture.add(.init(rowID: 1, chat: 2, text: nil, date: Fixture.time(0), handle: 2, itemType: 2, groupTitle: "Trip <2027>"))
        try fixture.add(.init(rowID: 2, chat: 2, text: nil, date: Fixture.time(1), fromMe: true, itemType: 1, groupAction: 0, otherHandle: 3))
        try fixture.add(.init(rowID: 3, chat: 2, text: nil, date: Fixture.time(2), handle: 1, itemType: 3, groupAction: 0))
        let report = try fixture.archiver(names: names).run()
        let chat = try conversation(report, "iMessage;+;chat123456789")
        let messages = try fixture.transcript(chat).messages
        #expect(messages.map(\.event) == [
            "Sam named the conversation \u{201C}Trip <2027>\u{201D}.",
            "You added +447700900123 to the conversation.",
            "+15551234567 left the conversation.",
        ])
        #expect(chat.messageCount == 0)
        #expect(try fixture.page(chat).contains("Trip &lt;2027&gt;"))
    }
}

@Suite struct HandleNamesTests {
    @Test func matchesPhoneNumbersByDigitsAndEmailsWithoutCase() {
        let names = HandleNames([
            .init(name: "Priya", handles: ["+91 98765 43210"]),
            .init(name: "Lee", handles: ["Lee@Example.COM", "020 7946 0018"]),
        ])
        #expect(names.name(for: "+919876543210") == "Priya")
        #expect(names.name(for: "9876543210") == "Priya")
        #expect(names.name(for: "lee@example.com") == "Lee")
        #expect(names.name(for: "+442079460018") == "Lee")
        #expect(names.name(for: "+15550000000") == nil)
        #expect(names.display("+15550000000") == "+15550000000")
    }
}
