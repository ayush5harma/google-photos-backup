import PhotosBackupCore
import SwiftUI

struct BackupSettingsTab: View {
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
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.bottom, 4)
                        .tag(quality)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            } header: {
                Text("Upload quality")
            }

            Section {
                StepperRow(title: "Parallel uploads", value: $model.settings.threads, range: BackupSettings.threadRange)
                StepperRow(title: "Items per batch", value: $model.settings.batchSize, range: BackupSettings.batchRange, step: 5)
                Toggle("Recreate my albums in Google Photos", isOn: $model.settings.mirrorAlbums)
                Toggle("Back up edits again", isOn: $model.settings.reuploadEdits)
            } header: {
                Text("Uploads")
            } footer: {
                FormNote("More parallel uploads finish sooner but use more bandwidth; 2 suits most connections. Larger batches need more free disk space while they upload. Edited photos are uploaded again as edited, the way Google Photos would back them up.")
            }

            Section {
                Toggle("On a metered network, like an iPhone hotspot", isOn: $model.settings.pauseOnExpensiveNetwork)
                Toggle("In Low Data Mode", isOn: $model.settings.pauseInLowDataMode)
                Toggle("On battery power", isOn: $model.settings.pauseOnBattery)
                Toggle("In Low Power Mode", isOn: $model.settings.pauseInLowPowerMode)
                conditionsLine
            } header: {
                Text("Pause uploads when")
            } footer: {
                FormNote("Automatic backups wait while one of these holds and continue by themselves when it clears. Back Up Now runs anyway.")
            }
        }
        .settingsForm(height: 700)
    }

    @ViewBuilder
    private var conditionsLine: some View {
        let blocking = model.conditions.blocking(for: model.settings)
        LabeledContent("Right now") {
            Text(model.conditions.summary).foregroundStyle(.secondary)
        }
        if let blocking {
            Label(blocking.title, systemImage: blocking.symbol)
                .foregroundStyle(.orange)
        }
    }
}

extension UploadQuality {
    var settingsTitle: String {
        switch self {
        case .original: "Original, free"
        case .saver: "Storage saver"
        case .quota: "Original, counts against storage"
        }
    }

    var explanation: String {
        switch self {
        case .original: "Full-quality files, uploaded the way older Pixel phones do, so they don't use your Google storage. Google Photos may still label them Storage saver; the file size shows the real quality."
        case .saver: "Google reduces the file size. Doesn't use your Google storage."
        case .quota: "Full quality, counted against your Google storage like an upload from a new phone. Use this if the free option stops working."
        }
    }
}
