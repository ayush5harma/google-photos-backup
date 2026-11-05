import Foundation
@testable import PhotosBackup
import PhotosBackupCore
import XCTest

/// One bridge process per backup run (issue #50), against the real bridge
/// and the fake gpmc: every request answered in order by the same process,
/// every upload committed as Original from a Pixel XL, Stop still immediate.
@MainActor
final class BridgeSessionTests: XCTestCase {
    private var fake: FakeRuntime!

    override func setUp() async throws {
        fake = try FakeRuntime()
        try fake.given([:])
    }

    override func tearDown() async throws {
        fake.remove()
    }

    private func run(_ session: BridgeSession, _ request: BridgeRequest, onEvent: (BridgeEvent) -> Void = { _ in }) async throws -> Int32 {
        try await session.run(request, runtime: fake.runtime, workDirectory: fake.logs, log: fake.log, onEvent: onEvent)
    }

    func testOneBridgeAnswersEveryRequestOfARunAsOriginalFromAPixelXL() async throws {
        let first = try (0..<6).map { try fake.stage("IMG_\($0).JPG", bytes: 4096) }
        let second = try (6..<9).map { try fake.stage("IMG_\($0).JPG", bytes: 4096) }
        let session = BridgeSession()
        var items: [String] = []
        var done = 0
        let record: (BridgeEvent) -> Void = { event in
            if case let .item(id, _, _) = event { items.append(id) }
            if case .done = event { done += 1 }
        }

        let codes = [
            try await run(session, .upload(FakeRuntime.auth, items: first, quality: .original, threads: 8, album: nil), onEvent: record),
            try await run(session, .upload(FakeRuntime.auth, items: second, quality: .original, threads: 3, album: AlbumTarget(id: nil, name: "Trip")),
                          onEvent: record),
            try await run(session, .version),
        ]
        session.close()

        XCTAssertEqual(codes, [0, 0, 0])
        XCTAssertEqual(Set(items), Set((first + second).map(\.id)))
        XCTAssertEqual(done, 2)
        let uploads = fake.uploads.filter { $0["status"] as? String == "uploaded" }
        XCTAssertEqual(uploads.count, 9)
        for upload in uploads {
            XCTAssertEqual(upload["saver"] as? Bool, false)
            XCTAssertEqual(upload["use_quota"] as? Bool, false)
            XCTAssertEqual(upload["quality"] as? String, "original")
            XCTAssertEqual(upload["model"] as? String, "Pixel XL")
        }
        XCTAssertEqual(Set(uploads.compactMap { $0["pid"] as? Int }).count, 1, "one bridge for the run")
        let counters = try XCTUnwrap(fake.ledger()["counters"] as? [String: Any])
        XCTAssertEqual(counters["auth"] as? Int, 1, "one sign-in for the run")
    }

    func testStopEndsTheRequestAndTheNextRequestStartsANewBridge() async throws {
        try fake.given(["delay": 0.5])
        let batch = try (0..<4).map { try fake.stage("IMG_\($0).JPG") }
        let session = BridgeSession()
        var events: [BridgeEvent] = []
        let code = try await run(session, .upload(FakeRuntime.auth, items: batch, quality: .original, threads: 1, album: nil)) { event in
            events.append(event)
            if case .item = event { session.terminate() }
        }

        XCTAssertEqual(code, 5)
        XCTAssertEqual(events.last, .stopped)
        let confirmed = events.filter { if case .item = $0 { true } else { false } }
        XCTAssertGreaterThanOrEqual(confirmed.count, 1)
        XCTAssertLessThan(confirmed.count, 4)

        try fake.given([:])
        let next = try await run(session, .version)
        session.close()
        XCTAssertEqual(next, 0)
    }

    /// Stop between requests: nobody would read the bridge's last "stopped",
    /// so the next request must get a new bridge, not that line.
    func testAStopBetweenRequestsLeavesNothingForTheNextOne() async throws {
        let session = BridgeSession()
        let first = try await run(session, .version)
        session.terminate()
        var events: [BridgeEvent] = []
        let next = try await run(session, .version) { events.append($0) }
        session.close()

        XCTAssertEqual([first, next], [0, 0])
        XCTAssertTrue(session.lastRequestStartedBridge)
        XCTAssertEqual(events.count, 1)
        guard case .version = events.first else { return XCTFail("expected the version answer, got \(events)") }
    }

    func testARequestTheBridgeRefusesStillEndsWithItsCode() async throws {
        let session = BridgeSession()
        var fatal: FatalKind?
        let code = try await run(session, .upload("no token here", items: [try fake.stage("a.jpg")], quality: .original, threads: 1, album: nil)) {
            if case let .fatal(kind, _) = $0 { fatal = kind }
        }
        let after = try await run(session, .version)
        session.close()

        XCTAssertEqual(code, 2)
        XCTAssertEqual(fatal, .auth)
        XCTAssertEqual(after, 0, "a refused request does not end the session")
    }
}

@MainActor
final class ExportAheadTests: XCTestCase {
    func testExportsRunOneAtATimeInOrderWithinTheWindow() async throws {
        let ahead = ExportAhead<Int>(bytes: { Int64($0) })
        var started: [Int] = []
        var running = 0
        var most = 0
        let export: (Int) async -> Int = { index in
            started.append(index)
            running += 1
            most = max(most, running)
            try? await Task.sleep(for: .milliseconds(20))
            running -= 1
            return index * 1_000
        }

        ahead.stage([1, 2, 3, 4], export: export)
        XCTAssertEqual(ahead.count, 1, "one export at a time")
        // Long enough for both window places to fill, and no more.
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(started, [1, 2])
        XCTAssertEqual(ahead.count, StagingWindow.batchesAhead)
        let first = await ahead.take(1)
        XCTAssertEqual(first, 1_000)
        let second = await ahead.take(2)
        let third = await ahead.take(3)
        XCTAssertEqual([second, third], [2_000, 3_000])
        let none = await ahead.take(9)
        XCTAssertNil(none)
        XCTAssertEqual(Array(started.prefix(3)), [1, 2, 3])
        XCTAssertEqual(most, 1, "one export at a time")
        _ = await ahead.discard()
        XCTAssertEqual(ahead.bytesReady, 0)
    }

    func testDiscardCancelsWhatWasNotTaken() async throws {
        let ahead = ExportAhead<Bool>(bytes: { _ in 1 })
        ahead.stage([1, 2]) { _ in
            try? await Task.sleep(for: .seconds(5))
            return Task.isCancelled
        }
        let cancelled = await ahead.discard()
        XCTAssertEqual(cancelled, [true], "the running export is cancelled; the next never starts")
        XCTAssertEqual(ahead.count, 0)
        XCTAssertEqual(ahead.bytesReady, 0)
    }

    /// The cap is judged on finished exports: a batch that fills it holds
    /// back the next one until it is taken.
    func testTheByteCapHoldsBackTheNextExport() async throws {
        let ahead = ExportAhead<Int64>(bytes: { $0 })
        var started: [Int] = []
        ahead.stage([1, 2]) { index in
            started.append(index)
            return index == 1 ? StagingWindow.bytesAhead : 1
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(started, [1])
        XCTAssertEqual(ahead.count, 1)
        _ = await ahead.take(1)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(started, [1, 2])
        _ = await ahead.discard()
    }

    /// A step taken before its export began is the caller's to export; it
    /// is never exported again behind its back.
    func testATakenStepIsNotExportedLater() async throws {
        let ahead = ExportAhead<Int>(bytes: { _ in 0 })
        var started: [Int] = []
        ahead.stage([1, 2]) { index in
            started.append(index)
            try? await Task.sleep(for: .milliseconds(30))
            return index
        }
        let early = await ahead.take(2)
        XCTAssertNil(early)
        let first = await ahead.take(1)
        XCTAssertEqual(first, 1)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(started, [1])
        _ = await ahead.discard()
    }
}
