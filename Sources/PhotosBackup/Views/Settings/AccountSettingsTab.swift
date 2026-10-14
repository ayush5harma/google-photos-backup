import PhotosBackupCore
import SwiftUI

struct AccountSettingsTab: View {
    @Environment(AppModel.self) private var model
    @State private var pasteDraft = ""
    @State private var showOtherWays = false
    @State private var confirmDisconnect = false
    @State private var confirmRecheck = false
    @State private var confirmForget = false

    private static let authHelp = URL(string: "https://github.com/xob0t/gpmc#auth_data-where-do-i-get-mine")!

    var body: some View {
        Form {
            Section {
                AccountCard()
                HStack {
                    if model.hasAuthData {
                        Button("Check Connection") { Task { await model.checkAccount() } }
                            .disabled(model.connectState == .connecting || model.account == .checking)
                        Button("Sign In Again…") { model.beginSignIn() }
                            .disabled(model.connectState == .connecting)
                        Spacer()
                        Button("Disconnect…", role: .destructive) { confirmDisconnect = true }
                    } else {
                        Button("Sign In with Google…") { model.beginSignIn() }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.connectState == .connecting)
                        Spacer()
                    }
                }
                connectStatus
            } header: {
                Text("Google account")
            } footer: {
                FormNote("You sign in on Google's own page. Google hands back a token for a new Android device, the kind Google Photos for Android uses. It stays in your login keychain; the sign-in page's session is discarded.")
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

            Section {
                LabeledContent("Items backed up", value: model.state.uploaded.count.formatted())
                LabeledContent("Linked Google albums", value: model.state.mirrors.values.filter { $0.googleAlbumID != nil }.count.formatted())
                HStack {
                    Button("Forget Album Links…") { confirmForget = true }
                    Spacer()
                    Button("Re-check Backups…") { confirmRecheck = true }
                }
            } header: {
                Text("Backup history")
            } footer: {
                FormNote("Re-check Backups compares everything you selected with Google Photos again. Before uploading, Google is asked whether it already has each file's exact bytes, so nothing is uploaded twice; it only makes the next backup take longer. Your Google albums stay linked.")
            }
        }
        .settingsForm(height: 560)
        .confirmationDialog("Disconnect your Google account?", isPresented: $confirmDisconnect) {
            Button("Disconnect", role: .destructive) { model.removeAuthData() }
        } message: {
            Text("Backups stop and the account is removed from your keychain. Your photos in Google Photos are not touched, and the backup history is kept for when you sign in again.")
        }
        .confirmationDialog("Re-check your backups with Google Photos?", isPresented: $confirmRecheck) {
            Button("Re-check") { model.resetHistory() }
        } message: {
            Text("The next backup checks every selected item with Google again and uploads anything that is missing. Nothing is uploaded twice.")
        }
        .confirmationDialog("Forget the Google albums made so far?", isPresented: $confirmForget) {
            Button("Forget", role: .destructive) { model.forgetAlbumLinks() }
        } message: {
            Text("The next backup creates new Google Photos albums for your selected albums. Use this after deleting those albums in Google Photos.")
        }
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

/// The account as a person sees it: an initial, the address, its state.
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
                state
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var state: some View {
        switch model.account {
        case .missing:
            Text("Sign in to start backing up").foregroundStyle(.secondary)
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Checking with Google…").foregroundStyle(.secondary)
            }
        case .connected:
            Label("Connected to Google Photos", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .labelStyle(.titleAndIcon)
        case let .failed(message):
            Text(message)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A circle with the account's first letter, or a person when signed out.
struct AccountAvatar: View {
    @Environment(AppModel.self) private var model
    var size: CGFloat = 28

    var body: some View {
        let initial = model.hasAuthData ? model.accountEmail?.first.map { String($0).uppercased() } : nil
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
                Text(model.accountEmail ?? "Google account")
                Button("Check Connection") { Task { await model.checkAccount() } }
                Button("Sign In Again…") { model.beginSignIn() }
            } else {
                Button("Sign In with Google…") { model.beginSignIn() }
            }
            Divider()
            Button("Account Settings…") { AppRouter.shared.openSettings(.account) }
        } label: {
            Label {
                Text(model.accountEmail ?? "Account")
            } icon: {
                Image(systemName: symbol)
            }
        }
        .help(model.accountEmail ?? "Google account")
    }

    private var symbol: String {
        switch model.account {
        case .connected: "person.crop.circle"
        case .checking: "person.crop.circle.badge.clock"
        case .failed: "person.crop.circle.badge.exclamationmark"
        case .missing: "person.crop.circle.badge.plus"
        }
    }
}
