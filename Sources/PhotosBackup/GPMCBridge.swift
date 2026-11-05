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
    /// Every bridge alive in the app, so quitting can end them all.
    private static var live: [ObjectIdentifier: Process] = [:]

    struct LaunchError: LocalizedError {
        let errorDescription: String?
    }

    /// Returns the bridge's exit status once its stdout has closed.
    func run(_ request: BridgeRequest, runtime: BridgeRuntime, workDirectory: URL, log: URL,
             onEvent: (BridgeEvent) -> Void) async throws -> Int32 {
        let child = try BridgeChild.launch(runtime: runtime, workDirectory: workDirectory, log: log, first: request.command)
        current = child.process
        Self.track(child.process)
        defer {
            current = nil
            Self.untrack(child.process)
        }
        child.send(request)
        child.closeInput()
        for await event in child.events { onEvent(event) }
        return await child.exitStatus()
    }

    /// SIGTERM the running bridge; a file mid-upload is abandoned, and the
    /// next run finds anything Google did commit through gpmc's hash check.
    func terminate() {
        if let current, current.isRunning { current.terminate() }
    }

    static func track(_ process: Process) {
        live[ObjectIdentifier(process)] = process
    }

    static func untrack(_ process: Process) {
        live[ObjectIdentifier(process)] = nil
    }

    /// The last resort at quit: SIGTERM every bridge and give each a moment
    /// to report what it finished, which nobody will read any more.
    static func terminateAll() {
        for process in live.values where process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning, Date() < deadline { usleep(20_000) }
        }
    }
}

/// One bridge process for a whole backup run (issue #50): a serve session,
/// where requests go one per line and each answer ends with `served`. The
/// run pays Python's start-up, the sign-in and new connections to Google
/// once instead of for every batch. Same shape as BridgeProcess.run: the
/// events of one request, in order, then that request's exit status.
@MainActor
final class BridgeSession {
    private var child: BridgeChild?
    private var events: AsyncStream<BridgeEvent>.Iterator?
    /// A request is waiting for its answer.
    private var busy = false
    /// The last request started the bridge, so its time includes Python's
    /// start-up and the sign-in.
    private(set) var lastRequestStartedBridge = false

    func run(_ request: BridgeRequest, runtime: BridgeRuntime, workDirectory: URL, log: URL,
             onEvent: (BridgeEvent) -> Void) async throws -> Int32 {
        lastRequestStartedBridge = !(child?.process.isRunning ?? false)
        let child = try running(runtime: runtime, workDirectory: workDirectory, log: log)
        busy = true
        defer { busy = false }
        child.note(request.command)
        child.send(request)
        while let event = await nextEvent() {
            if case let .served(code) = event {
                if code == BridgeProtocol.stoppedStatus { forget() }
                return code
            }
            onEvent(event)
        }
        // Its output ended before the answer did: a stop, or the bridge died.
        // What it reported is in; the next request starts a new bridge.
        let status = await child.exitStatus()
        forget()
        return status
    }

    /// The run is over: the bridge reads end of input and exits by itself.
    func close() {
        child?.closeInput()
        forget()
    }

    /// SIGTERM, as for BridgeProcess: the request in flight ends with what
    /// Google confirmed so far, and so does the session. Between requests
    /// nobody reads the bridge's last "stopped", so the session lets it go
    /// at once and the next request starts a new bridge.
    func terminate() {
        if let process = child?.process, process.isRunning { process.terminate() }
        if !busy { forget() }
    }

    private func running(runtime: BridgeRuntime, workDirectory: URL, log: URL) throws -> BridgeChild {
        if let child, child.process.isRunning { return child }
        forget()
        let started = try BridgeChild.launch(runtime: runtime, workDirectory: workDirectory, log: log, first: "serve") { process in
            Task { @MainActor in BridgeProcess.untrack(process) }
        }
        BridgeProcess.track(started.process)
        started.send(.serve)
        child = started
        events = started.events.makeAsyncIterator()
        return started
    }

    private func nextEvent() async -> BridgeEvent? {
        // The iterator shares the stream's storage, so a copy reads on.
        guard var iterator = events else { return nil }
        let event = await iterator.next()
        events = iterator
        return event
    }

    private func forget() {
        child = nil
        events = nil
    }
}

/// A started bridge child: its stdin, its stdout as decoded events, and the
/// log that is its stderr.
@MainActor
private struct BridgeChild {
    private static let logLimit: UInt64 = 5_000_000

    let process: Process
    let input: FileHandle
    let events: AsyncStream<BridgeEvent>
    let log: FileHandle

    /// - Parameter exited: runs on the process's own queue when it ends; set
    ///   before it starts, so a bridge that exits at once still calls it.
    static func launch(runtime: BridgeRuntime, workDirectory: URL, log: URL, first command: String,
                       exited: (@Sendable (Process) -> Void)? = nil) throws -> BridgeChild {
        let files = FileManager.default
        try files.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        if let size = try? files.attributesOfItem(atPath: log.path)[.size] as? UInt64, size > Self.logLimit {
            let previous = log.appendingPathExtension("1")
            try? files.removeItem(at: previous)
            try? files.moveItem(at: log, to: previous)
        }
        // O_APPEND: two bridges can run at once (a backup and an account
        // check), and each child inherits this descriptor; without it they
        // would write over each other's lines.
        let fd = open(log.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { throw BridgeProcess.LaunchError(errorDescription: "Could not open the log at \(log.path)") }
        let logHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        logHandle.write(Data("--- \(Date().ISO8601Format()) \(command)\n".utf8))

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
                if let event = try? BridgeEvent.decode(line) {
                    sink.yield(event)
                } else {
                    // 2026-10-26: a line the app could not read used to vanish,
                    // and its item surfaced three retries later as "stopped
                    // unexpectedly (exit 0)"; the log now names the line.
                    logHandle.write(Data("undecodable bridge line: \(String(decoding: line.prefix(500), as: UTF8.self))\n".utf8))
                }
            }
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                sink.finish()
            }
        }

        process.terminationHandler = exited
        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            throw BridgeProcess.LaunchError(errorDescription: "Could not start the uploader: \(error.localizedDescription)")
        }
        return BridgeChild(process: process, input: input.fileHandleForWriting, events: events, log: logHandle)
    }

    /// One request, one line. SIGPIPE is ignored app-wide, so a bridge that
    /// died before reading it makes this fail rather than kill the app; its
    /// stdout then ends and the caller reads the exit status.
    func send(_ request: BridgeRequest) {
        do {
            try input.write(contentsOf: request.encoded() + Data("\n".utf8))
        } catch {
            log.write(Data("could not send the request: \(error)\n".utf8))
        }
    }

    /// A serve session's later requests, marked in the log like a new bridge.
    func note(_ command: String) {
        log.write(Data("--- \(Date().ISO8601Format()) \(command) (serve)\n".utf8))
    }

    func closeInput() {
        try? input.close()
    }

    func exitStatus() async -> Int32 {
        let process = process
        return await Task.detached { process.waitUntilExit(); return process.terminationStatus }.value
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
