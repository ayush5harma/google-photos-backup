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

    init(_ section: AutomationCommand.Section) {
        switch section {
        case .overview: self = .home
        case .albums: self = .albums
        case .messages: self = .messages
        case .activity: self = .activity
        }
    }
}

@main
struct PhotosBackupApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        Window("Photos Backup", id: "main") {
            RootView()
                .environment(delegate.model)
        }
        .defaultSize(width: 960, height: 720)
        .commands { BackupCommands(model: delegate.model) }

        Settings {
            SettingsView().environment(delegate.model)
        }

        MenuBarExtra {
            MenuBarPanel().environment(delegate.model)
        } label: {
            MenuBarLabel().environment(delegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Opens the app's windows from places SwiftUI's environment does not
/// reach: the URL handler, notifications, the menu bar panel. The actions
/// are captured from the first view that has them.
@MainActor
@Observable
final class AppRouter {
    static let shared = AppRouter()

    @ObservationIgnored var openWindowAction: OpenWindowAction?
    @ObservationIgnored var openSettingsAction: OpenSettingsAction?
    /// The welcome guide, asked for again from Settings.
    var showingWelcome = false

    static let settingsTabKey = "settingsTab"

    func openMain(section: AppSection? = nil) {
        if let section { AppEnvironment.defaults.set(section.rawValue, forKey: "section") }
        // A closed SwiftUI window can linger in NSApp.windows; only a shown or
        // minimised one is brought forward, anything else goes through
        // SwiftUI so the scene is rebuilt properly.
        if let window = mainWindow, window.isVisible || window.isMiniaturized {
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
        } else if let openWindowAction {
            openWindowAction(id: "main")
        } else {
            mainWindow?.makeKeyAndOrderFront(nil)
        }
        // A menu-bar-only app is never frontmost by itself.
        NSApp.activate()
    }

    func openSettings(_ tab: AutomationCommand.SettingsTab? = nil) {
        if let tab { AppEnvironment.defaults.set(tab.rawValue, forKey: Self.settingsTabKey) }
        if let openSettingsAction {
            openSettingsAction()
        } else {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
        NSApp.activate()
    }

    func showWelcome() {
        showingWelcome = true
        openMain()
    }

    var mainWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Owned here rather than by the App so launch, links and notifications
    /// work before (and without) any window.
    let model = AppModel()
    /// SwiftUI wraps the delegate, so NSApp.delegate is not this object.
    private(set) static weak var current: AppDelegate?

    func applicationWillFinishLaunching(_ notification: Notification) {
        Self.current = self
        NSApp.setActivationPolicy(model.settings.showInDock ? .regular : .accessory)
        // Registered before launch finishes so a link that launched the app
        // is delivered too.
        registerURLHandler()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A bridge that dies before reading its request must not take the
        // app down with SIGPIPE on the write.
        signal(SIGPIPE, SIG_IGN)
        // Again, in case the scene setup claimed the event since.
        registerURLHandler()
        model.notifier.onOpen = { section in AppRouter.shared.openMain(section: section) }
        model.notifier.activate()
        LoginItem.shared.refresh()
        Task {
            await model.launch()
            #if DEBUG
            await Snapshots.runIfRequested(model)
            #endif
        }
    }

    /// Dock icon or Finder double-click with no window open.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { AppRouter.shared.openMain() }
        return true
    }

    /// Keep backing up from the menu bar once the window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Quitting mid-batch stops the backup the way Stop does and waits for
    /// it, so what Google confirmed is recorded and no uploader outlives the
    /// app (an orphan would race the next launch on the same photos).
    ///
    /// The wait happens with the quit cancelled, then quits again: under
    /// .terminateLater AppKit runs the loop in its modal panel mode, which
    /// does not drain the main queue, so neither the wait nor the run it
    /// waits for ever progressed (measured 2026-10-14: still alive after
    /// 4 minutes, no main-actor task ran).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let engine = model.engine
        model.cancelMessagesScan()
        model.archive.cancel()
        guard engine.isActive, !quitting else { return .terminateNow }
        quitting = true
        engine.stop()
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(15)
            while engine.isActive, Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
            sender.terminate(nil)
        }
        return .terminateCancel
    }

    private var quitting = false

    func applicationWillTerminate(_ notification: Notification) {
        BridgeProcess.terminateAll()
        // Items are recorded as they stream in but saved per batch; a quit
        // that outlasted the stop wait must not drop them.
        model.saveState()
    }

    // MARK: - photosbackup:// links

    private func registerURLHandler() {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleGetURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: string) else { return }
        handle(url)
    }

    func handle(_ url: URL) {
        guard let command = AutomationCommand(url: url) else {
            // Scheme and verb only: the rest of a link can carry anything.
            model.log(.app, "Ignored a link it does not know: \(url.scheme ?? "")://\(url.host ?? "")")
            return
        }
        model.perform(command)
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismissWindow) private var dismissWindow
    // Also settable at launch: `open -a "Photos Backup" --args -section albums`.
    @AppStorage("section", store: AppEnvironment.defaults) private var section: AppSection = .home
    @State private var router = AppRouter.shared
    @State private var launched = false

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: Binding($section)) { section in
                Label(section.title, systemImage: section.symbol).tag(section)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            switch section {
            case .home: HomeView(section: $section)
            case .albums: AlbumsView(section: $section)
            case .messages: MessagesView(section: $section)
            case .activity: ActivityView(section: $section)
            }
        }
        .toolbar { MainToolbar(section: $section) }
        .frame(minWidth: 760, minHeight: 560)
        .sheet(isPresented: Binding(get: { model.showingSignIn && !showingWelcome },
                                    set: { if !$0 { model.cancelSignIn() } })) {
            GoogleSignInSheet().environment(model)
        }
        .sheet(isPresented: Binding(get: { showingWelcome }, set: { if !$0 { router.showingWelcome = false } })) {
            OnboardingView().environment(model)
        }
        .onAppear {
            router.openWindowAction = openWindow
            router.openSettingsAction = openSettings
            guard !launched else { return }
            launched = true
            // Menu bar only: the app starts quietly in the menu bar. The
            // welcome guide and links still bring the window up.
            #if DEBUG
            if Snapshots.isRequested { return }
            #endif
            if !model.settings.showInDock, model.settings.onboardingCompleted { dismissWindow(id: "main") }
        }
    }

    private var showingWelcome: Bool {
        router.showingWelcome || !model.settings.onboardingCompleted
    }
}

/// The main window's toolbar: the two actions people come for, and the
/// account.
struct MainToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model
    @Binding var section: AppSection

    var body: some ToolbarContent {
        let engine = model.engine
        ToolbarItemGroup(placement: .primaryAction) {
            if engine.phase == .paused || engine.phase == .pausing {
                Button { engine.resume() } label: { Label("Resume", systemImage: "play.fill") }
                    .help("Resume the backup")
            } else {
                Button { engine.pauseAfterCurrent() } label: { Label("Pause", systemImage: "pause.fill") }
                    .help("Pause after the current uploads")
                    .disabled(engine.phase != .running)
            }
            Button { model.startBackupNow() } label: { Label("Back Up Now", systemImage: "arrow.up") }
                .help("Back up everything selected now (Command-B)")
                .disabled(engine.isActive || !model.hasAuthData)
        }
        ToolbarItem(placement: .primaryAction) {
            AccountMenu()
        }
    }
}

/// Main-menu commands: Back Up Now and Pause in a Backup menu, so the
/// shortcuts work whenever the window is key.
struct BackupCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandMenu("Backup") {
            Button("Back Up Now") { model.startBackupNow() }
                .keyboardShortcut("b")
                .disabled(model.engine.isActive || !model.hasAuthData)
            if model.engine.phase == .paused || model.engine.phase == .pausing {
                Button("Resume") { model.engine.resume() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
            } else {
                Button("Pause After Current Uploads") { model.engine.pauseAfterCurrent() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .disabled(model.engine.phase != .running)
            }
            Button("Stop") { model.stopBackup() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!model.engine.isActive && !model.isMessagesScanning)
            Divider()
            Button("Archive Messages Now") { model.archive.start(trigger: .manual) }
                .disabled(!model.settings.messagesArchive || model.archive.isRunning)
            Button("Retry Failed Items") { model.engine.retryFailed() }
                .disabled(model.engine.failedCount == 0 || model.engine.isActive)
        }
        CommandGroup(after: .appSettings) {
            Button("Show Welcome Guide…") { AppRouter.shared.showWelcome() }
        }
    }
}
