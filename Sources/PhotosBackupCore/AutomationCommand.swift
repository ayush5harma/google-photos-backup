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

    case backUp(Scope)
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
        case ("backup", nil): self = .backUp(.everything)
        case let ("backup", scope?):
            guard let scope = Scope(rawValue: scope), scope != .everything else { return nil }
            self = .backUp(scope)
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
}
