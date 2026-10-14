import PhotosBackupCore
import SwiftUI

/// The sidebar's Messages section: the readable archive of every
/// conversation kept on this Mac, and the Messages media upload beside it.
struct MessagesView: View {
    @Environment(AppModel.self) private var model
    @Binding var section: AppSection
    @State private var selection: ArchivedConversation.ID?
    @State private var search = ""

    var body: some View {
        let archive = model.archive
        Group {
            if !model.settings.messagesArchive {
                offState
            } else if archive.status == .needsFullDiskAccess {
                permissionState
            } else {
                archiveState(archive)
            }
        }
        .navigationTitle("Messages")
        .navigationSubtitle(subtitle(archive))
        .toolbar {
            if model.settings.messagesArchive {
                ToolbarItem {
                    Menu {
                        Button("Open Archive in Browser") { archive.openInBrowser() }
                        Button("Show Archive in Finder") { archive.revealInFinder() }
                        Divider()
                        Button("Change Folder\u{2026}") { archive.chooseFolder() }
                        Divider()
                        Button("Turn Off Messages Archive") { archive.turnOff() }
                    } label: {
                        Label("Archive Options", systemImage: "ellipsis")
                    }
                    .help("Archive options")
                }
            }
        }
        .task { await archive.loadOverviewIfNeeded() }
    }

    private func subtitle(_ archive: MessagesArchiveController) -> String {
        guard model.settings.messagesArchive else { return "" }
        if let last = archive.lastArchived { return "Archived \(last.formatted(.relative(presentation: .named)))" }
        return "Not archived yet"
    }

    // MARK: - Off

    private var offState: some View {
        ScrollView {
            VStack(spacing: 28) {
                ContentUnavailableView {
                    Label("Keep Every Conversation", systemImage: "archivebox")
                } description: {
                    Text("Messages Archive keeps a private, readable copy of your conversations on this Mac: texts, reactions, replies and attachments, in a folder you choose. Photos Backup never uploads it.")
                } actions: {
                    Button("Turn On Messages Archive") { model.archive.turnOn() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
                .frame(minHeight: 340)
                MessagesMediaPanel()
            }
            .padding(24)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Full Disk Access

    private var permissionState: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 14) {
                        Image(systemName: "lock.shield")
                            .symbolRenderingMode(.hierarchical)
                            .font(.system(size: 30))
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Allow Full Disk Access").font(.title2.bold())
                            Text("macOS keeps Messages private, so Photos Backup needs Full Disk Access to read your conversations. They are copied only to your archive folder.")
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        step(1, "Click Open Privacy & Security.")
                        step(2, "In Full Disk Access, turn on Photos Backup. If it is not in the list, click the add button and choose it from Applications.")
                        step(3, "Come back here and click Check Again.")
                    }
                    HStack {
                        Button("Open Privacy & Security") { model.openFullDiskAccess() }
                            .buttonStyle(.borderedProminent)
                        Button("Check Again") { model.archive.start(trigger: .manual) }
                    }
                    .controlSize(.large)
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
                .archivePanel()
                MessagesMediaPanel()
            }
            .padding(24)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(.tint))
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Archive

    private func archiveState(_ archive: MessagesArchiveController) -> some View {
        VStack(spacing: 14) {
            ArchiveHeader()
            ArchiveStats(overview: archive.overview)
            ArchiveNotes()
            if model.settings.archiveContactNames, archive.contactsAccess == .notDetermined, archive.overview != nil {
                contactsBanner
            }
            HStack(spacing: 0) {
                conversationList(archive.overview?.conversations ?? [])
                    .frame(minWidth: 200, idealWidth: 260, maxWidth: 280)
                Divider()
                Group {
                    if let selected = archive.overview?.conversations.first(where: { $0.id == selection }) {
                        ArchiveTranscriptPane(conversation: selected)
                    } else {
                        ContentUnavailableView("No Conversation Selected", systemImage: "bubble.left.and.bubble.right",
                                               description: Text("Choose a conversation to see its latest messages."))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // The panel takes what the window leaves; its list and transcript scroll.
            .frame(minHeight: 220, maxHeight: .infinity)
            .archivePanel()
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            MessagesMediaPanel()
        }
        .padding(20)
        .searchable(text: $search, placement: .toolbar, prompt: "Search Conversations")
        .onChange(of: archive.overview?.conversations.first?.id, initial: true) { _, first in
            if selection == nil { selection = first }
        }
    }

    private func conversationList(_ conversations: [ArchivedConversation]) -> some View {
        let query = search.trimmingCharacters(in: .whitespaces)
        let shown = query.isEmpty ? conversations : conversations.filter { conversation in
            conversation.title.localizedCaseInsensitiveContains(query)
                || conversation.participants.contains { $0.localizedCaseInsensitiveContains(query) }
        }
        return List(shown, selection: $selection) { conversation in
            ConversationRow(conversation: conversation).tag(conversation.id)
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .overlay {
            if conversations.isEmpty {
                ContentUnavailableView("No Conversations Yet", systemImage: "tray",
                                       description: Text(model.archive.isRunning ? "They appear here as they are archived." : "Click Archive Now to make the first copy."))
            } else if shown.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
    }

    private var contactsBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle")
                .symbolRenderingMode(.hierarchical)
                .font(.title2)
                .foregroundStyle(.tint)
            Text("Show names from Contacts instead of phone numbers and email addresses.")
                .lineLimit(2)
                .layoutPriority(1)
            Spacer(minLength: 8)
            Button("Allow Access to Contacts\u{2026}") { Task { await model.archive.requestContactsAccess() } }
                .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .archivePanel()
    }
}

/// Title, state and the one action: Archive Now, or Cancel while running.
private struct ArchiveHeader: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let archive = model.archive
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Image(systemName: "archivebox.fill")
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 22))
                    .foregroundStyle(.tint)
                    .frame(width: 44, height: 44)
                    .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .symbolEffect(.pulse, isActive: archive.isRunning && !reduceMotion)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Messages Archive").font(.title2.bold())
                    statusLine(archive.status)
                }
                Spacer(minLength: 12)
                if archive.isRunning {
                    Button("Cancel") { archive.cancel() }
                        .keyboardShortcut(.cancelAction)
                        .controlSize(.large)
                } else {
                    Button { archive.start(trigger: .manual) } label: {
                        Label("Archive Now", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                    .help("Archive new messages now (Shift-Command-A)")
                }
            }
            if case let .running(_, done, total) = archive.status {
                Group {
                    if total > 0 {
                        ProgressView(value: Double(done), total: Double(total))
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                }
                .controlSize(.small)
                .animation(reduceMotion ? nil : .easeOut, value: done)
            }
        }
    }

    @ViewBuilder private func statusLine(_ status: MessagesArchiveController.Status) -> some View {
        switch status {
        case let .running(phase, done, total):
            Text(total > 0 ? "\(phase)\u{2026} \(done.formatted()) of \(total.formatted())" : "\(phase)\u{2026}")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        case let .finished(date):
            Label("Up to date \u{B7} archived \(date.formatted(.relative(presentation: .named)))", systemImage: "checkmark.circle.fill")
                .labelStyle(StatusLabelStyle(color: .green))
        case let .failed(reason):
            Label(reason.prefix(1).uppercased() + reason.dropFirst(), systemImage: "exclamationmark.triangle.fill")
                .labelStyle(StatusLabelStyle(color: .orange))
        case .needsFullDiskAccess:
            Label("Needs Full Disk Access", systemImage: "exclamationmark.triangle.fill")
                .labelStyle(StatusLabelStyle(color: .orange))
        case .idle, .off:
            Text("Not archived yet").foregroundStyle(.secondary)
        }
    }
}

/// 2026-10-15: Where the archive is stored when that is more than this Mac, and what
/// the last run could not do. Calm, and only when there is something to say.
private struct ArchiveNotes: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let archive = model.archive
        let overview = archive.overview
        let notes = [
            archive.syncNote.map { ("icloud", $0, false) },
            overview?.snapshotProblem.map { ("exclamationmark.triangle", $0.prefix(1).uppercased() + $0.dropFirst() + ".", true) },
            (overview?.unreadableConversations ?? 0) > 0
                ? ("exclamationmark.triangle", "\(overview?.unreadableConversations ?? 0) archived conversations could not be read; they are kept as they were.", true)
                : nil,
        ].compactMap { $0 }
        if !notes.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(notes, id: \.1) { symbol, text, isProblem in
                    Label(text, systemImage: symbol)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(isProblem ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .lineLimit(2)
                }
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .archivePanel()
        }
    }
}

private struct StatusLabelStyle: LabelStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.foregroundStyle(color).imageScale(.small)
            configuration.title.foregroundStyle(.secondary)
        }
    }
}

private struct ArchiveStats: View {
    let overview: MessagesArchiveOverview?

    var body: some View {
        let overview = overview ?? MessagesArchiveOverview()
        HStack(spacing: 10) {
            tile("Conversations", value: Text(overview.conversations.count, format: .number), detail: nil)
            tile("Messages", value: Text(overview.messageCount, format: .number), detail: nil)
            tile("Attachments", value: Text(overview.attachmentCount, format: .number),
                 detail: overview.missingAttachmentCount > 0 ? "\(overview.missingAttachmentCount.formatted()) not on this Mac" : nil)
            tile("Archive Size", value: Text(overview.archiveBytes.byteString),
                 detail: overview.databaseSnapshots > 0 ? "\(overview.databaseSnapshots) database cop\(overview.databaseSnapshots == 1 ? "y" : "ies")" : nil)
        }
    }

    private func tile(_ title: String, value: Text, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            value
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(detail ?? " ").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .archivePanel()
        .accessibilityElement(children: .combine)
    }
}

private struct ConversationRow: View {
    let conversation: ArchivedConversation

    var body: some View {
        HStack(spacing: 10) {
            ConversationAvatar(conversation: conversation, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(conversation.title).fontWeight(.semibold).lineLimit(1)
                    Spacer(minLength: 4)
                    if let date = conversation.lastMessageDate {
                        Text(Self.shortDate(date)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("\(conversation.messageCount.formatted()) message\(conversation.messageCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    /// As Messages lists them: a time today, then Yesterday, a weekday this
    /// week, and a date before that.
    static func shortDate(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 7 { return date.formatted(.dateTime.weekday(.wide)) }
        return date.formatted(date: .numeric, time: .omitted)
    }
}

/// The Messages media upload to Google Photos, beside the archive.
private struct MessagesMediaPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let status = model.visibleMessagesStatus
        HStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .symbolRenderingMode(.hierarchical)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("Messages media in Google Photos").font(.headline)
                Text(detail(status))
                    .font(.callout)
                    .foregroundStyle(isProblem(status) ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(3)
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            if model.settings.messagesMedia {
                Button("Back Up Now") { model.backUpMessages() }
                    .disabled(model.isMessagesScanning || !model.hasAuthData)
            }
            Toggle("Back up Messages media", isOn: Binding(get: { model.settings.messagesMedia }, set: { model.setMessagesMedia($0) }))
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .archivePanel()
    }

    private func isProblem(_ status: MessagesStatus) -> Bool {
        if case .failed = status { true } else { false }
    }

    private func detail(_ status: MessagesStatus) -> String {
        switch status {
        case .off: "Off. Photos and videos from your conversations are not uploaded."
        case .idle: "Photos and videos from your conversations upload with your next backup."
        case .scanning: "Looking for new photos and videos\u{2026}"
        case let .ready(found, skipped, partial):
            (found == 0 ? "Everything found is backed up" : "\(found.formatted()) to upload")
                + (partial ? ", more to look through" : "") + (skipped > 0 ? "; \(skipped.formatted()) not on this Mac." : ".")
        case let .failed(reason): reason.prefix(1).uppercased() + reason.dropFirst()
        }
    }
}

extension View {
    /// The quiet grouped panel the Messages section is built from.
    func archivePanel() -> some View {
        background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5))
    }
}
