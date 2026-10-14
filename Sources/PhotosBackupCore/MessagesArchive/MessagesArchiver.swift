import Foundation

/// Writes the Messages archive: per conversation a Messages-like page,
/// `messages.json` and its attachments; a root index; dated chat.db copies;
/// and `archive.json`, which makes the next run touch only what changed.
///
/// Messages deleted from chat.db stay in the archive: a conversation that
/// changed is re-read whole and merged into what was archived before. A
/// messages.json that is there but cannot be read is never written over.
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
        /// Conversations left as they were because their messages.json could
        /// not be read; the next run tries them again.
        public var unreadableConversations: Int = 0
        /// Today's dated copy of chat.db failed; the rest of the run did not.
        public var snapshotProblem: String?
        /// archive.json was missing or damaged and was rebuilt from the
        /// conversation folders.
        public var manifestRebuilt = false
    }

    public static let conversationsFolder = "Conversations"
    public static let databaseFolder = "Database"
    /// The default folder's name, and the subfolder used when someone picks
    /// a folder that already holds other files.
    public static let defaultFolderName = "Messages Archive"
    static let attachmentsFolder = "Attachments"
    static let ownEntries = [ArchiveManifest.fileName, "index.html", "style.css", conversationsFolder, databaseFolder]

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
            throw MessagesArchiveError.folderUnavailable(error)
        }
        let lock = try ArchiveRunLock(folder: folder, in: configuration.temporaryDirectory)
        defer { lock.release() }
        // Holding the lock, anything half-written is from a run that died.
        ArchiveFiles.removePartials(in: folder)
        ArchiveFiles.removePartials(in: folder.appendingPathComponent(Self.databaseFolder, isDirectory: true))
        MessagesSnapshot.sweep(in: configuration.temporaryDirectory)

        var report = Report(overview: MessagesArchiveOverview(), newMessages: 0, conversationsWritten: 0, attachmentsCopied: 0,
                            bytesCopied: 0, decodeFailures: 0, rebuilt: false)
        var manifest: ArchiveManifest
        switch ArchiveManifest.load(from: folder) {
        case let .loaded(loaded):
            manifest = loaded
        case .absent:
            manifest = ArchiveManifest.rebuilt(from: folder)
            report.manifestRebuilt = !manifest.chats.isEmpty
        case .unreadable:
            // Kept for inspection; the folders say what the archive holds.
            let url = folder.appendingPathComponent(ArchiveManifest.fileName)
            try? FileManager.default.removeItem(at: url.appendingPathExtension("unreadable"))
            try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("unreadable"))
            manifest = ArchiveManifest.rebuilt(from: folder)
            report.manifestRebuilt = true
        }

        try Task.checkCancellation()
        progress(.copying, 0, 0)
        let snapshot = try MessagesSnapshot(of: configuration.database, in: configuration.temporaryDirectory)
        defer { snapshot.remove() }
        let database = try MessagesDatabase(snapshot: snapshot)
        let chats = try database.chats()
        let handles = try database.handles()
        let participants = try database.participants()
        let stats = try database.stats()
        let maxRowID = try database.maxMessageRowID()
        report.rebuilt = maxRowID < manifest.maxRowID
        let builder = TranscriptBuilder(handles: handles, names: configuration.names)
        let html = ArchiveHTML(timeZone: configuration.timeZone, locale: configuration.locale)

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
                if !report.rebuilt, let previous, previous.signature == signature { continue }
                if let written = try archive(chat, members: members, stats: chatStats, signature: signature, previous: previous,
                                             database: database, builder: builder, html: html, report: &report) {
                    manifest.chats[chat.guid] = written
                }
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
        manifest.maxRowID = maxRowID
        manifest.lastArchived = configuration.now
        do {
            try ArchiveFiles.writeIfChanged(Data(ArchiveHTML.stylesheet.utf8), to: folder.appendingPathComponent("style.css"))
            try ArchiveFiles.writeIfChanged(Data(html.indexPage(conversations: conversations, messages: messages, attachments: attachments).utf8),
                                            to: folder.appendingPathComponent("index.html"))
            // Saved before the dated copy, which can fail on a full disk
            // without undoing the conversations this run wrote.
            try manifest.save(to: folder)
        } catch {
            throw MessagesArchiveError.folderUnavailable(error)
        }

        try Task.checkCancellation()
        progress(.snapshot, 0, 0)
        do {
            manifest.snapshots = try keepSnapshots(database: database)
        } catch let error as CancellationError {
            throw error
        } catch {
            report.snapshotProblem = "could not save today's copy of the Messages database (error \(MessagesArchiveError.errorCode(error)))"
            manifest.snapshots = Self.snapshotNames(in: folder)
        }
        try? manifest.save(to: folder)

        report.overview = MessagesArchiveOverview(
            conversations: conversations, messageCount: messages, attachmentCount: attachments,
            missingAttachmentCount: manifest.chats.values.reduce(0) { $0 + $1.missingAttachments },
            archiveBytes: Self.archiveSize(of: folder), lastArchived: configuration.now, databaseSnapshots: manifest.snapshots.count,
            snapshotProblem: report.snapshotProblem, unreadableConversations: report.unreadableConversations)
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

    // MARK: - Where the archive goes

    /// 2026-10-15: A chosen folder or its conventional child can already
    /// hold an unrelated index.html. Use an empty folder or recognizable
    /// archive, otherwise choose the next unused numbered child.
    public static func archiveFolder(forChosen chosen: URL) -> URL {
        if isArchiveFolder(chosen) { return chosen }
        if let names = try? FileManager.default.contentsOfDirectory(atPath: chosen.path), names.isEmpty { return chosen }
        var number = 1
        while true {
            let name = number == 1 ? defaultFolderName : "\(defaultFolderName) \(number)"
            let candidate = chosen.appendingPathComponent(name, isDirectory: true)
            if !FileManager.default.fileExists(atPath: candidate.path) || isArchiveFolder(candidate) { return candidate }
            number += 1
        }
    }

    private static func isArchiveFolder(_ folder: URL) -> Bool {
        let conversations = folder.appendingPathComponent(conversationsFolder, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: conversations.path, isDirectory: &isDirectory), isDirectory.boolValue else { return false }
        switch ArchiveManifest.load(from: folder) {
        case .loaded: return true
        case .absent, .unreadable:
            let slugs = (try? FileManager.default.contentsOfDirectory(atPath: conversations.path)) ?? []
            return slugs.contains { slug in
                FileManager.default.fileExists(atPath: conversations.appendingPathComponent(slug).appendingPathComponent("messages.json").path)
            }
        }
    }

    /// Only what the archive itself wrote, whatever else shares the folder.
    public static func archiveSize(of folder: URL) -> Int64 {
        ownEntries.reduce(0) { total, name in
            let url = folder.appendingPathComponent(name)
            return total + (ArchiveFiles.size(of: url) ?? ArchiveFiles.totalSize(of: url))
        }
    }

    // MARK: - One conversation

    /// The conversation's manifest entry, or nil when its messages.json is
    /// there but unreadable: then nothing of it is touched.
    private func archive(_ chat: ChatRow, members: [String], stats: ChatStats, signature: String, previous: ArchiveManifest.Entry?,
                         database: MessagesDatabase, builder: TranscriptBuilder, html: ArchiveHTML,
                         report: inout Report) throws -> ArchiveManifest.Entry? {
        let slug = previous.map { ($0.conversation.relativePath as NSString).lastPathComponent } ?? ArchiveFiles.slug(forChatGUID: chat.guid)
        let relativePath = "\(Self.conversationsFolder)/\(slug)"
        let folder = configuration.folder.appendingPathComponent(relativePath, isDirectory: true)
        let jsonURL = folder.appendingPathComponent("messages.json")
        let earlier: [ArchivedMessage]
        switch TranscriptFile.load(jsonURL) {
        case .absent: earlier = []
        case let .loaded(transcript): earlier = transcript.messages
        case .unreadable:
            report.unreadableConversations += 1
            return nil
        }
        do {
            try ArchiveFiles.makeDirectory(folder)
            ArchiveFiles.removePartials(in: folder)
        } catch {
            throw MessagesArchiveError.folderUnavailable(error)
        }

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
            throw MessagesArchiveError.folderUnavailable(error)
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

    /// Fresh rows win, with what the archive saw before kept beside them: the
    /// first archived text of a message edited since, and the text of one
    /// unsent since. Messages no longer in chat.db stay as archived.
    static func merge(earlier: [ArchivedMessage], fresh: [ArchivedMessage], orphanReactions: [String: [ArchivedReaction]]) -> [ArchivedMessage] {
        let earlierByID = Dictionary(earlier.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let updated = fresh.map { message -> ArchivedMessage in
            guard let old = earlierByID[message.id] else { return message }
            var message = message
            message.previousText = old.previousText
            message.unsentText = old.unsentText
            if message.unsent {
                if message.unsentText == nil, !old.text.isEmpty { message.unsentText = old.text }
            } else if message.edited, message.previousText == nil, !old.text.isEmpty, old.text != message.text {
                message.previousText = old.text
            }
            return message
        }
        let freshIDs = Set(fresh.map(\.id))
        let kept = earlier.filter { !freshIDs.contains($0.id) }.map { message in
            var message = message
            if let reactions = orphanReactions[message.id] { message.reactions = reactions }
            return message
        }
        guard !kept.isEmpty else { return updated }
        return (updated + kept).sorted { a, b in
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

    /// 64 bits of the guid's hash keep two same-named attachments in one
    /// conversation apart. Archives from before used 32 bits; their files
    /// keep their names.
    static let attachmentPrefixLength = 16
    static let legacyAttachmentPrefixLength = 8

    /// The archived attachment, and the bytes copied if this run copied it.
    private func resolve(_ row: AttachmentRow, into folder: URL) -> (ArchivedAttachment, Int64?) {
        let name = row.transferName.flatMap { $0.isEmpty ? nil : $0 }
            ?? row.filename.map { ($0 as NSString).lastPathComponent } ?? "Attachment"
        var attachment = ArchivedAttachment(id: row.guid, name: name, mimeType: row.mimeType, uti: row.uti, bytes: row.totalBytes,
                                            isSticker: row.isSticker, file: nil, status: .skipped)
        guard configuration.archiveAttachments else { return (attachment, nil) }
        let hash = ArchiveFiles.hash(row.guid)
        let safeName = ArchiveFiles.safeFileName(name)
        let legacy = "\(Self.attachmentsFolder)/\(hash.prefix(Self.legacyAttachmentPrefixLength))-\(safeName)"
        let current = "\(Self.attachmentsFolder)/\(hash.prefix(Self.attachmentPrefixLength))-\(safeName)"
        let legacySize = ArchiveFiles.size(of: folder.appendingPathComponent(legacy))
        let relative = legacySize != nil && ArchiveFiles.size(of: folder.appendingPathComponent(current)) == nil ? legacy : current
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

    static func snapshotNames(in folder: URL) -> [String] {
        let database = folder.appendingPathComponent(databaseFolder, isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(atPath: database.path)) ?? [])
            .filter { $0.hasPrefix("chat-") && $0.hasSuffix(".db") }.sorted()
    }

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
                try ArchiveFiles.makeDirectory(folder)
                // A name of its own: a partial file is never another run's.
                let partial = folder.appendingPathComponent(".\(today.lastPathComponent).\(UUID().uuidString)\(ArchiveFiles.partialSuffix)")
                do {
                    guard files.createFile(atPath: partial.path, contents: nil, attributes: [.posixPermissions: ArchiveFiles.fileMode]) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                    try database.backup(to: partial, isCancelled: { Task.isCancelled })
                    try ArchiveFiles.setPrivate(partial)
                    try files.moveItem(at: partial, to: today)
                } catch {
                    try? files.removeItem(at: partial)
                    throw error
                }
            }
        }
        let existing = Self.snapshotNames(in: configuration.folder)
        let surplus = max(0, existing.count - configuration.snapshotsToKeep)
        for name in existing.prefix(surplus) { try? files.removeItem(at: folder.appendingPathComponent(name)) }
        return Array(existing.dropFirst(surplus))
    }
}
