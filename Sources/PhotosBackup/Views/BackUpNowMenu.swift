import PhotosBackupCore
import SwiftUI

/// Back Up Now's destinations once there are several accounts. Back Up Now
/// itself goes where "Back up to" says; these are one-offs that never
/// change that choice. The window's button, the toolbar, the menu bar panel
/// and the app menu all list the same items.
struct BackUpDestinations: View {
    let model: AppModel

    var body: some View {
        if model.accountsChoice == .chosen {
            let count = model.targetAccounts.count
            Button("Chosen Accounts (\(count.formatted()))") { model.startBackupNow() }
                .disabled(count == 0)
        }
        Button("All Accounts") { model.startBackupNow(to: .every) }
            .disabled(model.runnableAccounts.isEmpty)
        Divider()
        ForEach(model.accounts) { account in
            Button(title(account)) { model.startBackupNow(to: .only(account.id)) }
                .disabled(!model.runnableAccounts.contains { $0.id == account.id })
        }
    }

    private func title(_ account: BackupAccount) -> String {
        if !account.storageChecked { return "\(account.title) (waiting for its storage check)" }
        if !model.credentialAccounts.contains(account.id) { return "\(account.title) (signed out)" }
        return model.isIncluded(account.id) ? account.title : "\(account.title) (not included)"
    }
}

/// Back Up Now: a plain button with one account; with several, a button
/// for the saved choice and an arrow that offers all accounts or one.
struct BackUpNowButton: View {
    @Environment(AppModel.self) private var model
    /// The window's hero: a prominent button with the arrow beside it, since
    /// a menu does not take the prominent style. Elsewhere a split button.
    var prominent = false

    var body: some View {
        let label = Label("Back Up Now", systemImage: "arrow.up")
        if model.accounts.count <= 1 {
            if prominent {
                Button { model.startBackupNow() } label: { label }
                    .buttonStyle(.borderedProminent)
            } else {
                Button { model.startBackupNow() } label: { label }
            }
        } else if prominent {
            HStack(spacing: 6) {
                Button { model.startBackupNow() } label: { label }
                    .buttonStyle(.borderedProminent)
                    .help(help)
                Menu {
                    BackUpDestinations(model: model)
                } label: {
                    Label("Back Up To", systemImage: "chevron.down").labelStyle(.iconOnly)
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Back up to all accounts or to one, this once")
                .accessibilityLabel("Back Up To")
            }
        } else {
            Menu {
                BackUpDestinations(model: model)
            } label: {
                label
            } primaryAction: {
                model.startBackupNow()
            }
            .fixedSize()
            .help(help)
        }
    }

    private var help: String {
        model.accountsChoice == .all ? "Back up to every account; the arrow backs up to one"
            : "Back up to the chosen accounts; the arrow backs up to all or one"
    }
}
