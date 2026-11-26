import PhotosBackupCore
import SwiftUI

/// Settings: the accounts up top, then one page per group, the way iOS
/// Settings reads. The groups are the Mac's Settings tabs, in iPhone words.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.settingsPath) {
            Form {
                AccountsSection()
                Section {
                    link(.backup, "Backup", "photo.on.rectangle.angled", .accentColor)
                    link(.whenToBackUp, "When to Back Up", "wifi", .green)
                    link(.notifications, "Notifications", "bell.badge", .red)
                }
                Section {
                    link(.advanced, "Advanced", "wrench.and.screwdriver", .gray)
                    link(.about, "About", "info.circle", .gray)
                }
            }
            .navigationTitle("Settings")
            .navigationDestination(for: SettingsPage.self) { page in
                switch page {
                case let .account(id): AccountDetailView(accountID: id)
                case .backup: BackupSettingsView()
                case .whenToBackUp: WhenToBackUpView()
                case .notifications: NotificationSettingsView()
                case .advanced: AdvancedSettingsView()
                case .about: AboutView()
                }
            }
        }
    }

    private func link(_ page: SettingsPage, _ title: String, _ symbol: String, _ tint: Color) -> some View {
        NavigationLink(value: page) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 29, height: 29)
                    .background(tint.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
        }
    }
}

/// Every signed-in account, "Back up to", and Add Account.
private struct AccountsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            ForEach(model.accounts) { account in
                NavigationLink(value: SettingsPage.account(account.id)) {
                    AccountRow(account: account)
                }
            }
            if model.showsAccountChoice {
                Picker("Back up to", selection: Binding(get: { model.accountsChoice }, set: { model.chooseAccounts($0) })) {
                    Text("All accounts").tag(AccountsChoice.all)
                    Text("Only the accounts I choose").tag(AccountsChoice.chosen)
                }
            }
            Button {
                model.beginSignIn()
            } label: {
                Label(model.accounts.isEmpty ? "Sign In with Google" : "Add Account", systemImage: "person.crop.circle.badge.plus")
            }
            .disabled(model.connectState == .connecting)
        } header: {
            Text(model.accounts.count > 1 ? "Google Accounts" : "Google Account")
        } footer: {
            Text(footer)
        }
    }

    private var footer: String {
        if model.accounts.isEmpty { return "Sign in on Google's own page. The account is kept in the Keychain on this device." }
        if model.accounts.count == 1 { return "Each backup goes to this account. Add another to back up to several at the same time." }
        return model.accountsChoice == .all
            ? "Each backup goes to every account at the same time."
            : "Each backup goes only to the accounts with Include in Backups on."
    }
}

private struct AccountRow: View {
    @Environment(AppModel.self) private var model
    let account: BackupAccount

    var body: some View {
        HStack(spacing: 12) {
            AccountAvatar(size: 36, email: account.email)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.title).lineLimit(1).truncationMode(.middle)
                // "Primary" leads the second line: beside the address it
                // cut a long address short on a phone.
                Text(primary ? "Primary · " + line : line).font(.footnote).foregroundStyle(statusColor)
            }
        }
        .padding(.vertical, 2)
    }

    private var primary: Bool { account.id == model.primaryAccount?.id && model.accounts.count > 1 }

    private var line: String {
        if !account.storageChecked { return "Waiting for its storage check" }
        if model.showsAccountChoice, !model.isIncluded(account.id) { return "Not included in backups" }
        switch model.status(of: account.id) {
        case .missing: return "Signed out"
        case .checking: return "Checking with Google…"
        case .failed: return "Needs attention"
        case .connected:
            let summary = model.summary(of: account.id)
            return "\(summary.backedUp.formatted()) of \(summary.total.formatted()) backed up"
        }
    }

    private var statusColor: Color {
        switch model.status(of: account.id) {
        case .missing, .failed: .orange
        default: .secondary
        }
    }
}

/// One account: its state, its storage check, and what can be done to it.
struct AccountDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let accountID: String
    @State private var confirming: Confirmation?

    private enum Confirmation: Identifiable {
        case remove, recheck, forget
        var id: Self { self }
    }

    var body: some View {
        if let account = model.accounts.first(where: { $0.id == accountID }) {
            form(account)
        } else {
            ContentUnavailableView("Signed Out", systemImage: "person.crop.circle.badge.xmark")
        }
    }

    private func form(_ account: BackupAccount) -> some View {
        let summary = model.summary(of: account.id)
        let albums = model.record(of: account.id)?.mirrors.values.filter { $0.googleAlbumID != nil }.count ?? 0
        return Form {
            Section {
                HStack(spacing: 14) {
                    AccountAvatar(size: 48, email: account.email)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.title).font(.headline).lineLimit(1).truncationMode(.middle)
                        Text("\(summary.backedUp.formatted()) of \(summary.total.formatted()) backed up · \(albums.formatted()) album\(albums == 1 ? "" : "s") linked")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                if model.showsAccountChoice {
                    Toggle("Include in Backups", isOn: Binding(get: { model.isIncluded(account.id) },
                                                               set: { model.setIncluded(account.id, $0) }))
                }
            }
            if !account.storageChecked {
                Section("Before the first backup to this account") {
                    StorageCheckView(account: account)
                }
            }
            Section {
                Button("Sign In Again") { model.beginSignIn() }
                Button("Check Backups Again…") { confirming = .recheck }
                Button("Forget Album Links…") { confirming = .forget }
            } footer: {
                Text("Checking again asks Google about every selected item and uploads anything missing. Forgetting album links makes the next backup create new albums, after you deleted them in Google Photos.")
            }
            Section {
                Button("Remove Account…", role: .destructive) { confirming = .remove }
            } footer: {
                Text("Backups to this account stop and its sign-in leaves the Keychain. Photos already in this Google account stay there.")
            }
        }
        .navigationTitle(model.accounts.count > 1 ? "Account" : "Google Account")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(dialogTitle, isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            titleVisibility: .visible, presenting: confirming) { confirmation in
            switch confirmation {
            case .remove:
                Button("Remove", role: .destructive) {
                    Task {
                        await model.removeAccount(account.id)
                        dismiss()
                    }
                }
            case .recheck:
                Button("Check Again") { model.resetHistory(of: account.id) }
            case .forget:
                Button("Forget", role: .destructive) { model.forgetAlbumLinks(of: account.id) }
            }
        }
    }

    private var dialogTitle: String {
        switch confirming {
        case .remove: "Remove this account?"
        case .recheck: "Check every backup again?"
        case .forget: "Forget the links to Google albums?"
        case nil: ""
        }
    }
}

/// What the selection asks of an added account's storage before its first
/// run. Google does not tell the app an account's free storage, so Google
/// One is a tap away instead. The Mac's StorageCheckCard.
private struct StorageCheckView: View {
    @Environment(AppModel.self) private var model
    let account: BackupAccount

    var body: some View {
        let check = model.storageCheck(for: account.id)
        VStack(alignment: .leading, spacing: 8) {
            Text(sizeLine(check))
            Text(storageLine(check))
                .foregroundStyle(check.countsAgainstStorage ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
        }
        .font(.subheadline)
        if let email = account.email {
            Link("Check Storage in Google One", destination: StorageCheck.storagePage(for: email))
        }
        Button("Start Backing Up") { model.confirmStorage(for: account.id) }
            .disabled(!model.credentialAccounts.contains(account.id))
    }

    private func sizeLine(_ check: StorageCheck) -> String {
        let items = "\(check.items.formatted()) selected item\(check.items == 1 ? "" : "s") to upload"
        guard let bytes = check.estimatedBytes, check.items > 0 else { return items + "." }
        return items + ", about \(bytes.formatted(.byteCount(style: .file)))."
    }

    private func storageLine(_ check: StorageCheck) -> String {
        if check.countsAgainstStorage {
            let need = check.estimatedBytes.map { "about \($0.formatted(.byteCount(style: .file)))" } ?? "the whole selection's size"
            return "\(check.quality.title): this needs \(need) free in this account. A free Google account has 15 GB, shared with Gmail and Drive."
        }
        return "\(check.quality.title) does not count against this account's storage, so the upload does not fill it."
    }
}
