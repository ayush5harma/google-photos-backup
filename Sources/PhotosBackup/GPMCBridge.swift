import Foundation
import PhotosBackupCore

/// Where the bundled Python and Bridge/gpmc_bridge.py live.
struct BridgeRuntime {
    let python: URL
    let script: URL

    /// The app bundle's own copy (scripts/build-app.sh puts it there). Debug
    /// builds may point elsewhere through the environment, for `swift run`;
    /// release builds ignore it, so nothing outside the bundle runs with the
    /// app's Photos grant.
    static func locate() -> BridgeRuntime? {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if let python = env["PHOTOS_BACKUP_PYTHON"], let script = env["PHOTOS_BACKUP_BRIDGE"] {
            return BridgeRuntime(python: URL(fileURLWithPath: python), script: URL(fileURLWithPath: script))
        }
        #endif
        guard let resources = Bundle.main.resourceURL else { return nil }
        let runtime = BridgeRuntime(python: resources.appendingPathComponent("python/bin/python3"),
                                    script: resources.appendingPathComponent("bridge/gpmc_bridge.py"))
        let files = FileManager.default
        guard files.isExecutableFile(atPath: runtime.python.path), files.fileExists(atPath: runtime.script.path) else { return nil }
        return runtime
    }
}

/// Runs one bridge request at a time as a child process and hands its
/// events to the caller in order, on the main actor.
@MainActor
final class BridgeProcess {
    private var current: Process?

    struct LaunchError: LocalizedError {
        let errorDescription: String?
    }

    /// Returns the bridge's exit status once its stdout has closed.
    func run(_ request: BridgeRequest, runtime: BridgeRuntime, workDirectory: URL, log: URL,
             onEvent: (BridgeEvent) -> Void) async throws -> Int32 {
        let files = FileManager.default
        try files.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        if !files.fileExists(atPath: log.path) { files.createFile(atPath: log.path, contents: nil) }
        let logHandle = try FileHandle(forWritingTo: log)
        defer { try? logHandle.close() }
        try logHandle.seekToEnd()
        logHandle.write(Data("--- \(Date().ISO8601Format()) \(request.command)\n".utf8))

        let process = Process()
        process.executableURL = runtime.python
        // -I: no user site-packages, no PYTHON* variables, no script directory
        // on sys.path; the bridge adds its own vendored site-packages.
        // -B: never write __pycache__ into the bundle, which would break its
        // signature; the build precompiles everything instead.
        process.arguments = ["-I", "-B", runtime.script.path]
        // gpmc writes failed_skipped_files.log into its working directory.
        process.currentDirectoryURL = workDirectory
        process.environment = ["HOME": NSHomeDirectory(), "LANG": "en_US.UTF-8", "PATH": "/usr/bin:/bin",
                               "TMPDIR": NSTemporaryDirectory()]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = logHandle

        let (events, sink) = AsyncStream<BridgeEvent>.makeStream()
        let splitter = SplitterBox()
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            let lines = chunk.isEmpty ? splitter.finish() : splitter.append(chunk)
            for line in lines {
                if let event = try? BridgeEvent.decode(line) { sink.yield(event) }
            }
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                sink.finish()
            }
        }

        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            throw LaunchError(errorDescription: "Could not start the uploader: \(error.localizedDescription)")
        }
        current = process
        defer { current = nil }

        // SIGPIPE is ignored app-wide, so a bridge that died before reading
        // its request makes this throw rather than kill the app.
        do {
            try input.fileHandleForWriting.write(contentsOf: request.encoded())
        } catch {
            logHandle.write(Data("could not send the request: \(error)\n".utf8))
        }
        try? input.fileHandleForWriting.close()

        for await event in events { onEvent(event) }
        return await Task.detached { process.waitUntilExit(); return process.terminationStatus }.value
    }

    /// SIGTERM the running bridge; a file mid-upload is abandoned, and the
    /// next run finds anything Google did commit through gpmc's hash check.
    func terminate() {
        if let current, current.isRunning { current.terminate() }
    }
}

/// LineSplitter behind a lock: readabilityHandler runs on a private queue.
private final class SplitterBox: @unchecked Sendable {
    private var splitter = LineSplitter()
    private let lock = NSLock()

    func append(_ chunk: Data) -> [Data] {
        lock.withLock { splitter.append(chunk) }
    }

    func finish() -> [Data] {
        lock.withLock { splitter.finish().map { [$0] } ?? [] }
    }
}
