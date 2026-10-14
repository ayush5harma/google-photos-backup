import AppKit
import PhotosBackupCore
import SwiftUI

/// Something in the way of a working backup, with the one action that
/// clears it. The menu bar panel and the Overview show the same list.
struct Attention: Identifiable, Equatable {
    enum Action: Equatable {
        case signIn
        case requestPhotos
        case openPhotosPrivacy
        case openFullDiskAccess
        case openSettings(AutomationCommand.SettingsTab)
        case openGoogleStorage
    }

    let id: String
    let symbol: String
    let title: String
    let detail: String
    let actionTitle: String
    let action: Action
    var tint: Color = .orange
}

extension AccountStatus {
    var isFailed: Bool {
        if case .failed = self { true } else { false }
    }
}

extension WaitReason {
    /// What lets the run continue, for the line under the title.
    var resumeHint: String {
        switch self {
        case .offline: "Continues when your Mac is back online."
        case .expensiveNetwork: "Continues on a regular network."
        case .lowDataMode: "Continues when Low Data Mode is off."
        case .onBattery: "Continues when your Mac is plugged in."
        case .lowPowerMode: "Continues when Low Power Mode is off."
        case let .rateLimited(until), let .retrying(until): "Continues \(until.formatted(.relative(presentation: .named)))."
        }
    }
}

/// What the shell says about the model, in one place so the menu bar, the
/// panel and the window never disagree.
extension AppModel {
    /// The cached Photos status, or the live one: a fixture (and a grant
    /// made while the app runs) are both covered.
    var canReadPhotos: Bool {
        photosStatus == .authorized || photosStatus == .limited || library.isAuthorized
    }

    var accountEmail: String? {
        if case let .connected(email) = account { return email ?? state.accountEmail }
        return state.accountEmail
    }

    /// AppModel.describe words a full Google account this way.
    var isStorageFull: Bool {
        engine.lastError?.hasPrefix("Your Google account is out of storage") == true
    }

    var status: MenuBarStatus {
        let engine = engine
        let summary = summary
        let activity: MenuBarStatus.Activity = switch engine.phase {
        case .idle: .idle
        case .running: .running
        case .pausing: .pausing
        case .paused: .paused
        case .stopping: .stopping
        case .waiting: .waiting(engine.waitReason)
        }
        let accountProblem = if case .failed = account { true } else { false }
        return MenuBarStatus(.init(signedIn: hasAuthData, accountProblem: accountProblem, activity: activity,
                                   remaining: engine.remaining, pending: summary.pending, total: summary.total,
                                   failed: engine.failedCount, problem: isStorageFull ? "Google storage is full" : nil,
                                   archiving: archive.isRunning))
    }

    /// When a photos or Messages media backup last finished.
    var lastBackup: Date? {
        let recorded = diagnostics.runs.last { $0.kind != .messagesArchive && $0.finishedAt != nil }?.finishedAt
        switch (recorded, engine.lastRun) {
        case let (recorded?, last?): return max(recorded, last)
        case let (recorded, last): return recorded ?? last
        }
    }

    /// The file being worked on right now, for "Uploading IMG_0042.HEIC".
    var currentItem: ActivityItem? {
        engine.activity.first { !$0.status.isFinished }
    }

    /// The run's progress for the ring: the current run while one moves,
    /// else the share of the selection Google has.
    var displayFraction: Double {
        if engine.isActive, engine.runTotal > 0 { return engine.runFraction }
        let summary = summary
        return summary.total == 0 ? 0 : Double(summary.backedUp) / Double(summary.total)
    }

    /// The selection's share in Google Photos, rounded down: 99.6% must
    /// not read as 100% while items are still missing.
    var coverageText: String {
        let summary = summary
        guard summary.total > 0 else { return "0%" }
        let percent = summary.pending == 0 ? 100 : min(99, summary.backedUp * 100 / summary.total)
        return "\(percent)%"
    }

    /// The hero's title in the window and the panel. It says where the
    /// backup stands; the header line and attention rows say what is wrong,
    /// so it never repeats them.
    var heroTitle: String {
        let status = status
        switch status.kind {
        case .upToDate: return "Everything is backed up"
        case .backingUp: return engine.isActive ? "Backing up" : "Archiving Messages"
        case .ready: return summary.total == 0 ? "Choose what to back up" : "Ready to back up"
        case .paused: return "Backup is paused"
        case .waiting: return "Waiting"
        case .attention:
            if !hasAuthData { return "Not signed in" }
            if isStorageFull || account.isFailed { return "Backups are stopped" }
            return "\(engine.failedCount.formatted()) need another try"
        }
    }

    var messagesNeedFullDiskAccess: Bool {
        if archive.status == .needsFullDiskAccess { return true }
        if case let .failed(reason) = visibleMessagesStatus { return reason.localizedCaseInsensitiveContains("full disk access") }
        return false
    }

    var attention: [Attention] {
        var items: [Attention] = []
        switch account {
        case .missing:
            items.append(Attention(id: "sign-in", symbol: "person.crop.circle.badge.plus", title: "Sign in to Google Photos",
                                   detail: "Backups start once an account is connected.", actionTitle: "Sign In…",
                                   action: .signIn, tint: .accentColor))
        case .failed:
            items.append(Attention(id: "sign-in", symbol: "person.crop.circle.badge.exclamationmark", title: "Sign in again",
                                   detail: "Google did not accept the saved account.", actionTitle: "Sign In…", action: .signIn))
        case .connected, .checking:
            break
        }
        if !canReadPhotos {
            if photosStatus == .notDetermined {
                items.append(Attention(id: "photos", symbol: "photo.on.rectangle.angled", title: "Allow access to Photos",
                                       detail: "Photos Backup reads the albums you choose.", actionTitle: "Allow Access",
                                       action: .requestPhotos, tint: .accentColor))
            } else {
                items.append(Attention(id: "photos", symbol: "lock", title: "Photos access is off",
                                       detail: "Turn on Photos Backup in Privacy & Security.", actionTitle: "Open Settings",
                                       action: .openPhotosPrivacy))
            }
        }
        if isStorageFull {
            items.append(Attention(id: "storage", symbol: "exclamationmark.triangle.fill", title: "Google storage is full",
                                   detail: "Free up space, or choose Storage saver.", actionTitle: "Manage Storage",
                                   action: .openGoogleStorage, tint: .red))
        }
        if messagesNeedFullDiskAccess {
            items.append(Attention(id: "fda", symbol: "lock.shield", title: "Messages needs Full Disk Access",
                                   detail: "macOS keeps Messages private until you allow it.", actionTitle: "Open Settings",
                                   action: .openFullDiskAccess))
        }
        if engine.phase == .waiting, let reason = engine.waitReason {
            let until = reason.until.map { "Resumes \($0.formatted(.relative(presentation: .named)))." }
            items.append(Attention(id: "waiting", symbol: reason.symbol, title: reason.title,
                                   detail: until ?? "Uploads continue by themselves when this changes.",
                                   actionTitle: "Options…", action: .openSettings(.backup), tint: .secondary))
        }
        return items
    }

    func perform(_ action: Attention.Action) {
        switch action {
        case .signIn:
            AppRouter.shared.openMain()
            beginSignIn()
        case .requestPhotos:
            Task { await requestPhotosAccess() }
        case .openPhotosPrivacy:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") { NSWorkspace.shared.open(url) }
        case .openFullDiskAccess:
            openFullDiskAccess()
        case let .openSettings(tab):
            AppRouter.shared.openSettings(tab)
        case .openGoogleStorage:
            if let url = URL(string: "https://one.google.com/storage") { NSWorkspace.shared.open(url) }
        }
    }
}
