import Foundation

/// Where the app keeps its data, and the one switch that moves all of it.
///
/// Debug builds only: PHOTOS_BACKUP_SANDBOX=<dir> puts Application Support,
/// Caches, the settings domain and the keychain item somewhere the real app
/// never looks, while the bundle id (and so every privacy grant tied to it)
/// stays the real one. scripts/e2e.py relies on this to drive a build
/// against the real Photos library without touching the real app's history,
/// settings or Google credential. Release builds ignore the variable.
enum AppEnvironment {
    static let bundleID = Bundle.main.bundleIdentifier ?? "PhotosBackup"

    static let sandbox: URL? = {
        #if DEBUG
        guard let path = ProcessInfo.processInfo.environment["PHOTOS_BACKUP_SANDBOX"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
        #else
        return nil
        #endif
    }()

    static var isSandboxed: Bool { sandbox != nil }

    /// A suite of its own when sandboxed; UserDefaults refuses the app's own
    /// bundle id as a suite name, so the suffix is needed either way.
    static let defaults: UserDefaults = {
        guard isSandboxed, let suite = UserDefaults(suiteName: bundleID + ".sandbox") else { return .standard }
        return suite
    }()

    static let keychainService = bundleID + ".auth-data" + (isSandboxed ? ".sandbox" : "")

    static let supportDirectory: URL = {
        if let sandbox { return sandbox.appendingPathComponent("Support", isDirectory: true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleID, isDirectory: true)
    }()

    static let cachesDirectory: URL = {
        if let sandbox { return sandbox.appendingPathComponent("Caches", isDirectory: true) }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleID, isDirectory: true)
    }()
}
