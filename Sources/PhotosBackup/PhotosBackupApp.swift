import PhotosBackupCore
import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case home, albums, activity, settings

    var id: String { rawValue }

    var title: String { rawValue.capitalized }

    var symbol: String {
        switch self {
        case .home: "house"
        case .albums: "rectangle.stack"
        case .activity: "arrow.up.circle"
        case .settings: "gearshape"
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
                .task { await model.launch() }
        }
        .defaultSize(width: 900, height: 760)

        MenuBarExtra {
            MenuContent().environment(model)
        } label: {
            Image(systemName: model.engine.isActive ? "arrow.up.circle.fill" : "arrow.up.circle")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // A bridge that dies before reading its request must not take the
        // app down with SIGPIPE on the write.
        signal(SIGPIPE, SIG_IGN)
    }

    /// Keep backing up from the menu bar once the window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct RootView: View {
    // Also settable at launch: `open -a "Photos Backup" --args -section albums`.
    @AppStorage("section") private var section: AppSection = .home

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
            case .activity: ActivityView(section: $section)
            case .settings: SettingsView()
            }
        }
        .frame(minWidth: 720, minHeight: 560)
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
        Button("Back Up Now") { engine.start() }
            .disabled(engine.isActive || model.authData == nil)
        if engine.phase == .paused || engine.phase == .pausing {
            Button("Resume") { engine.resume() }
        } else if engine.phase == .running {
            Button("Pause After Current Uploads") { engine.pauseAfterCurrent() }
        }
        if engine.isActive { Button("Stop") { engine.stop() } }
        Divider()
        Button("Open Photos Backup") {
            openWindow(id: "main")
            NSApp.activate()
        }
        Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
