import PhotosBackupCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var pasteDraft = ""
    @State private var showOtherWays = false
    @State private var confirmReset = false
    @State private var confirmForget = false

    private static let authHelp = URL(string: "https://github.com/xob0t/gpmc#auth_data-where-do-i-get-mine")!
    private static let gpmc = URL(string: "https://github.com/xob0t/gpmc")!
    private static let gotohp = URL(string: "https://github.com/xob0t/gotohp")!

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                LabeledContent("Status") { accountStatus }
                HStack {
                    Button {
                        model.beginSignIn()
                    } label: {
                        Label(model.hasAuthData ? "Sign In Again..." : "Sign in with Google", systemImage: "person.crop.circle.badge.plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.connectState == .connecting)
                    Spacer()
                    if model.hasAuthData {
                        Button("Remove", role: .destructive) { model.removeAuthData() }
                        Button("Test") { Task { await model.checkAccount() } }
                    }
                }
                connectStatus
                DisclosureGroup("Other ways to connect", isExpanded: $showOtherWays) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("If Google's page will not work inside the app: open it in Safari, sign in and choose I agree, then copy the value of the oauth_token cookie (Develop > Show Web Inspector > Storage > Cookies) and paste it here. It works once, within a few minutes. A whole auth_data string from gpmc or gotohp works here too.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        SecureField("oauth_token or auth_data", text: $pasteDraft, prompt: Text("oauth2_4/... or androidId=...&Token=..."))
                        HStack {
                            Button("Open Sign-In Page in Safari") { NSWorkspace.shared.open(GoogleSignIn.embeddedSetupURL) }
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
            } header: {
                Text("Google Account")
            } footer: {
                Text("Signing in happens on Google's own page. Google hands back a token for a new Android device ID, the kind Google Photos for Android signs in with and gpmc uploads with. The token stays in your login keychain and reaches the uploader over a pipe, never a command line; the sign-in page's session is discarded. The sign-in flow follows gotohp by xob0t.")
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section("Uploads") {
                Picker("Quality", selection: $model.settings.quality) {
                    ForEach(UploadQuality.allCases) { Text($0.title).tag($0) }
                }
                Stepper("Parallel uploads: \(model.settings.threads)", value: $model.settings.threads, in: 1...4)
                Stepper("Items per batch: \(model.settings.batchSize)", value: $model.settings.batchSize, in: 5...100, step: 5)
                Toggle("Recreate my albums in Google Photos", isOn: $model.settings.mirrorAlbums)
                Toggle("Back up automatically", isOn: $model.settings.automatic)
            }

            Section {
                LabeledContent("Backed up items", value: "\(model.state.uploaded.count)")
                LabeledContent("Linked Google albums", value: "\(model.state.mirrors.values.filter { $0.googleAlbumID != nil }.count)")
                HStack {
                    Button("Show Log in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.paths.bridgeLog]) }
                    Spacer()
                    Button("Forget Album Links...") { confirmForget = true }
                    Button("Reset Backup History...", role: .destructive) { confirmReset = true }
                }
            } header: {
                Text("History")
            } footer: {
                Text("Resetting is safe: before sending anything, gpmc asks Google whether it already has the file's exact bytes, so nothing is uploaded twice, and the links to your Google albums are kept. It only makes the next run slower.")
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section("About") {
                LabeledContent("Uploader", value: model.runtimeDescription)
                Link("gpmc by xob0t (MIT)", destination: Self.gpmc)
                Text("gpmc talks to Google Photos' reverse-engineered mobile API as a Pixel XL, which Google lets back up in original quality for free. Google can change or end that at any time; uploads then count against your storage or fail, and nothing in Photos is touched either way.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .confirmationDialog("Reset the backup history?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { model.resetHistory() }
        } message: {
            Text("The next run checks every selected item with Google again. Your Google albums stay linked.")
        }
        .confirmationDialog("Forget the Google albums made so far?", isPresented: $confirmForget) {
            Button("Forget", role: .destructive) { model.forgetAlbumLinks() }
        } message: {
            Text("The next run creates new Google Photos albums for your selected albums. Use this after deleting those albums in Google Photos.")
        }
    }

    @ViewBuilder
    private var connectStatus: some View {
        switch model.connectState {
        case .connecting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Connecting to Google Photos...").foregroundStyle(.secondary)
            }
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case .idle, .signingIn:
            EmptyView()
        }
    }

    @ViewBuilder
    private var accountStatus: some View {
        switch model.account {
        case .missing: Text("Not connected").foregroundStyle(.secondary)
        case .checking: ProgressView().controlSize(.small)
        case let .connected(email): Text(email ?? "Connected").foregroundStyle(.green)
        case let .failed(message): Text(message).foregroundStyle(.orange).multilineTextAlignment(.trailing)
        }
    }
}
