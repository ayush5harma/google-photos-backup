import PhotosBackupCore
import SwiftUI

struct AccountSettingsTab: View {
    @Environment(AppModel.self) private var model
    @State private var pasteDraft = ""
    @State private var showOtherWays = false
    @State private var removing: BackupAccount?
    @State private var rechecking: BackupAccount?
    @State private var forgetting: BackupAccount?

    private static let authHelp = URL(string: "https://github.com/xob0t/gpmc#auth_data-where-do-i-get-mine")!

    var body: some View {
        Form {
            Section {
                if model.accounts.isEmpty {
                    AccountCard()
                    HStack {
                        Button("Sign In with Google…") { model.perform(.signIn) }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.connectState == .connecting)
                        Spacer()
                    }
                } else {
                    if model.showsAccountChoice {
                        Picker("Back up to", selection: Binding(get: { model.accountsChoice }, set: { model.chooseAccounts($0) })) {
                            Text("All accounts").tag(AccountsChoice.all)
                            Text("Only the accounts I choose").tag(AccountsChoice.chosen)
                        }
                        .pickerStyle(.radioGroup)
                    }
                    ForEach(model.accounts) { account in
                        AccountRow(account: account, remove: { removing = account },
                                   recheck: { rechecking = account }, forget: { forgetting = account })
                    }
                    HStack {
                        Button("Add Account…") { model.perform(.signIn) }
                            .disabled(model.connectState == .connecting)
                        Button("Check Connections") { Task { await model.checkAccounts() } }
                            .disabled(model.connectState == .connecting || model.accountStatuses.values.contains(.checking))
                        Spacer()
                    }
                }
                connectStatus
            } header: {
                Text(model.accounts.count > 1 ? "Google accounts" : "Google account")
            } footer: {
                FormNote(model.showsAccountChoice
                         ? "Back Up Now and automatic backups go to the accounts above at the same time, each at its own pace, with the same albums and a record of its own; Back Up Now's arrow backs up to one account once. Messages media, chosen photos, device imports and iCloud go to the primary account whether or not it is included. Your sign-in stays in your login keychain."
                         : "You sign in on Google's own page. Google hands back a token for a new Android device, the kind Google Photos for Android uses. It stays in your login keychain; the sign-in page's session is discarded. Every account gets the same albums at the same time, each with its own record, so adding or removing one never touches the others.")
            }

            Section {
                DisclosureGroup("Other ways to connect", isExpanded: $showOtherWays) {
                    VStack(alignment: .leading, spacing: 10) {
                        FormNote("If Google's page will not work inside the app: open it in Safari, sign in and choose I agree, then copy the value of the oauth_token cookie (Develop > Show Web Inspector > Storage > Cookies) and paste it here. It works once, within a few minutes. A whole auth_data string from gpmc or gotohp works here too.")
                        SecureField("oauth_token or auth_data", text: $pasteDraft, prompt: Text("oauth2_4/… or androidId=…&Token=…"))
                        HStack {
                            Button("Open Sign-In Page in Safari", action: openInSafari)
                            Link("About auth_data", destination: Self.authHelp)
                            Spacer()
                            Button("Connect") {
                                let value = pasteDraft
                                pasteDraft = ""
                                Task { await model.connect(pasted: value) }
                            }
                            .disabled(pasteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.connectState == .connecting)
                        }
                    }
                    .padding(.top, 6)
                }
            }
        }
        .settingsForm(height: 560)
        .confirmationDialog("Remove \(removing?.title ?? "this account")?", isPresented: presented($removing), presenting: removing) { account in
            Button("Remove", role: .destructive) { Task { await model.removeAccount(account.id) } }
        } message: { _ in
            Text("Backups to this account stop and its sign-in is removed from your keychain. Your other accounts are not touched. Photos already in this Google account stay there, and its backup history is kept for when you sign in again.")
        }
        .confirmationDialog("Re-check \(rechecking?.title ?? "this account")'s backups?", isPresented: presented($rechecking), presenting: rechecking) { account in
            Button("Re-check") { model.resetHistory(of: account.id) }
        } message: { _ in
            Text("The next backup checks every selected item with this account's Google Photos again and uploads anything that is missing. Google is asked whether it already has each file's exact bytes, so nothing is uploaded twice. Its Google albums stay linked.")
        }
        .confirmationDialog("Forget \(forgetting?.title ?? "this account")'s Google albums?", isPresented: presented($forgetting), presenting: forgetting) { account in
            Button("Forget", role: .destructive) { model.forgetAlbumLinks(of: account.id) }
        } message: { _ in
            Text("The next backup creates new Google Photos albums in this account for your selected albums. Use this after deleting those albums in Google Photos.")
        }
    }

    private func presented(_ item: Binding<BackupAccount?>) -> Binding<Bool> {
        Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
    }

    /// Safari specifically: the steps above use its Web Inspector, and the
    /// default browser may be another.
    private func openInSafari() {
        guard let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") else {
            NSWorkspace.shared.open(GoogleSignIn.embeddedSetupURL)
            return
        }
        NSWorkspace.shared.open([GoogleSignIn.embeddedSetupURL], withApplicationAt: safari, configuration: NSWorkspace.OpenConfiguration())
    }

    @ViewBuilder
    private var connectStatus: some View {
        switch model.connectState {
        case .connecting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Connecting to Google Photos…").foregroundStyle(.secondary)
            }
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case .idle, .signingIn:
            EmptyView()
        }
    }
}

/// One account: who, whether it is connected, how much of the selection it
/// holds, and its own actions.
struct AccountRow: View {
    @Environment(AppModel.self) private var model
    let account: BackupAccount
    var remove: () -> Void = {}
    var recheck: () -> Void = {}
    var forget: () -> Void = {}

    var body: some View {
        let summary = model.summary(of: account.id)
        let record = model.record(of: account.id)
        let albums = record?.mirrors.values.filter { $0.googleAlbumID != nil }.count ?? 0
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                AccountAvatar(size: 36, email: account.email ?? "")
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(account.title)
                            .font(.headline)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        if model.accounts.count > 1, account.id == model.primaryAccount?.id {
                            Text("Primary")
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                                .help("Messages media, chosen photos, device imports and iCloud go to this account.")
                        }
                    }
                    AccountStatusLine(account: account)
                    Text("\(summary.backedUp.formatted()) of \(summary.total.formatted()) backed up · \(albums.formatted()) Google album\(albums == 1 ? "" : "s") linked")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    if model.showsAccountChoice {
                        Toggle("Include in backups", isOn: Binding(get: { model.isIncluded(account.id) },
                                                                   set: { model.setIncluded(account.id, $0) }))
                            .toggleStyle(.checkbox)
                            .help(model.accountsChoice == .all
                                  ? "Backups go to every account. Untick this to back up only to the accounts you choose."
                                  : "Back Up Now and automatic backups go to the ticked accounts.")
                            .padding(.top, 2)
                    }
                }
                Spacer(minLength: 0)
                Menu {
                    Button("Check Connection") { Task { await model.checkAccount(account.id) } }
                    Button("Sign In Again…") { model.perform(.signIn) }
                    Divider()
                    Button("Re-check Backups…", action: recheck)
                    Button("Forget Album Links…", action: forget)
                    Divider()
                    Button("Remove…", role: .destructive, action: remove)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Actions for \(account.title)")
            }
            if !account.storageChecked {
                StorageCheckCard(account: account)
            }
        }
        .padding(.vertical, 4)
    }
}

/// The account's connection, or what the pass is doing with it.
struct AccountStatusLine: View {
    @Environment(AppModel.self) private var model
    let account: BackupAccount

    var body: some View {
        if let line = model.engine.backingUpLine(for: account.id) {
            Label(line, systemImage: "arrow.up.circle.fill")
                .foregroundStyle(.tint)
                .monospacedDigit()
        } else {
            switch model.status(of: account.id) {
            case .missing:
                Text("Signed out. Sign in again to keep backing up to it.").foregroundStyle(.orange)
            case .checking:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Checking with Google…").foregroundStyle(.secondary)
                }
            case .connected:
                if !account.storageChecked {
                    Label("Connected; waiting for the storage check below", systemImage: "clock")
                        .foregroundStyle(.secondary)
                } else if !model.isIncluded(account.id) {
                    Label("Connected; not included in backups", systemImage: "minus.circle")
                        .foregroundStyle(.secondary)
                } else {
                    Label("Connected to Google Photos", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            case let .failed(message):
                Text(message)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Before the first backup to an added account: what the selection needs
/// from its storage at the chosen quality. Google does not tell the app an
/// account's free storage, so Google One is a click away instead.
struct StorageCheckCard: View {
    @Environment(AppModel.self) private var model
    let account: BackupAccount

    var body: some View {
        let check = model.storageCheck(for: account.id)
        VStack(alignment: .leading, spacing: 6) {
            Label("Before the first backup to this account", systemImage: "externaldrive.badge.questionmark")
                .font(.subheadline.weight(.semibold))
            Text(sizeLine(check))
            Text(storageLine(check))
                .foregroundStyle(check.countsAgainstStorage ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            HStack {
                if let email = account.email {
                    Link("Check Storage in Google One", destination: StorageCheck.storagePage(for: email))
                }
                Spacer()
                Button("Start Backing Up") { model.confirmStorage(for: account.id) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.credentialAccounts.contains(account.id))
            }
            .padding(.top, 2)
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .padding(10)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func sizeLine(_ check: StorageCheck) -> String {
        let items = "\(check.items.formatted()) selected item\(check.items == 1 ? "" : "s") to upload"
        guard let bytes = check.estimatedBytes, check.items > 0 else { return items + "." }
        return items + ", about \(bytes.formatted(.byteCount(style: .file))) (from the average size of what this Mac has uploaded)."
    }

    private func storageLine(_ check: StorageCheck) -> String {
        if check.countsAgainstStorage {
            let need = check.estimatedBytes.map { "about \($0.formatted(.byteCount(style: .file)))" } ?? "the whole selection's size"
            return "\(check.quality.title): this needs \(need) free in this account. A free Google account has 15 GB, shared with Gmail and Drive."
        }
        return "\(check.quality.title) does not count against this account's storage, so the upload does not fill it."
    }
}

/// The account as a person sees it when there is none or one: an initial,
/// the address, its state.
struct AccountCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            AccountAvatar(size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.hasAuthData ? (model.accountEmail ?? "Google account") : "Not signed in")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                if model.accounts.isEmpty {
                    Text("Sign in to start backing up").foregroundStyle(.secondary)
                } else if let primary = model.primaryAccount {
                    AccountStatusLine(account: primary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

/// A circle with the account's first letter, or a person when signed out.
struct AccountAvatar: View {
    @Environment(AppModel.self) private var model
    var size: CGFloat = 28
    /// An account's address; nil draws the primary account.
    var email: String?

    var body: some View {
        let address = email ?? (model.hasAuthData ? model.accountEmail : nil)
        let initial = address?.first.map { String($0).uppercased() }
        ZStack {
            Circle().fill(initial == nil ? AnyShapeStyle(.quaternary) : AnyShapeStyle(Color.accentColor.gradient))
            if let initial {
                Text(initial)
                    .font(.system(size: size * 0.45, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.45))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The toolbar's account button: who is signed in, and the account actions.
struct AccountMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            if model.hasAuthData {
                ForEach(model.accounts) { account in
                    Text(model.isIncluded(account.id) ? account.title : "\(account.title) (not included)")
                }
                Button(model.accounts.count > 1 ? "Check Connections" : "Check Connection") { Task { await model.checkAccounts() } }
                Button("Add Account…") { model.perform(.signIn) }
            } else {
                Button("Sign In with Google…") { model.perform(.signIn) }
            }
            Divider()
            Button("Account Settings…") { AppRouter.shared.openSettings(.account) }
        } label: {
            Label {
                Text(label)
            } icon: {
                Image(systemName: symbol)
            }
        }
        .help(model.accounts.map(\.title).joined(separator: ", ").isEmpty ? "Google account" : model.accounts.map(\.title).joined(separator: ", "))
    }

    private var label: String {
        model.accounts.count > 1 ? "\(model.accounts.count) accounts" : (model.accountEmail ?? "Account")
    }

    private var symbol: String {
        if model.accounts.contains(where: { model.status(of: $0.id).isFailed }) { return "person.crop.circle.badge.exclamationmark" }
        switch model.account {
        case .connected: return model.accounts.count > 1 ? "person.2.circle" : "person.crop.circle"
        case .checking: return "person.crop.circle.badge.clock"
        case .failed: return "person.crop.circle.badge.exclamationmark"
        case .missing: return "person.crop.circle.badge.plus"
        }
    }
}
