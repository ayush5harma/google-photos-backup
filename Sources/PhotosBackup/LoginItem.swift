import Foundation
import Observation
import ServiceManagement

/// Launch at login through SMAppService: the app itself as a login item,
/// listed (and switchable) in System Settings > General > Login Items.
@MainActor
@Observable
final class LoginItem {
    static let shared = LoginItem()

    enum State: Equatable {
        case enabled
        case disabled
        /// Registered, but switched off in Login Items: only the person can
        /// turn it back on there.
        case requiresApproval
        /// Not an installed app bundle (a debug binary): nothing to register.
        case unavailable
    }

    private(set) var state: State = .disabled
    private(set) var error: String?

    func refresh() {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            state = .unavailable
            return
        }
        state = switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered: .disabled
        case .notFound: .unavailable
        @unknown default: .disabled
        }
    }

    func setEnabled(_ enabled: Bool) {
        error = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            self.error = error.localizedDescription
        }
        refresh()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
