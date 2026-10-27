import PhotosBackupCore
import PhotosUI
import SwiftUI

/// Overview: where the backup stands, in one look.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Binding var section: AppSection

    private static let albumRowsShown = 5

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                // The hero carries the sign-in button for a missing account.
                SetupBanners(section: $section, hiding: model.hasAuthData ? [] : ["sign-in"])
                OverviewHero()
                stats
                selectedAlbums
                RecentActivity(section: $section)
            }
            .readablePage()
        }
        .navigationTitle("Overview")
        .navigationSubtitle(model.windowSubtitle)
    }

    private var stats: some View {
        let summary = model.summary
        let failed = model.engine.failedCount
        return HStack(spacing: 12) {
            StatTile(value: summary.backedUp.formatted(), label: "Backed up", symbol: "checkmark.icloud", tint: .green)
            StatTile(value: summary.pending.formatted(), label: "To back up", symbol: "arrow.up.circle", tint: .accentColor)
            StatTile(value: summary.selectedAlbums.formatted(), label: summary.selectedAlbums == 1 ? "Album" : "Albums",
                     symbol: "rectangle.stack", tint: .orange)
            StatTile(value: failed.formatted(), label: "Failed", symbol: "exclamationmark.triangle", tint: failed > 0 ? .red : .secondary)
        }
    }

    private var selectedAlbums: some View {
        @Bindable var model = model
        let albums = model.selectedAlbums
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Selected albums").font(.headline)
                Spacer()
                Toggle("Back up automatically", isOn: $model.settings.automatic)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .help("Back up selected albums whenever Photos changes, and every 30 minutes")
            }
            .padding(.horizontal, 2)
            Card(padding: 0) {
                if albums.isEmpty {
                    HStack {
                        Text(model.albumsLoaded ? "No albums selected yet." : "Albums appear once Photos access is allowed.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        if model.albumsLoaded { Button("Choose Albums") { section = .albums } }
                    }
                    .padding(14)
                }
                ForEach(Array(albums.prefix(Self.albumRowsShown).enumerated()), id: \.element.id) { index, album in
                    if index > 0 { Divider().padding(.leading, 58) }
                    let progress = model.progress(of: album)
                    AlbumRow(album: album, progress: progress, showsBar: true) {
                        AlbumStatusMark(backedUp: progress.backedUp, total: progress.total)
                    }
                    .padding(.horizontal, 14)
                }
                if albums.count > Self.albumRowsShown {
                    Divider()
                    Button("Show all \(albums.count.formatted()) selected albums") { section = .albums }
                        .buttonStyle(.link)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                }
            }
        }
    }
}

/// The large ring and calm status copy at the top of the Overview.
private struct OverviewHero: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let status = model.status
        let engine = model.engine
        let summary = model.summary
        let coverage = summary.total == 0 ? 0 : Double(summary.backedUp) / Double(summary.total)
        HStack(alignment: .center, spacing: 24) {
            ProgressRing(fraction: model.hasAuthData ? coverage : 0, lineWidth: 10) {
                VStack(spacing: 0) {
                    if status.kind == .upToDate {
                        Image(systemName: "checkmark")
                            .font(.system(size: 38, weight: .bold))
                            .foregroundStyle(.tint)
                            .transition(.scale.combined(with: .opacity))
                    } else if model.hasAuthData, summary.total > 0 {
                        Text(model.coverageText)
                            .font(.system(size: 28, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Text("backed up").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Image(systemName: model.hasAuthData ? "photo.on.rectangle.angled" : "person.crop.circle.badge.plus")
                            .font(.system(size: 30, weight: .regular))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 124, height: 124)
            .tint(tint(status))

            VStack(alignment: .leading, spacing: 6) {
                Text(model.heroTitle)
                    .font(.title.weight(.semibold))
                Text(detail(status, summary: summary))
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if engine.isActive {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: engine.runTotal > 0 ? engine.runFraction : nil)
                            .progressViewStyle(.linear)
                        if let item = model.currentItem {
                            Text(item.filename)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .padding(.top, 6)
                }
                actions
                    .padding(.top, 8)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .panelBackground()
    }

    @ViewBuilder
    private var actions: some View {
        let engine = model.engine
        HStack(spacing: 8) {
            switch engine.phase {
            case .paused, .pausing:
                Button { engine.resume() } label: { Label("Resume", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent)
            case .running, .waiting, .stopping:
                Button { engine.pauseAfterCurrent() } label: { Label("Pause", systemImage: "pause.fill") }
                    .disabled(engine.phase != .running)
                Button(role: .destructive) { model.stopBackup() } label: { Label("Stop", systemImage: "stop.fill") }
                    .disabled(engine.phase == .stopping)
            case .idle:
                if model.hasAuthData {
                    Button { model.startBackupNow() } label: { Label("Back Up Now", systemImage: "arrow.up") }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canReadPhotos && !model.settings.messagesMedia)
                } else {
                    Button { model.beginSignIn() } label: { Label("Sign In with Google…", systemImage: "person.crop.circle") }
                        .buttonStyle(.borderedProminent)
                }
            }
            PickPhotosButton(plain: false) {
                Label("Choose Photos…", systemImage: "photo.badge.plus")
            }
            .help("Back up a hand-picked selection now")
        }
        .controlSize(.large)
    }

    private func tint(_ status: MenuBarStatus) -> Color {
        switch status.kind {
        case .upToDate: .green
        case .paused, .waiting: .orange
        case .attention: model.hasAuthData ? .orange : .secondary
        case .backingUp, .ready: .accentColor
        }
    }

    private func detail(_ status: MenuBarStatus, summary: BackupSummary) -> String {
        let engine = model.engine
        switch status.kind {
        case .upToDate:
            return "\(summary.backedUp.formatted()) photos and videos are in Google Photos."
        case .backingUp:
            if engine.isActive {
                return engine.remaining > 0 ? "\(engine.remaining.formatted()) items left in this backup." : "Looking for new photos and videos…"
            }
            return "Your conversations are being saved to the archive."
        case .ready:
            return summary.total == 0 ? "Turn on albums in Albums, or start with All Photos." : "\(summary.pending.formatted()) of \(summary.total.formatted()) items aren't in Google Photos yet."
        case .paused:
            return summary.pending > 0 ? "\(summary.pending.formatted()) items are waiting. Resume to continue." : "Resume to continue."
        case .waiting:
            let reason = engine.waitReason
            return [reason?.title, reason?.resumeHint ?? "Uploads continue by themselves."].compactMap { $0 }.joined(separator: ". ")
        case .attention:
            if !model.hasAuthData { return "Connect your Google account to back up \(summary.total.formatted()) items." }
            if model.isStorageFull || model.account.isFailed {
                return "\(summary.backedUp.formatted()) of \(summary.total.formatted()) items are in Google Photos; the rest wait until this is fixed."
            }
            return "Everything else is in Google Photos. Retry them from Activity."
        }
    }
}

/// The last few runs (or, before any run is recorded, the last uploads),
/// linking to Activity for the rest.
private struct RecentActivity: View {
    @Environment(AppModel.self) private var model
    @Binding var section: AppSection

    var body: some View {
        let runs = Array(model.diagnostics.runs.suffix(3).reversed())
        let items = Array(model.engine.activity.prefix(4))
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Recent activity", action: ("Show All", { section = .activity }))
            Card(padding: 0) {
                if runs.isEmpty, items.isEmpty {
                    Text("Backups you run appear here.")
                        .foregroundStyle(.secondary)
                        .padding(14)
                } else if !runs.isEmpty {
                    ForEach(Array(runs.enumerated()), id: \.element.id) { index, run in
                        if index > 0 { Divider().padding(.leading, 46) }
                        RunRow(run: run).padding(.horizontal, 14)
                    }
                } else {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider().padding(.leading, 46) }
                        ItemRow(item: item).padding(.horizontal, 14)
                    }
                }
            }
        }
    }
}

private struct RunRow: View {
    let run: RunRecord

    var body: some View {
        HStack(spacing: 12) {
            AlbumIcon(symbol: symbol, size: 22, tint: tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(run.kind.title) · \(run.trigger.title)").lineLimit(1)
                Text(summary).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text((run.finishedAt ?? run.startedAt).relativeDescription)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private var summary: String {
        var parts: [String] = []
        if run.uploaded > 0 { parts.append("\(run.uploaded.formatted()) backed up") }
        if run.existing > 0 { parts.append("\(run.existing.formatted()) already there") }
        if run.failed > 0 { parts.append("\(run.failed.formatted()) failed") }
        if case let .failed(reason) = run.outcome { parts.append(reason) }
        if run.outcome == .stopped { parts.append("stopped") }
        return parts.isEmpty ? "Nothing new" : parts.joined(separator: ", ")
    }

    private var symbol: String {
        switch run.outcome {
        case .failed: "xmark"
        case .stopped, .paused: "pause.fill"
        default: run.failed > 0 ? "exclamationmark" : "checkmark"
        }
    }

    private var tint: Color {
        switch run.outcome {
        case .failed: .red
        case .stopped, .paused: .secondary
        default: run.failed > 0 ? .orange : .green
        }
    }
}

private struct ItemRow: View {
    let item: ActivityItem

    var body: some View {
        HStack(spacing: 12) {
            AlbumIcon(symbol: symbol, size: 22, tint: tint)
            Text(item.filename).lineLimit(1).truncationMode(.middle)
            Spacer()
            Text(item.status.label).font(.callout).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.vertical, 8)
    }

    private var symbol: String {
        switch item.status {
        case .uploaded, .existing: "checkmark"
        case .failed: "xmark"
        case .stopped: "stop.fill"
        default: "arrow.up"
        }
    }

    private var tint: Color {
        switch item.status {
        case .uploaded, .existing: .green
        case .failed: .red
        case .stopped: .secondary
        default: .accentColor
        }
    }
}

struct AlbumRow<Trailing: View>: View {
    let album: LibraryAlbum
    let progress: AlbumProgress
    var selected = true
    var showsBar = false
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            AlbumIcon(symbol: album.symbol)
            VStack(alignment: .leading, spacing: 3) {
                Text(album.title).lineLimit(1).truncationMode(.tail)
                Text(selected ? "\(progress.backedUp.formatted()) of \(progress.total.formatted()) backed up" : "\(progress.total.formatted()) items")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if showsBar, selected, !progress.isComplete {
                    ProgressView(value: Double(progress.backedUp), total: Double(max(progress.total, 1)))
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                        .frame(maxWidth: 220)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            trailing
        }
        .padding(.vertical, 8)
    }
}

/// The account at a glance; kept for views that show it inline.
struct AccountBadge: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        AccountAvatar(size: 28)
            .help(model.accountEmail ?? "No Google account yet")
    }
}

/// Opens the system photo picker and backs up whatever is chosen.
struct PickPhotosButton<Label: View>: View {
    @Environment(AppModel.self) private var model
    /// Plain draws only the label (a card); otherwise a regular button.
    var plain = true
    @ViewBuilder var label: Label
    @State private var selection: [PhotosPickerItem] = []

    var body: some View {
        // .current: a pick that goes up from the picker's own file keeps its
        // format instead of becoming a JPEG.
        styled(PhotosPicker(selection: $selection, matching: .any(of: [.images, .videos]), preferredItemEncoding: .current,
                            photoLibrary: .shared()) { label })
            .disabled(!model.hasAuthData || !model.canReadPhotos)
            .onChange(of: selection) { _, items in
                // itemIdentifier is the PHAsset local identifier because the
                // picker was given the shared library.
                let picks = items.compactMap { item in item.itemIdentifier.map { ($0, item) } }
                selection = []
                guard !picks.isEmpty else { return }
                // Only what PhotoKit cannot see, and Google does not have yet,
                // is copied out of the picker, while its access is fresh; the
                // rest exports from the library as before and starts at once.
                let ids = picks.map(\.0)
                let unseen = Set(AssetExporter.unseen(ids)).subtracting(ids.filter { model.state.uploaded[$0] != nil })
                let visible = ids.filter { !unseen.contains($0) }
                if !visible.isEmpty { model.engine.backUp(picked: visible) }
                guard !unseen.isEmpty else { return }
                Task {
                    var files: [String: URL] = [:]
                    for (id, item) in picks where unseen.contains(id) {
                        do {
                            if let file = try await item.loadTransferable(type: PickedFile.self) { files[id] = file.url }
                        } catch {
                            model.log(.photos, "Photos did not hand over a picked item: \(error.localizedDescription)", problem: true)
                        }
                    }
                    model.engine.backUp(picked: ids.filter { unseen.contains($0) }, files: files)
                }
            }
    }

    @ViewBuilder
    private func styled(_ picker: some View) -> some View {
        if plain { picker.buttonStyle(.plain) } else { picker.buttonStyle(.bordered) }
    }
}

/// What still stands between the person and a working backup, and the
/// last error a run left.
struct SetupBanners: View {
    @Environment(AppModel.self) private var model
    @Binding var section: AppSection
    /// Attention ids a view already shows in its own way.
    var hiding: Set<String> = []

    var body: some View {
        let attention = model.attention.filter { $0.id != "waiting" && !hiding.contains($0.id) }
        if !attention.isEmpty || errorText != nil {
            VStack(spacing: 8) {
                ForEach(attention) { AttentionRow(item: $0) }
                if let error = errorText {
                    Banner(symbol: "exclamationmark.triangle.fill", text: error, color: .orange,
                           action: error.contains("Sign in") ? ("Account Settings", { AppRouter.shared.openSettings(.account) }) : nil)
                }
            }
        }
    }

    /// The run's last error, unless an attention row already says it.
    private var errorText: String? {
        if model.isStorageFull { return model.stateError }
        return model.engine.lastError ?? model.stateError
    }
}

extension AppModel {
    /// The window's subtitle: "Up to date · Last backup 5 minutes ago".
    var windowSubtitle: String {
        let headline = status.headline
        guard !engine.isActive, let last = lastBackup else { return headline }
        return "\(headline) · Last backup \(last.relativeDescription)"
    }
}
