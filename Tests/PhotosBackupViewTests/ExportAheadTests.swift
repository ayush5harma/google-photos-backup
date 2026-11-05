import Foundation
@testable import PhotosBackup
import PhotosBackupCore
import XCTest

/// An export PhotoKit is writing: it ignores cancellation, as
/// PHAssetResourceManager.writeData does, until the test finishes it.
@MainActor
private final class Download {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isDone = false

    func wait() async {
        if isDone { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func finish() {
        isDone = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

/// Bytes on the staging disk: the batch uploading, and what waits ahead of it.
@MainActor
private final class StagingDisk {
    private(set) var uploading: Int64 = 0
    private(set) var ahead: Int64 = 0
    private(set) var mostAhead: Int64 = 0

    func wroteAhead(_ bytes: Int64) {
        ahead += bytes
        mostAhead = max(mostAhead, ahead)
    }

    /// A step takes its batch: its bytes are the upload's now.
    func took(_ bytes: Int64) {
        ahead -= bytes
        uploading += bytes
    }

    func wroteForUpload(_ bytes: Int64) {
        uploading += bytes
    }

    func uploaded() {
        uploading = 0
    }
}

/// Export ahead (issue #50): one export at a time, in order, within
/// StagingWindow, and never in the way of a stop.
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
        // As the engine does: take a step, then stage what follows it.
        let first = await ahead.take(1)
        XCTAssertEqual(first, 1_000)
        ahead.stage([2, 3, 4], export: export)
        let second = await ahead.take(2)
        ahead.stage([3, 4], export: export)
        let third = await ahead.take(3)
        XCTAssertEqual([second, third], [2_000, 3_000])
        let none = await ahead.take(9)
        XCTAssertNil(none)
        XCTAssertEqual(Array(started.prefix(3)), [1, 2, 3])
        XCTAssertEqual(most, 1, "one export at a time")
        _ = ahead.discard()
        XCTAssertEqual(ahead.bytesReady, 0)
    }

    func testDiscardCancelsWhatWasNotTaken() async throws {
        var abandoned: [Bool] = []
        let ahead = ExportAhead<Bool>(bytes: { _ in 1 }, abandoned: { abandoned.append($0) })
        ahead.stage([1, 2]) { _ in
            try? await Task.sleep(for: .seconds(5))
            return Task.isCancelled
        }
        let discarded = ahead.discard()
        XCTAssertEqual(discarded.ready, [])
        XCTAssertEqual(discarded.exporting, 1)
        XCTAssertEqual(ahead.count, 0)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(abandoned, [true], "the running export is cancelled and handed to cleanup; the next never starts")
        XCTAssertEqual(ahead.bytesReady, 0)
    }

    /// PR #52 review, MAJOR 1: discard waited for the export in progress,
    /// and an item PhotoKit is writing (an iCloud download) cannot be
    /// interrupted, so a Stop during a large video stayed on Stopping for
    /// minutes, and quitting gave up on the run after 15 s.
    func testADiscardDoesNotWaitForTheItemInProgress() async throws {
        var abandoned: [Int] = []
        let ahead = ExportAhead<Int>(bytes: { _ in 1 }, abandoned: { abandoned.append($0) })
        let download = Download()
        var started: [Int] = []
        ahead.stage([1, 2]) { index in
            started.append(index)
            await download.wait()
            return index
        }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(started, [1])

        let discarded = ahead.discard()
        XCTAssertEqual(discarded.exporting, 1)
        XCTAssertEqual(discarded.ready, [])
        XCTAssertEqual(ahead.count, 0)

        // The next pass numbers its steps from 0 again: its step 1 is not the
        // export let go, and it starts only once that one has ended.
        ahead.stage([1]) { index in
            started.append(index)
            return index * 10
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(started, [1], "one export at a time, even across a discard")
        download.finish()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(abandoned, [1], "the batch let go goes to cleanup, never to a later take")
        XCTAssertEqual(started, [1, 1])
        let next = await ahead.take(1)
        XCTAssertEqual(next, 10)
        XCTAssertEqual(ahead.bytesReady, 0)
    }

    /// MAJOR 1, the other way a stop met a slow export ahead: the step whose
    /// turn it is waits in take() for its own export ahead.
    func testAStepWaitingForItsExportIsReleasedByAStop() async throws {
        let ahead = ExportAhead<Int>(bytes: { _ in 1 })
        let download = Download()
        ahead.stage([1]) { index in
            await download.wait()
            return index
        }
        var answered = false
        var taken: Int?
        let taking = Task { @MainActor in
            taken = await ahead.take(1)
            answered = true
        }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(answered, "the step waits while its export runs")
        _ = ahead.discard()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(answered, "a stop lets the step go on before the download ends")
        XCTAssertNil(taken, "without the batch let go")
        download.finish()
        await taking.value
    }

    /// The cap is judged on finished exports too: a batch that fills it
    /// holds back the next one until it is taken and its step stages again.
    func testTheByteCapHoldsBackTheNextExport() async throws {
        let ahead = ExportAhead<Int64>(bytes: { $0 })
        var started: [Int] = []
        let export: (Int) async -> Int64 = { index in
            started.append(index)
            return index == 1 ? StagingWindow.bytesAhead : 1
        }
        ahead.stage([1, 2], export: export)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(started, [1])
        XCTAssertEqual(ahead.count, 1)
        _ = await ahead.take(1)
        ahead.stage([2], export: export)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(started, [1, 2])
        _ = ahead.discard()
    }

    /// PR #52 review, MAJOR 2: the cap was judged only on finished batches
    /// and only before an export began, so the first batch ahead could stage
    /// any amount (a batch of 100 large videos). Here every step is 3 GB, half
    /// as much again as the cap, written 600 MB at a time the way the engine's
    /// export does it: asking before each item.
    func testStagedBytesNeverExceedTheCapPlusTheUploadingBatch() async throws {
        let video: Int64 = 600_000_000
        let perStep = 5
        let steps = 4
        let disk = StagingDisk()
        let ahead = ExportAhead<[Int64]>(bytes: { $0.reduce(0, +) }, isComplete: { $0.count == perStep })
        let exportAhead: (Int) async -> [Int64] = { _ in
            var written: [Int64] = []
            for _ in 0..<perStep {
                guard ahead.mayExport(video, after: written.reduce(0, +), freeSpace: nil) else { break }
                await Task.yield()
                written.append(video)
                disk.wroteAhead(video)
            }
            return written
        }

        var uploadedVideos = 0
        for step in 0..<steps {
            var batch = await ahead.take(step) ?? []
            disk.took(batch.reduce(0, +))
            // The step exports what its export ahead left, whatever the window.
            while batch.count < perStep {
                batch.append(video)
                disk.wroteForUpload(video)
            }
            ahead.stage(Array(step + 1 ..< steps), export: exportAhead)
            // The upload, while the next step exports ahead.
            try await Task.sleep(for: .milliseconds(30))
            uploadedVideos += batch.count
            disk.uploaded()
        }
        _ = ahead.discard()

        XCTAssertEqual(uploadedVideos, steps * perStep)
        XCTAssertGreaterThan(disk.mostAhead, 0, "the next step did export ahead")
        XCTAssertLessThanOrEqual(disk.mostAhead, StagingWindow.bytesAhead,
                                 "staged beyond the uploading batch: \(disk.mostAhead) bytes")
    }

    /// PR #52 review, MINOR 6: taking a step started the next export while
    /// the step still exported what its own export ahead had left after a
    /// hold, two exports at once.
    func testTakingAStepDoesNotStartTheNextExport() async throws {
        let ahead = ExportAhead<Int>(bytes: { _ in 1 })
        var started: [Int] = []
        let export: (Int) async -> Int = { index in
            started.append(index)
            return index
        }
        ahead.stage([1, 2, 3], export: export)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(started, [1, 2])
        _ = await ahead.take(1)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(started, [1, 2], "nothing starts until the step has exported what it lacks and stages again")
        ahead.stage([2, 3], export: export)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(started, [1, 2, 3])
        _ = ahead.discard()
    }

    /// MINOR 6, the same from the other side: an export that stopped part-way
    /// is finished by its step, so the next waits for that step's turn.
    func testAnExportThatStoppedPartWayHoldsTheNextUntilItsStep() async throws {
        let ahead = ExportAhead<Int>(bytes: { _ in 1 }, isComplete: { $0 != 1 })
        var started: [Int] = []
        let export: (Int) async -> Int = { index in
            started.append(index)
            return index
        }
        ahead.stage([1, 2], export: export)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(started, [1])
        let first = await ahead.take(1)
        XCTAssertEqual(first, 1)
        ahead.stage([2], export: export)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(started, [1, 2])
        _ = ahead.discard()
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
        _ = ahead.discard()
    }
}
