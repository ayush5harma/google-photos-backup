import Foundation
import Testing
@testable import PhotosBackupCore

/// What the archive must never lose or clobber: its own transcripts and
/// manifest, a chosen folder's other files, a run's work when the dated copy
/// fails, and one run's files to another.
@Suite struct MessagesArchiveSafetyTests {
    typealias Fixture = MessagesArchiveFixture

    private func oneChat(_ fixture: Fixture, messages: Int) throws {
        try fixture.addHandle(1, "+15551234567")
        try fixture.addChat(1, guid: "iMessage;-;+15551234567", identifier: "+15551234567", handles: [1])
        for row in 0..<messages {
            try fixture.add(.init(rowID: Int64(row + 1), chat: 1, text: "Message \(row)", date: Fixture.time(row), handle: 1))
        }
    }

    private func jsonURL(_ fixture: Fixture, _ conversation: ArchivedConversation) -> URL {
        fixture.archive.appendingPathComponent(conversation.relativePath).appendingPathComponent("messages.json")
    }

    @Test func aTranscriptFromBeforeAFieldExistedKeepsItsMessages() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try oneChat(fixture, messages: 3)
        let conversation = try #require(fixture.archiver().run().overview.conversations.first)
        try fixture.sql("DELETE FROM chat_message_join WHERE message_id = 2")
        try fixture.sql("DELETE FROM message WHERE ROWID = 2")
        let json = jsonURL(fixture, conversation)
        let older = try String(contentsOf: json, encoding: .utf8)
            .replacingOccurrences(of: "\"edited\":false,", with: "")
            .replacingOccurrences(of: "\"reactions\":[],", with: "")
        try older.write(to: json, atomically: true, encoding: .utf8)
        try fixture.add(.init(rowID: 4, chat: 1, text: "Message 3", date: Fixture.time(3), handle: 1))
        let report = try fixture.archiver().run()
        #expect(report.unreadableConversations == 0)
        #expect(try fixture.transcript(conversation).messages.map(\.text) == ["Message 0", "Message 1", "Message 2", "Message 3"])
    }

    @Test func anUnreadableTranscriptIsNeverWrittenOver() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try oneChat(fixture, messages: 2)
        try fixture.addHandle(2, "+15559876543")
        try fixture.addChat(2, guid: "iMessage;-;+15559876543", identifier: "+15559876543", handles: [2])
        try fixture.add(.init(rowID: 10, chat: 2, text: "Other chat", date: Fixture.time(10), handle: 2))
        let first = try fixture.archiver().run()
        let damaged = try #require(first.overview.conversations.first { $0.id == "iMessage;-;+15551234567" })
        let json = jsonURL(fixture, damaged)
        let garbage = Data("{\"version\":1,\"conversation\":".utf8)
        try garbage.write(to: json)

        try fixture.add(.init(rowID: 3, chat: 1, text: "New here", date: Fixture.time(3), handle: 1))
        try fixture.add(.init(rowID: 11, chat: 2, text: "And here", date: Fixture.time(11), handle: 2))
        let second = try fixture.archiver().run()
        #expect(second.unreadableConversations == 1)
        #expect(second.overview.unreadableConversations == 1)
        #expect(second.conversationsWritten == 1)
        #expect(try Data(contentsOf: json) == garbage)
        // The damaged conversation stays listed, and is tried again next run.
        #expect(second.overview.conversations.count == 2)
        #expect(try fixture.archiver().run().unreadableConversations == 1)
    }

    @Test func aTranscriptFromANewerAppIsLeftAlone() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try oneChat(fixture, messages: 1)
        let conversation = try #require(fixture.archiver().run().overview.conversations.first)
        let json = jsonURL(fixture, conversation)
        let newer = try String(contentsOf: json, encoding: .utf8).replacingOccurrences(of: "\"version\":1", with: "\"version\":99")
        try newer.write(to: json, atomically: true, encoding: .utf8)
        try fixture.add(.init(rowID: 2, chat: 1, text: "later", date: Fixture.time(2), handle: 1))
        #expect(try fixture.archiver().run().unreadableConversations == 1)
        #expect(try String(contentsOf: json, encoding: .utf8) == newer)
    }

    @Test func archiveTypesReadWithDefaultsForMissingFields() throws {
        let json = """
        {"conversation":{"id":"c","relativePath":"Conversations/c"},
         "messages":[{"id":"m","attachments":[{"id":"a","status":"from-the-future","file":"Attachments/x.jpg"}],
                      "reactions":[{"kind":"love"}]}]}
        """
        let transcript = try ConversationTranscript.decode(Data(json.utf8))
        #expect(transcript.version == 1)
        #expect(transcript.conversation.title == "c")
        let message = try #require(transcript.messages.first)
        #expect(message.text.isEmpty && !message.edited && !message.unsent && message.senderName == "Unknown")
        #expect(message.attachments.first?.status == .missing)
        #expect(message.reactions.first?.emoji == "\u{2764}\u{FE0F}")
    }

    @Test func aDamagedManifestIsRebuiltFromTheConversationFolders() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try oneChat(fixture, messages: 2)
        try fixture.addHandle(2, "+15559876543")
        try fixture.addChat(2, guid: "iMessage;-;+15559876543", identifier: "+15559876543", handles: [2])
        try fixture.add(.init(rowID: 10, chat: 2, text: "Soon deleted", date: Fixture.time(10), handle: 2))
        _ = try fixture.archiver().run()
        // The second conversation leaves Messages, then archive.json breaks.
        try fixture.sql("DELETE FROM chat_message_join WHERE chat_id = 2")
        try fixture.sql("DELETE FROM chat WHERE ROWID = 2")
        let manifest = fixture.archive.appendingPathComponent("archive.json")
        try Data("not json".utf8).write(to: manifest)
        let report = try fixture.archiver().run()
        #expect(report.manifestRebuilt)
        #expect(Set(report.overview.conversations.map(\.id)) == ["iMessage;-;+15551234567", "iMessage;-;+15559876543"])
        #expect(try String(contentsOf: fixture.archive.appendingPathComponent("index.html"), encoding: .utf8).contains("+15559876543"))
        #expect(FileManager.default.fileExists(atPath: manifest.appendingPathExtension("unreadable").path))

        // A deleted archive.json is rebuilt the same way.
        try FileManager.default.removeItem(at: manifest)
        #expect(try fixture.archiver().run().overview.conversations.count == 2)
        // A valid JSON object without the manifest's chats is damaged too.
        try Data("{}".utf8).write(to: manifest)
        let emptyObject = try fixture.archiver().run()
        #expect(emptyObject.manifestRebuilt)
        #expect(emptyObject.overview.conversations.count == 2)
    }

    @Test func aChosenFolderWithOtherFilesGetsAnArchiveFolderInside() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let chosen = fixture.root.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        #expect(MessagesArchiver.archiveFolder(forChosen: chosen) == chosen)
        try Data().write(to: chosen.appendingPathComponent(".DS_Store"))
        #expect(MessagesArchiver.archiveFolder(forChosen: chosen) == chosen.appendingPathComponent("Messages Archive", isDirectory: true))
        try Data("<p>my own page</p>".utf8).write(to: chosen.appendingPathComponent("index.html"))
        let inside = MessagesArchiver.archiveFolder(forChosen: chosen)
        #expect(inside == chosen.appendingPathComponent("Messages Archive", isDirectory: true))

        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        let unrelatedPage = inside.appendingPathComponent("index.html")
        try Data("<p>another page</p>".utf8).write(to: unrelatedPage)
        let secondInside = chosen.appendingPathComponent("Messages Archive 2", isDirectory: true)
        #expect(MessagesArchiver.archiveFolder(forChosen: chosen) == secondInside)
        #expect(try String(contentsOf: unrelatedPage, encoding: .utf8) == "<p>another page</p>")
        try FileManager.default.createDirectory(at: secondInside.appendingPathComponent("Conversations"), withIntermediateDirectories: true)
        var childManifest = ArchiveManifest()
        childManifest.lastArchived = Date()
        try childManifest.save(to: secondInside)
        #expect(MessagesArchiver.archiveFolder(forChosen: chosen) == secondInside)

        try oneChat(fixture, messages: 1)
        try FileManager.default.removeItem(at: chosen.appendingPathComponent("index.html"))
        try FileManager.default.createDirectory(at: fixture.archive, withIntermediateDirectories: true)
        try Data("<p>my own page</p>".utf8).write(to: fixture.archive.appendingPathComponent("notes.html"))
        let big = 5_000_000
        try Data(count: big).write(to: fixture.archive.appendingPathComponent("big.bin"))
        let report = try fixture.archiver().run()
        // An existing archive is used as it is, and only its files count.
        #expect(MessagesArchiver.archiveFolder(forChosen: fixture.archive) == fixture.archive)
        let own = ArchiveFiles.totalSize(of: fixture.archive) - Int64(big) - 18
        #expect(report.overview.archiveBytes == own)
        #expect(try String(contentsOf: fixture.archive.appendingPathComponent("notes.html"), encoding: .utf8) == "<p>my own page</p>")
    }

    @Test func aFailedDatabaseCopyIsAWarningAndTheRunCounts() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try oneChat(fixture, messages: 2)
        try FileManager.default.createDirectory(at: fixture.archive, withIntermediateDirectories: true)
        // A plain file where the Database folder should be.
        try Data("x".utf8).write(to: fixture.archive.appendingPathComponent("Database"))
        let report = try fixture.archiver().run()
        let problem = try #require(report.snapshotProblem)
        #expect(problem.hasPrefix("could not save today's copy"))
        #expect(report.overview.snapshotProblem == problem)
        #expect(report.overview.messageCount == 2)
        #expect(FileManager.default.fileExists(atPath: fixture.archive.appendingPathComponent("archive.json").path))
        #expect(try fixture.archiver().run().conversationsWritten == 0)
    }

    @Test func folderErrorsNameNoFolders() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try oneChat(fixture, messages: 1)
        try FileManager.default.createDirectory(at: fixture.archive, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: fixture.archive.appendingPathComponent("Conversations"))
        do {
            _ = try fixture.archiver().run()
            Issue.record("expected a folder error")
        } catch let error as MessagesArchiveError {
            guard case .folderUnavailable = error else { Issue.record("unexpected \(error)"); return }
            #expect(error.description.hasPrefix("could not write to the archive folder (error "))
            #expect(!error.description.contains("Conversations") && !error.description.contains("Archive/"))
        }
    }

    @Test func oneRunPerFolderAtATime() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try oneChat(fixture, messages: 1)
        let held = try ArchiveRunLock(folder: fixture.archive, in: fixture.temporary)
        #expect(throws: MessagesArchiveError.alreadyRunning) { try fixture.archiver().run() }
        held.release()
        #expect(try fixture.archiver().run().conversationsWritten == 1)
    }

    @Test func leftoversOfAKilledRunAreCleanedUp() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try oneChat(fixture, messages: 1)
        let database = fixture.archive.appendingPathComponent("Database", isDirectory: true)
        try FileManager.default.createDirectory(at: database, withIntermediateDirectories: true)
        let partial = database.appendingPathComponent(".chat-2026-10-14.db.\(UUID().uuidString).partial")
        try Data("half".utf8).write(to: partial)
        let rootPartial = fixture.archive.appendingPathComponent(".index.html.\(UUID().uuidString).partial")
        try Data("half".utf8).write(to: rootPartial)
        let unrelated = fixture.archive.appendingPathComponent(".download.partial")
        try Data("mine".utf8).write(to: unrelated)
        let misleading = fixture.archive.appendingPathComponent(".index.html.not-a-uuid.partial")
        try Data("mine too".utf8).write(to: misleading)
        let unrelatedDirectory = fixture.archive.appendingPathComponent(".index.html.\(UUID().uuidString).partial", isDirectory: true)
        try FileManager.default.createDirectory(at: unrelatedDirectory, withIntermediateDirectories: true)
        let stale = fixture.temporary.appendingPathComponent("photos-backup-archive-\(UUID().uuidString)", isDirectory: true)
        let fresh = fixture.temporary.appendingPathComponent("photos-backup-archive-\(UUID().uuidString)", isDirectory: true)
        for folder in [stale, fresh] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-7 * 3600)], ofItemAtPath: stale.path)
        _ = try fixture.archiver().run()
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        #expect(!FileManager.default.fileExists(atPath: rootPartial.path))
        #expect(try String(contentsOf: unrelated, encoding: .utf8) == "mine")
        #expect(try String(contentsOf: misleading, encoding: .utf8) == "mine too")
        #expect(FileManager.default.fileExists(atPath: unrelatedDirectory.path))
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
    }

    @Test func deniedDatabaseReadIsDifferentFromMissingDatabase() {
        #expect(MessagesSnapshot.sourceOpenError(EACCES) == .needsFullDiskAccess)
        #expect(MessagesSnapshot.sourceOpenError(EPERM) == .needsFullDiskAccess)
        #expect(MessagesSnapshot.sourceOpenError(ENOENT) == .databaseMissing)
    }

    @Test func rowsStillInTheWriteAheadLogAreArchived() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        // Messages keeps chat.db open in WAL mode; recent rows live in -wal.
        let keeper = try SQLiteDatabase(creating: fixture.database)
        try keeper.query("PRAGMA journal_mode=WAL") { _ in }
        try keeper.query("PRAGMA wal_autocheckpoint=0") { _ in }
        // An open read transaction, as a live reader has: the connections
        // the fixture opens and closes cannot fold the WAL back in.
        try keeper.query("BEGIN") { _ in }
        try keeper.query("SELECT count(*) FROM chat") { _ in }
        try oneChat(fixture, messages: 3)
        let wal = try #require(ArchiveFiles.size(of: URL(fileURLWithPath: fixture.database.path + "-wal")))
        #expect(wal > 0)
        let report = try fixture.archiver().run()
        #expect(report.overview.messageCount == 3)
        // The dated copy is one self-contained file.
        let copies = try FileManager.default.contentsOfDirectory(atPath: fixture.archive.appendingPathComponent("Database").path)
        #expect(copies.count == 1 && copies[0].hasSuffix(".db"))
        withExtendedLifetime(keeper) {}
    }

    @Test func aDamagedDateDoesNotCrash() {
        #expect(AppleTime.date(Int64.min) != nil)
        #expect(AppleTime.date(Int64.max) != nil)
    }
}

/// Edits and unsends that happen after a message was archived.
@Suite struct MessagesArchiveHistoryTests {
    typealias Fixture = MessagesArchiveFixture

    @Test func theFirstArchivedTextOfAnEditedMessageIsKept() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.addHandle(1, "+15551234567")
        try fixture.addChat(1, guid: "iMessage;-;+15551234567", identifier: "+15551234567", handles: [1])
        try fixture.add(.init(rowID: 1, chat: 1, text: "Meet at 8", date: Fixture.time(0), handle: 1))
        try fixture.add(.init(rowID: 2, chat: 1, text: "Secret plan", date: Fixture.time(1), handle: 1))
        let conversation = try #require(fixture.archiver().run().overview.conversations.first)

        try fixture.sql("UPDATE message SET text = 'Meet at 9', date_edited = \(Fixture.time(5)) WHERE ROWID = 1")
        try fixture.sql("UPDATE message SET text = NULL, date_retracted = \(Fixture.time(6)) WHERE ROWID = 2")
        _ = try fixture.archiver().run()
        try fixture.sql("UPDATE message SET text = 'Meet at 10', date_edited = \(Fixture.time(7)) WHERE ROWID = 1")
        _ = try fixture.archiver().run()

        let messages = try fixture.transcript(conversation).messages
        #expect(messages[0].text == "Meet at 10" && messages[0].previousText == "Meet at 8")
        #expect(messages[1].unsent && messages[1].text.isEmpty && messages[1].unsentText == "Secret plan")
        let page = try fixture.page(conversation)
        #expect(page.contains("<summary>Original</summary><p>Meet at 8</p>"))
        #expect(page.contains("Archived before it was unsent</summary><p>Secret plan</p>"))
    }
}

/// Attachment file names and links.
@Suite struct MessagesArchiveAttachmentTests {
    typealias Fixture = MessagesArchiveFixture

    private func oneChat(_ fixture: Fixture) throws {
        try fixture.addHandle(1, "+15551234567")
        try fixture.addChat(1, guid: "iMessage;-;+15551234567", identifier: "+15551234567", handles: [1])
        try fixture.add(.init(rowID: 1, chat: 1, text: "files", date: Fixture.time(0), handle: 1))
    }

    @Test func pagesSentAsAttachmentsGetNoLink() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try oneChat(fixture)
        try fixture.addAttachment(1, message: 1, filename: fixture.writeAttachment("a/invite.html", bytes: "<script>x</script>"),
                                  name: "invite.html", mime: "text/html")
        try fixture.addAttachment(2, message: 1, filename: fixture.writeAttachment("b/logo.svg", bytes: "<svg/>"), name: "logo.svg",
                                  mime: "image/svg+xml")
        try fixture.addAttachment(3, message: 1, filename: fixture.writeAttachment("c/notes.pdf"), name: "notes.pdf", mime: "application/pdf")
        let conversation = try #require(fixture.archiver().run().overview.conversations.first)
        let page = try fixture.page(conversation)
        let files = try fixture.transcript(conversation).messages[0].attachments.compactMap(\.file)
        #expect(files.count == 3)
        #expect(!page.contains("href=\"\(files[0])\""))
        #expect(!page.contains("href=\"\(files[1])\""))
        #expect(page.contains("<img src=\"\(files[1])\""))
        #expect(page.contains("href=\"\(files[2])\""))
    }

    @Test func newCopiesUse64BitNamesAndOldOnesStay() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try oneChat(fixture)
        try fixture.addAttachment(1, message: 1, filename: fixture.writeAttachment("a/photo.jpg"), name: "photo.jpg")
        try fixture.addAttachment(2, message: 1, filename: fixture.writeAttachment("b/other.jpg"), name: "other.jpg")
        let conversation = try #require(fixture.archiver().run().overview.conversations.first)
        let folder = fixture.archive.appendingPathComponent(conversation.relativePath)
        var files = try fixture.transcript(conversation).messages[0].attachments.compactMap(\.file)
        #expect(files.allSatisfy { ($0 as NSString).lastPathComponent.split(separator: "-")[0].count == 16 })

        // An archive from before: the second copy carries an 8-hex name.
        let hash = ArchiveFiles.hash("att-2")
        let legacy = "Attachments/\(hash.prefix(8))-other.jpg"
        try FileManager.default.moveItem(at: folder.appendingPathComponent(files[1]), to: folder.appendingPathComponent(legacy))
        try fixture.sql("UPDATE message SET date_edited = \(Fixture.time(5)) WHERE ROWID = 1")
        let report = try fixture.archiver().run()
        files = try fixture.transcript(conversation).messages[0].attachments.compactMap(\.file)
        #expect(files[1] == legacy)
        #expect(report.attachmentsCopied == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("Attachments").path).count == 2)
    }
}

@Suite struct ArchiveLocationTests {
    @Test func namesTheCloudAFolderIsReallyIn() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("location-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let drive = home.appendingPathComponent("Library/CloudStorage/GoogleDrive-someone@example.com/My Drive/Documents", isDirectory: true)
        let iCloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        let local = home.appendingPathComponent("Archive", isDirectory: true)
        for folder in [drive, iCloud, local] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        // ~/Documents as a symlink into Drive, as on the developer's Mac.
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("Documents"), withDestinationURL: drive)

        #expect(ArchiveLocation.syncService(for: home.appendingPathComponent("Documents/Messages Archive"), home: home) == "Google Drive")
        #expect(ArchiveLocation.syncService(for: iCloud.appendingPathComponent("Messages Archive"), home: home) == "iCloud Drive")
        #expect(ArchiveLocation.syncService(for: local, home: home) == nil)
        #expect(ArchiveLocation.syncService(for: home.appendingPathComponent("Messages Archive"), home: home) == nil)
        #expect(ArchiveLocation.providerName("Dropbox") == "Dropbox")
        #expect(ArchiveLocation.providerName("OneDrive-Personal") == "OneDrive")
    }
}

@Suite struct ArchiveDefaultsTests {
    @Test func theDefaultFolderIsOutsideDocumentsAndInsideASandbox() {
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        #expect(ArchiveLocation.defaultFolder(home: home, sandbox: nil).path == "/Users/someone/Messages Archive")
        let sandbox = URL(fileURLWithPath: "/tmp/sandbox", isDirectory: true)
        #expect(ArchiveLocation.defaultFolder(home: home, sandbox: sandbox).path == "/tmp/sandbox/Archive")
    }

    @Test func anArchiveAtThePreviousDefaultStaysThere() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("home-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let old = ArchiveLocation.previousDefaultFolder(home: home)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        #expect(ArchiveLocation.folderToKeep(setting: nil, home: home, sandbox: nil) == nil)
        try Data("{}".utf8).write(to: old.appendingPathComponent("archive.json"))
        #expect(ArchiveLocation.folderToKeep(setting: nil, home: home, sandbox: nil) == old)
        #expect(ArchiveLocation.folderToKeep(setting: "/elsewhere", home: home, sandbox: nil) == nil)
        #expect(ArchiveLocation.folderToKeep(setting: nil, home: home, sandbox: home) == nil)
    }

    @Test func archiveRunsAreDescribedInTheArchivesOwnWords() {
        #expect(ArchiveLocation.describe(.manual) == "Archive Now")
        #expect(ArchiveLocation.describe(.timer) == "daily archive")
        #expect(ArchiveLocation.describe(.launch) == "daily archive")
        #expect(ArchiveLocation.describe(.automation) == "Shortcut or link")
    }
}

@Suite struct ArchiveFileComparisonTests {
    @Test func aLargeUnchangedPageKeepsItsDateAndSameSizeChangesAreWritten() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("archive-compare-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let page = folder.appendingPathComponent("index.html")
        let original = Data(repeating: 0x41, count: 200_000)
        #expect(try ArchiveFiles.writeIfChanged(original, to: page))
        let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: page.path)
        #expect(try !ArchiveFiles.writeIfChanged(original, to: page))
        let unchangedDate = try #require(FileManager.default.attributesOfItem(atPath: page.path)[.modificationDate] as? Date)
        #expect(unchangedDate == oldDate)

        var changed = original
        changed[150_000] = 0x42
        #expect(try ArchiveFiles.writeIfChanged(changed, to: page))
        #expect(try Data(contentsOf: page) == changed)
        #expect(try ArchiveFiles.writeIfChanged(Data(), to: page))
        #expect(try Data(contentsOf: page).isEmpty)
        #expect(try !ArchiveFiles.writeIfChanged(Data(), to: page))
    }
}
