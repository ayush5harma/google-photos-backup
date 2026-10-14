import Foundation

/// The archive's readable side: one page per conversation that looks like
/// Messages, and a root index. Every piece of message-derived text goes
/// through `escape`; the pages carry no script and forbid it by policy.
struct ArchiveHTML {
    let timeZone: TimeZone
    let locale: Locale

    private let dayFormatter: DateFormatter
    private let timeFormatter: DateFormatter
    private let shortDateFormatter: DateFormatter
    private let fullFormatter: DateFormatter
    private let numberFormatter: NumberFormatter
    private let calendar: Calendar
    private let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Two messages further apart than this get a time between them, as in
    /// Messages; closer ones show their time on hover.
    static let timeGap: TimeInterval = 60 * 60
    /// Bubbles from one sender closer than this read as one group.
    static let groupGap: TimeInterval = 5 * 60
    static let quoteLength = 140

    init(timeZone: TimeZone = .current, locale: Locale = .current) {
        self.timeZone = timeZone
        self.locale = locale
        func formatter(_ date: DateFormatter.Style, _ time: DateFormatter.Style) -> DateFormatter {
            let formatter = DateFormatter()
            formatter.timeZone = timeZone
            formatter.locale = locale
            formatter.dateStyle = date
            formatter.timeStyle = time
            return formatter
        }
        dayFormatter = formatter(.full, .none)
        timeFormatter = formatter(.none, .short)
        shortDateFormatter = formatter(.medium, .none)
        fullFormatter = formatter(.long, .short)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.calendar = calendar
        numberFormatter = NumberFormatter()
        numberFormatter.numberStyle = .decimal
        numberFormatter.locale = locale
    }

    static func escape(_ text: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(text.utf8.count)
        for character in text {
            switch character {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            case "'": escaped += "&#39;"
            default: escaped.append(character)
            }
        }
        return escaped
    }

    func number(_ value: Int) -> String { numberFormatter.string(from: NSNumber(value: value)) ?? String(value) }

    /// "1 message", "1,234 messages".
    func count(_ value: Int, _ noun: String) -> String { "\(number(value)) \(noun)\(value == 1 ? "" : "s")" }

    /// Initials for an avatar, or nil when the title is a phone number or
    /// email that initials would only garble.
    static func initials(_ title: String) -> String? {
        let words = title.split(whereSeparator: { $0.isWhitespace || $0 == "," }).filter { $0.first?.isLetter == true }
        guard let first = words.first?.first, !title.contains("@") else { return nil }
        let second = words.count > 1 ? words.last?.first.map(String.init) ?? "" : ""
        return (String(first) + second).uppercased()
    }

    // MARK: - Pages

    private func head(title: String, stylesheet: String) -> String {
        """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="light dark">
        <meta name="referrer" content="no-referrer">
        <meta http-equiv="Content-Security-Policy" content="script-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
        <title>\(Self.escape(title))</title>
        <link rel="stylesheet" href="\(stylesheet)">
        </head>

        """
    }

    func indexPage(conversations: [ArchivedConversation], messages: Int, attachments: Int) -> String {
        var html = head(title: "Messages Archive", stylesheet: "style.css")
        html += "<body class=\"index\">\n<header class=\"hero\">\n<h1>Messages Archive</h1>\n"
        html += "<p>\(count(conversations.count, "conversation")) \u{B7} \(count(messages, "message")) \u{B7} \(count(attachments, "attachment"))</p>\n</header>\n"
        html += "<ul class=\"conversations\">\n"
        for conversation in conversations {
            let href = Self.escape(Self.percentEncoded(conversation.relativePath) + "/index.html")
            let date = conversation.lastMessageDate.map { "<time datetime=\"\(Self.iso($0))\">\(Self.escape(shortDateFormatter.string(from: $0)))</time>" } ?? ""
            let people = conversation.isGroup ? conversation.participants.joined(separator: ", ") : conversation.service
            html += "<li><a href=\"\(href)\">\(avatar(conversation))<div class=\"info\"><div class=\"line\"><strong>\(Self.escape(conversation.title))</strong>\(date)</div>"
            html += "<div class=\"sub\"><span>\(Self.escape(people))</span><span class=\"count\">\(count(conversation.messageCount, "message"))</span></div></div></a></li>\n"
        }
        html += "</ul>\n<footer>Kept on this Mac by Photos Backup. Nothing here leaves it.</footer>\n</body>\n</html>\n"
        return html
    }

    func avatar(_ conversation: ArchivedConversation) -> String {
        if conversation.isGroup { return "<span class=\"avatar group\" aria-hidden=\"true\">\(Self.groupGlyph)</span>" }
        if let initials = Self.initials(conversation.title) { return "<span class=\"avatar\" aria-hidden=\"true\">\(Self.escape(initials))</span>" }
        return "<span class=\"avatar\" aria-hidden=\"true\">\(Self.personGlyph)</span>"
    }

    func conversationPage(_ transcript: ConversationTranscript) -> String {
        let conversation = transcript.conversation
        var html = head(title: conversation.title, stylesheet: "../../style.css")
        let people = conversation.participants.joined(separator: ", ")
        html += "<body class=\"conversation\">\n<header class=\"topbar\">\n<a class=\"back\" href=\"../../index.html\">\u{2039} Conversations</a>\n"
        html += "<div class=\"who\">\(avatar(conversation))<div><h1>\(Self.escape(conversation.title))</h1>"
        html += "<p>\(Self.escape(people.isEmpty ? conversation.service : people + " \u{B7} " + conversation.service)) \u{B7} \(count(conversation.messageCount, "message"))</p></div></div>\n</header>\n"
        html += "<main class=\"transcript\">\n"
        let byID = Dictionary(transcript.messages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var previous: ArchivedMessage?
        var previousDay: DateComponents?
        for message in transcript.messages {
            if let date = message.date {
                let day = calendar.dateComponents([.year, .month, .day], from: date)
                if day != previousDay {
                    html += "<div class=\"day\"><span>\(Self.escape(dayFormatter.string(from: date)))</span></div>\n"
                    previousDay = day
                    previous = nil
                } else if let last = previous?.date, date.timeIntervalSince(last) > Self.timeGap {
                    html += "<div class=\"gap\"><span>\(Self.escape(timeFormatter.string(from: date)))</span></div>\n"
                    previous = nil
                }
            }
            html += row(message, after: previous, in: conversation, byID: byID)
            previous = message
        }
        html += "</main>\n<footer>Kept on this Mac by Photos Backup.</footer>\n</body>\n</html>\n"
        return html
    }

    private func row(_ message: ArchivedMessage, after previous: ArchivedMessage?, in conversation: ArchivedConversation,
                     byID: [String: ArchivedMessage]) -> String {
        let anchor = "m-" + Self.escape(message.id)
        let time = message.date.map { "<time datetime=\"\(Self.iso($0))\" title=\"\(Self.escape(fullFormatter.string(from: $0)))\">\(Self.escape(timeFormatter.string(from: $0)))</time>" } ?? ""
        if let event = message.event {
            return "<div class=\"event\" id=\"\(anchor)\"><span>\(Self.escape(event))</span>\(time)</div>\n"
        }
        if message.unsent {
            return "<div class=\"event unsent\" id=\"\(anchor)\"><span>\(Self.escape(message.senderName)) unsent a message.</span>\(time)</div>\n"
        }
        let continues = previous.map { previous in
            !previous.isEvent && !previous.unsent && previous.isFromMe == message.isFromMe && previous.sender == message.sender
                && (message.date ?? .distantPast).timeIntervalSince(previous.date ?? .distantPast) < Self.groupGap
        } ?? false
        let side = message.isFromMe ? "me" : "them"
        let service = (message.service ?? conversation.service).lowercased().contains("sms") ? "sms" : "imessage"
        var html = "<div class=\"msg \(side) \(service)\(continues ? " cont" : "")\" id=\"\(anchor)\">"
        if conversation.isGroup, !message.isFromMe, !continues {
            html += "<div class=\"sender\">\(Self.escape(message.senderName))</div>"
        }
        if let replyTo = message.replyTo {
            let quoted = byID[replyTo]
            let quote = quoted.map { quote($0) } ?? "an earlier message"
            let who = quoted?.senderName ?? ""
            html += "<a class=\"reply\" href=\"#m-\(Self.escape(replyTo))\"><span class=\"who\">\(Self.escape(who.isEmpty ? "Reply" : "Replying to " + who))</span>\(Self.escape(quote))</a>"
        }
        html += "<div class=\"stack\">"
        if let subject = message.subject {
            html += "<div class=\"bubble\"><strong>\(Self.escape(subject))</strong>\(message.text.isEmpty ? "" : "<br>" + linkified(message.text))</div>"
        } else if !message.text.isEmpty {
            html += "<div class=\"bubble\">\(linkified(message.text))</div>"
        } else if let app = message.app {
            html += "<div class=\"bubble note\">\(Self.escape(app))</div>"
        } else if message.attachments.isEmpty {
            html += "<div class=\"bubble note\">Message could not be read</div>"
        }
        for attachment in message.attachments { html += self.attachment(attachment) }
        if !message.reactions.isEmpty {
            html += "<div class=\"tapbacks\">"
            for reaction in message.reactions {
                let label = "\(reaction.senderName): \(reaction.kind == "emoji" ? reaction.emoji : reaction.kind.capitalized)"
                html += "<span title=\"\(Self.escape(label))\">\(Self.escape(reaction.emoji))</span>"
            }
            html += "</div>"
        }
        html += "</div>"
        var notes = [time]
        if message.edited { notes.append("<span class=\"flag\">Edited</span>") }
        if let effect = message.effect { notes.append("<span class=\"flag\">Sent with \(Self.escape(effect))</span>") }
        html += "<div class=\"meta\">\(notes.filter { !$0.isEmpty }.joined(separator: " \u{B7} "))</div>"
        return html + "</div>\n"
    }

    private func quote(_ message: ArchivedMessage) -> String {
        if !message.text.isEmpty {
            let text = message.text.replacingOccurrences(of: "\n", with: " ")
            return text.count > Self.quoteLength ? String(text.prefix(Self.quoteLength)) + "\u{2026}" : text
        }
        if let attachment = message.attachments.first { return attachment.name }
        return message.app ?? "a message"
    }

    private func attachment(_ attachment: ArchivedAttachment) -> String {
        let name = Self.escape(attachment.name)
        guard attachment.status == .archived, let file = attachment.file else {
            let reason = switch attachment.status {
            case .missing: "Not on this Mac"
            case .refused: "Not archived"
            default: "Attachments are off"
            }
            return "<span class=\"chip off\"><span class=\"name\">\(name)</span><span class=\"why\">\(reason)</span></span>"
        }
        let source = Self.escape(Self.percentEncoded(file))
        switch attachment.kind {
        case .image:
            let style = attachment.isSticker ? "media sticker" : "media"
            return "<a class=\"\(style)\" href=\"\(source)\"><img src=\"\(source)\" alt=\"\(name)\" loading=\"lazy\"></a>"
        case .video:
            return "<video class=\"media\" controls preload=\"metadata\" src=\"\(source)\" title=\"\(name)\"></video>"
        case .audio:
            return "<div class=\"bubble audio\"><audio controls preload=\"none\" src=\"\(source)\" title=\"\(name)\"></audio></div>"
        case .other:
            let size = attachment.bytes > 0 ? "<span class=\"why\">\(Self.escape(ByteCountFormatter.string(fromByteCount: attachment.bytes, countStyle: .file)))</span>" : ""
            return "<a class=\"chip\" href=\"\(source)\"><span class=\"name\">\(name)</span>\(size)</a>"
        }
    }

    /// Escaped text with web, mail and phone links made clickable. Any
    /// other scheme (javascript:, file:) stays plain text.
    func linkified(_ text: String) -> String {
        guard let detector, text.contains(where: { $0 == "." || $0 == "@" || $0 == ":" }) else { return Self.escape(text) }
        var html = ""
        var cursor = text.startIndex
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let url = match.url, let scheme = url.scheme?.lowercased(), ["http", "https", "mailto", "tel"].contains(scheme),
                  let range = Range(match.range, in: text), range.lowerBound >= cursor else { continue }
            html += Self.escape(String(text[cursor..<range.lowerBound]))
            html += "<a href=\"\(Self.escape(url.absoluteString))\" rel=\"noopener noreferrer\">\(Self.escape(String(text[range])))</a>"
            cursor = range.upperBound
        }
        return html + Self.escape(String(text[cursor...]))
    }

    static func percentEncoded(_ path: String) -> String {
        path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "?#"))) ?? path
    }

    static func iso(_ date: Date) -> String { date.formatted(.iso8601) }

    static let personGlyph = """
    <svg viewBox="0 0 24 24" width="22" height="22"><circle cx="12" cy="8.5" r="4.2" fill="currentColor"/><path d="M3.8 21c.6-4.6 4-7.2 8.2-7.2s7.6 2.6 8.2 7.2z" fill="currentColor"/></svg>
    """

    static let groupGlyph = """
    <svg viewBox="0 0 24 24" width="24" height="24"><circle cx="8.5" cy="9" r="3.4" fill="currentColor"/><circle cx="16" cy="8" r="2.8" fill="currentColor" opacity=".7"/><path d="M2 20c.5-3.8 3.2-6 6.5-6s6 2.2 6.5 6z" fill="currentColor"/><path d="M15.8 13.2c3 .1 5.4 2.1 5.9 5.6h-5.1c-.3-2.2-1.3-4.1-2.9-5.3.7-.2 1.4-.3 2.1-.3z" fill="currentColor" opacity=".7"/></svg>
    """
}
