import Foundation

/// Writes the Messages archive: per conversation a Messages-like page,
/// `messages.json` and its attachments; a root index; dated chat.db copies;
/// and `archive.json`, which makes the next run touch only what changed.
///
/// Messages deleted from chat.db stay in the archive: a conversation that
/// changed is re-read whole and merged into what was archived before.
public struct MessagesArchiver: Sendable {
    public struct Configuration: Sendable {
        public var folder: URL
        public var database: URL
        public var homeDirectory: URL
        public var temporaryDirectory: URL
        public var archiveAttachments: Bool
        public var snapshotsToKeep: Int
        public var names: HandleNames
        public var timeZone: TimeZone
        public var locale: Locale
        public var now: Date

        public init(folder: URL, database: URL, homeDirectory: URL, temporaryDirectory: URL = FileManager.default.temporaryDirectory,
                    archiveAttachments: Bool = true, snapshotsToKeep: Int = 7, names: HandleNames = HandleNames(),
                    timeZone: TimeZone = .current, locale: Locale = .current, now: Date = Date()) {
            self.folder = folder
            self.database = database
            self.homeDirectory = homeDirectory
            self.temporaryDirectory = temporaryDirectory
            self.archiveAttachments = archiveAttachments
            self.snapshotsToKeep = max(0, snapshotsToKeep)
            self.names = names
            self.timeZone = timeZone
            self.locale = locale
            self.now = now
        }

        public static func standard(folder: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Configuration {
            Configuration(folder: folder, database: home.appendingPathComponent("Library/Messages/chat.db"), homeDirectory: home)
        }
    }

    public enum Phase: String, Sendable {
        case copying = "Copying the Messages database"
        case reading = "Reading conversations"
        case finishing = "Writing the archive index"
        case snapshot = "Saving a copy of the database"
    }

    public struct Report: Equatable, Sendable {
        public var overview: MessagesArchiveOverview
        /// Messages added to the archive by this run.
        public var newMessages: Int
        public var conversationsWritten: Int
        public var attachmentsCopied: Int
        public var bytesCopied: Int64
        public var decodeFailures: Int
        /// chat.db went backwards, so every conversation was rewritten.
        public var rebuilt: Bool
    }

    public static let conversationsFolder = "Conversations"
    public static let databaseFolder = "Database"
    static let attachmentsFolder = "Attachments"

    private let configuration: Configuration

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    /// Throws MessagesArchiveError, or CancellationError when the task was
    /// cancelled (the conversations finished so far stay recorded).
    public func run(progress: @Sendable (Phase, Int, Int) -> Void = { _, _, _ in }) throws -> Report {
        let folder = configuration.folder
        do {
            try ArchiveFiles.makeDirectory(folder)
            try ArchiveFiles.makeDirectory(folder.appendingPathComponent(Self.conversationsFolder, isDirectory: true))
        } catch {
            throw MessagesArchiveError.folderUnavailable(error.localizedDescription)
        }
        var manifest = ArchiveManifest.load(from: folder) ?? ArchiveManifest()

        progress(.copying, 0, 0)
        let snapshot = try MessagesSnapshot(of: configuration.database, in: configuration.temporaryDirectory)
        defer { snapshot.remove() }
        let database = try MessagesDatabase(snapshot: snapshot)
        let chats = try database.chats()
        let handles = try database.handles()
        let participants = try database.participants()
        let stats = try database.stats()
        let maxRowID = try database.maxMessageRowID()
        let rebuilt = maxRowID < manifest.maxRowID
        let builder = TranscriptBuilder(handles: handles, names: configuration.names)
        let html = ArchiveHTML(timeZone: configuration.timeZone, locale: configuration.locale)

        var report = Report(overview: MessagesArchiveOverview(), newMessages: 0, conversationsWritten: 0, attachmentsCopied: 0,
                            bytesCopied: 0, decodeFailures: 0, rebuilt: rebuilt)
        let active = chats.filter { stats[$0.rowID] != nil }
        do {
            for (index, chat) in active.enumerated() {
                try Task.checkCancellation()
                progress(.reading, index, active.count)
                guard let chatStats = stats[chat.rowID] else { continue }
                let members = (participants[chat.rowID] ?? []).compactMap { handles[$0] }
                let signature = ArchiveFiles.hash([
                    "v\(ConversationTranscript.formatVersion)", "\(chatStats.maxRowID)", "\(chatStats.count)", "\(chatStats.lastEdit)",
                    "attachments=\(configuration.archiveAttachments)", chat.displayName ?? "", chat.service ?? "",
                    configuration.names.fingerprint(for: members),
                ].joined(separator: "|"))
                let previous = manifest.chats[chat.guid]
                if !rebuilt, let previous, previous.signature == signature { continue }
                let written = try archive(chat, members: members, stats: chatStats, signature: signature, previous: previous,
                                          database: database, builder: builder, html: html, report: &report)
                manifest.chats[chat.guid] = written
            }
        } catch let error as CancellationError {
            try? manifest.save(to: folder)
            throw error
        }
        progress(.reading, active.count, active.count)

        progress(.finishing, 0, 0)
        let conversations = manifest.chats.values.map(\.conversation).sorted(by: Self.mostRecentFirst)
        let messages = conversations.reduce(0) { $0 + $1.messageCount }
        let attachments = conversations.reduce(0) { $0 + $1.attachmentCount }
        do {
            try ArchiveFiles.writeIfChanged(Data(ArchiveHTML.stylesheet.utf8), to: folder.appendingPathComponent("style.css"))
            try ArchiveFiles.writeIfChanged(Data(html.indexPage(conversations: conversations, messages: messages, attachments: attachments).utf8),
                                            to: folder.appendingPathComponent("index.html"))
        } catch {
            throw MessagesArchiveError.folderUnavailable(error.localizedDescription)
        }

        progress(.snapshot, 0, 0)
        manifest.snapshots = try keepSnapshots(database: database)
        manifest.maxRowID = maxRowID
        manifest.lastArchived = configuration.now
        do { try manifest.save(to: folder) }
        catch { throw MessagesArchiveError.folderUnavailable(error.localizedDescription) }

        report.overview = MessagesArchiveOverview(
            conversations: conversations, messageCount: messages, attachmentCount: attachments,
            missingAttachmentCount: manifest.chats.values.reduce(0) { $0 + $1.missingAttachments },
            archiveBytes: ArchiveFiles.totalSize(of: folder), lastArchived: configuration.now, databaseSnapshots: manifest.snapshots.count)
        return report
    }

    static func mostRecentFirst(_ a: ArchivedConversation, _ b: ArchivedConversation) -> Bool {
        switch (a.lastMessageDate, b.lastMessageDate) {
        case let (x?, y?) where x != y: x > y
        case (.some, nil): true
        case (nil, .some): false
        default: a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }

    // MARK: - One conversation

    private func archive(_ chat: ChatRow, members: [String], stats: ChatStats, signature: String, previous: ArchiveManifest.Entry?,
                         database: MessagesDatabase, builder: TranscriptBuilder, html: ArchiveHTML,
                         report: inout Report) throws -> ArchiveManifest.Entry {
        let slug = previous.map { ($0.conversation.relativePath as NSString).lastPathComponent } ?? ArchiveFiles.slug(forChatGUID: chat.guid)
        let relativePath = "\(Self.conversationsFolder)/\(slug)"
        let folder = configuration.folder.appendingPathComponent(relativePath, isDirectory: true)
        let jsonURL = folder.appendingPathComponent("messages.json")
        do { try ArchiveFiles.makeDirectory(folder) }
        catch { throw MessagesArchiveError.folderUnavailable(error.localizedDescription) }

        let rows = try database.messages(chat: chat.rowID)
        let attachmentRows = try database.attachments(chat: chat.rowID)
        var copied = 0
        var bytes: Int64 = 0
        let built = builder.build(rows: rows) { row in
            (attachmentRows[row.rowID] ?? []).map { attachmentRow in
                let (attachment, copiedBytes) = resolve(attachmentRow, into: folder)
                if let copiedBytes { copied += 1; bytes += copiedBytes }
                return attachment
            }
        }
        let earlier = (try? Data(contentsOf: jsonURL)).flatMap { try? ConversationTranscript.decode($0) }?.messages ?? []
        let messages = Self.merge(earlier: earlier, fresh: built.messages, orphanReactions: built.orphanReactions)

        let names = configuration.names
        let people = members.map { names.display($0) }
        let title = Self.title(chat: chat, people: people)
        let counted = messages.filter { !$0.isEvent }
        let allAttachments = messages.flatMap(\.attachments)
        let conversation = ArchivedConversation(
            id: chat.guid, title: title, participants: people, isGroup: chat.isGroup, service: chat.service ?? "iMessage",
            messageCount: counted.count, attachmentCount: allAttachments.count,
            lastMessageDate: messages.compactMap(\.date).max(), relativePath: relativePath)
        let transcript = ConversationTranscript(conversation: conversation, messages: messages)
        do {
            try ArchiveFiles.writeIfChanged(ArchiveJSON.encoder.encode(transcript), to: jsonURL)
            try ArchiveFiles.writeIfChanged(Data(html.conversationPage(transcript).utf8), to: folder.appendingPathComponent("index.html"))
        } catch {
            throw MessagesArchiveError.folderUnavailable(error.localizedDescription)
        }
        report.conversationsWritten += 1
        report.newMessages += max(0, counted.count - (previous?.conversation.messageCount ?? 0))
        report.attachmentsCopied += copied
        report.bytesCopied += bytes
        report.decodeFailures += built.decodeFailures
        return ArchiveManifest.Entry(conversation: conversation, lastRowID: stats.maxRowID, signature: signature,
                                     missingAttachments: allAttachments.filter { $0.status == .missing || $0.status == .refused }.count,
                                     decodeFailures: built.decodeFailures)
    }

    static func merge(earlier: [ArchivedMessage], fresh: [ArchivedMessage], orphanReactions: [String: [ArchivedReaction]]) -> [ArchivedMessage] {
        let freshIDs = Set(fresh.map(\.id))
        let kept = earlier.filter { !freshIDs.contains($0.id) }.map { message in
            var message = message
            if let reactions = orphanReactions[message.id] { message.reactions = reactions }
            return message
        }
        guard !kept.isEmpty else { return fresh }
        return (fresh + kept).sorted { a, b in
            let (x, y) = (a.date ?? .distantPast, b.date ?? .distantPast)
            return x != y ? x < y : a.rowID < b.rowID
        }
    }

    static func title(chat: ChatRow, people: [String]) -> String {
        if let name = chat.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        switch people.count {
        case 0: return chat.identifier
        case 1: return people[0]
        case 2, 3: return people.dropLast().joined(separator: ", ") + " & " + people[people.count - 1]
        default: return people.prefix(2).joined(separator: ", ") + " & \(people.count - 2) others"
        }
    }

    // MARK: - Attachments

    /// The archived attachment, and the bytes copied if this run copied it.
    private func resolve(_ row: AttachmentRow, into folder: URL) -> (ArchivedAttachment, Int64?) {
        let name = row.transferName.flatMap { $0.isEmpty ? nil : $0 }
            ?? row.filename.map { ($0 as NSString).lastPathComponent } ?? "Attachment"
        var attachment = ArchivedAttachment(id: row.guid, name: name, mimeType: row.mimeType, uti: row.uti, bytes: row.totalBytes,
                                            isSticker: row.isSticker, file: nil, status: .skipped)
        guard configuration.archiveAttachments else { return (attachment, nil) }
        let fileName = "\(ArchiveFiles.hash(row.guid).prefix(8))-\(ArchiveFiles.safeFileName(name))"
        let relative = "\(Self.attachmentsFolder)/\(fileName)"
        let destination = folder.appendingPathComponent(relative)
        let archivedSize = ArchiveFiles.size(of: destination)

        attachment.status = .missing
        guard let path = row.filename, !path.isEmpty else { return (Self.keep(attachment, relative, archivedSize), nil) }
        let messagesRoot = configuration.homeDirectory.appendingPathComponent("Library/Messages", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        let source = (path.hasPrefix("~/") ? configuration.homeDirectory.appendingPathComponent(String(path.dropFirst(2)))
            : URL(fileURLWithPath: path)).resolvingSymlinksInPath().standardizedFileURL
        guard ArchiveFiles.isChild(source, of: messagesRoot) else {
            attachment.status = .refused
            return (attachment, nil)
        }
        guard let sourceSize = ArchiveFiles.size(of: source), sourceSize > 0 else { return (Self.keep(attachment, relative, archivedSize), nil) }
        attachment.bytes = sourceSize
        attachment.file = relative
        attachment.status = .archived
        if archivedSize == sourceSize { return (attachment, nil) }
        do {
            try ArchiveFiles.makeDirectory(destination.deletingLastPathComponent())
            if archivedSize != nil { try FileManager.default.removeItem(at: destination) }
            // copyItem clones on APFS: no extra space until either side changes.
            try FileManager.default.copyItem(at: source, to: destination)
            try ArchiveFiles.setPrivate(destination)
            return (attachment, sourceSize)
        } catch {
            attachment.file = nil
            attachment.status = .missing
            return (attachment, nil)
        }
    }

    /// An attachment copied by an earlier run stays archived after Messages
    /// lets go of it (Optimize Storage, a deleted conversation).
    private static func keep(_ attachment: ArchivedAttachment, _ relative: String, _ archivedSize: Int64?) -> ArchivedAttachment {
        guard let archivedSize, archivedSize > 0 else { return attachment }
        var attachment = attachment
        attachment.file = relative
        attachment.bytes = archivedSize
        attachment.status = .archived
        return attachment
    }

    // MARK: - Database copies

    /// Today's copy if there is none yet, then the oldest pruned down to the
    /// setting. Returns what is kept, oldest first.
    private func keepSnapshots(database: MessagesDatabase) throws -> [String] {
        let folder = configuration.folder.appendingPathComponent(Self.databaseFolder, isDirectory: true)
        let files = FileManager.default
        if configuration.snapshotsToKeep > 0 {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = configuration.timeZone
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            let today = folder.appendingPathComponent("chat-\(formatter.string(from: configuration.now)).db")
            if !files.fileExists(atPath: today.path) {
                do {
                    try ArchiveFiles.makeDirectory(folder)
                    let partial = folder.appendingPathComponent(".\(today.lastPathComponent).partial")
                    try? files.removeItem(at: partial)
                    try database.backup(to: partial)
                    try ArchiveFiles.setPrivate(partial)
                    try files.moveItem(at: partial, to: today)
                } catch {
                    throw MessagesArchiveError.folderUnavailable(error.localizedDescription)
                }
            }
        }
        let existing = ((try? files.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasPrefix("chat-") && $0.hasSuffix(".db") }.sorted()
        let surplus = max(0, existing.count - configuration.snapshotsToKeep)
        for name in existing.prefix(surplus) { try? files.removeItem(at: folder.appendingPathComponent(name)) }
        return Array(existing.dropFirst(surplus))
    }
}
