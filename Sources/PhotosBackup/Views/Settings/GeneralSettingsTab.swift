import AppKit
import PhotosBackupCore
import SwiftUI

struct GeneralSettingsTab: View {
    @Environment(AppModel.self) private var model
    @State private var loginItem = LoginItem.shared

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Open at login", isOn: Binding(get: { loginItem.state == .enabled || loginItem.state == .requiresApproval },
                                                      set: { loginItem.setEnabled($0) }))
                    .disabled(loginItem.state == .unavailable)
                if loginItem.state == .requiresApproval {
                    LabeledContent {
                        Button("Open Login Items") { loginItem.openSystemSettings() }
                    } label: {
                        Label("Turned off in Login Items", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                if let error = loginItem.error {
                    Text(error).font(.callout).foregroundStyle(.orange)
                }
                Toggle("Show in Dock", isOn: Binding(get: { model.settings.showInDock }, set: { setShowInDock($0) }))
                Toggle("Show progress in the menu bar", isOn: $model.settings.menuBarShowsProgress)
            } header: {
                Text("Startup and menu bar")
            } footer: {
                FormNote(loginItem.state == .unavailable
                         ? "Open at login is available once Photos Backup is installed as an app."
                         : "Photos Backup always stays in the menu bar. Without the Dock icon it starts there quietly; open the window from the menu bar.")
            }

            Section {
                Toggle("Back up automatically", isOn: $model.settings.automatic)
            } footer: {
                FormNote("Selected albums back up when Photos changes, after your Mac wakes and every 30 minutes. Back Up Now always works.")
            }

            Section("Notifications") {
                Toggle("When an automatic backup finishes", isOn: notificationBinding(\.notifyWhenFinished))
                Toggle("About problems that need you", isOn: notificationBinding(\.notifyAboutProblems))
                notificationState
            }

            Section {
                LabeledContent("Welcome guide") {
                    Button("Show Welcome Guide…") { AppRouter.shared.showWelcome() }
                }
            }
        }
        .settingsForm(height: 520)
        .task {
            loginItem.refresh()
            await model.notifier.refresh()
        }
    }

    @ViewBuilder
    private var notificationState: some View {
        switch model.notifier.authorization {
        case .denied:
            LabeledContent {
                Button("Open Settings") { model.notifier.openSystemSettings() }
            } label: {
                Label("Notifications are off for Photos Backup", systemImage: "bell.slash")
                    .foregroundStyle(.secondary)
            }
        case .notDetermined:
            LabeledContent {
                Button("Allow Notifications") { model.notifier.requestAuthorization() }
            } label: {
                Text("macOS asks once before Photos Backup can notify you.")
                    .foregroundStyle(.secondary)
            }
        case .unavailable:
            Text("Notifications are available once Photos Backup is installed as an app.")
                .foregroundStyle(.secondary)
        case .allowed:
            EmptyView()
        }
    }

    /// Turning a notification on is the moment to ask macOS for permission.
    private func notificationBinding(_ key: WritableKeyPath<BackupSettings, Bool>) -> Binding<Bool> {
        Binding(get: { model.settings[keyPath: key] }, set: { on in
            model.settings[keyPath: key] = on
            if on, model.notifier.authorization == .notDetermined { model.notifier.requestAuthorization() }
        })
    }

    /// Changing the policy deactivates the app, which would drop the
    /// Settings window behind other apps' windows.
    private func setShowInDock(_ show: Bool) {
        model.settings.showInDock = show
        let window = NSApp.keyWindow
        NSApp.setActivationPolicy(show ? .regular : .accessory)
        DispatchQueue.main.async {
            NSApp.activate()
            window?.makeKeyAndOrderFront(nil)
        }
    }
}
