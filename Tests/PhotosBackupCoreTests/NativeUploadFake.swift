import Foundation
@testable import PhotosBackupCore

/// A scripted Google for UploadLane and AlbumMirroring tests: keys are
/// "key-<file name>", every call is logged, and each behaviour the tests
/// need is a field set before the run.
actor FakeUploader: GooglePhotosUploading {
    /// sha1 -> the key Google already has for those bytes.
    var existing: [Data: String] = [:]
    /// File name -> errors its successive uploads throw before one succeeds.
    var uploadFailures: [String: [GooglePhotosError]] = [:]
    /// File names whose upload never ends until the task is cancelled.
    var hanging: Set<String> = []
    /// File names a batch commit answers without a key.
    var batchMisses: Set<String> = []
    /// Errors the next batch commits throw, in order.
    var commitFailures: [GooglePhotosError] = []
    /// File name -> the error commitOne throws for it.
    var commitOneFailures: [String: GooglePhotosError] = [:]
    /// Media keys Google no longer has: an album call holding one is a 404.
    var deadKeys: Set<String> = []
    /// The album is gone: every append is a 404.
    var albumGone = false
    /// Errors the next album calls throw before any other check, in order.
    var albumFailures: [GooglePhotosError] = []
    /// Keys whose read-back fails with something other than a 404.
    var unreadableKeys: Set<String> = []

    private(set) var calls: [String] = []
    private(set) var commitSizes: [Int] = []
    private(set) var albums: [String: [String]] = [:]
    private(set) var uploadsStarted = 0
    private var albumCount = 0

    func set(_ change: @Sendable (isolated FakeUploader) -> Void) { change(self) }

    static func key(_ fileName: String) -> String { "key-\(fileName)" }

    func findRemoteMedia(sha1: Data) async throws(GooglePhotosError) -> String? {
        calls.append("find")
        return existing[sha1]
    }

    func upload(file: URL, fileName: String, sha1: Data, timestamp: Date,
                progress: (@Sendable (Int64) -> Void)?) async throws(GooglePhotosError) -> UploadedFile {
        calls.append("upload \(fileName)")
        uploadsStarted += 1
        if hanging.contains(fileName) {
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                throw .network("cancelled")
            }
        }
        if var queue = uploadFailures[fileName], !queue.isEmpty {
            let error = queue.removeFirst()
            uploadFailures[fileName] = queue
            throw error
        }
        return UploadedFile(receipt: Data(fileName.utf8), sha1: sha1, fileName: fileName, timestamp: timestamp, size: 1)
    }

    func commit(_ files: [UploadedFile], quality: UploadQuality) async throws(GooglePhotosError) -> [String?] {
        calls.append("commit \(files.count)")
        commitSizes.append(files.count)
        if !commitFailures.isEmpty { throw commitFailures.removeFirst() }
        return files.map { batchMisses.contains($0.fileName) ? nil : Self.key($0.fileName) }
    }

    func commitOne(_ file: UploadedFile, quality: UploadQuality) async throws(GooglePhotosError) -> String {
        calls.append("commitOne \(file.fileName)")
        if let error = commitOneFailures[file.fileName] { throw error }
        return Self.key(file.fileName)
    }

    func createAlbum(name: String, mediaKeys: [String]) async throws(GooglePhotosError) -> String {
        calls.append("create \(mediaKeys.count)")
        if !albumFailures.isEmpty { throw albumFailures.removeFirst() }
        if mediaKeys.contains(where: deadKeys.contains) { throw .http(status: 404, message: "Not Found") }
        albumCount += 1
        let key = "album-\(albumCount)"
        albums[key] = mediaKeys
        return key
    }

    func addToAlbum(_ albumKey: String, mediaKeys: [String]) async throws(GooglePhotosError) {
        calls.append("add \(mediaKeys.count)")
        if !albumFailures.isEmpty { throw albumFailures.removeFirst() }
        if albumGone || mediaKeys.contains(where: deadKeys.contains) { throw .http(status: 404, message: "Not Found") }
        albums[albumKey, default: []] += mediaKeys
    }

    func hasOriginalDownload(mediaKey: String) async throws(GooglePhotosError) -> Bool {
        calls.append("read \(mediaKey)")
        if unreadableKeys.contains(mediaKey) { throw .http(status: 500, message: "") }
        if deadKeys.contains(mediaKey) { throw .http(status: 404, message: "Not Found") }
        return true
    }
}

/// Collects a lane's reports and the waits it asked for.
actor LaneRecorder {
    private(set) var outcomes: [String: ItemOutcome] = [:]
    private(set) var reportCount = 0
    private(set) var waits: [Date?] = []

    func record(_ id: String, _ outcome: ItemOutcome) {
        reportCount += 1
        outcomes[id] = outcome
    }

    func waited(_ until: Date?) { waits.append(until) }

    var reporter: UploadLane.Reporter { { id, outcome in await self.record(id, outcome) } }
    var waiter: UploadLane.Waiter { { until in await self.waited(until); return true } }
}

enum Staged {
    static func item(_ name: String, size: Int64 = 1, force: Bool = false) -> StagedItem {
        StagedItem(assetID: "asset-\(name)", file: URL(fileURLWithPath: "/tmp/\(name)"), fileName: name,
                   sha1: Data(name.utf8), timestamp: Date(timeIntervalSince1970: 1_700_000_000), size: size, force: force)
    }
}

/// A clock the lane reads and its waiter moves forward, as a real wait would.
final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) { current = start }

    var now: Date { lock.withLock { current } }

    func advance(to date: Date) { lock.withLock { current = max(current, date) } }

    var reader: @Sendable () -> Date { { self.now } }

    /// A waiter that records each wait and lets the time pass.
    func waiter(_ recorder: LaneRecorder) -> UploadLane.Waiter {
        { until in
            await recorder.waited(until)
            if let until { self.advance(to: until) }
            return true
        }
    }
}
