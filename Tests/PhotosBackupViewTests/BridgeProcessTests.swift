import Foundation
@testable import PhotosBackup
import PhotosBackupCore
import XCTest

/// A bridge line the app cannot decode is written to the bridge log rather
/// than dropped. Measured 2026-10-26: gpmc 0.9.0 handed back a media key as a
/// dict, the item's line failed to decode and vanished, and three retries
/// later the item surfaced only as "The uploader stopped unexpectedly (exit 0)".
@MainActor
final class BridgeProcessTests: XCTestCase {
    func testAnUndecodableLineIsLoggedAndTheRestStillArrive() async throws {
        let files = FileManager.default
        let dir = files.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: dir) }
        let script = dir.appendingPathComponent("bridge.py")
        try """
        import sys
        sys.stdin.read()
        print('{"type":"item","id":"a","media_key":{"6":{"1":81}}}')
        print('{"type":"done","uploaded":0,"existing":0,"failed":0}')
        """.write(to: script, atomically: true, encoding: .utf8)
        let log = dir.appendingPathComponent("bridge.log")
        let runtime = BridgeRuntime(python: URL(fileURLWithPath: "/usr/bin/python3"), script: script)

        var events: [BridgeEvent] = []
        let exit = try await BridgeProcess().run(.version, runtime: runtime, workDirectory: dir, log: log) { events.append($0) }

        XCTAssertEqual(exit, 0)
        XCTAssertEqual(events, [.done(uploaded: 0, existing: 0, failed: 0)])
        let written = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(written.contains(#"undecodable bridge line: {"type":"item","id":"a","media_key":{"6""#), written)
    }
}
