import PhotosBackupCore
import SwiftUI

@main
struct PhotosBackupApp: App {
    @State private var model: AppModel

    init() {
        // BGTaskScheduler takes registrations only before launch ends.
        BackgroundCoordinator.shared.register()
        let model = AppModel()
        #if DEBUG
        if model.isFixture { SnapshotFixture.apply(to: model) }
        switch AppEnvironment.requestedSheet {
        case .onboarding: model.showingOnboarding = true
        case .signin: model.showingSignIn = true
        case nil: break
        }
        if let link = AppEnvironment.requestedLink { model.open(link) }
        #endif
        _model = State(initialValue: model)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { await model.launch() }
                .onOpenURL { model.open($0) }
        }
    }
}

/// The four tabs. On iOS 18 and later the tab bar becomes a sidebar on iPad
/// (.sidebarAdaptable); iOS 17 keeps the plain tab bar.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var model = model
        tabs
            .sheet(isPresented: $model.showingSignIn, onDismiss: { model.cancelSignIn() }) {
                GoogleSignInSheet()
            }
            .fullScreenCover(isPresented: $model.showingOnboarding) {
                OnboardingView()
                    .sheet(isPresented: $model.showingSignIn, onDismiss: { model.cancelSignIn() }) {
                        GoogleSignInSheet()
                    }
            }
            .onChange(of: scenePhase) { _, phase in
                // Photos access can change in Settings while the app is away;
                // leaving the front saves the run and schedules the next
                // background backup.
                switch phase {
                case .active: model.sceneChanged(active: true)
                case .background: model.sceneChanged(active: false)
                default: break
                }
            }
    }

    @ViewBuilder
    private var tabs: some View {
        @Bindable var model = model
        if #available(iOS 18, *) {
            TabView(selection: $model.tab) {
                ForEach(AppTab.allCases) { tab in
                    Tab(tab.title, systemImage: tab.symbol, value: tab) { content(for: tab) }
                }
            }
            .tabViewStyle(.sidebarAdaptable)
            .modifier(MinimizingTabBar())
        } else {
            TabView(selection: $model.tab) {
                ForEach(AppTab.allCases) { tab in
                    content(for: tab)
                        .tabItem { Label(tab.title, systemImage: tab.symbol) }
                        .tag(tab)
                }
            }
        }
    }

    @ViewBuilder
    private func content(for tab: AppTab) -> some View {
        switch tab {
        case .overview: NavigationStack { OverviewView() }
        case .albums: NavigationStack { AlbumsView() }
        case .activity: NavigationStack { ActivityView() }
        case .settings: SettingsView()
        }
    }
}

/// Liquid Glass chrome on iOS 26: the tab bar steps aside while a long page
/// scrolls down. Nothing before iOS 26.
private struct MinimizingTabBar: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            content
        }
    }
}
