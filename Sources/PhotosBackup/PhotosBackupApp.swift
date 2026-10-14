import PhotosBackupCore
import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    // Settings moved to the Settings window (Command-,); a stored "settings"
    // selection falls back to home.
    case home, albums, messages, activity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Overview"
        case .albums: "Albums"
        case .messages: "Messages"
        case .activity: "Activity"
        }
    }

    var symbol: String {
        switch self {
        case .home: "square.grid.2x2"
        case .albums: "rectangle.stack"
        case .messages: "message"
        case .activity: "clock.arrow.circlepath"
        }
    }
}

@main
struct PhotosBackupApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Photos Backup", id: "main") {
            RootView()
                .environment(model)
                .task {
                    delegate.model = model
                    await model.launch()
                    #if DEBUG
                    await Snapshots.runIfRequested(model)
                    #endif
                }
        }
        .defaultSize(width: 900, height: 760)

        Settings {
            SettingsView().environment(model)
        }

        MenuBarExtra {
            MenuContent().environment(model)
        } label: {
            Image(systemName: model.engine.isActive ? "arrow.up.circle.fill" : "arrow.up.circle")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A bridge that dies before reading its request must not take the
        // app down with SIGPIPE on the write.
        signal(SIGPIPE, SIG_IGN)
    }

    /// Keep backing up from the menu bar once the window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Quitting mid-batch stops the backup the way Stop does and waits for
    /// it, so what Google confirmed is recorded and no uploader outlives the
    /// app (an orphan would race the next launch on the same photos).
    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        let engine = model.engine
        model.cancelMessagesScan()
        guard engine.isActive else { return .terminateNow }
        engine.stop()
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(15)
            while engine.isActive, Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        BridgeProcess.terminateAll()
        // Items are recorded as they stream in but saved per batch; a quit
        // that outlasted the stop wait must not drop them.
        model?.saveState()
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    // Also settable at launch: `open -a "Photos Backup" --args -section albums`.
    @AppStorage("section", store: AppEnvironment.defaults) private var section: AppSection = .home

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: Binding($section)) { section in
                Label(section.title, systemImage: section.symbol).tag(section)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            switch section {
            case .home: HomeView(section: $section)
            case .albums: AlbumsView(section: $section)
            case .messages: MessagesView(section: $section)
            case .activity: ActivityView(section: $section)
            }
        }
        .frame(minWidth: 720, minHeight: 560)
        .sheet(isPresented: Binding(get: { model.showingSignIn }, set: { if !$0 { model.cancelSignIn() } })) {
            GoogleSignInSheet().environment(model)
        }
    }
}

struct MenuContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let engine = model.engine
        let summary = model.summary
        Text(engine.isActive ? "Backing up, \(engine.remaining) remaining" : "\(summary.backedUp) of \(summary.total) backed up")
        Divider()
        Button("Back Up Now") { model.startBackupNow() }
            .disabled(engine.isActive || !model.hasAuthData)
        Button("Back Up Messages Media") { model.backUpMessages() }
            .disabled(engine.isActive || model.isMessagesScanning || !model.hasAuthData || !model.settings.messagesMedia)
        Text(model.visibleMessagesStatus.menuTitle)
            .foregroundStyle(.secondary)
        if case .failed = model.visibleMessagesStatus {
            Button("Grant Full Disk Access…") { model.openFullDiskAccess() }
        }
        if engine.phase == .paused || engine.phase == .pausing {
            Button("Resume") { engine.resume() }
        } else if engine.phase == .running {
            Button("Pause After Current Uploads") { engine.pauseAfterCurrent() }
        }
        if engine.isActive || model.isMessagesScanning { Button("Stop") { model.stopBackup() } }
        Divider()
        Button("Refresh Now") { model.refreshNow() }
        Button("Open Photos Backup") {
            openWindow(id: "main")
            NSApp.activate()
        }
        Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
