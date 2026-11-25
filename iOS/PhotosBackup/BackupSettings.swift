import Foundation
import PhotosBackupCore

/// The iOS app's settings. Every key it shares with the Mac app's
/// BackupSettings (Sources/PhotosBackup/AppModel.swift) has the Mac's name,
/// meaning and default, and it is stored the same way: one JSON blob under
/// "settings" in the app's defaults (a suite of its own when sandboxed).
/// Mac-only keys (Dock, menu bar, Messages, the archive, parallel uploads)
/// are left out rather than carried unused.
struct BackupSettings: Codable, Equatable {
    var quality: UploadQuality = .original
    var mirrorAlbums = true
    var automatic = true
    var reuploadEdits = true

    var notifyWhenFinished = true
    var notifyAboutProblems = true
    var onboardingCompleted = false

    // When to hold uploads, in the Mac's names. On iPhone,
    // pauseOnExpensiveNetwork is "Wi-Fi only" (cellular and hotspots are
    // expensive paths) and pauseOnBattery is "Only while charging".
    var pauseOnExpensiveNetwork = true
    var pauseInLowDataMode = true
    var pauseOnBattery = false
    var pauseInLowPowerMode = true

    init() {}

    private enum CodingKeys: String, CodingKey {
        case quality, mirrorAlbums, automatic, reuploadEdits
        case notifyWhenFinished, notifyAboutProblems, onboardingCompleted
        case pauseOnExpensiveNetwork, pauseInLowDataMode, pauseOnBattery, pauseInLowPowerMode
    }

    /// Every key optional: a blob from an older build, or with a key added
    /// later, keeps what it has and takes the defaults for the rest.
    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try values.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        quality = try value(.quality, quality)
        mirrorAlbums = try value(.mirrorAlbums, mirrorAlbums)
        automatic = try value(.automatic, automatic)
        reuploadEdits = try value(.reuploadEdits, reuploadEdits)
        notifyWhenFinished = try value(.notifyWhenFinished, notifyWhenFinished)
        notifyAboutProblems = try value(.notifyAboutProblems, notifyAboutProblems)
        onboardingCompleted = try value(.onboardingCompleted, onboardingCompleted)
        pauseOnExpensiveNetwork = try value(.pauseOnExpensiveNetwork, pauseOnExpensiveNetwork)
        pauseInLowDataMode = try value(.pauseInLowDataMode, pauseInLowDataMode)
        pauseOnBattery = try value(.pauseOnBattery, pauseOnBattery)
        pauseInLowPowerMode = try value(.pauseInLowPowerMode, pauseInLowPowerMode)
    }

    var conditionFlags: ConditionFlags {
        ConditionFlags(pauseOnExpensiveNetwork: pauseOnExpensiveNetwork, pauseInLowDataMode: pauseInLowDataMode,
                       pauseOnBattery: pauseOnBattery, pauseInLowPowerMode: pauseInLowPowerMode)
    }

    private static let key = "settings"

    static func load() -> BackupSettings {
        guard let data = AppEnvironment.defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(BackupSettings.self, from: data) else { return BackupSettings() }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { AppEnvironment.defaults.set(data, forKey: Self.key) }
    }
}

extension UploadQuality {
    var settingsTitle: String {
        switch self {
        case .original: "Original, free"
        case .saver: "Storage saver"
        case .quota: "Original, counts against storage"
        }
    }

    var explanation: String {
        switch self {
        case .original: "Full-quality files, uploaded the way older Pixel phones do, so they don't use your Google storage. Google Photos may still label them Storage saver; the file size shows the real quality."
        case .saver: "Google reduces the file size. Doesn't use your Google storage."
        case .quota: "Full quality, counted against your Google storage like an upload from a new phone. Use this if the free option stops working."
        }
    }
}
