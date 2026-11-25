import Foundation

/// What one album step did, reported even when it stopped part-way, so an
/// album it created is never lost (the bridge's AlbumIncomplete).
public struct AlbumStepResult: Sendable, Equatable {
    /// The Google album: the one passed in, or the one this step created.
    public var albumKey: String?
    /// Media keys that went in.
    public var added: [String] = []
    /// Media keys Google no longer has (refused on their own while the album
    /// was shown alive by this step's own adds).
    public var missing: [String] = []
    /// Why the step stopped short; nil when every key was dealt with.
    public var error: GooglePhotosError?
    /// The caller's stop ended a wait between calls.
    public var stopped = false

    public init(albumKey: String?) {
        self.albumKey = albumKey
    }
}

/// Adding keys to a mirrored album, as the bridge's `_add_splitting_missing`
/// does for the Mac app (Bridge/gpmc_bridge.py):
///
/// - an album without a Google key yet is created with the first 500 keys
///   (GooglePhotosClient.albumBatchSize), the rest appended 500 a call once
///   the key is held, so a failed append never loses the album;
/// - Google refuses a whole call with a 404 when any key no longer
///   resolves (measured 2026-10-27: 1 of 72 sampled keys a day after a
///   25,954-item run), so a refused batch is halved until each dead key
///   stands alone, every live key still goes in, and the dead ones go back to
///   the caller to upload again (BackupState.forgetUploads);
/// - a 404 counts as the keys' only once one of this step's own adds went
///   in (or it is creating the album): a deleted album answers 404 too, and
///   nothing is ever re-added to tell the two apart. The bridge then reads
///   each refused key back; the native client has no read-back call, so the
///   refusal stays the album's, the worst case being an album that fails
///   again next run, never a photo sent twice;
/// - a 5xx or 408 is tried again after 2, 5 and 12 s, at most 8 times a step
///   (measured 2026-10-27: 7 of about 30 album steps hit a passing 500/503).
public enum AlbumMirroring {
    public static let retryDelays: [TimeInterval] = [2, 5, 12]
    public static let retryBudget = 8
    public static let refusalBudget = 128

    /// Sleeps `seconds`; false when the caller stopped meanwhile.
    public typealias Sleeper = @Sendable (_ seconds: TimeInterval) async -> Bool

    public static let taskSleep: Sleeper = { seconds in
        do {
            try await Task.sleep(for: .seconds(seconds))
            return true
        } catch {
            return false
        }
    }

    public static func add(_ mediaKeys: [String], to albumKey: String?, named name: String, using client: any GooglePhotosUploading,
                           sleep: @escaping Sleeper = taskSleep) async -> AlbumStepResult {
        var step = Step(client: client, name: name, known: albumKey, sleep: sleep)
        do {
            var start = 0
            while start < mediaKeys.count {
                let batch = Array(mediaKeys[start..<min(start + GooglePhotosClient.albumBatchSize, mediaKeys.count)])
                if step.albumKey == nil { try await step.create(batch) } else { try await step.append(batch) }
                start += batch.count
            }
        } catch {
            var result = step.result
            switch error {
            case .stopped: result.stopped = true
            case let .google(failure): result.error = failure
            }
            return result
        }
        var result = step.result
        if !step.refusedAlone.isEmpty, !step.alive, let refusal = step.firstRefusal {
            result.error = refusal
        }
        return result
    }

    /// What applying a step to an account's record did.
    public struct Applied: Equatable, Sendable {
        /// Adds counted against BackupPlanner.linkedAlbumAddLimit this run.
        public var counted = 0
        /// Assets whose upload was forgotten because Google no longer has
        /// their key; the planner sends them again, without the hash check.
        public var forgotten: [String] = []
    }

    /// The Mac engine's reaction to the bridge's `album` and `missing_media`
    /// events: the assets among `assetIDs` whose keys went in are recorded in
    /// the album (a new album also approves `members`, the Photos album's
    /// visible members, as BackupState.recordAlbum explains), and the ones
    /// whose keys Google no longer has are forgotten and forced. A key is
    /// matched to the asset that holds it, never to another asset.
    public static func apply(_ result: AlbumStepResult, albumID: String, assetIDs: [String], members: [String],
                             to state: inout BackupState) -> Applied {
        var applied = Applied()
        if let albumKey = result.albumKey {
            let added = state.assets(assetIDs, withMediaKeys: result.added)
            let isNew = state.mirrors[albumID]?.googleAlbumID == nil
            applied.counted = state.recordAlbum(albumID, googleAlbumID: albumKey, added: added, members: isNew ? members : [])
        }
        applied.forgotten = state.forgetUploads(withMediaKeys: result.missing, among: assetIDs, reportedBy: albumID)
        return applied
    }

    enum Stop: Error {
        case stopped
        case google(GooglePhotosError)
    }

    private struct Step {
        let client: any GooglePhotosUploading
        let name: String
        let known: String?
        let sleep: Sleeper
        var albumKey: String?
        var added: [String] = []
        var refusedAlone: [String] = []
        var refusals = 0
        var firstRefusal: GooglePhotosError?
        var retriesLeft = AlbumMirroring.retryBudget

        init(client: any GooglePhotosUploading, name: String, known: String?, sleep: @escaping Sleeper) {
            self.client = client
            self.name = name
            self.known = known
            self.sleep = sleep
            albumKey = known
        }

        /// An album being created exists once createAlbum answers, and a 404
        /// before that can only be the keys' own.
        var alive: Bool { known == nil || !added.isEmpty }

        var result: AlbumStepResult {
            var result = AlbumStepResult(albumKey: albumKey)
            result.added = added
            result.missing = alive ? refusedAlone : []
            return result
        }

        mutating func append(_ keys: [String]) async throws(Stop) {
            guard let albumKey else { return try await create(keys) }
            let client = client
            do {
                try await call { () async throws(GooglePhotosError) in try await client.addToAlbum(albumKey, mediaKeys: keys) }
            } catch {
                try refused(error, keys: keys)
                if keys.count == 1 {
                    refusedAlone.append(keys[0])
                    return
                }
                let half = keys.count / 2
                try await append(Array(keys[..<half]))
                try await append(Array(keys[half...]))
                return
            }
            added += keys
        }

        mutating func create(_ keys: [String]) async throws(Stop) {
            let client = client, name = name
            do {
                albumKey = try await call { () async throws(GooglePhotosError) in try await client.createAlbum(name: name, mediaKeys: keys) }
            } catch {
                try refused(error, keys: keys)
                if keys.count == 1 {
                    refusedAlone.append(keys[0])
                    return
                }
                let half = keys.count / 2
                try await create(Array(keys[..<half]))
                if albumKey == nil { try await create(Array(keys[half...])) } else { try await append(Array(keys[half...])) }
                return
            }
            added += keys
        }

        /// Rethrows anything but a 404 within the refusal budget.
        private mutating func refused(_ failure: Stop, keys: [String]) throws(Stop) {
            guard case let .google(error) = failure, case .http(404, _) = error else { throw failure }
            refusals += 1
            firstRefusal = firstRefusal ?? error
            guard refusals <= AlbumMirroring.refusalBudget else { throw failure }
        }

        /// Waits out Google's passing 5xx and 408, within the step's budget.
        private mutating func call<T>(_ body: () async throws(GooglePhotosError) -> T) async throws(Stop) -> T {
            for delay in AlbumMirroring.retryDelays + [nil] {
                do {
                    return try await body()
                } catch {
                    guard let delay, Self.isTransient(error), retriesLeft > 0 else { throw .google(error) }
                    retriesLeft -= 1
                    guard await sleep(delay) else { throw .stopped }
                }
            }
            throw .google(.invalidResponse("unreachable"))
        }

        private static func isTransient(_ error: GooglePhotosError) -> Bool {
            if case let .http(status, _) = error { return status == 408 || status >= 500 }
            return false
        }
    }
}
