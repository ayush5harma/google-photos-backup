import PhotosBackupCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var authDraft = ""
    @State private var confirmReset = false
    @State private var confirmForget = false

    private static let authHelp = URL(string: "https://github.com/xob0t/gpmc#auth_data-where-do-i-get-mine")!
    private static let gpmc = URL(string: "https://github.com/xob0t/gpmc")!

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                LabeledContent("Status") { accountStatus }
                SecureField("auth_data", text: $authDraft, prompt: Text("androidId=...&Email=...&Token=..."))
                HStack {
                    Link("Where do I get auth_data?", destination: Self.authHelp)
                    Spacer()
                    if model.authData != nil {
                        Button("Remove", role: .destructive) { model.removeAuthData() }
                        Button("Test") { Task { await model.checkAccount() } }
                    }
                    Button("Save") {
                        let value = authDraft
                        authDraft = ""
                        Task { await model.saveAuthData(value) }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(authDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } header: {
                Text("Google Account")
            } footer: {
                Text("The auth_data string comes from Google Photos for Android (the gpmc README shows two ways to get it). It holds a long-lived Google token, so it is kept in your login keychain and handed to the uploader over a pipe, never on a command line.")
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
                Text("Resetting is safe: before sending anything, gpmc asks Google whether it already has the file's exact bytes, so nothing is uploaded twice. It only makes the next run slower.")
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
            Text("The next run checks every selected item with Google again.")
        }
        .confirmationDialog("Forget the Google albums made so far?", isPresented: $confirmForget) {
            Button("Forget", role: .destructive) { model.forgetAlbumLinks() }
        } message: {
            Text("The next run creates new Google Photos albums for your selected albums. Use this after deleting those albums in Google Photos.")
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
