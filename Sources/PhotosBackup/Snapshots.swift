#if DEBUG
import AppKit
import PhotosBackupCore
import WebKit

/// Debug builds only, run by scripts/snapshots.sh: with
/// PHOTOS_BACKUP_SNAPSHOTS=<dir> the app renders its own window, once per
/// section, into <dir>/<section>.png and quits. The window draws itself, so
/// this needs no Screen Recording permission and never captures anything but
/// the app.
///
/// PHOTOS_BACKUP_SNAPSHOT_AUTH=<auth_data> first saves it through the same
/// path as Settings' Save button (keychain, then an account check through the
/// bridge) and removes it again before quitting. Use a throwaway value: it
/// passes through the environment, which the real app never does.
///
/// Both refuse to run unless the bundle id ends in ".snapshots", so this can
/// never touch the real app's keychain item, state or settings, and snapshot
/// runs never start a backup.
enum Snapshots {
    static let bundleSuffix = ".snapshots"
    /// The sign-in sheet's web view, for the last snapshot.
    @MainActor static weak var signInWebView: WKWebView?

    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["PHOTOS_BACKUP_SNAPSHOTS"] != nil
    }

    @MainActor
    static func runIfRequested(_ model: AppModel) async {
        let env = ProcessInfo.processInfo.environment
        guard let directory = env["PHOTOS_BACKUP_SNAPSHOTS"] else { return }
        guard Bundle.main.bundleIdentifier?.hasSuffix(bundleSuffix) == true else {
            FileHandle.standardError.write(Data("snapshots need a bundle id ending in \(bundleSuffix); use scripts/snapshots.sh\n".utf8))
            NSApp.terminate(nil)
            return
        }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let uiOnly = env["PHOTOS_BACKUP_SNAPSHOT_UI_ONLY"] == "1"
        let auth = uiOnly ? nil : env["PHOTOS_BACKUP_SNAPSHOT_AUTH"].flatMap { $0.isEmpty ? nil : $0 }
        if let auth { await model.connect(pasted: auth) }

        try? await Task.sleep(for: .seconds(2))
        for section in AppSection.allCases {
            AppEnvironment.defaults.set(section.rawValue, forKey: "section")
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
        if !uiOnly { await snapshotSignIn(model, into: output) }
        if auth != nil { model.removeAuthData() }
        NSApp.terminate(nil)
    }

    /// Opens the sign-in sheet and records what Google served it: the page
    /// as the web view renders it (window caching leaves web content blank)
    /// and a line of what is on it, so a refusal ("This browser or app may
    /// not be secure") would show up in signin.txt.
    @MainActor
    private static func snapshotSignIn(_ model: AppModel, into output: URL) async {
        model.beginSignIn()
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(500))
            if let webView = signInWebView, !webView.isLoading, webView.url != nil { break }
        }
        try? await Task.sleep(for: .seconds(3))
        guard let webView = signInWebView else {
            try? "no sign-in web view\n".write(to: output.appendingPathComponent("signin.txt"), atomically: true, encoding: .utf8)
            model.cancelSignIn()
            return
        }
        let probe = "[location.host + location.pathname, document.title, document.querySelector('input[type=email]') ? 'email field' : 'NO email field', document.body.innerText.replace(/\\s+/g, ' ').slice(0, 400)].join(' | ')"
        let text = (try? await webView.evaluateJavaScript(probe) as? String) ?? "probe failed"
        try? (text + "\n").write(to: output.appendingPathComponent("signin.txt"), atomically: true, encoding: .utf8)
        if let image = try? await webView.takeSnapshot(configuration: nil),
           let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: output.appendingPathComponent("signin.png"))
        }
        await plantFakeCookie(in: webView, model, into: output)
        model.cancelSignIn()
        // A terminate sent while the sheet is still animating closed was
        // ignored (the run outlived its 60 s budget with every file written).
        try? await Task.sleep(for: .seconds(1.5))
    }

    /// Everything after Google's page short of a real account: a made-up
    /// oauth_token cookie must reach the exchange, which Google refuses, and
    /// the refusal must reach the sheet. The outcome goes to signin.txt.
    @MainActor
    private static func plantFakeCookie(in webView: WKWebView, _ model: AppModel, into output: URL) async {
        let cookie = HTTPCookie(properties: [.name: GoogleSignIn.cookieName, .value: "oauth2_4/snapshot-fake-0000000000",
                                             .domain: ".google.com", .path: "/", .secure: "TRUE"])!
        await webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
        let started = ContinuousClock.now
        for _ in 0..<160 {
            try? await Task.sleep(for: .milliseconds(250))
            if case .failed = model.connectState { break }
        }
        let outcome = "fake cookie -> \(model.connectState) after \(ContinuousClock.now - started); stored account: \(model.hasAuthData)\n"
        if let handle = try? FileHandle(forWritingTo: output.appendingPathComponent("signin.txt")) {
            handle.seekToEndOfFile()
            handle.write(Data(outcome.utf8))
            try? handle.close()
        }
        if let sheet = NSApp.windows.first(where: { $0.isSheet && $0.isVisible }), let view = sheet.contentView?.superview ?? sheet.contentView,
           let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("signin-refused.png"))
        }
    }
}
#endif
