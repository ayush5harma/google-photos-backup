import Foundation
import Testing
@testable import PhotosBackupCore

@Suite(.serialized) struct MessagesMediaScannerTests {
    @Test func scansOnlyLocalMediaInsideAttachmentsAndUsesContentIds() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/sqlite3") else { return }
        let fixture = try Fixture()
        defer { fixture.remove() }
        let media = fixture.attachments.appendingPathComponent("nested/photo one.JPG")
        try FileManager.default.createDirectory(at: media.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("pixels".utf8).write(to: media)
        let document = fixture.attachments.appendingPathComponent("document.pdf")
        try Data("not media".utf8).write(to: document)
        let outside = fixture.root.appendingPathComponent("outside.jpg")
        try Data("outside".utf8).write(to: outside)
        let link = fixture.attachments.appendingPathComponent("escape.jpg")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        try fixture.sql("CREATE TABLE attachment (guid TEXT, filename TEXT, created_date INTEGER);")
        try fixture.sql("INSERT INTO attachment VALUES ('a', '~/Library/Messages/Attachments/nested/photo one.JPG', 0);")
        try fixture.sql("INSERT INTO attachment VALUES ('b', '\(document.path)', 0);")
        try fixture.sql("INSERT INTO attachment VALUES ('c', '\(link.path)', 0);")
        try fixture.sql("INSERT INTO attachment VALUES ('d', '~/Library/Messages/Attachments/nested/photo one.JPG', 0);")

        let report = try MessagesMediaScanner(configuration: .init(attachmentsRoot: fixture.attachments, database: fixture.database,
                                                                    homeDirectory: fixture.home, temporaryDirectory: fixture.root)).scan()
        #expect(report.items.count == 1)
        #expect(report.items[0].id.hasPrefix("messages:"))
        #expect(report.items[0].filename.hasPrefix("Messages-"))
        #expect(report.items[0].filename.hasSuffix(".jpg"))
        #expect(report.skipped == 2)
    }

    @Test func reportsUnavailableAttachmentsWithoutTouchingARealMessagesLibrary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let scanner = MessagesMediaScanner(configuration: .init(attachmentsRoot: root.appendingPathComponent("Attachments"),
                                                                 database: root.appendingPathComponent("chat.db"), temporaryDirectory: root))
        #expect(throws: MessagesMediaScanner.ScanError.attachmentsUnavailable) { try scanner.scan() }
    }

    @Test func completedPassRechecksAttachmentThatBecomesLocalLater() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/sqlite3") else { return }
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.sql("CREATE TABLE attachment (guid TEXT, filename TEXT, created_date INTEGER);")
        try fixture.sql("INSERT INTO attachment VALUES ('late', '~/Library/Messages/Attachments/late.jpg', 0);")
        let configuration = MessagesMediaScanner.Configuration(attachmentsRoot: fixture.attachments, database: fixture.database,
                                                                homeDirectory: fixture.home, temporaryDirectory: fixture.root)
        let first = try MessagesMediaScanner(configuration: configuration).scan()
        #expect(first.items.isEmpty)
        #expect(first.skipped == 1)
        #expect(first.nextCursor == nil)
        try Data("downloaded later".utf8).write(to: fixture.attachments.appendingPathComponent("late.jpg"))
        let second = try MessagesMediaScanner(configuration: configuration).scan()
        #expect(second.items.count == 1)
    }

    @Test func boundedPassesAdvanceToTheTailBeforeWrapping() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/sqlite3") else { return }
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.sql("CREATE TABLE attachment (guid TEXT, filename TEXT, created_date INTEGER);")
        for name in ["first.jpg", "second.jpg"] {
            let file = fixture.attachments.appendingPathComponent(name)
            try Data(name.utf8).write(to: file)
            try fixture.sql("INSERT INTO attachment VALUES ('\(name)', '~/Library/Messages/Attachments/\(name)', 0);")
        }
        let first = try MessagesMediaScanner(configuration: .init(attachmentsRoot: fixture.attachments, database: fixture.database,
                                                                   homeDirectory: fixture.home, temporaryDirectory: fixture.root, maximumRows: 1)).scan()
        #expect(first.items.count == 1)
        #expect(first.nextCursor != nil)
        let second = try MessagesMediaScanner(configuration: .init(attachmentsRoot: fixture.attachments, database: fixture.database,
                                                                    homeDirectory: fixture.home, temporaryDirectory: fixture.root, cursor: first.nextCursor!, maximumRows: 1)).scan()
        #expect(second.items.count == 1)
        #expect(second.items[0].id != first.items[0].id)
        #expect(second.nextCursor == nil)
    }
}

private final class Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let home: URL
    let attachments: URL
    let database: URL

    init() throws {
        home = root
        attachments = home.appendingPathComponent("Library/Messages/Attachments", isDirectory: true)
        database = home.appendingPathComponent("Library/Messages/chat.db")
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
    }

    func sql(_ query: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [database.path, query]
        try process.run(); process.waitUntilExit()
        if process.terminationStatus != 0 { throw CocoaError(.fileWriteUnknown) }
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

