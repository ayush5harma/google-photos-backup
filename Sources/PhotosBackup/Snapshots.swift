#if DEBUG
import AppKit

/// Debug builds only: with PHOTOS_BACKUP_SNAPSHOTS=<dir> the app renders its
/// own window, once per section, into <dir>/<section>.png and quits. The
/// window draws itself, so this needs no Screen Recording permission and never
/// captures anything but the app.
///
/// PHOTOS_BACKUP_SNAPSHOT_AUTH=<auth_data> first saves it through the same
/// path as Settings' Save button (keychain, then an account check through the
/// bridge) and removes it again before quitting. An item made by the
/// `security` tool cannot stand in: its partition list makes the keychain
/// ask the user before any other app may read it.
enum Snapshots {
    @MainActor
    static func runIfRequested(_ model: AppModel) async {
        let env = ProcessInfo.processInfo.environment
        guard let directory = env["PHOTOS_BACKUP_SNAPSHOTS"] else { return }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let auth = env["PHOTOS_BACKUP_SNAPSHOT_AUTH"]
        if let auth { await model.saveAuthData(auth) }

        try? await Task.sleep(for: .seconds(2))
        for section in AppSection.allCases {
            UserDefaults.standard.set(section.rawValue, forKey: "section")
            try? await Task.sleep(for: .seconds(1.5))
            // The frame view, not the content view: the window's own
            // background is drawn there.
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.title != "Item-0" }),
                  let view = window.contentView?.superview ?? window.contentView else { continue }
            window.setContentSize(NSSize(width: 900, height: 1100))
            view.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .seconds(0.5))
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("\(section.rawValue).png"))
        }
        if auth != nil { model.removeAuthData() }
        NSApp.terminate(nil)
    }
}
#endif
