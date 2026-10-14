#if DEBUG
import AppKit
import PhotosBackupCore
import SwiftUI

/// Debug builds only: PHOTOS_BACKUP_SNAPSHOT_FIXTURE=1 (with
/// PHOTOS_BACKUP_SNAPSHOTS=<dir>) fills the model with a synthetic library,
/// account and runs, then renders every screen of the shell in light and
/// dark: the sidebar sections, the Overview in each state, every Settings
/// tab, every welcome page and the menu bar panel in each state. Nothing
/// here reads Photos, Messages, the keychain or the network, and every value
/// is made up.
///
/// The window draws itself (cacheDisplay), so no Screen Recording grant is
/// needed. Materials and Liquid Glass are composited by the window server
/// and so come out flat in these images; the layout, copy and colours are
/// what they show.
@MainActor
enum SnapshotFixture {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["PHOTOS_BACKUP_SNAPSHOT_FIXTURE"] == "1"
    }

    enum Scenario: String, CaseIterable {
        case upToDate = "up-to-date"
        case backingUp = "backing-up"
        case paused
        case waiting
        case attention
        case signedOut = "signed-out"
    }

    private static let appearances: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]

    /// scripts/e2e.py (photosbackup://debug/render): the live model, not a
    /// fixture, drawn the same way: the menu bar panel and every section.
    static func renderLive(_ model: AppModel, into output: URL) async {
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (name, appearance) in appearances {
            NSApp.appearance = NSAppearance(named: appearance)
            await render(PanelSnapshot().environment(model), size: nil, appearance: appearance,
                         to: output.appendingPathComponent("live-menubar-\(name).png"))
            for section in AppSection.allCases {
                await captureMain(section: section, to: output.appendingPathComponent("live-section-\(section.rawValue)-\(name).png"))
            }
        }
        NSApp.appearance = nil
    }

    static func run(_ model: AppModel, into output: URL) async {
        // Every setting from scratch: the sandbox's defaults suite is named
        // after the bundle id, not the sandbox folder, so another sandboxed
        // run may have left its own settings there.
        var settings = BackupSettings()
        settings.onboardingCompleted = true
        settings.messagesMedia = true
        settings.messagesArchive = true
        model.settings = settings
        model.iCloud.applyFixture(phase: .signedOut)
        recordRuns(model)
        let only = ProcessInfo.processInfo.environment["PHOTOS_BACKUP_SNAPSHOT_ONLY"].flatMap { $0.isEmpty ? nil : Set($0.split(separator: ",").map(String.init)) }
        func wanted(_ group: String) -> Bool { only?.contains(group) ?? true }

        for (name, appearance) in appearances {
            NSApp.appearance = NSAppearance(named: appearance)
            if wanted("sections") {
                apply(.backingUp, to: model)
                // 2026-10-15: Sidebar captures draw inactive controls gray; a form-only render keeps the setup guidance legible without foreground activation.
                model.iCloud.applyFixture(phase: .signedOut)
                await render(ICloudSourceView().environment(model).environment(\.controlActiveState, .active),
                             size: CGSize(width: 800, height: 760), appearance: appearance,
                             to: output.appendingPathComponent("icloud-setup-\(name).png"), activateWindow: false)
                model.iCloud.applyFixture(phase: .needs2FA, account: accountEmail)
                await render(ICloudSourceView().environment(model).environment(\.controlActiveState, .active),
                             size: CGSize(width: 800, height: 760), appearance: appearance,
                             to: output.appendingPathComponent("icloud-verification-\(name).png"), activateWindow: false)
                model.iCloud.applyFixture(phase: .signedOut)
                for section in AppSection.allCases {
                    await captureMain(section: section, to: output.appendingPathComponent("section-\(section.rawValue)-\(name).png"))
                }
                for scenario in Scenario.allCases where scenario != .backingUp {
                    apply(scenario, to: model)
                    await captureMain(section: .home, to: output.appendingPathComponent("overview-\(scenario.rawValue)-\(name).png"))
                }
                apply(.backingUp, to: model)
                await captureMain(section: .albums, query: "Ice", to: output.appendingPathComponent("section-albums-search-\(name).png"))
            }
            if wanted("settings") {
                apply(.upToDate, to: model)
                AppRouter.shared.mainWindow?.orderOut(nil)
                for tab in AutomationCommand.SettingsTab.allCases {
                    await captureSettings(tab: tab, to: output.appendingPathComponent("settings-\(tab.rawValue)-\(name).png"))
                }
                settingsWindow?.close()
            }
            if wanted("onboarding") {
                apply(.upToDate, to: model)
                for page in OnboardingPage.allCases {
                    await render(OnboardingView(page: page).environment(model), size: OnboardingView.size, appearance: appearance,
                                 to: output.appendingPathComponent("onboarding-\(page.rawValue + 1)-\(String(describing: page))-\(name).png"))
                }
            }
            if wanted("menubar") {
                for scenario in Scenario.allCases {
                    apply(scenario, to: model)
                    await render(PanelSnapshot().environment(model), size: nil, appearance: appearance,
                                 to: output.appendingPathComponent("menubar-\(scenario.rawValue)-\(name).png"))
                }
                let statuses = Scenario.allCases.map { scenario in
                    apply(scenario, to: model)
                    return model.status
                }
                await render(LabelStrip(statuses: statuses), size: nil, appearance: appearance,
                             to: output.appendingPathComponent("menubar-labels-\(name).png"))
            }
        }
        NSApp.appearance = nil
        if wanted("links") { checkLinks(model, into: output) }
    }

    // MARK: - The made-up library

    private static let accountEmail = "jane.appleseed@example.com"

    private static func album(_ id: String, _ title: String, _ kind: AlbumKind, _ symbol: String, count: Int, offset: Int = 0) -> LibraryAlbum {
        LibraryAlbum(snapshot: AlbumSnapshot(id: id, title: title, kind: kind, assetIDs: (offset..<offset + count).map { "fixture-\($0)" }),
                     symbol: symbol)
    }

    private static let albums: [LibraryAlbum] = [
        album(PhotoLibrary.allPhotosID, "All Photos", .allPhotos, "photo.on.rectangle.angled", count: 48_213),
        album("smart-favorites", "Favorites", .smart, "heart", count: 1_342, offset: 100),
        album("smart-recents", "Recently Added", .smart, "clock", count: 214, offset: 47_999),
        album("smart-videos", "Videos", .smart, "video", count: 2_861, offset: 3_000),
        album("smart-selfies", "Selfies", .smart, "person.crop.square", count: 611, offset: 9_000),
        album("smart-live", "Live Photos", .smart, "livephoto", count: 7_420, offset: 12_000),
        album("smart-screenshots", "Screenshots", .smart, "camera.viewfinder", count: 3_904, offset: 20_000),
        album("user-iceland", "Iceland, June 2025", .user, "rectangle.stack", count: 812, offset: 30_000),
        album("user-family", "Family", .user, "rectangle.stack", count: 2_506, offset: 31_000),
        album("user-wedding", "Wedding: Priya and Arjun, Udaipur, the whole weekend including the sangeet and the after-party", .user,
              "rectangle.stack", count: 1_977, offset: 34_000),
        album("user-recipes", "Recipes", .user, "rectangle.stack", count: 96, offset: 36_500),
        album("user-drawings", "Kids' drawings", .user, "rectangle.stack", count: 143, offset: 36_700),
        album("user-ice-hockey", "Ice hockey league", .user, "rectangle.stack", count: 320, offset: 37_000),
    ]

    private static let selected: Set<String> = [PhotoLibrary.allPhotosID, "smart-favorites", "user-iceland", "user-family", "user-wedding", "user-recipes"]

    /// Everything selected backed up except `missing` items, newest first.
    private static func state(missing: Int) -> BackupState {
        var state = BackupState()
        state.selectedAlbumIDs = selected
        state.accountEmail = accountEmail
        var ids = Set<String>()
        for album in albums where selected.contains(album.id) { ids.formUnion(album.snapshot.assetIDs) }
        let sorted = ids.sorted()
        for id in sorted.dropFirst(missing) {
            state.recordUpload(assetID: id, mediaKey: "fixture-key", existing: false)
        }
        state.recordAlbum("user-iceland", googleAlbumID: "fixture-album-1", added: [])
        state.recordAlbum("user-family", googleAlbumID: "fixture-album-2", added: [])
        return state
    }

    private static func item(_ name: String, _ status: ActivityItem.Status, size: Int64?, minutesAgo: Double = 1) -> ActivityItem {
        ActivityItem(id: "fixture-item-\(name)", filename: name, size: size, status: status, detail: nil,
                     date: Date().addingTimeInterval(-minutesAgo * 60))
    }

    private static var finishedItems: [ActivityItem] {
        [item("IMG_4820.HEIC", .uploaded, size: 2_412_331),
         item("IMG_4819.MOV", .uploaded, size: 48_901_220, minutesAgo: 2),
         item("IMG_4818.HEIC", .existing, size: 1_904_118, minutesAgo: 2),
         item("Screenshot 2026-10-12 at 09.41.22.png", .uploaded, size: 812_004, minutesAgo: 3)]
    }

    private static var failedItems: [ActivityItem] {
        [item("IMG_3301.HEIC", .failed("Google could not process this file (400)"), size: 3_100_221, minutesAgo: 30),
         item("IMG_3302.MOV", .failed("No answer from the uploader"), size: 101_220_004, minutesAgo: 31),
         item("DSC_0042.JPG", .failed("The file could not be read from Photos"), size: nil, minutesAgo: 31)]
    }

    static func apply(_ scenario: Scenario, to model: AppModel) {
        // A stray key press while a fixture window is key can flip a switch.
        model.settings.automatic = true
        let account: AccountStatus = scenario == .signedOut ? .missing : .connected(email: accountEmail)
        model.applyFixture(albums: albums, account: account, runtime: "gpmc 0.9.0 on Python 3.13.15",
                           messages: .ready(found: 0, skipped: 12, partial: false))
        let engine = model.engine
        let lastRun = Date().addingTimeInterval(-6 * 60)
        if scenario != .signedOut {
            model.settings.messagesArchive = true
            model.archive.applyFixture(overview: archiveOverview, status: .finished(Date().addingTimeInterval(-3 * 3600)),
                                       transcripts: [archiveOverview.conversations[0].id: transcript])
        }
        switch scenario {
        case .upToDate:
            model.state = state(missing: 0)
            engine.applyFixture(activity: finishedItems, runTotal: 0, runDone: 0, phase: .idle, lastRun: lastRun)
        case .backingUp:
            model.state = state(missing: 1_234)
            let current = item("IMG_4821_long_name_from_a_camera_import_2026-10-14.HEIC", .uploading(0.42), size: 6_210_004, minutesAgo: 0)
            engine.applyFixture(activity: [current, item("IMG_4822.HEIC", .hashing, size: nil, minutesAgo: 0)] + finishedItems + failedItems.prefix(1),
                                runTotal: 2_960, runDone: 1_726, phase: .running, lastRun: lastRun)
        case .paused:
            model.state = state(missing: 640)
            engine.applyFixture(activity: finishedItems, runTotal: 1_240, runDone: 600, phase: .paused, lastRun: lastRun)
        case .waiting:
            model.state = state(missing: 212)
            engine.applyFixture(activity: finishedItems, runTotal: 212, runDone: 0, phase: .waiting, lastRun: lastRun, waitReason: .onBattery)
        case .attention:
            model.state = state(missing: 3)
            engine.applyFixture(activity: failedItems + finishedItems, runTotal: 0, runDone: 0, phase: .idle, lastRun: lastRun,
                                lastError: AppModel.describe(.storageFull, "quota exceeded"))
        case .signedOut:
            model.state = state(missing: 48_213)
            model.state.accountEmail = nil
            engine.applyFixture(activity: [], runTotal: 0, runDone: 0, phase: .idle, lastRun: nil)
        }
    }

    // Made-up people and words: the archive fixture never reads Messages.
    private static let archiveOverview: MessagesArchiveOverview = {
        let now = Date()
        func conversation(_ id: String, _ title: String, _ people: [String], group: Bool, messages: Int, attachments: Int, hoursAgo: Double) -> ArchivedConversation {
            ArchivedConversation(id: id, title: title, participants: people, isGroup: group, service: "iMessage", messageCount: messages,
                                 attachmentCount: attachments, lastMessageDate: now.addingTimeInterval(-hoursAgo * 3600), relativePath: "Conversations/\(id)")
        }
        let conversations = [
            conversation("chat-family", "Family", ["Mom", "Dad", "Riya"], group: true, messages: 18_204, attachments: 1_312, hoursAgo: 0.4),
            conversation("chat-jane", "Jane Appleseed", ["Jane Appleseed"], group: false, messages: 6_120, attachments: 214, hoursAgo: 2),
            conversation("chat-trip", "Iceland trip", ["Arjun", "Priya", "Sam", "Lee"], group: true, messages: 2_907, attachments: 388, hoursAgo: 30),
            conversation("chat-sam", "Sam Lee", ["Sam Lee"], group: false, messages: 912, attachments: 12, hoursAgo: 80),
            conversation("chat-bank", "+1 (555) 010-2030", ["+1 (555) 010-2030"], group: false, messages: 64, attachments: 0, hoursAgo: 200),
        ]
        return MessagesArchiveOverview(conversations: conversations, messageCount: 28_207, attachmentCount: 1_926, missingAttachmentCount: 140,
                                       archiveBytes: 2_148_000_000, lastArchived: now.addingTimeInterval(-3 * 3600), databaseSnapshots: 7)
    }()

    private static let transcript: [ArchivedMessage] = {
        let start = Date().addingTimeInterval(-26 * 3600)
        let lines: [(Bool, String, String)] = [
            (false, "Mom", "Did everyone get home safe?"),
            (true, "", "Yes! Landed an hour ago"),
            (false, "Riya", "Same here. Sending the photos from the beach tonight"),
            (false, "Dad", "That dinner was the best part"),
            (true, "", "Agreed. Booking the same place for next year"),
        ]
        return lines.enumerated().map { index, line in
            ArchivedMessage(id: "m\(index)", rowID: Int64(index), date: start.addingTimeInterval(Double(index) * 420), isFromMe: line.0,
                            sender: line.0 ? nil : line.1, senderName: line.0 ? "Me" : line.1, service: "iMessage", text: line.2,
                            reactions: index == 3 ? [ArchivedReaction(kind: "love", emoji: "\u{2764}\u{FE0F}", sender: nil, senderName: "Me", isFromMe: true, date: nil)] : [])
        }
    }()

    /// The history and timeline are the diagnostics piece's; these go
    /// through its public recording calls, into the sandbox only.
    private static func recordRuns(_ model: AppModel) {
        let now = Date()
        let runs = [
            RunRecord(kind: .photos, trigger: .timer, startedAt: now.addingTimeInterval(-26 * 3600), finishedAt: now.addingTimeInterval(-25.8 * 3600),
                      uploaded: 24, existing: 3, failed: 0, bytes: 182_000_000, outcome: .completed, conditions: "Wi-Fi, on power"),
            RunRecord(kind: .messagesArchive, trigger: .schedule, startedAt: now.addingTimeInterval(-3 * 3600), finishedAt: now.addingTimeInterval(-2.9 * 3600),
                      uploaded: 1_203, outcome: .completed),
            RunRecord(kind: .photos, trigger: .manual, startedAt: now.addingTimeInterval(-7 * 60), finishedAt: now.addingTimeInterval(-6 * 60),
                      uploaded: 112, existing: 9, failed: 3, bytes: 912_000_000, outcome: .completed, conditions: "Wi-Fi, on power"),
        ]
        runs.forEach(model.diagnostics.record)
    }

    // MARK: - Capturing

    private static func settle(_ seconds: Double = 0.8) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private static func write(_ view: NSView, to url: URL) {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// The real main window, with its toolbar and sidebar.
    private static func captureMain(section: AppSection, query: String? = nil, to url: URL) async {
        AppRouter.shared.openMain(section: section)
        await settle(query == nil ? 0.9 : 0.4)
        guard let window = AppRouter.shared.mainWindow else { return }
        window.setContentSize(NSSize(width: 1000, height: 760))
        if let query, let field = searchField(in: window.contentView?.superview) {
            field.stringValue = query
            field.sendAction(field.action, to: field.target)
            NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: field)
            await settle(0.8)
        }
        guard let frame = window.contentView?.superview ?? window.contentView else { return }
        write(frame, to: url)
        if query != nil, let field = searchField(in: frame) {
            field.stringValue = ""
            NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: field)
        }
    }

    private static func searchField(in view: NSView?) -> NSSearchField? {
        guard let view else { return nil }
        if let field = view as? NSSearchField { return field }
        for child in view.subviews { if let field = searchField(in: child) { return field } }
        return nil
    }

    private static var settingsWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.contains("Settings") == true || $0.title.hasPrefix("General") || $0.title.hasSuffix("Settings") }
    }

    /// The real Settings window, tab by tab.
    private static func captureSettings(tab: AutomationCommand.SettingsTab, to url: URL) async {
        AppRouter.shared.openSettings(tab)
        await settle(1.0)
        let window = NSApp.keyWindow.flatMap { $0.identifier?.rawValue.hasPrefix("main") == true ? nil : $0 } ?? settingsWindow
        guard let window, let frame = window.contentView?.superview ?? window.contentView else { return }
        write(frame, to: url)
    }

    /// Anything else, in an offscreen window of its own.
    private static func render(_ view: some View, size: CGSize?, appearance: NSAppearance.Name, to url: URL,
                               activateWindow: Bool = true) async {
        // The window background is drawn by the frame view, which a
        // content view capture leaves out.
        let hosting = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        let fitting = size ?? hosting.fittingSize
        // Off every screen but key, so controls draw as in an active panel
        // (an inactive window greys prominent buttons and progress bars).
        let origin = NSPoint(x: (NSScreen.main?.frame.maxX ?? 4000) + 2000, y: 0)
        let window = KeyableWindow(contentRect: NSRect(origin: origin, size: fitting), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.backgroundColor = .windowBackgroundColor
        window.contentView = hosting
        if activateWindow {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderBack(nil)
        }
        await settle(0.6)
        if size == nil { window.setContentSize(hosting.fittingSize) }
        await settle(0.2)
        write(hosting, to: url)
        window.close()
    }

    // MARK: - Links

    /// The URL handler, driven directly: what each link changed, in links.txt.
    private static func checkLinks(_ model: AppModel, into output: URL) {
        guard let delegate = AppDelegate.current else {
            try? "no app delegate\n".write(to: output.appendingPathComponent("links.txt"), atomically: true, encoding: .utf8)
            return
        }
        apply(.backingUp, to: model)
        var lines: [String] = []
        for link in ["photosbackup://open/activity", "photosbackup://open/albums", "photosbackup://settings/advanced",
                     "photosbackup://pause", "photosbackup://resume", "photosbackup://nonsense"] {
            delegate.handle(URL(string: link)!)
            let section = AppEnvironment.defaults.string(forKey: "section") ?? "-"
            let tab = AppEnvironment.defaults.string(forKey: AppRouter.settingsTabKey) ?? "-"
            lines.append("\(link) -> section=\(section) settingsTab=\(tab) phase=\(model.engine.phase)")
        }
        try? (lines.joined(separator: "\n") + "\n").write(to: output.appendingPathComponent("links.txt"), atomically: true, encoding: .utf8)
    }
}

private final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

/// The panel as the menu bar shows it: on the window background, rounded.
private struct PanelSnapshot: View {
    var body: some View {
        MenuBarPanel()
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(16)
    }
}

/// Every state's menu bar item side by side, on a menu-bar-like strip.
private struct LabelStrip: View {
    let statuses: [MenuBarStatus]

    var body: some View {
        HStack(spacing: 18) {
            ForEach(Array(statuses.enumerated()), id: \.offset) { _, status in
                VStack(spacing: 6) {
                    HStack(spacing: 4) {
                        Image(systemName: status.symbol)
                        if status.kind == .backingUp { Text("58%").monospacedDigit() }
                    }
                    .font(.system(size: 13))
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(.bar, in: RoundedRectangle(cornerRadius: 5))
                    Text(status.headline).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(width: 130)
            }
        }
        .padding(16)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
#endif
