import AppKit
import ImageIO
import PhotosBackupCore
import SwiftUI

/// The selected conversation, drawn the way Messages draws it, from the end
/// of its messages.json. The full transcript is the page in the browser.
struct ArchiveTranscriptPane: View {
    @Environment(AppModel.self) private var model
    let conversation: ArchivedConversation
    @State private var messages: [ArchivedMessage]?

    var body: some View {
        let archive = model.archive
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ConversationAvatar(conversation: conversation, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(conversation.title).font(.headline).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Button { archive.openInBrowser(conversation) } label: { Label("Open in Browser", systemImage: "safari") }
                    .help("Open the whole conversation in your browser")
                Button { archive.revealInFinder(conversation) } label: { Label("Show in Finder", systemImage: "folder") }
                    .help("Show the conversation's folder in Finder")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .imageScale(.large)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: conversation.id) {
            messages = nil
            messages = await archive.recentMessages(in: conversation)
        }
    }

    private var subtitle: String {
        let count = "\(conversation.messageCount.formatted()) message\(conversation.messageCount == 1 ? "" : "s")"
        return conversation.isGroup ? "\(conversation.participants.joined(separator: ", ")) \u{B7} \(count)" : "\(conversation.service) \u{B7} \(count)"
    }

    @ViewBuilder private var content: some View {
        if let messages {
            if messages.isEmpty {
                ContentUnavailableView("Nothing to Preview", systemImage: "text.bubble",
                                       description: Text("Open the conversation in your browser to read it."))
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if conversation.messageCount > messages.count {
                            Text("The last \(messages.count) messages. Open in Browser to read them all.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.bottom, 8)
                        }
                        ForEach(Self.items(messages)) { item in
                            switch item.kind {
                            case let .day(date):
                                Text(date, format: .dateTime.weekday(.wide).day().month(.wide).year())
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 16)
                                    .padding(.bottom, 6)
                            case let .message(message, grouped):
                                BubbleRow(message: message, conversation: conversation, grouped: grouped,
                                          quote: message.replyTo.flatMap { id in messages.first { $0.id == id } })
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .defaultScrollAnchor(.bottom)
            }
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    struct Item: Identifiable {
        enum Kind {
            case day(Date)
            /// grouped: follows a bubble from the same sender within minutes.
            case message(ArchivedMessage, grouped: Bool)
        }
        let id: String
        let kind: Kind
    }

    static func items(_ messages: [ArchivedMessage]) -> [Item] {
        var items: [Item] = []
        var previous: ArchivedMessage?
        let calendar = Calendar.current
        for message in messages {
            if let date = message.date, previous?.date.map({ calendar.isDate($0, inSameDayAs: date) }) != true {
                items.append(Item(id: "day-\(message.id)", kind: .day(date)))
                previous = nil
            }
            let grouped = previous.map { previous in
                !previous.isEvent && !previous.unsent && previous.isFromMe == message.isFromMe && previous.sender == message.sender
                    && (message.date ?? .distantPast).timeIntervalSince(previous.date ?? .distantPast) < 5 * 60
            } ?? false
            items.append(Item(id: message.id, kind: .message(message, grouped: grouped)))
            previous = message
        }
        return items
    }
}

/// One message: a bubble (blue for me on iMessage, green on SMS, grey for
/// others), its tapbacks, reply quote, attachments and flags.
struct BubbleRow: View {
    @Environment(AppModel.self) private var model
    let message: ArchivedMessage
    let conversation: ArchivedConversation
    let grouped: Bool
    let quote: ArchivedMessage?

    var body: some View {
        if let event = message.event {
            note(event)
        } else if message.unsent {
            VStack(spacing: 2) {
                note("\(message.senderName) unsent a message.")
                if let archived = message.unsentText {
                    DisclosureGroup("Archived before it was unsent") {
                        Text(archived).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 320)
                }
            }
        } else {
            HStack(alignment: .bottom, spacing: 0) {
                if message.isFromMe { Spacer(minLength: 56) }
                VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 3) {
                    if conversation.isGroup, !message.isFromMe, !grouped {
                        Text(message.senderName).font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 12)
                    }
                    if let quote { replyQuote(quote) }
                    bubble
                    ForEach(message.attachments) { attachment in
                        AttachmentView(attachment: attachment, url: attachment.file.map { model.archive.fileURL($0, in: conversation) })
                    }
                    let flags = [message.edited ? "Edited" : nil, message.effect.map { "Sent with \($0)" }].compactMap { $0 }
                    if !flags.isEmpty {
                        Text(flags.joined(separator: " \u{B7} ")).font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 10)
                            .help(message.previousText.map { "Originally: \($0)" } ?? "")
                    }
                    if let previous = message.previousText {
                        DisclosureGroup("Original") {
                            Text(previous).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 280)
                        .padding(.horizontal, 10)
                    }
                }
                if !message.isFromMe { Spacer(minLength: 56) }
            }
            .padding(.top, message.reactions.isEmpty ? (grouped ? 2 : 8) : 16)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
    }

    private var bubbleText: String? {
        if !message.text.isEmpty { return message.subject.map { "\($0)\n\(message.text)" } ?? message.text }
        if let subject = message.subject { return subject }
        if let app = message.app { return app }
        return message.attachments.isEmpty ? "Message could not be read" : nil
    }

    @ViewBuilder private var bubble: some View {
        if let text = bubbleText {
            Text(text)
                .italic(message.text.isEmpty)
                .textSelection(.enabled)
                .foregroundStyle(message.isFromMe ? Color.white : Color.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(BubbleColor.fill(for: message, in: conversation), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                .overlay(alignment: message.isFromMe ? .topLeading : .topTrailing) { tapbacks }
                .help(message.date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "")
        } else if !message.reactions.isEmpty {
            tapbacks
        }
    }

    @ViewBuilder private var tapbacks: some View {
        if !message.reactions.isEmpty {
            HStack(spacing: 1) {
                ForEach(Array(message.reactions.enumerated()), id: \.offset) { _, reaction in
                    Text(reaction.emoji).help("\(reaction.senderName): \(reaction.kind == "emoji" ? reaction.emoji : reaction.kind.capitalized)")
                }
            }
            .font(.system(size: 11))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(BubbleColor.them, in: Capsule())
            .overlay(Capsule().stroke(Color(nsColor: .controlBackgroundColor), lineWidth: 1.5))
            .offset(x: message.isFromMe ? -12 : 12, y: -13)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Reactions: \(message.reactions.map(\.kind).joined(separator: ", "))")
        }
    }

    private func replyQuote(_ quote: ArchivedMessage) -> some View {
        HStack(spacing: 6) {
            Capsule().fill(.quaternary).frame(width: 2)
            Text(quote.text.isEmpty ? (quote.attachments.first?.name ?? "a message") : quote.text)
                .lineLimit(1)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 6)
        .accessibilityLabel("Reply to \(quote.senderName)")
    }
}

enum BubbleColor {
    /// Messages' own greys: lighter than any semantic fill in light mode,
    /// and a raised grey in dark mode.
    static let them = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.23, green: 0.23, blue: 0.24, alpha: 1)
            : NSColor(srgbRed: 0.914, green: 0.914, blue: 0.922, alpha: 1)
    })

    static func fill(for message: ArchivedMessage, in conversation: ArchivedConversation) -> Color {
        guard message.isFromMe else { return them }
        return (message.service ?? conversation.service).localizedCaseInsensitiveContains("sms") ? Color(nsColor: .systemGreen) : Color(nsColor: .systemBlue)
    }
}

struct AttachmentView: View {
    let attachment: ArchivedAttachment
    let url: URL?
    @State private var thumbnail: CGImage?

    var body: some View {
        if attachment.kind == .image, let url, attachment.status == .archived {
            Group {
                if let thumbnail {
                    Image(decorative: thumbnail, scale: 2)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.quaternary).aspectRatio(4 / 3, contentMode: .fit)
                }
            }
            .frame(maxWidth: attachment.isSticker ? 90 : 220, maxHeight: 220)
            .clipShape(RoundedRectangle(cornerRadius: attachment.isSticker ? 0 : 14, style: .continuous))
            .accessibilityLabel(attachment.name)
            .task(id: url) { thumbnail = await Self.thumbnail(url) }
        } else {
            HStack(spacing: 8) {
                Image(systemName: symbol).symbolRenderingMode(.hierarchical).font(.title3).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(attachment.name).lineLimit(1).truncationMode(.middle)
                    Text(detail).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: 240, alignment: .leading)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityElement(children: .combine)
        }
    }

    private var symbol: String {
        switch attachment.kind {
        case .image: "photo"
        case .video: "video"
        case .audio: "waveform"
        case .other: "doc"
        }
    }

    private var detail: String {
        switch attachment.status {
        case .archived: attachment.bytes > 0 ? attachment.bytes.byteString : "Archived"
        case .missing: "Not on this Mac"
        case .skipped: "Attachments are off"
        case .refused: "Not archived"
        }
    }

    private static func thumbnail(_ url: URL) async -> CGImage? {
        await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 480,
                           kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
        }.value
    }
}

struct ConversationAvatar: View {
    let conversation: ArchivedConversation
    var size: CGFloat = 32

    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [Color(white: 0.66), Color(white: 0.53)], startPoint: .top, endPoint: .bottom))
            if conversation.isGroup {
                Image(systemName: "person.2.fill").font(.system(size: size * 0.38))
            } else if let initials = conversation.initials {
                Text(initials).font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
            } else {
                Image(systemName: "person.fill").font(.system(size: size * 0.45))
            }
        }
        .foregroundStyle(.white)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
