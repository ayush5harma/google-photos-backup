import Foundation

/// Turns chat.db rows into the archive's messages: text decoded, tapbacks
/// folded onto their targets, system rows put into words.
struct TranscriptBuilder {
    let handles: [Int64: String]
    let names: HandleNames

    struct Output {
        var messages: [ArchivedMessage]
        /// Reactions whose target is not among these rows (a message the
        /// archive kept after it was deleted from Messages), by target guid.
        var orphanReactions: [String: [ArchivedReaction]]
        var decodeFailures: Int
    }

    func build(rows: [MessageRow], attachments: (MessageRow) -> [ArchivedAttachment]) -> Output {
        var messages: [ArchivedMessage] = []
        var tapbacks: [MessageRow] = []
        var failures = 0
        for row in rows {
            if row.associatedGUID != nil, Tapback.kind(of: row.associatedType) != nil {
                tapbacks.append(row)
                continue
            }
            var message = base(row)
            if row.dateRetracted > 0 {
                message.unsent = true
            } else if let event = event(row, actor: message.senderName) {
                message.event = event
            } else {
                let decoded = text(of: row)
                if decoded == nil { failures += 1 }
                message.text = decoded ?? ""
                message.edited = row.dateEdited > 0
                message.attachments = attachments(row)
                message.app = Self.app(row.balloonBundle)
                message.effect = Self.effect(row.effect)
                message.replyTo = row.threadOriginator.flatMap { $0.isEmpty ? nil : $0 }
            }
            messages.append(message)
        }
        let reactions = resolve(tapbacks)
        var orphans = reactions
        for index in messages.indices {
            guard let found = reactions[messages[index].id] else { continue }
            messages[index].reactions = found
            orphans[messages[index].id] = nil
        }
        return Output(messages: messages, orphanReactions: orphans, decodeFailures: failures)
    }

    private func base(_ row: MessageRow) -> ArchivedMessage {
        let sender = row.isFromMe ? nil : handles[row.handleID]
        return ArchivedMessage(id: row.guid, rowID: row.rowID, date: AppleTime.date(row.date), isFromMe: row.isFromMe, sender: sender,
                               senderName: senderName(row), service: row.service, text: "",
                               subject: row.subject.flatMap { $0.isEmpty ? nil : $0 })
    }

    private func senderName(_ row: MessageRow) -> String {
        if row.isFromMe { return "You" }
        guard let handle = handles[row.handleID] else { return "Unknown" }
        return names.display(handle)
    }

    /// nil when there was a body that could not be read; "" for a message
    /// that is only attachments.
    private func text(of row: MessageRow) -> String? {
        let stored = (row.text ?? "").filter { $0 != TypedStream.objectReplacement }
        if !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return stored }
        guard let body = row.attributedBody, !body.isEmpty else { return stored }
        return TypedStream.plainText(from: body)
    }

    /// A user has one tapback per message at a time: a new one replaces
    /// theirs, a removal clears it if it names the one they left.
    private func resolve(_ tapbacks: [MessageRow]) -> [String: [ArchivedReaction]] {
        var current: [String: [String: ArchivedReaction]] = [:]
        var order: [String: [String]] = [:]
        for row in tapbacks.sorted(by: { $0.rowID < $1.rowID }) {
            guard let associated = row.associatedGUID, let tapback = Tapback.kind(of: row.associatedType) else { continue }
            let (kind, adds) = tapback
            let target = Tapback.targetGUID(associated)
            let who = row.isFromMe ? "me" : (handles[row.handleID] ?? "handle-\(row.handleID)")
            if adds {
                if current[target]?[who] == nil { order[target, default: []].append(who) }
                current[target, default: [:]][who] = ArchivedReaction(
                    kind: kind, emoji: Tapback.emoji(for: kind, custom: row.associatedEmoji), sender: row.isFromMe ? nil : handles[row.handleID],
                    senderName: senderName(row), isFromMe: row.isFromMe, date: AppleTime.date(row.date))
            } else if let existing = current[target]?[who], existing.kind == kind,
                      row.associatedEmoji == nil || existing.emoji == row.associatedEmoji {
                current[target]?[who] = nil
                order[target]?.removeAll { $0 == who }
            }
        }
        var result: [String: [ArchivedReaction]] = [:]
        for (target, senders) in order {
            let reactions = senders.compactMap { current[target]?[$0] }
            if !reactions.isEmpty { result[target] = reactions }
        }
        return result
    }

    /// System rows: membership, renames, the group photo, kept audio.
    private func event(_ row: MessageRow, actor: String) -> String? {
        let other = handles[row.otherHandle].map { names.display($0) } ?? "someone"
        switch (row.itemType, row.groupActionType) {
        case (0, _): return nil
        case (1, 0): return "\(actor) added \(other) to the conversation."
        case (1, 1): return "\(actor) removed \(other) from the conversation."
        case (2, _):
            if let title = row.groupTitle, !title.isEmpty { return "\(actor) named the conversation \u{201C}\(title)\u{201D}." }
            return "\(actor) removed the conversation name."
        case (3, 0): return "\(actor) left the conversation."
        case (3, 1): return "\(actor) changed the group photo."
        case (3, 2): return "\(actor) removed the group photo."
        case (4, _): return "\(actor) changed location sharing."
        case (5, _): return "\(actor) kept an audio message."
        default: return "\(actor) updated the conversation."
        }
    }

    static func app(_ bundle: String?) -> String? {
        guard let bundle, !bundle.isEmpty else { return nil }
        // Link previews carry their URL in the text already.
        if bundle.contains("URLBalloonProvider") { return nil }
        if bundle.contains("Handwriting") { return "Handwritten message" }
        if bundle.contains("DigitalTouch") { return "Digital Touch" }
        if bundle.contains("PeerPayment") { return "Apple Cash" }
        if bundle.contains("Polls") { return "Poll" }
        return "iMessage app"
    }

    static func effect(_ style: String?) -> String? {
        guard let style, !style.isEmpty else { return nil }
        let known = [
            "impact": "Slam", "loud": "Loud", "gentle": "Gentle", "invisibleink": "Invisible Ink",
            "CKConfettiEffect": "Confetti", "CKEchoEffect": "Echo", "CKFireworksEffect": "Fireworks",
            "CKHappyBirthdayEffect": "Balloons", "CKHeartEffect": "Love", "CKLasersEffect": "Lasers",
            "CKShootingStarEffect": "Shooting Star", "CKSparklesEffect": "Celebration", "CKSpotlightEffect": "Spotlight",
        ]
        let last = String(style.split(separator: ".").last ?? Substring(style))
        return known[last] ?? last
    }
}
