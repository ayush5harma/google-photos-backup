import PhotosBackupCore
import PhotosUI
import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Binding var section: AppSection

    private static let albumRowsShown = 4

    var body: some View {
        let summary = model.summary
        let engine = model.engine
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                SetupBanners(section: $section)
                statusCard(summary, engine: engine)
                HStack(spacing: 14) {
                    Button { model.startBackupNow() } label: {
                        tile(symbol: "arrow.up.circle.fill", title: "Back Up Now", detail: "\(summary.backedUp) of \(summary.total) backed up")
                    }
                    .buttonStyle(.plain)
                    .disabled(engine.isActive || !model.hasAuthData)
                    PickPhotosButton {
                        tile(symbol: "photo.badge.plus", title: "Pick Photos", detail: "Manual backup")
                    }
                }
                selectedAlbums
            }
            .padding(24)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Home")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Photos Backup").font(.largeTitle.bold())
            Spacer()
            AccountBadge()
        }
    }

    private func statusCard(_ summary: BackupSummary, engine: BackupEngine) -> some View {
        Card {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(statusTitle(summary, engine: engine)).font(.title2.bold())
                    Text(statusDetail(summary, engine: engine)).foregroundStyle(.secondary)
                }
                Spacer()
                ProgressRing(fraction: summary.total == 0 ? 0 : Double(summary.backedUp) / Double(summary.total), lineWidth: 6) {
                    Image(systemName: summary.pending == 0 && summary.total > 0 ? "checkmark" : "arrow.up")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.tint)
                        .symbolEffect(.pulse, isActive: engine.isActive)
                }
                .frame(width: 72, height: 72)
            }
            Divider().padding(.vertical, 14)
            HStack {
                stat("\(summary.backedUp)", "Backed up")
                Divider().frame(height: 36)
                stat("\(summary.selectedAlbums)", "Albums")
                Divider().frame(height: 36)
                stat("\(summary.pending)", "In queue")
            }
            HStack(spacing: 12) {
                if engine.phase == .paused || engine.phase == .pausing {
                    Button { engine.resume() } label: { Label("Resume", systemImage: "play.circle") }
                        .buttonStyle(TintedButtonStyle(color: .accentColor))
                } else {
                    Button { engine.pauseAfterCurrent() } label: { Label("Pause", systemImage: "pause.circle") }
                        .buttonStyle(TintedButtonStyle(color: .accentColor))
                        .disabled(engine.phase != .running)
                }
                Button(role: .destructive) { model.stopBackup() } label: { Label("Stop", systemImage: "stop.circle") }
                    .buttonStyle(TintedButtonStyle(color: .red))
                    .disabled((engine.phase == .idle && !model.isMessagesScanning) || engine.phase == .stopping)
            }
            .padding(.top, 16)
        }
    }

    private func statusTitle(_ summary: BackupSummary, engine: BackupEngine) -> String {
        switch engine.phase {
        case .running: "Backing up..."
        case .pausing: "Pausing after this batch..."
        case .paused: "Paused"
        case .stopping: "Stopping..."
        case .waiting: engine.waitReason?.title ?? "Waiting..."
        case .idle: summary.total == 0 ? "Nothing selected" : summary.pending == 0 ? "Backed up" : "Ready to back up"
        }
    }

    private func statusDetail(_ summary: BackupSummary, engine: BackupEngine) -> String {
        if engine.isActive, engine.remaining > 0 { return "\(engine.remaining) items remaining" }
        if summary.pending > 0 { return "\(summary.pending) items remaining" }
        if let last = engine.lastRun { return "Last checked \(last.formatted(.relative(presentation: .named)))" }
        return summary.total == 0 ? "Choose albums to back up" : "Everything selected is in Google Photos"
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
            Text(label).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func tile(symbol: String, title: String, detail: String) -> some View {
        Card {
            Image(systemName: symbol).font(.title).foregroundStyle(.tint).padding(.bottom, 12)
            Text(title).font(.title3.weight(.semibold))
            Text(detail).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }

    private var selectedAlbums: some View {
        @Bindable var model = model
        let albums = model.selectedAlbums
        return Card {
            HStack {
                Text("Selected Albums").font(.title3.weight(.semibold))
                Spacer()
                Toggle(isOn: $model.settings.automatic) {
                    Label("Automatic", systemImage: "arrow.triangle.2.circlepath")
                }
                .toggleStyle(.button)
                .tint(.green)
                .help("Back up selected albums whenever Photos changes, and every 30 minutes")
            }
            .padding(.bottom, 8)
            if albums.isEmpty {
                Text(model.albumsLoaded ? "No albums selected yet." : "Albums appear once Photos access is allowed.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
            ForEach(Array(albums.prefix(Self.albumRowsShown).enumerated()), id: \.element.id) { index, album in
                if index > 0 { Divider().padding(.leading, 56) }
                AlbumRow(album: album, progress: model.progress(of: album)) {
                    let progress = model.progress(of: album)
                    AlbumStatusMark(backedUp: progress.backedUp, total: progress.total)
                }
            }
            if albums.count > Self.albumRowsShown {
                Button("+ \(albums.count - Self.albumRowsShown) more albums") { section = .albums }
                    .buttonStyle(.link)
                    .padding(.top, 8)
            }
        }
    }
}

struct AlbumRow<Trailing: View>: View {
    let album: LibraryAlbum
    let progress: AlbumProgress
    var selected = true
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 14) {
            AlbumIcon(symbol: album.symbol)
            VStack(alignment: .leading, spacing: 2) {
                Text(album.title).font(.body.weight(.medium))
                Text(selected ? "\(progress.backedUp) of \(progress.total) backed up" : "\(progress.total) items")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            trailing
        }
        .padding(.vertical, 8)
    }
}

struct AccountBadge: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let (symbol, color, help): (String, Color, String) = switch model.account {
        case let .connected(email): ("person.crop.circle.fill", .accentColor, email ?? "Connected")
        case .checking: ("person.crop.circle.badge.clock", .secondary, "Checking the account...")
        case let .failed(message): ("person.crop.circle.badge.exclamationmark", .orange, message)
        case .missing: ("person.crop.circle.badge.plus", .secondary, "No Google account yet")
        }
        Image(systemName: symbol)
            .font(.system(size: 30))
            .foregroundStyle(color)
            .help(help)
    }
}

/// Opens the system photo picker and backs up whatever is chosen.
struct PickPhotosButton<Label: View>: View {
    @Environment(AppModel.self) private var model
    @ViewBuilder var label: Label
    @State private var selection: [PhotosPickerItem] = []

    var body: some View {
        PhotosPicker(selection: $selection, matching: .any(of: [.images, .videos]), photoLibrary: .shared()) { label }
            .buttonStyle(.plain)
            .disabled(!model.hasAuthData || !model.library.isAuthorized)
            .onChange(of: selection) { _, items in
                // itemIdentifier is the PHAsset local identifier because the
                // picker was given the shared library.
                let ids = items.compactMap(\.itemIdentifier)
                selection = []
                if !ids.isEmpty { model.engine.backUp(picked: ids) }
            }
    }
}

/// What still stands between the user and a working backup.
struct SetupBanners: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @Binding var section: AppSection

    var body: some View {
        if !model.library.isAuthorized {
            if model.photosStatus == .notDetermined {
                Banner(symbol: "photo.on.rectangle", text: "Photos Backup needs access to your Photos library.", color: .accentColor,
                       action: ("Allow Access", { Task { await model.requestPhotosAccess() } }))
            } else {
                Banner(symbol: "lock", text: "Photos access is off. Turn on Photos Backup in System Settings > Privacy & Security > Photos.",
                       color: .orange, action: ("Open Settings", openPhotosPrivacy))
            }
        }
        switch model.account {
        case .missing:
            Banner(symbol: "person.crop.circle.badge.plus", text: "Sign in with Google to choose where your photos go.", color: .accentColor,
                   action: ("Sign In", { model.beginSignIn() }))
        case let .failed(message):
            Banner(symbol: "person.crop.circle.badge.exclamationmark", text: message, color: .orange,
                   action: ("Settings", { openSettings() }))
        case .connected, .checking:
            EmptyView()
        }
        if let error = model.engine.lastError ?? model.stateError {
            Banner(symbol: "exclamationmark.triangle", text: error, color: .orange,
                   action: error.contains("Sign in") ? ("Settings", { openSettings() }) : nil)
        }
    }

    private func openPhotosPrivacy() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") {
            NSWorkspace.shared.open(url)
        }
    }
}
