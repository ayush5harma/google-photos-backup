import Foundation
import Testing
@testable import PhotosBackupCore

private func run(_ minute: Int, _ trigger: RunTrigger = .timer, uploaded: Int = 1) -> RunRecord {
    RunRecord(kind: .photos, trigger: trigger, startedAt: Date(timeIntervalSince1970: TimeInterval(minute * 60)),
              finishedAt: Date(timeIntervalSince1970: TimeInterval(minute * 60 + 30)), uploaded: uploaded, outcome: .completed)
}

private func scratchFile(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent(name)
}

@Suite struct RunHistoryTests {
    @Test func keepsTheNewestFirstWhateverOrderTheyArrive() {
        var history = RunHistory()
        history.add(run(2))
        history.add(run(5))
        history.add(run(1))
        #expect(history.runs.map(\.startedAt.timeIntervalSince1970) == [300, 120, 60])
    }

    @Test func addingTheSameRunAgainReplacesIt() {
        var history = RunHistory()
        var record = run(1)
        history.add(record)
        record.uploaded = 9
        history.add(record)
        #expect(history.runs == [record])
    }

    @Test func keepsFortyAutomaticRunsDroppingTheOldest() {
        var history = RunHistory()
        for minute in 0..<45 { history.add(run(minute)) }
        #expect(history.runs.count == 40)
        #expect(history.runs.last?.startedAt == Date(timeIntervalSince1970: 5 * 60))
    }

    @Test func dropsRunsAPersonStartedBeforeAutomaticOnes() {
        var history = RunHistory()
        history.add(run(0, .manual))
        history.add(run(1, .picker))
        for minute in 2..<42 { history.add(run(minute, .timer)) }
        // 42 runs: the two manual ones go, although the automatic ones are newer.
        #expect(history.runs.count == 40)
        #expect(history.runs.allSatisfy { $0.trigger.isAutomatic })

        // The run that just ended stays even when it is the one manual run.
        history.add(run(50, .manual))
        #expect(history.runs.first?.trigger == .manual)
        #expect(history.runs.last?.startedAt == Date(timeIntervalSince1970: 3 * 60))
        // The next run pushes out that manual run, not an automatic one.
        history.add(run(51, .retry))
        #expect(history.runs.count == 40)
        #expect(history.runs.first?.trigger == .retry)
        #expect(!history.runs.contains { $0.trigger == .manual })
        #expect(history.runs.last?.startedAt == Date(timeIntervalSince1970: 3 * 60))
    }

    @Test func runsThatFoundNothingToDoGoFirst() {
        var history = RunHistory()
        history.add(run(0, .manual))
        for minute in 1..<20 { history.add(run(minute, .timer, uploaded: 1)) }
        for minute in 20..<45 { history.add(run(minute, .timer, uploaded: 0)) }
        #expect(history.runs.count == 40)
        // Five idle timer runs went; the manual one and every busy run stayed.
        #expect(history.runs.filter { $0.isIdle }.count == 20)
        #expect(history.runs.contains { $0.trigger == .manual })
        #expect(history.runs.first?.startedAt == Date(timeIntervalSince1970: 44 * 60))

        var failed = run(46, .timer, uploaded: 0)
        failed.outcome = .failed("offline")
        #expect(!failed.isIdle)
    }

    @Test func decodingTrimsAndSortsAnOversizedFile() throws {
        let runs = (0..<50).map { run($0, $0 % 2 == 0 ? .manual : .timer) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let history = try decoder.decode(RunHistory.self, from: encoder.encode(runs))
        #expect(history.runs.count == 40)
        #expect(history.runs.filter { !$0.trigger.isAutomatic }.count == 15)
        #expect(history.runs.first?.startedAt == Date(timeIntervalSince1970: 49 * 60))
    }
}

@Suite struct RecordStoreTests {
    @Test func roundTripsAndReportsAMissingFile() throws {
        let url = scratchFile("history.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = RecordStore<RunHistory>(url: url)
        guard case .missing = store.load() else { Issue.record("expected missing"); return }

        var history = RunHistory()
        history.add(run(3, .manual))
        try store.save(history)
        guard case let .loaded(loaded) = store.load() else { Issue.record("expected loaded"); return }
        #expect(loaded == history)
    }

    @Test func aCorruptFileIsSetAsideAndTheStoreStartsEmpty() throws {
        let url = scratchFile("events.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: url)
        let store = RecordStore<RunHistory>(url: url)

        guard case let .unreadable(setAside, _) = store.load() else { Issue.record("expected unreadable"); return }
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(try Data(contentsOf: setAside) == Data("{ not json".utf8))
        guard case .missing = store.load() else { Issue.record("expected a fresh start"); return }

        // A later corrupt file replaces the earlier copy rather than failing.
        try Data("[1]".utf8).write(to: url)
        guard case .unreadable = store.load() else { Issue.record("expected unreadable"); return }
        #expect(try Data(contentsOf: setAside) == Data("[1]".utf8))
    }
}
