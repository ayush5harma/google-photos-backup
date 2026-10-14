import PhotosBackupCore
import SwiftUI

/// The menu bar panel: where the backup stands, what needs a hand, and the
/// controls, without opening the window.
struct MenuBarPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    static let width: CGFloat = 340

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader()
            PanelHero()
            PanelStats()
            // The hero already says why a run is waiting.
            let attention = model.attention.filter { $0.id != "waiting" }
            if !attention.isEmpty {
                VStack(spacing: 6) {
                    ForEach(attention) { AttentionRow(item: $0, compact: true) }
                }
            }
            PanelControls()
            Divider().padding(.horizontal, 4)
            PanelMenu()
        }
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .frame(width: Self.width)
        .onAppear {
            AppRouter.shared.openWindowAction = openWindow
            AppRouter.shared.openSettingsAction = openSettings
        }
    }
}

private struct PanelHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            AppMark(size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("Photos Backup").font(.headline)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        let headline = model.status.headline
        guard let last = model.lastBackup, !model.engine.isActive else { return headline }
        return "\(headline) · \(last.relativeDescription)"
    }
}

/// The ring and the run: how much of the selection Google has, what is
/// moving now, and the run's own progress.
private struct PanelHero: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let status = model.status
        let engine = model.engine
        let summary = model.summary
        let coverage = summary.total == 0 ? 0 : Double(summary.backedUp) / Double(summary.total)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                ProgressRing(fraction: model.hasAuthData ? coverage : 0, lineWidth: 5) {
                    ringCenter(status, coverage: coverage)
                }
                .frame(width: 56, height: 56)
                .tint(tint(status))
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.heroTitle)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    if status.kind == .backingUp, model.engine.isActive, let item = model.currentItem {
                        Text(item.filename)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text(detail(status, summary: summary, engine: engine))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }
                }
                Spacer(minLength: 0)
            }
            if engine.isActive, engine.runTotal > 0 {
                VStack(spacing: 4) {
                    HStack {
                        Text("This backup")
                        Spacer()
                        Text("\(engine.runDone.formatted()) of \(engine.runTotal.formatted())")
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    ProgressView(value: engine.runFraction)
                        .progressViewStyle(.linear)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("This backup")
                .accessibilityValue("\(engine.runDone) of \(engine.runTotal) items")
            }
        }
        .padding(12)
        .panelBackground()
    }

    @ViewBuilder
    private func ringCenter(_ status: MenuBarStatus, coverage: Double) -> some View {
        switch status.kind {
        case .upToDate:
            Image(systemName: "checkmark").font(.system(size: 20, weight: .bold))
        case .backingUp, .ready:
            if model.hasAuthData, model.summary.total > 0 {
                Text(model.coverageText)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.7)
            } else {
                Image(systemName: "arrow.up").font(.system(size: 18, weight: .semibold))
            }
        case .paused:
            Image(systemName: "pause.fill").font(.system(size: 18, weight: .semibold))
        case .waiting:
            Image(systemName: model.engine.waitReason?.symbol ?? "clock").font(.system(size: 17, weight: .semibold))
        case .attention:
            Image(systemName: model.hasAuthData ? "exclamationmark" : "person.fill").font(.system(size: 18, weight: .bold))
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

    /// Never a repeat of the header line or an attention row: those say
    /// what is wrong, this says where the backup stands.
    private func detail(_ status: MenuBarStatus, summary: BackupSummary, engine: BackupEngine) -> String {
        if status.kind == .backingUp, engine.isActive {
            return model.currentItem?.filename ?? "Looking for new photos and videos…"
        }
        if status.kind == .attention {
            if !model.hasAuthData { return "Sign in to back up \(summary.total.formatted()) items." }
            if model.isStorageFull || model.account.isFailed {
                return "\(summary.backedUp.formatted()) of \(summary.total.formatted()) items are in Google Photos."
            }
            return "Everything else is in Google Photos."
        }
        if status.kind == .waiting { return engine.waitReason?.resumeHint ?? "Continues by itself." }
        if status.kind == .backingUp, case let .running(phase, done, total) = model.archive.status {
            return total > 0 ? "\(phase) · \(done.formatted()) of \(total.formatted())" : phase
        }
        switch status.kind {
        case .upToDate:
            return "\(summary.backedUp.formatted()) items in Google Photos"
        case .ready:
            return summary.total == 0 ? "Choose albums in Photos Backup" : "\(summary.pending.formatted()) of \(summary.total.formatted()) items to go"
        case .paused:
            return summary.pending > 0 ? "\(summary.pending.formatted()) items to go" : "Resume to continue"
        default:
            return status.headline
        }
    }
}

private struct PanelStats: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let summary = model.summary
        let failed = model.engine.failedCount
        VStack(spacing: 0) {
            StatRow(symbol: "photo.on.rectangle.angled", tint: .accentColor, title: "Photos backed up",
                    value: summary.total == 0 ? "None selected" : "\(summary.backedUp.formatted()) of \(summary.total.formatted())")
            Divider().padding(.leading, 38)
            StatRow(symbol: "archivebox", tint: .indigo, title: "Messages archive", value: archiveValue)
            if failed > 0 {
                Divider().padding(.leading, 38)
                StatRow(symbol: "exclamationmark.triangle.fill", tint: .orange, title: "\(failed.formatted()) couldn't be backed up", value: nil) {
                    Button("Retry") { model.engine.retryFailed() }
                        .controlSize(.small)
                        .disabled(model.engine.isActive)
                }
            }
        }
        .padding(.vertical, 2)
        .panelBackground()
    }

    private var archiveValue: String {
        guard model.settings.messagesArchive else { return "Off" }
        switch model.archive.status {
        case let .running(_, done, total): return total > 0 ? "Archiving, \(done.formatted()) of \(total.formatted())" : "Archiving…"
        case .needsFullDiskAccess: return "Needs Full Disk Access"
        case .failed: return "Could not archive"
        default: break
        }
        guard let overview = model.archive.overview else { return "Not archived yet" }
        let conversations = "\(overview.conversations.count.formatted()) chats"
        guard let last = overview.lastArchived else { return conversations }
        return "\(conversations) · \(last.relativeDescription)"
    }
}

private struct StatRow<Accessory: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let value: String?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .frame(width: 18)
            Text(title).lineLimit(1)
            Spacer(minLength: 8)
            if let value {
                Text(value)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            accessory
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .frame(minHeight: 30)
        .accessibilityElement(children: .combine)
    }
}

extension StatRow where Accessory == EmptyView {
    init(symbol: String, tint: Color, title: String, value: String?) {
        self.init(symbol: symbol, tint: tint, title: title, value: value) { EmptyView() }
    }
}

/// One thing in the way, with the action that clears it.
struct AttentionRow: View {
    @Environment(AppModel.self) private var model
    let item: Attention
    var compact = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.symbol)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: compact ? 16 : 20))
                .foregroundStyle(item.tint)
                .frame(width: compact ? 20 : 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(compact ? .callout.weight(.medium) : .headline)
                Text(item.detail)
                    .font(compact ? .caption : .callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            Button(item.actionTitle) { model.perform(item.action) }
                .controlSize(compact ? .small : .regular)
        }
        .padding(.horizontal, compact ? 10 : 14)
        .padding(.vertical, compact ? 8 : 12)
        .background {
            RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous)
                .fill(item.tint.opacity(0.09))
        }
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous)
                .strokeBorder(item.tint.opacity(0.2), lineWidth: 1)
        }
    }
}

/// Back Up Now, Pause or Resume, Stop: glass on macOS 26, side by side so
/// they read as one control group.
private struct PanelControls: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let engine = model.engine
        let paused = engine.phase == .paused || engine.phase == .pausing
        GlassGroup(spacing: 8) {
            HStack(spacing: 8) {
                Button { model.startBackupNow() } label: {
                    Label("Back Up Now", systemImage: "arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .prominentGlassButton()
                .controlSize(.large)
                .keyboardShortcut("b")
                .disabled(engine.isActive || !model.hasAuthData)

                Button {
                    paused ? engine.resume() : engine.pauseAfterCurrent()
                } label: {
                    Image(systemName: paused ? "play.fill" : "pause.fill")
                        .frame(width: 18)
                }
                .glassButton()
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .disabled(!paused && engine.phase != .running)
                .help(paused ? "Resume" : "Pause after the current uploads")
                .accessibilityLabel(paused ? "Resume" : "Pause")

                Button { model.stopBackup() } label: {
                    Image(systemName: "stop.fill").frame(width: 18)
                }
                .glassButton()
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .disabled((!engine.isActive && !model.isMessagesScanning) || engine.phase == .stopping)
                .help("Stop the backup")
                .accessibilityLabel("Stop")
            }
        }
    }
}

/// The menu-like rows under the controls.
private struct PanelMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if model.settings.messagesMedia {
                PanelMenuRow(title: model.isMessagesScanning ? "Looking for Messages Media…" : "Back Up Messages Media",
                             symbol: "photo.on.rectangle") {
                    model.backUpMessages()
                }
                .disabled(model.engine.isActive || model.isMessagesScanning || !model.hasAuthData)
            }
            if model.settings.messagesArchive {
                PanelMenuRow(title: model.archive.isRunning ? "Archiving Messages…" : "Archive Messages Now", symbol: "archivebox") {
                    model.archive.start(trigger: .manual)
                }
                .disabled(model.archive.isRunning)
            }
            PanelMenuRow(title: "Open Photos Backup", symbol: "macwindow") { AppRouter.shared.openMain() }
            PanelMenuRow(title: "Settings…", symbol: "gearshape", shortcut: "⌘,") { AppRouter.shared.openSettings() }
                .keyboardShortcut(",")
            PanelMenuRow(title: "Quit Photos Backup", symbol: "power", shortcut: "⌘Q") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}

private struct PanelMenuRow: View {
    let title: String
    let symbol: String
    var shortcut: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(title)
                Spacer()
                if let shortcut {
                    Text(shortcut).foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PanelMenuRowStyle())
    }
}

/// Menu-item behaviour: a rounded highlight under the pointer.
private struct PanelMenuRowStyle: ButtonStyle {
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.14 : hovering && isEnabled ? 0.08 : 0))
            }
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { hovering = $0 }
    }
}
