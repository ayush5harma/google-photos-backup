import PhotosBackupCore
import SwiftUI

/// The Settings window (Command-,): five tabs of grouped forms.
struct SettingsView: View {
    @AppStorage(AppRouter.settingsTabKey, store: AppEnvironment.defaults) private var tab: AutomationCommand.SettingsTab = .general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(AutomationCommand.SettingsTab.general)
            BackupSettingsTab()
                .tabItem { Label("Backup", systemImage: "arrow.up.circle") }
                .tag(AutomationCommand.SettingsTab.backup)
            MessagesSettingsTab()
                .tabItem { Label("Messages", systemImage: "message") }
                .tag(AutomationCommand.SettingsTab.messages)
            AccountSettingsTab()
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
                .tag(AutomationCommand.SettingsTab.account)
            AdvancedSettingsTab()
                .tabItem { Label("Advanced", systemImage: "gearshape.2") }
                .tag(AutomationCommand.SettingsTab.advanced)
        }
        .frame(width: SettingsLayout.width)
    }
}

enum SettingsLayout {
    static let width: CGFloat = 580
}

extension View {
    /// A tab's form: grouped, at the window's fixed width, as tall as the tab
    /// needs up to a screen-friendly limit, scrolling beyond it.
    func settingsForm(height: CGFloat) -> some View {
        formStyle(.grouped)
            .scrollBounceBehavior(.basedOnSize)
            .frame(width: SettingsLayout.width, height: height)
    }
}

/// A number with its stepper at the trailing edge, the way System Settings
/// lays them out.
struct StepperRow: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step = 1
    var display: (Int) -> String = { $0.formatted() }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Text(display(value)).monospacedDigit()
                Stepper(title, value: $value, in: range, step: step).labelsHidden()
            }
        }
    }
}

/// A form footer that wraps rather than truncates.
struct FormNote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}
