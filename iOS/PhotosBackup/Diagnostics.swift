import Foundation
import Observation
import PhotosBackupCore

/// The run history (last 40) and the event timeline (400 events, 14 days),
/// persisted in Application Support as the Mac app keeps them
/// (history.json, events.json through Core's RecordStore), and the
/// shareable diagnostic report. Every line passes through Redactor.
@MainActor
@Observable
final class Diagnostics {
    private(set) var runs: [RunRecord] = []
    private(set) var events: [EventRecord] = []
    private(set) var saveError: String?

    @ObservationIgnored private let redactor = Redactor()
    @ObservationIgnored private let historyStore: RecordStore<RunHistory>?
    @ObservationIgnored private let eventStore: RecordStore<EventLog>?
    @ObservationIgnored private var history = RunHistory()
    @ObservationIgnored private var timeline = EventLog()

    /// - Parameter directory: nil keeps everything in memory (fixture mode
    ///   writes nothing).
    init(directory: URL?) {
        historyStore = directory.map { RecordStore(url: $0.appendingPathComponent("history.json")) }
        eventStore = directory.map { RecordStore(url: $0.appendingPathComponent("events.json")) }
        var unreadable: [String] = []
        switch eventStore?.load() {
        case let .loaded(log): timeline = EventLog(events: log.events)
        case let .unreadable(setAside, _): unreadable.append(setAside.lastPathComponent)
        case .missing, nil: break
        }
        switch historyStore?.load() {
        case let .loaded(loaded): history = loaded
        case let .unreadable(setAside, _): unreadable.append(setAside.lastPathComponent)
        case .missing, nil: break
        }
        runs = history.runs
        events = timeline.events
        for name in unreadable {
            log(.app, "A diagnostics file could not be read and was set aside as \(name); it starts empty.", problem: true)
        }
    }

    func record(_ run: RunRecord) {
        history.add(run)
        runs = history.runs
        save(history, to: historyStore)
    }

    func log(_ category: EventCategory, _ message: String, problem: Bool) {
        timeline.append(EventRecord(category: category, message: message, isProblem: problem), redactor: redactor)
        events = timeline.events
        save(timeline, to: eventStore)
    }

    /// Settings > Advanced > Clear Activity: the timeline and the run
    /// history. Backups and their records are not affected.
    func clearActivity() {
        timeline.removeAll()
        history = RunHistory()
        events = []
        runs = []
        save(timeline, to: eventStore)
        save(history, to: historyStore)
    }

    private func save<Value: Codable & Sendable>(_ value: Value, to store: RecordStore<Value>?) {
        guard let store else { return }
        do {
            try store.save(value)
            saveError = nil
        } catch {
            saveError = "Could not save \(store.url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// A redacted plain-text report with a "What stands out" summary first.
    func report(_ snapshot: DiagnosticSnapshot) -> String {
        var snapshot = snapshot
        snapshot.runs = runs
        snapshot.events = events
        return DiagnosticReport.build(snapshot, redactor: redactor)
    }
}
