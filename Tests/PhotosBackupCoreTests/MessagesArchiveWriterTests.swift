import Foundation
import Testing
@testable import PhotosBackupCore

/// The archive on disk: attachments, escaping, incremental runs, database
/// copies and file modes.
@Suite struct MessagesArchiveWriterTests {
    typealias Fixture = MessagesArchiveFixture

    private func oneChat(_ fixture: Fixture, messages: Int = 2) throws {
        try fixture.addHandle(1, "+15551234567")
        try fixture.addChat(1, guid: "iMessage;-;+15551234567", identifier: "+15551234567", handles: [1])
        for row in 0..<messages {
            try fixture.add(.init(rowID: Int64(row + 1), chat: 1, text: "Message \(row)", date: Fixture.time(row), handle: 1))
        }
    }

    private func onlyConversation(_ report: MessagesArchiver.Report) throws -> ArchivedConversation {
        try #require(report.overview.conversations.first)
    }

    private func mode(_ url: URL) throws -> Int {
        try (FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    @Test func copiesAttachmentsOnceAndCountsMissingOnes() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try oneChat(fixture)
        try fixture.addAttachment(1, message: 1, filename: fixture.writeAttachment("ab/01/IMG_0001.HEIC"), name: "IMG_0001.HEIC", mime: "image/heic")
        try fixture.addAttachment(2, message: 2, filename: "~/Library/Messages/Attachments/cd/02/gone.mov", name: "gone.mov", mime: "video/quicktime")
        let first = try fixture.archiver().run()
        let conversation = try onlyConversation(first)
        let attachments = try fixture.transcript(conversation).messages.flatMap(\.attachments)
        #expect(attachments.map(\.status) == [.archived, .missing])
        let file = try #require(attachments[0].file)
        let copy = fixture.archive.appendingPathComponent(conversation.relativePath).appendingPathComponent(file)
        #expect(try String(contentsOf: copy, encoding: .utf8) == "pixels")
        #expect(first.attachmentsCopied == 1)
        #expect(first.overview.missingAttachmentCount == 1)
        #expect(first.overview.attachmentCount == 2)
        let page = try fixture.page(conversation)
        #expect(page.contains("<img src=\"\(file)\""))
        #expect(page.contains("Not on this Mac"))

        // Same size already archived: not copied again. Once Messages lets
        // go of the original, the archived copy is still used.
        try fixture.sql("UPDATE message SET date_edited = \(Fixture.time(9)) WHERE ROWID = 1")
        let second = try fixture.archiver().run()
        #expect(second.conversationsWritten == 1)
        #expect(second.attachmentsCopied == 0)
        try FileManager.default.removeItem(at: fixture.attachments.appendingPathComponent("ab"))
        try fixture.sql("UPDATE message SET date_edited = \(Fixture.time(10)) WHERE ROWID = 1")
        _ = try fixture.archiver().run()
        #expect(try fixture.transcript(conversation).messages[0].attachments[0].status == .archived)
    }

    @Test func attachmentsOffWritesNoAttachmentFiles() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try oneChat(fixture)
        try fixture.addAttachment(1, message: 1, filename: fixture.writeAttachment("ab/photo.jpg"), name: "photo.jpg")
        let report = try fixture.archiver(attachments: false).run()
        let conversation = try onlyConversation(report)
        let folder = fixture.archive.appendingPathComponent(conversation.relativePath)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("Attachments").path))
        let attachment = try #require(try fixture.transcript(conversation).messages[0].attachments.first)
        #expect(attachment.status == .skipped && attachment.file == nil)
        #expect(try fixture.page(conversation).contains("photo.jpg"))
        #expect(report.overview.missingAttachmentCount == 0)
    }

    @Test func refusesAttachmentPathsOutsideMessages() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try oneChat(fixture)
        let secret = fixture.root.appendingPathComponent("secret.txt")
        try Data("private".utf8).write(to: secret)
        let link = fixture.attachments.appendingPathComponent("link.jpg")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)
        try fixture.addAttachment(1, message: 1, filename: secret.path, name: "secret.txt", mime: "text/plain")
        try fixture.addAttachment(2, message: 1, filename: "~/Library/Messages/Attachments/../../../../secret.txt", name: "dots.txt")
        try fixture.addAttachment(3, message: 2, filename: "~/Library/Messages/Attachments/link.jpg", name: "link.jpg")
        let report = try fixture.archiver().run()
        let conversation = try onlyConversation(report)
        let attachments = try fixture.transcript(conversation).messages.flatMap(\.attachments)
        #expect(attachments.map(\.status) == [.refused, .refused, .refused])
        #expect(report.attachmentsCopied == 0)
        #expect(report.overview.missingAttachmentCount == 3)
        let copies = fixture.archive.appendingPathComponent(conversation.relativePath).appendingPathComponent("Attachments")
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: copies.path)) ?? []).isEmpty)
    }

    @Test func escapesEveryPieceOfMessageText() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.addHandle(1, "<b>@example.com")
        try fixture.addChat(1, guid: "iMessage;+;chat<1>", identifier: "chat<1>", name: "<img src=x onerror=alert(1)>", group: true, handles: [1])
        try fixture.add(.init(rowID: 1, chat: 1, text: "<script>alert(1)</script> & \"quotes\" 'single'", date: Fixture.time(0), handle: 1))
        try fixture.add(.init(rowID: 2, chat: 1, text: "javascript:alert(1) and https://example.com/a?b=1&c=<2>", date: Fixture.time(1), handle: 1))
        try fixture.addAttachment(1, message: 1, filename: fixture.writeAttachment("x/\"><svg onload=1>.jpg"), name: "\"><svg onload=1>.jpg")
        let report = try fixture.archiver().run()
        let conversation = try onlyConversation(report)
        let page = try fixture.page(conversation)
        let index = try String(contentsOf: fixture.archive.appendingPathComponent("index.html"), encoding: .utf8)
        for html in [page, index] {
            #expect(!html.contains("<script>"))
            #expect(!html.contains("<img src=x"))
            #expect(!html.contains("<svg onload"))
            #expect(!html.contains("<b>"))
        }
        #expect(page.contains("&lt;script&gt;alert(1)&lt;/script&gt; &amp; &quot;quotes&quot; &#39;single&#39;"))
        #expect(page.contains("<a href=\"https://example.com/a?b=1&amp;c="))
        #expect(!page.contains("href=\"javascript"))
        #expect(page.contains("script-src 'none'"))
    }

    @Test func slugsComeFromTheChatGUIDAndSurviveRenames() throws {
        let slug = ArchiveFiles.slug(forChatGUID: "iMessage;+;chat123456789")
        #expect(slug == ArchiveFiles.slug(forChatGUID: "iMessage;+;chat123456789"))
        #expect(slug.hasPrefix("chat123456789-"))
        #expect(slug != ArchiveFiles.slug(forChatGUID: "SMS;+;chat123456789"))
        let odd = ArchiveFiles.slug(forChatGUID: "iMessage;-;../../Évil/Name\u{0}")
        #expect(odd.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
        #expect(ArchiveFiles.slug(forChatGUID: ";;;").hasPrefix("chat-"))

        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.addHandle(1, "+15551234567")
        try fixture.addChat(1, guid: "iMessage;+;chat42", identifier: "chat42", name: "Before", group: true, handles: [1])
        try fixture.add(.init(rowID: 1, chat: 1, text: "hi", date: Fixture.time(0), handle: 1))
        let before = try onlyConversation(fixture.archiver().run())
        try fixture.sql("UPDATE chat SET display_name = 'After' WHERE ROWID = 1")
        let after = try onlyConversation(fixture.archiver().run())
        #expect(after.title == "After")
        #expect(after.relativePath == before.relativePath)
    }

    @Test func aSecondRunWithNothingNewRewritesOnlyTheManifest() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try oneChat(fixture)
        try fixture.addAttachment(1, message: 1, filename: fixture.writeAttachment("a/photo.jpg"), name: "photo.jpg")
        let first = try fixture.archiver().run()
        #expect(first.newMessages == 2 && first.conversationsWritten == 1)
        let dates = try fixture.modificationDates()
        let manifest = try Data(contentsOf: fixture.archive.appendingPathComponent("archive.json"))

        let later = Fixture.day.addingTimeInterval(3600)
        let second = try fixture.archiver(now: later).run()
        #expect(second.newMessages == 0 && second.conversationsWritten == 0 && second.attachmentsCopied == 0)
        #expect(second.overview.messageCount == 2)
        #expect(second.overview.lastArchived == later)
        let after = try fixture.modificationDates()
        #expect(Set(after.keys) == Set(dates.keys))
        for (path, date) in dates where path != "/archive.json" { #expect(after[path] == date, "\(path) was rewritten") }
        #expect(try Data(contentsOf: fixture.archive.appendingPathComponent("archive.json")) != manifest)
    }

    @Test func newMessagesReRenderOnlyTheirConversation() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.addHandle(1, "+15551234567")
        try fixture.addHandle(2, "+15559876543")
        try fixture.addChat(1, guid: "iMessage;-;+15551234567", identifier: "+15551234567", handles: [1])
        try fixture.addChat(2, guid: "iMessage;-;+15559876543", identifier: "+15559876543", handles: [2])
        try fixture.add(.init(rowID: 1, chat: 1, text: "one", date: Fixture.time(0), handle: 1))
        try fixture.add(.init(rowID: 2, chat: 2, text: "two", date: Fixture.time(1), handle: 2))
        let first = try fixture.archiver().run()
        let quiet = try #require(first.overview.conversations.first { $0.id == "iMessage;-;+15559876543" })
        let dates = try fixture.modificationDates()

        try fixture.add(.init(rowID: 3, chat: 1, text: "three", date: Fixture.time(2), handle: 1))
        let second = try fixture.archiver().run()
        #expect(second.conversationsWritten == 1)
        #expect(second.newMessages == 1)
        let after = try fixture.modificationDates()
        let quietPage = "/\(quiet.relativePath)/index.html"
        #expect(after[quietPage] == dates[quietPage])
        #expect(after["/index.html"] != dates["/index.html"])
        // Most recent conversation first.
        #expect(second.overview.conversations.map(\.id) == ["iMessage;-;+15551234567", "iMessage;-;+15559876543"])
    }

    @Test func aDatabaseThatWentBackwardsRebuildsAndKeepsWhatWasArchived() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try oneChat(fixture, messages: 3)
        let first = try fixture.archiver().run()
        #expect(!first.rebuilt)

        // A restored Mac: an older chat.db, without the last message.
        try FileManager.default.removeItem(at: fixture.database)
        try fixture.createSchema()
        try oneChat(fixture, messages: 2)
        let second = try fixture.archiver().run()
        #expect(second.rebuilt)
        #expect(second.conversationsWritten == 1)
        let messages = try fixture.transcript(onlyConversation(second)).messages
        #expect(messages.map(\.text) == ["Message 0", "Message 1", "Message 2"])
        #expect(!(try fixture.archiver().run().rebuilt))
    }

    @Test func messagesDeletedFromMessagesStayArchived() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try oneChat(fixture, messages: 3)
        _ = try fixture.archiver().run()
        try fixture.sql("DELETE FROM chat_message_join WHERE message_id = 2")
        try fixture.sql("DELETE FROM message WHERE ROWID = 2")
        let report = try fixture.archiver().run()
        #expect(report.conversationsWritten == 1)
        #expect(try fixture.transcript(onlyConversation(report)).messages.map(\.text) == ["Message 0", "Message 1", "Message 2"])
    }

    @Test func keepsOneDatabaseCopyPerDayUpToTheSetting() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try oneChat(fixture)
        let folder = fixture.archive.appendingPathComponent("Database")
        for day in 0..<4 {
            _ = try fixture.archiver(keep: 2, now: Fixture.day.addingTimeInterval(Double(day) * 86_400)).run()
        }
        let again = try fixture.archiver(keep: 2, now: Fixture.day.addingTimeInterval(3 * 86_400 + 60)).run()
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["chat-2026-10-17.db", "chat-2026-10-18.db"])
        #expect(again.overview.databaseSnapshots == 2)
        // The copy is a real, consistent database.
        let copy = try SQLiteDatabase(readOnly: folder.appendingPathComponent("chat-2026-10-18.db"))
        var count: Int64 = 0
        try copy.query("SELECT count(*) FROM message") { count = $0.int(0) }
        #expect(count == 2)

        let none = try fixture.archiver(keep: 0, now: Fixture.day.addingTimeInterval(5 * 86_400)).run()
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        #expect(none.overview.databaseSnapshots == 0)
    }

    @Test func archiveFoldersArePrivateAndFilesOwnerOnly() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try oneChat(fixture)
        try fixture.addAttachment(1, message: 1, filename: fixture.writeAttachment("a/photo.jpg"), name: "photo.jpg")
        _ = try fixture.archiver().run()
        let walker = FileManager.default.enumerator(at: fixture.archive, includingPropertiesForKeys: [.isDirectoryKey])
        var checked = 0
        #expect(try mode(fixture.archive) == 0o700)
        while let url = walker?.nextObject() as? URL {
            let isDirectory = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            #expect(try mode(url) == (isDirectory ? 0o700 : 0o600), "\(url.lastPathComponent)")
            checked += 1
        }
        #expect(checked >= 9)
    }

    @Test func anUnreadableDatabaseMeansFullDiskAccess() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try oneChat(fixture)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: fixture.database.path)
        #expect(throws: MessagesArchiveError.needsFullDiskAccess) { try fixture.archiver().run() }
        try FileManager.default.removeItem(at: fixture.database)
        #expect(throws: MessagesArchiveError.databaseMissing) { try fixture.archiver().run() }
    }

    @Test func cancellingKeepsFinishedConversations() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try oneChat(fixture)
        let archiver = fixture.archiver()
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try archiver.run()
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: fixture.archive.appendingPathComponent("index.html").path))
        #expect(try fixture.archiver().run().conversationsWritten == 1)
    }
}
