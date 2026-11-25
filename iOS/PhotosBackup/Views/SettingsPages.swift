import PhotosBackupCore
import SwiftUI

struct BackupSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker("Upload quality", selection: $model.settings.quality) {
                    ForEach(UploadQuality.allCases) { quality in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(quality.settingsTitle)
                            Text(quality.explanation)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .tag(quality)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Upload quality")
            }
            Section {
                Toggle("Back up automatically", isOn: $model.settings.automatic)
                Toggle("Recreate my albums in Google Photos", isOn: $model.settings.mirrorAlbums)
                Toggle("Back up edits again", isOn: $model.settings.reuploadEdits)
            } footer: {
                Text("Automatic backups run when Photos changes and when iOS gives the app time in the background. Edited photos are uploaded again as edited, the way Google Photos would back them up.")
            }
        }
        .navigationTitle("Backup")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The Mac's "Pause uploads when" in iPhone words. The keys are the Mac's:
/// Wi-Fi only is pauseOnExpensiveNetwork (cellular and hotspots are the
/// expensive paths), Only while charging is pauseOnBattery.
struct WhenToBackUpView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Wi-Fi only", isOn: $model.settings.pauseOnExpensiveNetwork)
                Toggle("Not in Low Data Mode", isOn: $model.settings.pauseInLowDataMode)
                Toggle("Only while charging", isOn: $model.settings.pauseOnBattery)
                Toggle("Not in Low Power Mode", isOn: $model.settings.pauseInLowPowerMode)
            } footer: {
                Text("Automatic backups wait while one of these holds and continue by themselves when it clears. Back Up Now runs anyway.")
            }
            Section("Right now") {
                LabeledContent("Conditions", value: model.conditions.summary)
                if let blocking = model.conditions.blocking(for: model.settings) {
                    Label(blocking.phoneTitle, systemImage: blocking.symbol)
                        .foregroundStyle(.orange)
                } else {
                    Label("Nothing holds automatic backups", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                }
            }
        }
        .navigationTitle("When to Back Up")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct NotificationSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("When an automatic backup finishes", isOn: $model.settings.notifyWhenFinished)
                Toggle("About problems that need you", isOn: $model.settings.notifyAboutProblems)
            } footer: {
                Text("iOS asks once before Photos Backup can notify you.")
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct AdvancedSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmingClear = false

    var body: some View {
        Form {
            Section {
                ShareLink(item: model.report(), subject: Text("Photos Backup diagnostic report"),
                          preview: SharePreview("Photos Backup diagnostic report")) {
                    Label("Share Diagnostic Report", systemImage: "square.and.arrow.up")
                }
            } footer: {
                Text("The report lists versions, settings, recent runs and problems, with account addresses, file names and tokens removed, so it is safe to attach to a bug report.")
            }
            Section {
                Button("Clear Activity…", role: .destructive) { confirmingClear = true }
            } footer: {
                Text("Clears the run history and the timeline in Activity. Your backups and what has been uploaded are not affected.")
            }
        }
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Clear the run history and timeline?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Clear Activity", role: .destructive) { model.clearActivity() }
        }
    }
}

struct AboutView: View {
    private static let repository = URL(string: "https://github.com/ayush5harma/google-photos-backup")!
    private static let acknowledgements = URL(string: "https://github.com/ayush5harma/google-photos-backup/blob/main/ACKNOWLEDGEMENTS.md")!
    private static let gpmc = URL(string: "https://github.com/xob0t/gpmc")!
    private static let gotohp = URL(string: "https://github.com/xob0t/gotohp")!

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    AppMark(size: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Photos Backup").font(.headline)
                        Text("Version \(AppEnvironment.version)").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            Section("Credits") {
                Link("Upload engine: gpmc by xob0t", destination: Self.gpmc)
                Link("Sign-in flow: gotohp by xob0t", destination: Self.gotohp)
                Link("All acknowledgements", destination: Self.acknowledgements)
                Link("Source code", destination: Self.repository)
            }
            Section {
                Text("Photos Backup is not made by Google. It talks to Google Photos' unofficial mobile interface, as an Android phone would. Google can change or end that at any time; uploads would then count against your storage or stop, and nothing in Photos is touched either way.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}
