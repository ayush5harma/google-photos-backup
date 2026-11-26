import Foundation
import PhotosBackupCore
import SwiftUI
import UIKit

/// Something in the way of a working backup, with the one action that
/// clears it. The Mac's Attention, with the iOS actions.
struct Attention: Identifiable, Equatable {
    enum Action: Equatable {
        case signIn
        case requestPhotos
        case choosePhotos
        case openAppSettings
        case openAccounts
        case openWhenToBackUp
    }

    let id: String
    let symbol: String
    let title: String
    let detail: String
    let actionTitle: String
    let action: Action
    var tint: Color = .orange
}

extension WaitReason {
    /// What lets the run continue, in iPhone words.
    var resumeHint: String {
        switch self {
        case .offline: "Continues when your iPhone is back online."
        case .expensiveNetwork: "Continues on Wi-Fi."
        case .lowDataMode: "Continues when Low Data Mode is off."
        case .onBattery: "Continues when your iPhone is charging."
        case .lowPowerMode: "Continues when Low Power Mode is off."
        case let .rateLimited(until), let .retrying(until): "Continues \(until.comingDescription)."
        }
    }

    /// The iPhone's names for the Mac's "metered network" and "battery".
    var phoneTitle: String {
        switch self {
        case .expensiveNetwork: "Waiting for Wi-Fi"
        case .onBattery: "Waiting for a charger"
        default: title
        }
    }
}

/// What the screens say about the model, in one place so the Overview,
/// Activity and Settings never disagree. Wording follows the Mac's AppStatus.
extension AppModel {
    static let noAccountHeadline = "No account is included in backups"

    var isStorageFull: Bool {
        status.lastError?.hasPrefix(EventPhrase.storageFull) == true
    }

    /// The automatic backup's hold, when nothing is running: what the
    /// "When to back up" switches stop right now.
    var conditionsHolding: WaitReason? {
        guard settings.automatic, !status.isActive else { return nil }
        return conditions.blocking(for: settings)
    }

    var menuStatus: MenuBarStatus {
        let engine = status
        let summary = overallSummary
        let activity: MenuBarStatus.Activity = switch engine.phase {
        case .idle: .idle
        case .running: .running
        case .pausing: .pausing
        case .paused: .paused
        case .stopping: .stopping
        case let .waiting(reason): .waiting(reason)
        }
        let problem = isStorageFull ? "Google storage is full" : (noAccountIncluded ? Self.noAccountHeadline : nil)
        return MenuBarStatus(.init(signedIn: hasAuthData, accountProblem: account.isFailed, activity: activity,
                                   remaining: engine.remaining, pending: summary.pending, total: summary.total,
                                   failed: engine.failedCount, problem: problem))
    }

    var lastBackup: Date? {
        let recorded = diagnostics.runs.first { $0.finishedAt != nil }?.finishedAt
        switch (recorded, status.lastRun) {
        case let (recorded?, last?): return max(recorded, last)
        case let (recorded, last): return recorded ?? last
        }
    }

    /// Rounded down: 99.6% must not read as 100% while items are missing.
    var coverageText: String {
        let summary = overallSummary
        guard summary.total > 0 else { return "0%" }
        let percent = summary.pending == 0 ? 100 : min(99, summary.backedUp * 100 / summary.total)
        return "\(percent)%"
    }

    var heroTitle: String {
        switch menuStatus.kind {
        case .upToDate: return "Everything is backed up"
        case .backingUp: return "Backing up"
        case .ready: return summary.total == 0 ? "Choose what to back up" : "Ready to back up"
        case .paused: return "Backup is paused"
        case .waiting: return "Waiting"
        case .attention:
            if !hasAuthData { return "Not signed in" }
            if isStorageFull || account.isFailed { return "Backups are stopped" }
            if noAccountIncluded { return "Photo backups are stopped" }
            return "\(status.failedCount.formatted()) need another try"
        }
    }

    var heroDetail: String {
        let engine = status
        let summary = summary
        switch menuStatus.kind {
        case .upToDate:
            let targets = targetAccounts
            let count = leadingSummary.backedUp.formatted()
            if targets.count > 1 {
                return targets.count == accounts.count
                    ? "\(count) photos and videos are in each of your \(targets.count) Google accounts."
                    : "\(count) photos and videos are in each of the \(targets.count) accounts you back up to."
            }
            if accounts.count > 1, let only = targets.first { return "\(count) photos and videos are in \(only.title)." }
            return "\(count) photos and videos are in Google Photos."
        case .backingUp:
            return engine.remaining > 0 ? "\(engine.remaining.formatted()) items left in this backup." : "Looking for new photos and videos…"
        case .ready:
            return summary.total == 0 ? "Turn on albums in Albums, or start with All Photos."
                : "\(overallSummary.pending.formatted()) of \(overallSummary.total.formatted()) items aren't in Google Photos yet."
        case .paused:
            return summary.pending > 0 ? "\(summary.pending.formatted()) items are waiting. Resume to continue." : "Resume to continue."
        case .waiting:
            let reason = engine.waitReason
            return [reason?.phoneTitle, reason?.resumeHint ?? "Uploads continue by themselves."].compactMap { $0 }.joined(separator: ". ")
        case .attention:
            if !hasAuthData { return "Connect your Google account to back up \(summary.total.formatted()) items." }
            if noAccountIncluded, !isStorageFull, !account.isFailed {
                return "Every account is left out. Include one in Settings > Accounts, or back up to all accounts."
            }
            if isStorageFull || account.isFailed {
                return "\(summary.backedUp.formatted()) of \(summary.total.formatted()) items are in Google Photos; the rest wait until this is fixed."
            }
            return "Everything else is in Google Photos. Retry them from Activity."
        }
    }

    var attention: [Attention] {
        var items: [Attention] = []
        switch account {
        case .missing:
            items.append(Attention(id: "sign-in", symbol: "person.crop.circle.badge.plus", title: "Sign in to Google Photos",
                                   detail: "Backups start once an account is connected.", actionTitle: "Sign In",
                                   action: .signIn, tint: .accentColor))
        case .failed:
            items.append(Attention(id: "sign-in", symbol: "person.crop.circle.badge.exclamationmark", title: "Sign in again",
                                   detail: "Google did not accept the saved account.", actionTitle: "Sign In", action: .signIn))
        case .connected, .checking:
            break
        }
        switch photosStatus {
        case .notDetermined:
            items.append(Attention(id: "photos", symbol: "photo.on.rectangle.angled", title: "Allow access to Photos",
                                   detail: "Photos Backup reads the albums you choose.", actionTitle: "Allow",
                                   action: .requestPhotos, tint: .accentColor))
        case .denied, .restricted:
            items.append(Attention(id: "photos", symbol: "lock", title: "Photos access is off",
                                   detail: "Turn on Photos for Photos Backup in Settings.", actionTitle: "Settings",
                                   action: .openAppSettings))
        case .limited:
            items.append(Attention(id: "photos-limited", symbol: "photo.badge.exclamationmark", title: "Only some photos are shared",
                                   detail: "Photos Backup sees, and backs up, only the photos you chose. All Photos means those.",
                                   actionTitle: "Choose", action: .choosePhotos, tint: .accentColor))
        default:
            break
        }
        if noAccountIncluded {
            items.append(Attention(id: "no-account", symbol: "person.crop.circle.badge.xmark", title: Self.noAccountHeadline,
                                   detail: "Include an account in backups, or back up to all accounts.",
                                   actionTitle: "Accounts", action: .openAccounts))
        }
        if isStorageFull {
            items.append(Attention(id: "storage", symbol: "exclamationmark.triangle.fill", title: "Google storage is full",
                                   detail: "Free up space, or choose Storage saver.", actionTitle: "Settings",
                                   action: .openAccounts, tint: .red))
        }
        if let reason = status.waitReason ?? conditionsHolding {
            let until = reason.until.map { "Resumes \($0.comingDescription)." }
            items.append(Attention(id: "waiting", symbol: reason.symbol, title: reason.phoneTitle,
                                   detail: until ?? reason.resumeHint, actionTitle: "Options", action: .openWhenToBackUp,
                                   tint: .secondary))
        }
        return items
    }

    func perform(_ action: Attention.Action) {
        switch action {
        case .signIn: beginSignIn()
        case .requestPhotos: Task { await requestPhotosAccess() }
        case .choosePhotos: PhotoLibrary.presentLimitedPicker()
        case .openAppSettings:
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        case .openAccounts, .openWhenToBackUp:
            settingsPath = action == .openAccounts ? [] : [.whenToBackUp]
            tab = .settings
        }
    }
}
