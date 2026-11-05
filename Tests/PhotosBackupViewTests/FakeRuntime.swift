import Foundation
@testable import PhotosBackup
import PhotosBackupCore

/// The real Bridge/gpmc_bridge.py beside Tests/E2E/fake_gpmc, copied into a
/// scratch folder the way Tests/E2E/make_fake_runtime.sh lays them out. The
/// fake finds its scenario beside site-packages, since the app gives the
/// bridge no environment of its own. Nothing here reaches Google, the
/// Keychain or the app's own support folder.
struct FakeRuntime {
    static let auth = "androidId=abc&Email=someone%40example.com&lang=en_US&Token=aas_et%2Ffake"

    let root: URL
    let runtime: BridgeRuntime
    let staging: URL
    let logs: URL
    let log: URL

    /// - Parameter bridge: another gpmc_bridge.py to run (the benchmark's
    ///   baseline is an earlier release's); the repository's by default.
    init(bridge: URL? = nil) throws {
        let files = FileManager.default
        root = files.temporaryDirectory.appendingPathComponent("photos-backup-tests-\(UUID().uuidString)", isDirectory: true)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bridgeDirectory = root.appendingPathComponent("runtime", isDirectory: true)
        try files.createDirectory(at: bridgeDirectory, withIntermediateDirectories: true)
        try files.copyItem(at: bridge ?? repo.appendingPathComponent("Bridge/gpmc_bridge.py"), to: bridgeDirectory.appendingPathComponent("gpmc_bridge.py"))
        try files.copyItem(at: repo.appendingPathComponent("Tests/E2E/fake_gpmc"), to: bridgeDirectory.appendingPathComponent("site-packages"))
        runtime = BridgeRuntime(python: URL(fileURLWithPath: Self.python), script: bridgeDirectory.appendingPathComponent("gpmc_bridge.py"))
        staging = root.appendingPathComponent("staging", isDirectory: true)
        logs = root.appendingPathComponent("logs", isDirectory: true)
        log = logs.appendingPathComponent("bridge.log")
        try files.createDirectory(at: staging, withIntermediateDirectories: true)
        try files.createDirectory(at: logs, withIntermediateDirectories: true)
    }

    /// PHOTOS_BACKUP_TEST_PYTHON picks another interpreter (the benchmark
    /// wants the one the app bundles); the system one is enough otherwise.
    static var python: String {
        ProcessInfo.processInfo.environment["PHOTOS_BACKUP_TEST_PYTHON"] ?? "/usr/bin/python3"
    }

    var ledgerURL: URL { root.appendingPathComponent("runtime/fake_gpmc_ledger.json") }

    func given(_ scenario: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: scenario, options: [.sortedKeys])
        try data.write(to: root.appendingPathComponent("runtime/fake_gpmc_scenario.json"))
    }

    func ledger() throws -> [String: Any] {
        let data = try Data(contentsOf: ledgerURL)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    var uploads: [[String: Any]] {
        ((try? ledger())?["uploads"] as? [[String: Any]]) ?? []
    }

    /// A file of `bytes` whose first bytes make it unique; the rest is a hole
    /// (APFS keeps it sparse), so large videos cost no disk.
    @discardableResult
    func stage(_ name: String, bytes: Int64 = 64, in folder: String = "0") throws -> BridgeItem {
        let directory = staging.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        let header = Data("pixels of \(folder)/\(name)\n".utf8)
        FileManager.default.createFile(atPath: url.path, contents: header)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(max(bytes, Int64(header.count))))
        try handle.close()
        return BridgeItem(id: "asset-\(folder)-\(name)", path: url.path, filename: name)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
