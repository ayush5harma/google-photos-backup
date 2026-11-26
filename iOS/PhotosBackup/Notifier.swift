import Foundation
import PhotosBackupCore
import UserNotifications

/// The notifications Settings > Notifications promises: an automatic run
/// that finished (Core's RunNotification decides whether it is worth one,
/// and never for a run someone started and is watching), and problems that
/// need the person, at most one per kind an hour (ProblemThrottle). The
/// Mac's Notifier without its window routing.
@MainActor
final class Notifier {
    private var throttle = ProblemThrottle()
    private var allowed = false
    private let enabled: Bool

    init(enabled: Bool) {
        self.enabled = enabled
    }

    func refresh() async {
        guard enabled else { return }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        allowed = [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus)
    }

    func requestAuthorization() async {
        guard enabled else { return }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        await refresh()
    }

    func runFinished(_ record: RunRecord, settings: BackupSettings) {
        guard settings.notifyWhenFinished, let note = RunNotification(record) else { return }
        post(id: "run-\(record.id)", title: note.title, body: note.body)
    }

    func problem(_ message: String, category: EventCategory, settings: BackupSettings) {
        // The hour starts only with a notification actually shown.
        guard settings.notifyAboutProblems, allowed, throttle.allows(category) else { return }
        post(id: "problem-\(category.rawValue)", title: Self.title(for: category), body: message)
    }

    private func post(id: String, title: String, body: String) {
        guard enabled, allowed else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    private static func title(for category: EventCategory) -> String {
        switch category {
        case .account: "Sign in to keep backing up"
        case .photos: "Photos backup stopped"
        case .run: "Backup stopped"
        case .network: "Can't reach Google Photos"
        case .app, .messages, .archive: "Photos Backup needs attention"
        }
    }
}
