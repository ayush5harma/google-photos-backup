import PhotosBackupCore
import SwiftUI

/// Overview: where the backup stands, in one look. The Mac's HomeView laid
/// out for a phone: banners, the ring, each account, the counts, the albums
/// and the last runs.
struct OverviewView: View {
    @Environment(AppModel.self) private var model

    private static let albumRowsShown = 4

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                AttentionBanners()
                OverviewHero()
                if !model.accounts.isEmpty { AccountsOverview() }
                stats
                selectedAlbums
                RecentRuns()
            }
            .readablePage()
        }
        .background(Color.pageBackground)
        .navigationTitle("Overview")
    }

    private var stats: some View {
        let failed = model.status.failedCount
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
            StatTile(value: model.leadingSummary.backedUp.formatted(), label: "Backed up", symbol: "checkmark.icloud", tint: .green)
            StatTile(value: model.overallSummary.pending.formatted(), label: "To back up", symbol: "arrow.up.circle", tint: .accentColor)
            StatTile(value: model.summary.selectedAlbums.formatted(), label: model.summary.selectedAlbums == 1 ? "Album" : "Albums",
                     symbol: "rectangle.stack", tint: .orange)
            StatTile(value: failed.formatted(), label: "Failed", symbol: "exclamationmark.triangle", tint: failed > 0 ? .red : .secondary)
        }
    }

    private var selectedAlbums: some View {
        let albums = model.selectedAlbums
        return VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Selected albums", action: albums.isEmpty ? nil : ("Show All", { model.tab = .albums }))
            Card(padding: 0) {
                if albums.isEmpty {
                    HStack {
                        Text(model.albumsLoaded ? "No albums selected yet." : "Albums appear once Photos access is allowed.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        if model.albumsLoaded { Button("Choose") { model.tab = .albums } }
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
            }
        }
    }
}

/// The ring, the calm status line and the controls, at the top.
private struct OverviewHero: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let status = model.menuStatus
        let engine = model.status
        let overall = model.overallSummary
        let coverage = overall.total == 0 ? 0 : Double(overall.backedUp) / Double(overall.total)
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 18) {
                ProgressRing(fraction: model.hasAuthData ? (engine.isActive ? engine.runFraction : coverage) : 0, lineWidth: 9) {
                    ringCenter(status)
                }
                .frame(width: 104, height: 104)
                .tint(tint(status))
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.heroTitle)
                        .font(.title2.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(model.heroDetail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            if engine.isActive || engine.phase == .paused { runLine(engine) }
            actions(engine)
            if let last = model.lastBackup {
                Label("Last backup \(last.relativeDescription)", systemImage: "clock")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .panelBackground()
    }

    @ViewBuilder
    private func ringCenter(_ status: MenuBarStatus) -> some View {
        if status.kind == .upToDate {
            Image(systemName: "checkmark")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(.tint)
        } else if model.hasAuthData, model.summary.total > 0 {
            VStack(spacing: 0) {
                Text(model.status.isActive ? "\(Int(model.status.runFraction * 100))%" : model.coverageText)
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(model.status.isActive ? "this run" : "backed up").font(.caption2).foregroundStyle(.secondary)
            }
        } else {
            Image(systemName: model.hasAuthData ? "photo.on.rectangle.angled" : "person.crop.circle.badge.plus")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
        }
    }

    private func runLine(_ engine: BackupEngineStatus) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: engine.runTotal > 0 ? engine.runFraction : 0)
                .progressViewStyle(.linear)
            HStack {
                Text("\(engine.runDone.formatted()) of \(engine.runTotal.formatted())")
                    .monospacedDigit()
                Spacer()
                if let name = engine.currentFilename {
                    Text(name).lineLimit(1).truncationMode(.middle)
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func actions(_ engine: BackupEngineStatus) -> some View {
        switch engine.phase {
        case .paused, .pausing:
            HStack(spacing: 10) {
                Button { model.resume() } label: { Label("Resume", systemImage: "play.fill") }
                    .buttonStyle(ProminentButtonStyle())
                Button(role: .destructive) { model.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                    .buttonStyle(TintedButtonStyle(color: .red))
            }
        case .running, .waiting, .stopping:
            HStack(spacing: 10) {
                Button { model.pause() } label: { Label("Pause", systemImage: "pause.fill") }
                    .buttonStyle(TintedButtonStyle(color: .orange))
                    .disabled(engine.phase == .stopping)
                Button(role: .destructive) { model.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                    .buttonStyle(TintedButtonStyle(color: .red))
                    .disabled(engine.phase == .stopping)
            }
        case .idle:
            if model.hasAuthData {
                Button { model.backUpNow() } label: { Label("Back Up Now", systemImage: "arrow.up") }
                    .buttonStyle(ProminentButtonStyle())
                    .disabled(!model.canReadPhotos)
            } else {
                Button { model.beginSignIn() } label: { Label("Sign In with Google", systemImage: "person.crop.circle") }
                    .buttonStyle(ProminentButtonStyle())
            }
        }
    }

    private func tint(_ status: MenuBarStatus) -> Color {
        switch status.kind {
        case .upToDate: .green
        case .paused, .waiting: .orange
        case .attention: model.hasAuthData ? .orange : .secondary
        case .backingUp, .ready: .accentColor
        }
    }
}

/// Each account's share of the selection, so an account still catching up
/// is visible next to one that is complete.
private struct AccountsOverview: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: model.accounts.count == 1 ? "Google account" : "Google accounts",
                          action: ("Manage", { model.settingsPath = []; model.tab = .settings }))
            Card(padding: 0) {
                ForEach(Array(model.accounts.enumerated()), id: \.element.id) { index, account in
                    if index > 0 { Divider().padding(.leading, 52) }
                    row(account).padding(.horizontal, 14).padding(.vertical, 10)
                }
            }
        }
    }

    private func row(_ account: BackupAccount) -> some View {
        let summary = model.summary(of: account.id)
        let running = model.status.accounts.first { $0.account == account.id }
        let fraction = running?.fraction ?? (summary.total == 0 ? 0 : Double(summary.backedUp) / Double(summary.total))
        // An account a run skips (left out, or before its storage check) is drawn dimmed.
        let included = model.isIncluded(account.id) && account.storageChecked
        return HStack(spacing: 12) {
            AccountAvatar(size: 28, email: account.email)
                .opacity(included ? 1 : 0.5)
            VStack(alignment: .leading, spacing: 5) {
                Text(account.title).lineLimit(1).truncationMode(.middle)
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .tint(included ? .accentColor : .secondary)
                    .opacity(included ? 1 : 0.5)
                Text(state(account, summary: summary, running: running))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func state(_ account: BackupAccount, summary: BackupSummary, running: BackupEngineStatus.AccountProgress?) -> String {
        if let running { return "Backing up · \(running.done.formatted()) of \(running.total.formatted())" }
        if !account.storageChecked { return "Waiting for its storage check" }
        if !model.isIncluded(account.id) { return "Not included" }
        switch model.status(of: account.id) {
        case .missing: return "Signed out"
        case .failed: return "Needs attention"
        default: break
        }
        if summary.total > 0, summary.pending == 0 { return "Up to date" }
        let percent = summary.total == 0 ? 0 : min(99, summary.backedUp * 100 / summary.total)
        return "\(percent)% · \(summary.pending.formatted()) to back up"
    }
}

/// The last few runs, linking to Activity for the rest.
private struct RecentRuns: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let runs = Array(model.diagnostics.runs.prefix(3))
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Recent activity", action: ("Show All", { model.tab = .activity }))
            Card(padding: 0) {
                if runs.isEmpty {
                    Text("Backups you run appear here.")
                        .foregroundStyle(.secondary)
                        .padding(14)
                } else {
                    ForEach(Array(runs.enumerated()), id: \.element.id) { index, run in
                        if index > 0 { Divider().padding(.leading, 48) }
                        RunRow(run: run, account: model.accounts.count > 1 ? model.accountTitle(reference: run.account) : nil)
                            .padding(.horizontal, 14)
                    }
                }
            }
        }
    }
}

/// What still stands between the person and a working backup.
struct AttentionBanners: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let items = model.attention
        let error = model.isStorageFull ? nil : (model.status.lastError ?? model.stateError)
        if !items.isEmpty || error != nil {
            VStack(spacing: 8) {
                ForEach(items) { item in
                    Banner(symbol: item.symbol, text: item.detail, color: item.tint, title: item.title,
                           action: (item.actionTitle, { model.perform(item.action) }))
                }
                if let error {
                    Banner(symbol: "exclamationmark.triangle.fill", text: error, color: .orange)
                }
            }
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
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if showsBar, selected, !progress.isComplete {
                    ProgressView(value: Double(progress.backedUp), total: Double(max(progress.total, 1)))
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 220)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            trailing
        }
        .padding(.vertical, 9)
    }
}

/// One run in the Overview and in Activity's history.
struct RunRow: View {
    let run: RunRecord
    /// With several accounts, the address of the one the run went to.
    var account: String?

    var body: some View {
        // The Mac puts the account on the title line; a phone is too narrow
        // for both, so it gets a line of its own.
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            AlbumIcon(symbol: symbol, size: 24, tint: tint)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).lineLimit(1)
                    Spacer(minLength: 8)
                    Text((run.finishedAt ?? run.startedAt).relativeDescription)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let account {
                    Text(account).font(.footnote).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Text(summary).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private var title: String { "\(run.kind.title) · \(run.trigger.title)" }

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
