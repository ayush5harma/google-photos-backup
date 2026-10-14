#if DEBUG
import AppKit
import Foundation
import PhotosBackupCore
import ServiceManagement
import UserNotifications

/// Debug builds only, and only in a PHOTOS_BACKUP_SANDBOX run: the
/// photosbackup://debug/... links scripts/e2e.sh drives the app with. They
/// read state out and set up a scenario; every real action goes through the
/// public photosbackup:// links, the same way a person's Shortcut would.
///
///   debug/state?out=<file>[&settle=1]  the model as JSON (ids and counts only)
///   debug/connect?auth=<value>      Settings' paste path (keychain + check-auth)
///   debug/settings?<key>=<value>    one BackupSettings field (JSON value)
///   debug/select?albums=<id,id>     the albums to back up
///   debug/select?smallest=<min>-<max>  the smallest user album with that many items
///   debug/conditions?network=online|offline|expensive|constrained|real&power=ac|battery|lowpower|real
///   debug/render?dir=<dir>         the live menu bar panel and sections as PNGs
///   debug/login?on=1|0             Launch at login, as the General tab does
///   debug/quit
///
/// The state file never carries an album title, a file name from the
/// library, message text or a credential: the harness's log is safe to keep.
enum E2EHooks {
    /// scripts/e2e.py marks its copy of the bundle (Info.plist
    /// PhotosBackupE2ECopy). Such a copy has the real bundle id, so if
    /// LaunchServices ever starts it without the sandbox (a link that
    /// arrived after the test copy quit, a login item left behind) it would
    /// back up with the real account: measured 2026-10-14, one did. It quits
    /// before reading anything instead.
    static func refuseUnsandboxedCopy() {
        guard Bundle.main.object(forInfoDictionaryKey: "PhotosBackupE2ECopy") != nil, !AppEnvironment.isSandboxed else { return }
        FileHandle.standardError.write(Data("e2e copy started without PHOTOS_BACKUP_SANDBOX; quitting\n".utf8))
        exit(0)
    }

    /// A copy started straight from a shell (to inherit its Full Disk
    /// Access) is not the instance LaunchServices sends links to; it starts
    /// a second copy instead. Such a run reads links from
    /// <sandbox>/inbox/*.url, in name order, and handles them exactly as if
    /// they had arrived as Apple events.
    @MainActor private static var inboxTimer: Timer?

    @MainActor
    static func startInbox(_ delegate: AppDelegate) {
        guard inboxTimer == nil, let sandbox = AppEnvironment.sandbox else { return }
        let inbox = sandbox.appendingPathComponent("inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        inboxTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
            MainActor.assumeIsolated {
                let files = (try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)) ?? []
                for file in files.filter({ $0.pathExtension == "url" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    let text = (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
                    try? FileManager.default.removeItem(at: file)
                    if let text, let url = URL(string: text) { delegate.handle(url) }
                }
            }
        }
    }

    @MainActor
    static func handle(_ url: URL, model: AppModel) -> Bool {
        guard url.host?.lowercased() == "debug" else { return false }
        guard AppEnvironment.isSandboxed else {
            model.log(.app, "Ignored a debug link outside a sandboxed run", problem: false)
            return true
        }
        let verb = url.pathComponents.dropFirst().first?.lowercased() ?? ""
        let query = Dictionary(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .compactMap { item in item.value.map { (item.name, $0) } } ?? [], uniquingKeysWith: { $1 })
        switch verb {
        case "state":
            guard let out = query["out"] else { return true }
            Task { @MainActor in
                // settle=1: read after the app has finished reacting to the
                // delivery of this very link (the Dock policy, for one).
                if query["settle"] == "1" { try? await Task.sleep(for: .seconds(1.2)) }
                await writeState(model, to: URL(fileURLWithPath: out))
            }
        case "connect":
            guard let auth = query["auth"] else { return true }
            Task { @MainActor in await model.connect(pasted: auth) }
        case "settings":
            applySettings(query, model: model)
        case "select":
            select(query, model: model)
        case "conditions":
            model.conditions.simulate(network: query["network"], power: query["power"])
        case "render":
            guard let dir = query["dir"] else { return true }
            Task { @MainActor in await SnapshotFixture.renderLive(model, into: URL(fileURLWithPath: dir)) }
        case "login":
            // The same call the General tab's switch makes.
            LoginItem.shared.setEnabled(query["on"] == "1")
        case "quit":
            NSApp.terminate(nil)
        default:
            model.log(.app, "Unknown debug link \(verb)")
        }
        return true
    }

    @MainActor
    private static func applySettings(_ query: [String: String], model: AppModel) {
        guard var object = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(model.settings))) as? [String: Any] else { return }
        for (key, raw) in query {
            // Values are JSON (true, 3, "text"); a bare word is a string.
            let value = (try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: .fragmentsAllowed)) ?? raw
            object[key] = value is NSNull ? nil : value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let settings = try? JSONDecoder().decode(BackupSettings.self, from: data) else { return }
        model.settings = settings
    }

    @MainActor
    private static func select(_ query: [String: String], model: AppModel) {
        if let list = query["albums"] {
            model.state.selectedAlbumIDs = Set(list.split(separator: ",").map(String.init))
        } else if let range = query["smallest"]?.split(separator: "-").compactMap({ Int($0) }), range.count == 2 {
            let candidate = model.albums
                .filter { $0.snapshot.kind == .user && (range[0]...range[1]).contains($0.snapshot.assetIDs.count) }
                .min { $0.snapshot.assetIDs.count < $1.snapshot.assetIDs.count }
            model.state.selectedAlbumIDs = candidate.map { [$0.id] } ?? []
        }
        model.saveState()
    }

    @MainActor
    private static func writeState(_ model: AppModel, to url: URL) async {
        let engine = model.engine
        let summary = model.summary
        let archive = model.archive
        let notifications = await UNUserNotificationCenter.current().deliveredNotifications()
        let authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        var archiveStatus: String
        switch archive.status {
        case .off: archiveStatus = "off"
        case .idle: archiveStatus = "idle"
        case let .running(phase, done, total): archiveStatus = "running \(phase) \(done)/\(total)"
        case let .finished(date): archiveStatus = "finished \(date.ISO8601Format())"
        case .needsFullDiskAccess: archiveStatus = "needsFullDiskAccess"
        case let .failed(message): archiveStatus = "failed \(message)"
        }
        let overview = archive.overview
        let state: [String: Any?] = [
            "pid": ProcessInfo.processInfo.processIdentifier,
            "sandbox": AppEnvironment.sandbox?.path,
            "phase": "\(engine.phase)",
            "waitReason": engine.waitReason?.title,
            "runTotal": engine.runTotal,
            "runDone": engine.runDone,
            "failedCount": engine.failedCount,
            "lastError": engine.lastError,
            "lastRun": engine.lastRun?.ISO8601Format(),
            "activity": engine.activity.prefix(200).map { item in
                ["id": item.id, "status": item.status.label, "finished": item.status.isFinished,
                 "failed": { if case .failed = item.status { true } else { false } }(), "detail": item.detail as Any]
            },
            "summary": ["backedUp": summary.backedUp, "pending": summary.pending, "selectedAlbums": summary.selectedAlbums],
            "uploadedCount": model.state.uploaded.count,
            "uploadedIDs": Array(model.state.uploaded.keys).sorted(),
            "mirrors": model.state.mirrors.mapValues { ["googleAlbumID": $0.googleAlbumID as Any, "added": $0.addedAssetIDs.count] },
            "selectedAlbumIDs": Array(model.state.selectedAlbumIDs).sorted(),
            "albums": model.albums.map { ["id": $0.id, "kind": $0.snapshot.kind.rawValue, "count": $0.snapshot.assetIDs.count] },
            "albumsLoaded": model.albumsLoaded,
            "photosAuthorized": model.library.isAuthorized,
            "account": "\(model.account)",
            "hasAuthData": model.hasAuthData,
            "messagesStatus": model.visibleMessagesStatus.menuTitle,
            "archiveStatus": archiveStatus,
            "archiveFolder": archive.folder.path,
            "archiveOverview": overview.map { ["conversations": $0.conversations.count, "messages": $0.messageCount,
                                              "attachments": $0.attachmentCount, "missing": $0.missingAttachmentCount,
                                              "bytes": $0.archiveBytes, "snapshots": $0.databaseSnapshots,
                                              "lastArchived": $0.lastArchived?.ISO8601Format() as Any] },
            "conditions": model.conditions.summary,
            "blocking": model.conditions.blocking(for: model.settings)?.title,
            "runs": model.diagnostics.runs.prefix(20).map { run in
                ["kind": run.kind.rawValue, "trigger": run.trigger.rawValue, "uploaded": run.uploaded, "existing": run.existing,
                 "failed": run.failed, "outcome": run.outcome.map { "\($0)" } as Any, "finished": run.finishedAt != nil]
            },
            "events": model.diagnostics.events.prefix(60).map { ["category": $0.category.rawValue, "message": $0.message, "problem": $0.isProblem] },
            "settings": (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(model.settings))) as Any,
            "activationPolicy": NSApp.activationPolicy() == .regular ? "regular" : NSApp.activationPolicy() == .accessory ? "accessory" : "prohibited",
            "loginItem": "\(LoginItem.shared.state)",
            "loginItemError": LoginItem.shared.error,
            "notificationAuthorization": authorization.rawValue,
            "deliveredNotifications": notifications.map { ["title": $0.request.content.title, "body": $0.request.content.body] },
            "windows": NSApp.windows.filter(\.isVisible).map(\.title),
        ]
        let clean = state.compactMapValues { $0 }
        guard let data = try? JSONSerialization.data(withJSONObject: clean, options: [.prettyPrinted, .sortedKeys]) else { return }
        let temporary = url.appendingPathExtension("tmp")
        try? data.write(to: temporary)
        _ = try? FileManager.default.replaceItemAt(url, withItemAt: temporary)
        if !FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.moveItem(at: temporary, to: url) }
    }
}
#endif
