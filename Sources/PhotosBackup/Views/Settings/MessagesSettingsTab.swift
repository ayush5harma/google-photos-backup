import PhotosBackupCore
import SwiftUI

struct MessagesSettingsTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let archive = model.archive
        Form {
            Section {
                Toggle("Back up photos and videos from Messages", isOn: Binding(get: { model.settings.messagesMedia },
                                                                                 set: { model.setMessagesMedia($0) }))
                LabeledContent("Status") {
                    Text(messagesMediaStatus).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                }
                HStack {
                    Button("Back Up Messages Media Now") { model.backUpMessages() }
                        .disabled(!model.settings.messagesMedia || !model.hasAuthData || model.engine.isActive || model.isMessagesScanning)
                    Spacer()
                    Button("Full Disk Access…") { model.openFullDiskAccess() }
                }
            } header: {
                Text("Messages media to Google Photos")
            } footer: {
                FormNote("Off unless you turn it on. Uploads copies of the images and videos on this Mac from your conversations; never message text, chat names or contacts, and it never changes Messages. macOS needs Full Disk Access for Photos Backup before it can read them.")
            }

            Section {
                Toggle("Keep an archive of my messages", isOn: $model.settings.messagesArchive)
                Group {
                    LabeledContent("Folder") {
                        HStack(spacing: 8) {
                            Text(abbreviated(archive.folder.path))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(archive.folder.path)
                            Button("Choose…") { archive.chooseFolder() }
                        }
                    }
                    Toggle("Archive automatically every day", isOn: $model.settings.archiveAutomatically)
                    Toggle("Include attachments", isOn: $model.settings.archiveAttachments)
                    Toggle("Show contact names", isOn: $model.settings.archiveContactNames)
                    StepperRow(title: "Database copies to keep", value: $model.settings.archiveSnapshotsToKeep, range: BackupSettings.snapshotRange,
                               display: { $0 == 0 ? "None" : $0.formatted() })
                }
                .disabled(!model.settings.messagesArchive)
                LabeledContent("Last archived") {
                    archiveStatus
                }
                HStack {
                    if archive.isRunning {
                        Button("Stop Archiving") { archive.cancel() }
                    } else {
                        Button("Archive Now") { archive.start(trigger: .manual) }
                            .disabled(!model.settings.messagesArchive)
                    }
                    Spacer()
                    Button("Show in Finder") { archive.revealInFinder() }
                    Button("Open in Browser") { archive.openInBrowser() }
                        .disabled(archive.overview == nil)
                }
            } header: {
                Text("Messages archive")
            } footer: {
                FormNote("A readable copy of every conversation, with reactions, replies and attachments, kept up to date in a folder on this Mac. Nothing in it leaves your Mac. Database copies are dated snapshots of Messages' own database, for a full restore.")
            }
        }
        .settingsForm(height: 700)
    }

    @ViewBuilder
    private var archiveStatus: some View {
        let archive = model.archive
        switch archive.status {
        case .off, .idle:
            if let last = archive.overview?.lastArchived {
                Text(last.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
            } else {
                Text(model.settings.messagesArchive ? "Not yet" : "Off").foregroundStyle(.secondary)
            }
        case let .running(phase, done, total):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(total > 0 ? "\(phase), \(done.formatted()) of \(total.formatted())" : phase)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        case let .finished(date):
            Text(date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
        case .needsFullDiskAccess:
            Button("Allow Full Disk Access…") { model.openFullDiskAccess() }
        case let .failed(message):
            Text(message).foregroundStyle(.orange).multilineTextAlignment(.trailing)
        }
    }

    private var messagesMediaStatus: String {
        switch model.visibleMessagesStatus {
        case .off: "Off"
        case .idle: "Ready"
        case .scanning: "Looking for attachments…"
        case let .ready(found, skipped, partial):
            "\(found.formatted()) ready\(partial ? ", more to look through" : "")\(skipped > 0 ? ", \(skipped.formatted()) not on this Mac" : "")"
        case let .failed(message): message
        }
    }

    private func abbreviated(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
