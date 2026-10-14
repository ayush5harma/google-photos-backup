import PhotosBackupCore
import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    // Settings moved to the Settings window (Command-,); a stored "settings"
    // selection falls back to home.
    case home, albums, icloud, messages, activity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Overview"
        case .albums: "Albums"
        case .icloud: "iCloud Photos"
        case .messages: "Messages"
        case .activity: "Activity"
        }
    }

    var symbol: String {
        switch self {
        case .home: "square.grid.2x2"
        case .albums: "rectangle.stack"
        case .icloud: "icloud"
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
    /// Whether the window that opens at launch has been dealt with (kept,
    /// or closed for a menu-bar-only start).
    @ObservationIgnored var handledLaunchWindow = false

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
    private var appearanceObservation: NSKeyValueObservation?

    func applicationWillFinishLaunching(_ notification: Notification) {
        Self.current = self
        NSApp.setActivationPolicy(model.settings.showInDock ? .regular : .accessory)
        // Registered before launch finishes so a link that launched the app
        // is delivered too.
        registerURLHandler()
        #if DEBUG
        E2EHooks.startInbox(self)
        #endif
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.initial, .new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.updateDockIcon() }
        }
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

    private func updateDockIcon() {
        let variant = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "dark" : "light"
        let icon = Bundle.main.url(forResource: "AppIcon-\(variant)", withExtension: "png")
            .flatMap { NSImage(contentsOf: $0) }
            ?? Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
                .flatMap { NSImage(contentsOf: $0) }
        if let icon { NSApp.applicationIconImage = icon }
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
    ///
    /// A log out, restart or shut down must not be cancelled (that aborts it
    /// with "Photos Backup interrupted"), so those wait in place instead,
    /// running the loop in its default mode, which does drain the main queue.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model.cancelMessagesScan()
        model.archive.cancel()
        guard isBusy, !quitting else { return .terminateNow }
        quitting = true
        model.engine.stop()
        model.iCloud.stopForQuit()
        if isSystemQuit {
            let deadline = Date().addingTimeInterval(Self.stopWait)
            while isBusy, Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1)) }
            return .terminateNow
        }
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(Self.stopWait)
            while self.isBusy, Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
            sender.terminate(nil)
        }
        return .terminateCancel
    }

    private static let stopWait: TimeInterval = 15
    private var quitting = false

    /// A run is recording what Google confirmed, or the archive is writing.
    private var isBusy: Bool { model.engine.isActive || model.archive.isRunning || model.iCloud.isRunning }

    /// The quit Apple event carries a reason only when the system sent it
    /// (log out, restart, shut down); Command-Q and the Quit button have none.
    private var isSystemQuit: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["PHOTOS_BACKUP_SIMULATE_SYSTEM_QUIT"] == "1" { return true }
        #endif
        return NSAppleEventManager.shared().currentAppleEvent?.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)) != nil
    }

    func applicationWillTerminate(_ notification: Notification) {
        BridgeProcess.terminateAll()
        model.iCloud.stopForQuit()
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
        // The delivery itself made the app a Dock app again; put it back on
        // the next turns, after LaunchServices has finished with it.
        for delay in [0.1, 0.6] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [model] in model.applyDockVisibility() }
        }
    }

    func handle(_ url: URL) {
        #if DEBUG
        if E2EHooks.handle(url, model: model) { return }
        #endif
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
            case .icloud: ICloudSourceView()
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
            // Once per launch, not per window: the view is rebuilt every time
            // the window is opened again.
            guard !router.handledLaunchWindow else { return }
            router.handledLaunchWindow = true
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
