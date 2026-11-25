import Foundation
import os

/// Where the app keeps its data, and the debug switches that move or fake
/// all of it. The names match the Mac app's (Sources/PhotosBackup/AppEnvironment.swift).
///
/// Debug builds only:
/// - PHOTOS_BACKUP_SANDBOX=<dir> puts Application Support, Caches, the
///   settings domain and the Keychain item somewhere the real app never looks.
/// - PHOTOS_BACKUP_SNAPSHOT_FIXTURE=1 draws made-up data: no PhotoKit, no
///   Keychain, no network and nothing written.
/// - PHOTOS_BACKUP_TAB=<overview|albums|activity|settings> opens a tab.
/// - PHOTOS_BACKUP_SHOW=<onboarding|signin> opens a sheet.
/// - PHOTOS_BACKUP_OPEN=<photosbackup:// link> runs a link at launch.
/// Release builds ignore all five.
enum AppEnvironment {
    static let bundleID = Bundle.main.bundleIdentifier ?? "io.github.ayush5harma.PhotosBackup"

    private static func value(_ name: String) -> String? {
        #if DEBUG
        guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else { return nil }
        return value
        #else
        return nil
        #endif
    }

    static let sandbox: URL? = value("PHOTOS_BACKUP_SANDBOX").map { URL(fileURLWithPath: $0, isDirectory: true) }

    static var isSandboxed: Bool { sandbox != nil }

    static let isFixture = value("PHOTOS_BACKUP_SNAPSHOT_FIXTURE") == "1"

    static let requestedTab: AppTab? = value("PHOTOS_BACKUP_TAB").flatMap(AppTab.init(rawValue:))

    enum Sheet: String {
        case onboarding, signin
    }

    static let requestedSheet: Sheet? = value("PHOTOS_BACKUP_SHOW").flatMap(Sheet.init(rawValue:))

    /// A photosbackup:// link run at launch through the same path as one
    /// opened from outside: `simctl openurl` stops at a confirmation alert
    /// that nothing scripted can answer (iOS 27 simulator, 2026-11-26).
    static let requestedLink: URL? = value("PHOTOS_BACKUP_OPEN").flatMap(URL.init(string:))

    /// A suite of its own when sandboxed; UserDefaults refuses the app's own
    /// bundle id as a suite name, so the suffix is needed either way.
    static let defaults: UserDefaults = {
        guard isSandboxed, let suite = UserDefaults(suiteName: bundleID + ".sandbox") else { return .standard }
        return suite
    }()

    /// The Mac app's scheme, so one credential format and one item layout
    /// serve both: "<bundleID>.auth-data", account = normalized address.
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

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "Development build"
        let build = info?["CFBundleVersion"] as? String
        return build.map { $0 == short ? short : "\(short) (\($0))" } ?? short
    }
}

/// The app's unified-log channels. Messages are never given a token, and
/// addresses only through Redactor (`.private` interpolation besides).
enum Log {
    static let app = Logger(subsystem: AppEnvironment.bundleID, category: "app")
    static let account = Logger(subsystem: AppEnvironment.bundleID, category: "account")
    static let photos = Logger(subsystem: AppEnvironment.bundleID, category: "photos")
    static let engine = Logger(subsystem: AppEnvironment.bundleID, category: "engine")
}
