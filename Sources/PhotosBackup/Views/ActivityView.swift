import AppKit
import PhotosBackupCore
import SwiftUI

/// Uploads in this session, the run history and the event timeline.
struct ActivityView: View {
    enum Pane: String, CaseIterable, Identifiable {
        case uploads, history, timeline

        var id: String { rawValue }

        var title: String {
            switch self {
            case .uploads: "Uploads"
            case .history: "History"
            case .timeline: "Timeline"
            }
        }
    }

    @Environment(AppModel.self) private var model
    @Binding var section: AppSection
    @AppStorage("activityPane", store: AppEnvironment.defaults) private var pane: Pane = .uploads

    var body: some View {
        Group {
            switch pane {
            case .uploads: UploadsPane()
            case .history: HistoryPane()
            case .timeline: TimelinePane()
            }
        }
        .navigationTitle("Activity")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $pane) {
                    ForEach(Pane.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    private var subtitle: String {
        let engine = model.engine
        if engine.isActive, engine.remaining > 0 { return "\(engine.remaining.formatted()) remaining" }
        if let last = engine.lastRun { return "Last run \(last.formatted(.relative(presentation: .named)))" }
        return ""
    }
}

// MARK: - Uploads

private struct UploadsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let engine = model.engine
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                RunPanel()
                if engine.activity.isEmpty {
                    ContentUnavailableView("No Uploads Yet", systemImage: "arrow.up.circle",
                                           description: Text("Photos and Messages items appear here while a backup runs."))
                        .frame(maxWidth: .infinity, minHeight: 240)
                } else {
                    Panel {
                        LazyVStack(spacing: 0) {
                            ForEach(engine.activity) { item in
                                ActivityRow(item: item)
                                if item.id != engine.activity.last?.id { Divider().padding(.leading, 52) }
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
    }
}

/// The current run: what it is doing, how far it got, and its controls.
private struct RunPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let engine = model.engine
        Panel {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Label(title, systemImage: symbol)
                        .font(.headline)
                        .symbolRenderingMode(.hierarchical)
                        .contentTransition(.symbolEffect(.replace))
                    Spacer()
                    if engine.runTotal > 0 {
                        Text("\(engine.runDone.formatted()) of \(engine.runTotal.formatted())")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }
                }
                if engine.isActive || engine.runTotal > 0 {
                    ProgressView(value: engine.runFraction)
                        .accessibilityLabel("Overall progress")
                }
                if let reason = engine.waitReason { WaitLine(reason: reason) }
                if let error = engine.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                controls
            }
            .padding(16)
        }
        .animation(.default, value: engine.phase)
    }

    @ViewBuilder
    private var controls: some View {
        let engine = model.engine
        HStack(spacing: 8) {
            if engine.phase == .paused || engine.phase == .pausing {
                Button("Resume", systemImage: "play.fill") { engine.resume() }
            } else {
                Button("Pause", systemImage: "pause.fill") { engine.pauseAfterCurrent() }
                    .disabled(engine.phase != .running && engine.phase != .waiting)
                    .help("Pause after the uploads in progress")
            }
            Button("Stop", systemImage: "stop.fill", role: .destructive) { model.stopBackup() }
                .disabled((engine.phase == .idle && !model.isMessagesScanning) || engine.phase == .stopping)
            Spacer()
            if engine.failedCount > 0 {
                Button("Retry Failed (\(engine.failedCount.formatted()))", systemImage: "arrow.clockwise") { engine.retryFailed() }
            }
            Button("Clear Finished") { engine.clearFinished() }
                .disabled(!engine.activity.contains { $0.status.isFinished })
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
    }

    private var title: String {
        let engine = model.engine
        switch engine.phase {
        case .idle: return engine.lastRun == nil ? "Not started yet" : "Not running"
        case .running: return "Backing up"
        case .waiting: return engine.waitReason?.title ?? "Waiting"
        case .pausing: return "Pausing after the current uploads"
        case .paused: return "Paused"
        case .stopping: return "Stopping"
        }
    }

    private var symbol: String {
        let engine = model.engine
        switch engine.phase {
        case .idle: return engine.lastError == nil ? "checkmark.circle" : "exclamationmark.circle"
        case .running: return "arrow.up.circle"
        case .waiting: return engine.waitReason?.symbol ?? "hourglass"
        case .pausing, .paused: return "pause.circle"
        case .stopping: return "stop.circle"
        }
    }
}

/// Why the run holds, with a live countdown when the wait has an end.
private struct WaitLine: View {
    let reason: WaitReason

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: reason.symbol).symbolRenderingMode(.hierarchical)
            Text(detail)
            if let until = reason.until, until > .now {
                Text(timerInterval: Date.now...until, countsDown: true)
                    .monospacedDigit()
            }
        }
        .font(.callout)
        .foregroundStyle(.orange)
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        switch reason {
        case .rateLimited: "Google asked the app to slow down. Uploads continue in"
        case .retrying: "Trying again in"
        case .offline: "Uploads continue when the Mac is back online."
        case .expensiveNetwork: "Automatic backups wait for a network that is not metered."
        case .lowDataMode: "Automatic backups wait while Low Data Mode is on."
        case .onBattery: "Automatic backups wait for the Mac to be plugged in."
        case .lowPowerMode: "Automatic backups wait while Low Power Mode is on."
        }
    }
}

struct ActivityRow: View {
    @Environment(AppModel.self) private var model
    let item: ActivityItem
    @State private var showingDetail = false

    var body: some View {
        HStack(spacing: 12) {
            icon
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.filename).lineLimit(1).truncationMode(.middle)
                Text(item.status.label)
                    .font(.callout)
                    .foregroundStyle(item.isFailed ? Color.red : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            if let size = item.size {
                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if item.isFailed {
                Button("Details", systemImage: "info.circle") { showingDetail = true }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("What Google said")
                    .popover(isPresented: $showingDetail, arrowEdge: .trailing) {
                        FailureDetail(item: item, canRetry: model.engine.canRetry(item.id)) {
                            showingDetail = false
                            model.engine.retry(item.id)
                        }
                    }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { if item.isFailed { showingDetail = true } }
        .contextMenu {
            Button("Retry") { model.engine.retry(item.id) }
                .disabled(!model.engine.canRetry(item.id))
            Button("Copy Error") { copy(item.detail ?? item.status.label) }
                .disabled(!item.isFailed)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var icon: some View {
        switch item.status {
        case .uploaded, .existing:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title3)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red).font(.title3)
        case .stopped:
            Image(systemName: "stop.circle").foregroundStyle(.secondary).font(.title3)
        case .waiting:
            Image(systemName: "clock").foregroundStyle(.orange).font(.title3)
        case let .uploading(fraction):
            ProgressView(value: fraction).progressViewStyle(.circular).controlSize(.small)
        default:
            ProgressView().controlSize(.small)
        }
    }
}

/// Google's message in full, for a failed row.
private struct FailureDetail: View {
    let item: ActivityItem
    let canRetry: Bool
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What Google Said").font(.headline)
            Text(item.filename).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            ScrollView {
                Text(message)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)
            if let retryable = item.retryable {
                Label(retryable ? "This looks temporary; trying again may work."
                                : "Trying again will most likely fail the same way.",
                      systemImage: retryable ? "arrow.clockwise" : "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Copy") { copy(message) }
                Spacer()
                Button("Retry", action: retry)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canRetry)
            }
        }
        .padding(16)
        .frame(width: 380)
    }

    private var message: String { item.detail ?? item.status.label }
}

// MARK: - History

private struct HistoryPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let runs = model.diagnostics.runs
        if runs.isEmpty {
            ContentUnavailableView("No Runs Yet", systemImage: "clock.arrow.circlepath",
                                   description: Text("Each backup run is listed here once it ends."))
        } else {
            Table(runs) {
                TableColumn("Started") { run in
                    Text(run.startedAt, format: .relative(presentation: .named))
                        .help(run.startedAt.formatted(date: .abbreviated, time: .shortened))
                }
                .width(min: 110, ideal: 130)
                TableColumn("Run") { run in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(run.kind.title)
                        Text(run.trigger.title).font(.callout).foregroundStyle(.secondary)
                    }
                }
                .width(min: 120, ideal: 160)
                TableColumn("Duration") { run in
                    Text(run.duration.map(Self.duration) ?? "-").monospacedDigit()
                }
                .width(min: 60, ideal: 70)
                TableColumn("Uploaded") { run in count(run.uploaded) }.width(min: 60, ideal: 70)
                TableColumn("Already There") { run in count(run.existing) }.width(min: 60, ideal: 90)
                TableColumn("Failed") { run in
                    count(run.failed).foregroundStyle(run.failed > 0 ? Color.red : Color.primary)
                }
                .width(min: 50, ideal: 60)
                TableColumn("Outcome") { run in OutcomeLabel(outcome: run.outcome) }
                    .width(min: 100, ideal: 140)
            }
        }
    }

    private func count(_ value: Int) -> Text {
        Text(value.formatted()).monospacedDigit()
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds < 60 ? [.second] : seconds < 3600 ? [.minute, .second] : [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: seconds) ?? "-"
    }
}

private struct OutcomeLabel: View {
    let outcome: RunOutcome?

    var body: some View {
        switch outcome {
        case .completed: Label("Completed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .stopped: Label("Stopped", systemImage: "stop.circle").foregroundStyle(.secondary)
        case .paused: Label("Paused", systemImage: "pause.circle").foregroundStyle(.orange)
        case let .failed(reason):
            Label("Failed", systemImage: "xmark.circle.fill").foregroundStyle(.red).help(reason)
        case nil: Label("Unfinished", systemImage: "questionmark.circle").foregroundStyle(.secondary)
        }
    }
}

// MARK: - Timeline

private struct TimelinePane: View {
    @Environment(AppModel.self) private var model
    @State private var problemsOnly = false
    @State private var search = ""
    @State private var confirmingClear = false

    var body: some View {
        let events = filtered
        Group {
            if events.isEmpty {
                ContentUnavailableView(search.isEmpty ? (problemsOnly ? "No Problems" : "Nothing Yet") : "No Results",
                                       systemImage: problemsOnly ? "checkmark.seal" : "list.bullet.rectangle",
                                       description: Text(search.isEmpty ? "Runs, sign-ins and problems are recorded here for 14 days." : "No event matches \u{201C}\(search)\u{201D}."))
            } else {
                List(events) { event in
                    EventRow(event: event)
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search Timeline")
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Picker("Show", selection: $problemsOnly) {
                    Text("All Events").tag(false)
                    Text("Problems").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                Button("Copy Report") { copy(model.diagnostics.report(model: model)) }
                    .help("Copy a diagnostic report with tokens, addresses and phone numbers removed")
                Button("Copy All") { copy(events.map(EventRow.line).joined(separator: "\n")) }
                    .disabled(events.isEmpty)
                Button("Clear...") { confirmingClear = true }
                    .disabled(model.diagnostics.events.isEmpty)
            }
            .controlSize(.small)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .confirmationDialog("Clear the timeline?", isPresented: $confirmingClear) {
            Button("Clear Timeline", role: .destructive) { model.diagnostics.clearTimeline() }
        } message: {
            Text("The run history and your backups are not affected.")
        }
    }

    private var filtered: [EventRecord] {
        model.diagnostics.events.filter { event in
            (!problemsOnly || event.isProblem) && (search.isEmpty || event.message.localizedCaseInsensitiveContains(search))
        }
    }
}

private struct EventRow: View {
    let event: EventRecord

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: event.isProblem ? "exclamationmark.triangle.fill" : symbol)
                .foregroundStyle(event.isProblem ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .symbolRenderingMode(.hierarchical)
                .frame(width: 18)
                .accessibilityLabel(event.isProblem ? "Problem" : event.category.rawValue)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.message).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Text("\(event.category.rawValue.capitalized) \u{00B7} \(event.date.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(event.date.formatted(date: .abbreviated, time: .standard))
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

    static func line(_ event: EventRecord) -> String {
        "\(event.date.ISO8601Format()) [\(event.category.rawValue)]\(event.isProblem ? " problem:" : "") \(event.message)"
    }
}

// MARK: - Shared

/// A quiet grouped surface for content (no glass inside scrolling content).
private struct Panel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
    }
}

@MainActor
private func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
