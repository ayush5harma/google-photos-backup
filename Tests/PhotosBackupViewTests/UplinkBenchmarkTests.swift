import Foundation
@testable import PhotosBackup
import PhotosBackupCore
import XCTest

/// Issue #50's speed-up, measured: about 500 mixed items through the real
/// bridge and the fake gpmc over a simulated link, uploaded the way v0.5.7
/// did and the way a run does now. Skipped unless PHOTOS_BACKUP_BENCH=1:
///
///     PHOTOS_BACKUP_BENCH=1 swift test --filter UplinkBenchmarkTests
///
/// PHOTOS_BACKUP_BENCH_ITEMS changes the item count, PHOTOS_BACKUP_BENCH_OUT
/// names a file for the results table, and PHOTOS_BACKUP_BENCH_BASELINE_BRIDGE
/// the bridge the v0.5.7 pipeline runs, so it also opens a connection per
/// gpmc call as that release did:
///
///     git show v0.5.7:Bridge/gpmc_bridge.py > /tmp/gpmc_bridge_0.5.7.py
///
/// Without it the baseline runs this tree's bridge one request per process.
///
/// Both pipelines use the app's own pieces: BridgeProcess per batch and
/// settings.threads = 2 for v0.5.7; BridgeSession, ExportAhead,
/// StagingWindow.largestFirst and UploadParallelism for now, in the order
/// BackupEngine calls them. The export from Photos is simulated (a pause per
/// item, then a sparse file); everything after it is the real bridge.
@MainActor
final class UplinkBenchmarkTests: XCTestCase {
    /// A link, as the fake gpmc's "network" scenario describes it.
    private struct Link {
        let name: String
        let network: [String: Double]
    }

    /// Measured 2026-11-05: importing gpmc 0.9.0 and its dependencies takes
    /// 0.22 s warm on this Mac (Python 3.13). The rest are assumptions about
    /// a home connection about 40 ms from Google, written down here so the
    /// owner's own measurement can replace them.
    private static let common: [String: Double] = [
        "startup": 0.25, "auth": 0.3, "rtt": 0.04, "handshake": 0.08, "commit": 0.15,
    ]
    private static let links = [
        // Per-connection throughput below the uplink (a long or lossy path,
        // or Google pacing each upload): parallel uploads fill the link.
        Link(name: "200 Mbit/s uplink, 24 Mbit/s per connection",
             network: common.merging(["link_mb_s": 25, "stream_mb_s": 3]) { $1 }),
        // One connection could fill the link: only the gaps, the start-ups
        // and the handshakes are left to win back.
        Link(name: "100 Mbit/s uplink, no per-connection limit",
             network: common.merging(["link_mb_s": 12.5, "stream_mb_s": 12.5]) { $1 }),
    ]

    private struct Item {
        let name: String
        let bytes: Int64
        var isVideo: Bool { name.hasSuffix(".MOV") }
    }

    private struct Batch {
        var items: [(item: BridgeItem, bytes: Int64)] = []
        var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
    }

    private struct Result {
        let seconds: Double
        let bytes: Int64
        let failed: Int
        let levels: [Int]
        let pids: Int
        let signIns: Int
        let connections: Int
        let models: Set<String>
    }

    /// One video in ten; photos 0.5-2.5 MB, videos 5-35 MB, fixed by a seed.
    private static func library(count: Int) -> [Item] {
        var seed: UInt64 = 50
        func next() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(1 << 53)
        }
        return (0..<count).map { index in
            index % 10 == 7
                ? Item(name: "IMG_\(index).MOV", bytes: Int64((5 + 30 * next()) * 1_000_000))
                : Item(name: "IMG_\(index).HEIC", bytes: Int64((0.5 + 2 * next()) * 1_000_000))
        }
    }

    /// What PhotoKit costs per item: a fixed part and a local copy.
    private static func exportTime(_ item: Item) -> Duration {
        .milliseconds(Int64((item.isVideo ? 300 : 60) + Double(item.bytes) / 400_000))
    }

    private func export(_ items: [Item], batch: Int, into fake: FakeRuntime) async throws -> Batch {
        var staged = Batch()
        for item in items {
            try await Task.sleep(for: Self.exportTime(item))
            staged.items.append((try fake.stage(item.name, bytes: item.bytes, in: "\(batch)"), item.bytes))
        }
        return staged
    }

    private func upload(_ batch: Batch, threads: Int, run: (BridgeRequest, (BridgeEvent) -> Void) async throws -> Int32) async throws -> Int {
        var failed = 0
        let request = BridgeRequest.upload(FakeRuntime.auth, items: batch.items.map(\.item), quality: .original, threads: threads, album: nil)
        let code = try await run(request) { event in
            if case .itemFailed = event { failed += 1 }
        }
        XCTAssertEqual(code, 0)
        return failed
    }

    /// v0.5.7: export a batch of 20, start a bridge for it, 2 at a time.
    private func before(_ library: [Item], fake: FakeRuntime) async throws -> (failed: Int, levels: [Int]) {
        var failed = 0
        for (index, items) in library.chunked(into: 20).enumerated() {
            let batch = try await export(items, batch: index, into: fake)
            failed += try await upload(batch, threads: 2) { request, onEvent in
                try await BridgeProcess().run(request, runtime: fake.runtime, workDirectory: fake.logs, log: fake.log, onEvent: onEvent)
            }
        }
        return (failed, [2])
    }

    /// Now: one bridge, export ahead, largest first, adaptive parallelism.
    private func after(_ library: [Item], fake: FakeRuntime) async throws -> (failed: Int, levels: [Int]) {
        let batches = Array(library.chunked(into: 20))
        let session = BridgeSession()
        let ahead = ExportAhead<Batch>(bytes: \.bytes)
        var parallelism = UploadParallelism(cap: UploadParallelism.automaticCap)
        var levels: [Int] = []
        var failed = 0
        defer { session.close() }
        for index in batches.indices {
            let staged: Batch
            if let taken = await ahead.take(index) {
                staged = taken
            } else {
                staged = try await export(batches[index], batch: index, into: fake)
            }
            ahead.stage(Array(batches.indices.dropFirst(index + 1))) { next in
                (try? await self.export(batches[next], batch: next, into: fake)) ?? Batch()
            }
            let ordered = Batch(items: StagingWindow.largestFirst(staged.items, size: \.bytes))
            levels.append(parallelism.current)
            let started = ContinuousClock.now
            let lost = try await upload(ordered, threads: parallelism.current) { request, onEvent in
                try await session.run(request, runtime: fake.runtime, workDirectory: fake.logs, log: fake.log, onEvent: onEvent)
            }
            failed += lost
            let seconds = (ContinuousClock.now - started) / .seconds(1)
            parallelism.measured(UploadSample(bytes: ordered.bytes, seconds: seconds, items: ordered.items.count - lost,
                                              rateLimited: false, serverFailures: lost,
                                              includesStartUp: session.lastRequestStartedBridge))
        }
        return (failed, levels)
    }

    private func measure(_ link: Link, library: [Item], bridge: URL? = nil,
                         pipeline: ([Item], FakeRuntime) async throws -> (failed: Int, levels: [Int])) async throws -> Result {
        let fake = try FakeRuntime(bridge: bridge)
        defer { fake.remove() }
        try fake.given(["network": link.network])
        let started = ContinuousClock.now
        let (failed, levels) = try await pipeline(library, fake)
        let seconds = (ContinuousClock.now - started) / .seconds(1)
        let uploads = fake.uploads.filter { $0["status"] as? String == "uploaded" }
        let counters = (try fake.ledger()["counters"] as? [String: Any]) ?? [:]
        // Each process counts its own connections; the last entry of each is its total.
        let perProcess = Dictionary(grouping: uploads, by: { $0["pid"] as? Int ?? 0 })
            .values.map { entries in entries.compactMap { $0["connections"] as? Int }.max() ?? 0 }
        return Result(seconds: seconds, bytes: library.reduce(0) { $0 + $1.bytes }, failed: failed + library.count - uploads.count,
                      levels: levels, pids: perProcess.count, signIns: counters["auth"] as? Int ?? 0,
                      connections: perProcess.reduce(0, +),
                      models: Set(uploads.map { "\($0["quality"] ?? "?")/\($0["model"] ?? "?")/saver=\($0["saver"] ?? "?")/quota=\($0["use_quota"] ?? "?")" }))
    }

    func testTheNewPipelineUploadsAtLeastTwiceAsFast() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["PHOTOS_BACKUP_BENCH"] == "1", "set PHOTOS_BACKUP_BENCH=1 to run the throughput benchmark")
        let library = Self.library(count: Int(env["PHOTOS_BACKUP_BENCH_ITEMS"] ?? "") ?? 500)
        let baseline = env["PHOTOS_BACKUP_BENCH_BASELINE_BRIDGE"].map { URL(fileURLWithPath: $0) }
        let total = library.reduce(0) { $0 + $1.bytes }
        var report = ["# Issue #50 benchmark", "",
                      "\(library.count) items (\(library.filter(\.isVideo).count) videos), \(String(format: "%.2f", Double(total) / 1e9)) GB, "
                          + "batches of 20; python \(FakeRuntime.python); v0.5.7 runs "
                          + (baseline.map { "\($0.lastPathComponent)" } ?? "this tree's bridge one request per process"), "",
                      "| Link | Pipeline | Time | MB/s | Failed | Bridges | Sign-ins | Connections | Uploads at once | Committed as |",
                      "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |"]
        for (position, link) in Self.links.enumerated() {
            let old = try await measure(link, library: library, bridge: baseline, pipeline: before)
            let new = try await measure(link, library: library, pipeline: after)
            for (name, result) in [("v0.5.7", old), ("now", new)] {
                let levels = Array(Set(result.levels)).sorted().map(String.init).joined(separator: "-")
                report.append("| \(link.name) | \(name) | \(String(format: "%.1f s", result.seconds)) | "
                              + "\(String(format: "%.1f", Double(result.bytes) / 1e6 / result.seconds)) | \(result.failed) | \(result.pids) | "
                              + "\(result.signIns) | \(result.connections) | \(levels) | \(result.models.sorted().joined(separator: ", ")) |")
            }
            let speedup = old.seconds / new.seconds
            report.append("| \(link.name) | **speed-up** | **\(String(format: "%.2fx", speedup))** | | | | | | | |")
            XCTAssertEqual(old.failed + new.failed, 0)
            XCTAssertEqual(new.models, ["original/Pixel XL/saver=0/quota=0"])
            XCTAssertEqual(new.pids, 1)
            if position == 0 { XCTAssertGreaterThanOrEqual(speedup, 2.0, link.name) }
            XCTAssertGreaterThan(speedup, 1.0, link.name)
        }
        let text = report.joined(separator: "\n") + "\n"
        print(text)
        if let out = env["PHOTOS_BACKUP_BENCH_OUT"] { try text.write(toFile: out, atomically: true, encoding: .utf8) }
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
