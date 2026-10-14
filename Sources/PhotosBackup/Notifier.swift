import AppKit
import Foundation
import Observation
import PhotosBackupCore
import UserNotifications

/// User notifications for finished automatic runs and for problems that
/// need a person (sign in again, Full Disk Access, storage full).
///
/// Permission is asked for from the welcome guide or Settings, never at
/// first launch: a prompt before the app has done anything is the one most
/// people refuse.
@MainActor
@Observable
final class Notifier: NSObject {
    enum Authorization: Equatable {
        /// Not an app bundle (a `swift build` binary): notifications need one.
        case unavailable
        case notDetermined
        case denied
        case allowed
    }

    private(set) var authorization: Authorization = .unavailable
    /// Where a click on a notification goes.
    @ObservationIgnored var onOpen: ((AppSection) -> Void)?
    @ObservationIgnored private var throttle = ProblemThrottle()

    nonisolated private static let sectionKey = "section"

    /// UNUserNotificationCenter traps in a process without a bundle.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleURL.pathExtension == "app" ? UNUserNotificationCenter.current() : nil
    }

    /// Becomes the center's delegate (so clicks and foreground deliveries
    /// reach the app) and reads the current permission.
    func activate() {
        guard let center else { return }
        center.delegate = self
        Task { await refresh() }
    }

    func refresh() async {
        guard let center else { authorization = .unavailable; return }
        let settings = await center.notificationSettings()
        authorization = switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: .allowed
        case .denied: .denied
        default: .notDetermined
        }
    }

    func requestAuthorization() {
        guard let center else { return }
        Task {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            await refresh()
        }
    }

    func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    func runFinished(_ record: RunRecord, settings: BackupSettings) {
        guard settings.notifyWhenFinished, let note = RunNotification(record) else { return }
        post(id: "run-\(record.id)", title: note.title, body: note.body, section: note.opensActivity ? .activity : .home)
    }

    func problem(_ message: String, category: EventCategory, settings: BackupSettings) {
        // The hour starts only with a notification actually shown, so one
        // refused before permission was given does not mute the next.
        guard settings.notifyAboutProblems, center != nil, authorization == .allowed, throttle.allows(category) else { return }
        // One notification per category, replaced rather than stacked.
        post(id: "problem-\(category.rawValue)", title: Self.title(for: category), body: message, section: .activity)
    }

    private func post(id: String, title: String, body: String, section: AppSection) {
        guard let center, authorization == .allowed else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = [Self.sectionKey: section.rawValue]
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    private static func title(for category: EventCategory) -> String {
        switch category {
        case .account: "Sign in to keep backing up"
        case .photos: "Photos backup stopped"
        case .messages: "Messages media backup stopped"
        case .archive: "Messages archive stopped"
        case .run: "Backup stopped"
        case .network: "Can't reach Google Photos"
        case .app: "Photos Backup needs attention"
        }
    }
}

extension Notifier: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let raw = response.notification.request.content.userInfo[Self.sectionKey] as? String
        Task { @MainActor in
            self.onOpen?(raw.flatMap(AppSection.init(rawValue:)) ?? .home)
            completionHandler()
        }
    }

    /// Shown even while the app is frontmost: the window may be on another
    /// Space, and a menu bar app is frontmost whenever its panel is open.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}
