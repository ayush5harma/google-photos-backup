import Foundation

/// A photosbackup:// link: the Mac's answer to the iOS app's Shortcuts
/// action. Shortcuts' "Open URL", a terminal's `open`, a calendar alarm or a
/// link in a note can all run one, with or without a window open.
///
///     photosbackup://backup                  Back Up Now (photos, and Messages media when on)
///     photosbackup://backup/photos           photos only
///     photosbackup://backup/messages-media   Messages media only
///     photosbackup://archive                 archive Messages now
///     photosbackup://pause | resume | stop | retry-failed
///     photosbackup://open[/overview|albums|messages|activity]
///     photosbackup://settings[/general|backup|messages|account|advanced]
///
/// The two backup links go where Settings > Account's "Back up to" says
/// (every account, or the chosen ones). `?account=<address>` sends one of
/// them to that one account instead, as a one-off that leaves the choice
/// alone; Messages media goes along only when it is the primary account:
///
///     photosbackup://backup?account=me@example.com
///     photosbackup://backup/photos?account=family%40example.com
///
/// The address is compared as Google compares it (case, and for Gmail the
/// dots and googlemail.com, do not matter). A link with an empty address,
/// something that is not an address, or `account` twice is not followed,
/// and neither is `account` on backup/messages-media, which only the
/// primary takes; an address no signed-in account has is logged and
/// ignored, never matched to another account.
public enum AutomationCommand: Equatable, Sendable {
    public enum Scope: String, Sendable {
        case everything
        case photos
        case messagesMedia = "messages-media"
    }

    public enum Section: String, Sendable, CaseIterable {
        case overview, albums, messages, activity
    }

    public enum SettingsTab: String, Sendable, CaseIterable {
        case general, backup, messages, account, advanced
    }

    /// `account`: one account's normalized address (GoogleSignIn.normalizedEmail);
    /// nil goes where "Back up to" says.
    case backUp(Scope, account: String? = nil)
    case archive
    case pause
    case resume
    case stop
    case retryFailed
    case open(Section?)
    case settings(SettingsTab?)

    public static let scheme = "photosbackup"
    /// What every run a link starts is recorded as.
    public static let trigger = RunTrigger.automation

    /// nil for another scheme or anything not listed above: a link is
    /// followed exactly or not at all, never guessed at.
    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme else { return nil }
        // 2026-10-15: macOS 15 URL.path drops an opaque scheme path;
        // URLComponents retains it so typed Shortcuts links work on both SDKs.
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let words = ([components.host ?? ""] + components.path.split(separator: "/").map(String.init))
            .map { $0.lowercased() }
            .filter { !$0.isEmpty }
        guard let verb = words.first else { return nil }
        let argument = words.count > 1 ? words[1] : nil
        guard words.count <= 2 else { return nil }

        switch (verb, argument) {
        case ("backup", _):
            let scope: Scope
            if let argument {
                guard let named = Scope(rawValue: argument), named != .everything else { return nil }
                scope = named
            } else {
                scope = .everything
            }
            guard let account = Self.account(in: components) else { return nil }
            // Only the primary takes Messages media: a link naming an
            // account for it would be guessed at, so it is not followed.
            if account != nil, scope == .messagesMedia { return nil }
            self = .backUp(scope, account: account)
        case ("archive", nil): self = .archive
        case ("pause", nil): self = .pause
        case ("resume", nil): self = .resume
        case ("stop", nil): self = .stop
        case ("retry-failed", nil): self = .retryFailed
        case ("open", nil): self = .open(nil)
        case let ("open", section?):
            // The sidebar's first section was called Home until 0.2.
            guard let section = section == "home" ? .overview : Section(rawValue: section) else { return nil }
            self = .open(section)
        case ("settings", nil): self = .settings(nil)
        case let ("settings", tab?):
            guard let tab = SettingsTab(rawValue: tab) else { return nil }
            self = .settings(tab)
        default: return nil
        }
    }

    /// The `account` query item, normalized: `.some(nil)` when the link has
    /// none, nil when the link is not to be followed (an empty value,
    /// something that is not one address, or the item given twice).
    private static func account(in components: URLComponents) -> String?? {
        let values = (components.queryItems ?? []).filter { $0.name.lowercased() == "account" }.map { $0.value ?? "" }
        guard let value = values.first else { return .some(nil) }
        guard values.count == 1 else { return nil }
        let address = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = address.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty, !address.contains(where: \.isWhitespace) else { return nil }
        return .some(GoogleSignIn.normalizedEmail(address))
    }
}
