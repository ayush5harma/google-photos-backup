import PhotosBackupCore
import SwiftUI

/// The run in progress, the run history and the event timeline. The Mac's
/// Activity, with History and Timeline as a segmented choice.
struct ActivityView: View {
    enum Pane: String, CaseIterable, Identifiable {
        case history, timeline

        var id: String { rawValue }
        var title: String { self == .history ? "History" : "Timeline" }
    }

    @Environment(AppModel.self) private var model
    @State private var pane: Pane = .history
    @State private var problemsOnly = false

    var body: some View {
        List {
            Section {
                RunPanel()
            }
            Section {
                Picker("Show", selection: $pane) {
                    ForEach(Pane.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
            switch pane {
            case .history: history
            case .timeline: timeline
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Activity")
        .toolbar {
            if pane == .timeline {
                ToolbarItem(placement: .topBarTrailing) {
                    Toggle(isOn: $problemsOnly) { Label("Problems Only", systemImage: "exclamationmark.triangle") }
                        .toggleStyle(.button)
                }
            }
        }
    }

    @ViewBuilder
    private var history: some View {
        let runs = model.diagnostics.runs
        if runs.isEmpty {
            Section {
                ContentUnavailableView("No Runs Yet", systemImage: "clock.arrow.circlepath",
                                       description: Text("Each backup run is listed here once it ends."))
            }
        } else {
            Section(runs.count == 1 ? "Last run" : "Last \(runs.count.formatted()) runs") {
                ForEach(runs) { run in
                    RunRow(run: run, account: model.accounts.count > 1 ? model.accountTitle(reference: run.account) : nil)
                }
            }
        }
    }

    @ViewBuilder
    private var timeline: some View {
        let events = model.diagnostics.events.filter { !problemsOnly || $0.isProblem }
        if events.isEmpty {
            Section {
                ContentUnavailableView(problemsOnly ? "No Problems" : "Nothing Yet",
                                       systemImage: problemsOnly ? "checkmark.seal" : "list.bullet.rectangle",
                                       description: Text("Runs, sign-ins and problems are recorded here for 14 days."))
            }
        } else {
            Section {
                ForEach(events) { EventRow(event: $0) }
            } footer: {
                Text("Kept for 14 days. Addresses and tokens never appear here.")
            }
        }
    }
}

/// The current run: what it is doing, how far it got, and its controls.
private struct RunPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let engine = model.status
        VStack(alignment: .leading, spacing: 10) {
            Label(title(engine), systemImage: symbol(engine))
                .font(.headline)
                .symbolRenderingMode(.hierarchical)
            if engine.isActive || engine.phase == .paused {
                ProgressView(value: engine.runFraction)
                HStack {
                    Text("\(engine.runDone.formatted()) of \(engine.runTotal.formatted())").monospacedDigit()
                    Spacer()
                    if let name = engine.currentFilename { Text(name).lineLimit(1).truncationMode(.middle) }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                if model.accounts.count > 1, !engine.accounts.isEmpty {
                    ForEach(engine.accounts) { lane in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Label(model.accounts.first { $0.id == lane.account }?.title ?? "Account", systemImage: "person.crop.circle")
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Text("\(lane.done.formatted()) of \(lane.total.formatted())").monospacedDigit().foregroundStyle(.secondary)
                            }
                            ProgressView(value: lane.fraction)
                        }
                        .font(.footnote)
                    }
                }
            } else if let last = model.lastBackup {
                Text("Last backup \(last.relativeDescription).").font(.subheadline).foregroundStyle(.secondary)
            }
            if let reason = engine.waitReason {
                Label(reason.resumeHint, systemImage: reason.symbol).font(.footnote).foregroundStyle(.orange)
            }
            if let error = engine.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.orange)
            }
            controls(engine)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func controls(_ engine: BackupEngineStatus) -> some View {
        HStack(spacing: 10) {
            switch engine.phase {
            case .paused, .pausing:
                Button("Resume", systemImage: "play.fill") { model.resume() }
                    .buttonStyle(TintedButtonStyle(color: .accentColor))
                Button("Stop", systemImage: "stop.fill", role: .destructive) { model.stop() }
                    .buttonStyle(TintedButtonStyle(color: .red))
            case .running, .waiting, .stopping:
                Button("Pause", systemImage: "pause.fill") { model.pause() }
                    .buttonStyle(TintedButtonStyle(color: .orange))
                Button("Stop", systemImage: "stop.fill", role: .destructive) { model.stop() }
                    .buttonStyle(TintedButtonStyle(color: .red))
            case .idle:
                Button("Back Up Now", systemImage: "arrow.up") { model.backUpNow() }
                    .buttonStyle(TintedButtonStyle(color: .accentColor))
                    .disabled(!model.hasAuthData || !model.canReadPhotos)
                if engine.failedCount > 0 {
                    Button("Retry Failed (\(engine.failedCount.formatted()))", systemImage: "arrow.clockwise") { model.retryFailed() }
                        .buttonStyle(TintedButtonStyle(color: .orange))
                }
            }
        }
    }

    private func title(_ engine: BackupEngineStatus) -> String {
        switch engine.phase {
        case .idle: engine.lastRun == nil && model.diagnostics.runs.isEmpty ? "Not started yet" : "Not running"
        case .running: "Backing up"
        case let .waiting(reason): reason.phoneTitle
        case .pausing: "Pausing after the current uploads"
        case .paused: "Paused"
        case .stopping: "Stopping"
        }
    }

    private func symbol(_ engine: BackupEngineStatus) -> String {
        switch engine.phase {
        case .idle: engine.lastError == nil ? "checkmark.circle" : "exclamationmark.circle"
        case .running: "arrow.up.circle"
        case let .waiting(reason): reason.symbol
        case .pausing, .paused: "pause.circle"
        case .stopping: "stop.circle"
        }
    }
}

private struct EventRow: View {
    let event: EventRecord

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: event.isProblem ? "exclamationmark.triangle.fill" : symbol)
                .foregroundStyle(event.isProblem ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .frame(width: 20)
                .accessibilityLabel(event.isProblem ? "Problem" : event.category.rawValue)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.message)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(event.category.rawValue.capitalized) \u{00B7} \(event.date.relativeDescription)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var symbol: String {
        switch event.category {
        case .app: "app"
        case .account: "person.crop.circle"
        case .photos: "photo"
        case .messages: "message"
        case .archive: "archivebox"
        case .run: "arrow.up.circle"
        case .network: "network"
        }
    }
}
