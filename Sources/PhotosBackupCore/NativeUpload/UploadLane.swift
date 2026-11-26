import Foundation

/// One exported file, ready for every account that planned its asset.
public struct StagedItem: Sendable, Equatable {
    public let assetID: String
    public let file: URL
    public let fileName: String
    public let sha1: Data
    /// The capture time (PHAsset.creationDate), sent in whole seconds.
    public let timestamp: Date
    public let size: Int64
    /// Skip the hash check: Google lost the key it had for these bytes
    /// (BackupState.forcedUploads), so the check could hand it back.
    public let force: Bool

    public init(assetID: String, file: URL, fileName: String, sha1: Data, timestamp: Date, size: Int64, force: Bool = false) {
        self.assetID = assetID
        self.file = file
        self.fileName = fileName
        self.sha1 = sha1
        self.timestamp = timestamp
        self.size = size
        self.force = force
    }

    public func forced(_ force: Bool) -> StagedItem {
        StagedItem(assetID: assetID, file: file, fileName: fileName, sha1: sha1, timestamp: timestamp, size: size, force: force)
    }
}

/// What became of one item in one account.
public enum ItemOutcome: Sendable, Equatable {
    /// Google gave a media key: the only proof of an upload. `existing`: it
    /// had these bytes already (the hash check found them).
    case committed(mediaKey: String, existing: Bool)
    /// Failed for this run; `retryable`: sending the file again may work.
    case failed(message: String, retryable: Bool)
    /// Not sent, or sent without an answer (stop, pause, the account's part
    /// ended): it stays un-uploaded, never failed, and the next run sends it.
    case notSent

    public var mediaKey: String? {
        if case let .committed(key, _) = self { key } else { nil }
    }
}

/// Why an account's part of a run ended early. The other accounts carry on.
public struct LaneHalt: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// Google refused the account (sign in again).
        case auth
        /// The account has no room left.
        case storageFull
        /// Google could not be reached through every attempt.
        case network
        /// Google kept answering 429 through RateLimiter.maximumHoldsPerRun holds.
        case rateLimit
    }

    public let kind: Kind
    public let message: String

    public init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
    }
}

public enum LaneEnd: Sendable, Equatable {
    /// Every item has an outcome other than notSent.
    case finished
    /// Stop, pause or cancellation: what was not answered is notSent.
    case stopped
    case halted(LaneHalt)
}

/// One account's uploads, as the bridge's `upload` command does them, with
/// the Mac engine's decisions between its requests:
///
/// - each item's hash is looked up first unless it is forced; a key Google
///   already has is recorded as existing, and the file is not sent;
/// - up to `parallelism.current` files go up at once (UploadParallelism
///   moves it between rounds from what each round measured);
/// - finished uploads are gathered and committed up to 20 a request
///   (GooglePhotosClient.commitBatchSize, the bridge's CommitBatcher), and an
///   item a batch answered without a key is committed alone (commitOne);
/// - failures are classified (GooglePhotosError.failureClass) and decided by
///   RetryTracker: a retryable one goes in a later round after its backoff,
///   a 429 holds the account (RateLimiter) and costs no attempt, a permanent
///   one fails; auth and a full account end the account's part, as does a
///   network failure that spent its attempts.
///
/// A media key is the only proof of an upload: an item is reported
/// committed only with the key Google issued for it, so the caller never
/// records anything without one.
public actor UploadLane {
    /// Called before every round with the moment the round may start (a
    /// retry's backoff or Google's hold; nil when nothing is due). Returns
    /// false to stop: the caller's stop, pause, or a condition it gave up
    /// waiting for. It also waits out the caller's own conditions.
    public typealias Waiter = @Sendable (_ until: Date?) async -> Bool
    /// Each item's outcome as soon as it has one; awaited, so a committed
    /// key can be recorded before the lane moves on.
    public typealias Reporter = @Sendable (_ assetID: String, _ outcome: ItemOutcome) async -> Void

    public nonisolated let account: String
    private let client: any GooglePhotosUploading
    private let quality: UploadQuality
    private let now: @Sendable () -> Date
    public private(set) var parallelism: UploadParallelism
    public private(set) var retries: RetryTracker
    public private(set) var rateLimiter = RateLimiter()

    public init(account: String, client: any GooglePhotosUploading, quality: UploadQuality, parallelism: UploadParallelism,
                retries: RetryTracker = RetryTracker(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.account = account
        self.client = client
        self.quality = quality
        self.parallelism = parallelism
        self.retries = retries
        self.now = now
    }

    /// Google's hold on this account, if one is running.
    public func hold(at date: Date) -> Date? { rateLimiter.hold(at: date) }

    /// Google's 429 on a call outside `send` (an album call): holds the
    /// account as a refused upload does. True when the run should give up.
    public func hitRateLimit() -> Bool {
        rateLimiter.hitLimit(at: now())
        return rateLimiter.runShouldGiveUp
    }

    public func runStarted() { rateLimiter.runStarted() }

    public static let rateLimitGiveUp = "\(EventPhrase.rateLimited) through \(RateLimiter.maximumHoldsPerRun) waits in a row, "
        + "so this run stopped; the next run tries again."

    /// Sends `items` until each is committed, has failed for this run, or the
    /// lane stops; every item gets exactly one outcome through `report`.
    public func send(_ items: [StagedItem], wait: Waiter, report: Reporter) async -> LaneEnd {
        // The largest first, so a long video starts early (the Mac's order).
        var pending = StagingWindow.largestFirst(items, size: \.size)
        var retryAt: Date?
        var firstRound = true
        while !pending.isEmpty {
            let until = [retryAt, rateLimiter.hold(at: now())].compactMap { $0 }.max()
            let mayGo = Task.isCancelled ? false : await wait(until)
            if !mayGo || Task.isCancelled {
                await Self.notSent(pending, report)
                return .stopped
            }
            retryAt = nil
            let round = await sendRound(pending, report: report)

            var next: [StagedItem] = []
            var limited = round.rateLimited
            var serverFailures = 0
            var halt: LaneHalt?
            for (item, error) in round.failures {
                if let kind = Self.endsPart(error) {
                    halt = halt ?? LaneHalt(kind: kind, message: error.message)
                    next.append(item)
                    continue
                }
                let failure = error.failureClass
                if failure == .retryable { serverFailures += 1 }
                if failure == .rateLimited { limited = true }
                switch retries.failed(item.assetID, as: failure) {
                case let .retry(after):
                    let at = now().addingTimeInterval(after)
                    retryAt = max(retryAt ?? at, at)
                    next.append(item)
                case .waitForRateLimit:
                    next.append(item)
                case .giveUp:
                    await report(item.assetID, .failed(message: error.message, retryable: failure != .permanent))
                    // Attempts spent and Google still unreachable: the
                    // account's part ends as a Mac run's does.
                    if case .network = error { halt = halt ?? LaneHalt(kind: .network, message: error.message) }
                }
            }
            parallelism.measured(UploadSample(bytes: round.bytes, seconds: now().timeIntervalSince(round.startedAt), items: round.uploaded,
                                              rateLimited: limited, serverFailures: serverFailures, requested: pending.count,
                                              firstRound: firstRound))
            firstRound = false
            if let halt {
                await Self.notSent(next + round.unanswered, report)
                return .halted(halt)
            }
            if !round.unanswered.isEmpty {
                await Self.notSent(next + round.unanswered, report)
                return .stopped
            }
            if limited {
                rateLimiter.hitLimit(at: now())
                if rateLimiter.runShouldGiveUp {
                    await Self.notSent(next, report)
                    return .halted(LaneHalt(kind: .rateLimit, message: Self.rateLimitGiveUp))
                }
            } else if round.committed > 0 {
                rateLimiter.batchSucceeded()
            }
            pending = next
        }
        return .finished
    }

    /// Auth trouble and a full account cannot be fixed by sending again:
    /// the account's part ends and its unsent items wait for the next run.
    private static func endsPart(_ error: GooglePhotosError) -> LaneHalt.Kind? {
        switch error {
        case .auth, .invalidCredential: .auth
        case .storageFull: .storageFull
        default: nil
        }
    }

    private static func notSent(_ items: [StagedItem], _ report: Reporter) async {
        for item in items { await report(item.assetID, .notSent) }
    }

    // MARK: - One round

    private struct Round {
        let startedAt: Date
        var failures: [(StagedItem, GooglePhotosError)] = []
        /// Sent but not answered: the round was cancelled.
        var unanswered: [StagedItem] = []
        var committed = 0
        var uploaded = 0
        var bytes: Int64 = 0
        var rateLimited = false
    }

    private enum Step: Sendable {
        case existing(StagedItem, String)
        case uploaded(StagedItem, UploadedFile)
        case failed(StagedItem, GooglePhotosError)
    }

    /// The bridge's one request: hash checks and uploads `parallelism` at a
    /// time, commits gathered 20 at a time as uploads finish, the rest at
    /// the end.
    private func sendRound(_ items: [StagedItem], report: Reporter) async -> Round {
        var round = Round(startedAt: now())
        let client = client
        let width = max(1, parallelism.current)
        var gathered: [(StagedItem, UploadedFile)] = []
        await withTaskGroup(of: Step.self) { group in
            var queue = items[...]
            func startNext() {
                guard !Task.isCancelled, let item = queue.popFirst() else { return }
                group.addTask { await Self.prepare(item, client: client) }
            }
            for _ in 0..<width { startNext() }
            while let step = await group.next() {
                switch step {
                case let .existing(item, key):
                    round.committed += 1
                    await report(item.assetID, .committed(mediaKey: key, existing: true))
                case let .uploaded(item, file):
                    gathered.append((item, file))
                    if gathered.count >= GooglePhotosClient.commitBatchSize, !Task.isCancelled {
                        await commit(gathered, into: &round, report: report)
                        gathered = []
                    }
                case let .failed(item, error):
                    if Task.isCancelled {
                        round.unanswered.append(item)
                    } else {
                        if error.failureClass == .rateLimited { round.rateLimited = true }
                        round.failures.append((item, error))
                    }
                }
                startNext()
            }
            // Cancelled: what never started is unanswered too.
            round.unanswered += queue
        }
        if Task.isCancelled {
            // Uploaded bytes without a commit are not a backup; the next run's
            // hash check finds any Google did keep.
            round.unanswered += gathered.map(\.0)
        } else if !gathered.isEmpty {
            await commit(gathered, into: &round, report: report)
        }
        return round
    }

    private static func prepare(_ item: StagedItem, client: any GooglePhotosUploading) async -> Step {
        do {
            if !item.force, let key = try await client.findRemoteMedia(sha1: item.sha1) {
                return .existing(item, key)
            }
            let file = try await client.upload(file: item.file, fileName: item.fileName, sha1: item.sha1,
                                               timestamp: item.timestamp, progress: nil)
            return .uploaded(item, file)
        } catch {
            return .failed(item, error)
        }
    }

    /// Up to 20 per request; an item a batch answered without a key goes
    /// alone. A commit refused as a whole fails each of its items alike.
    private func commit(_ batch: [(StagedItem, UploadedFile)], into round: inout Round, report: Reporter) async {
        let keys: [String?]
        do {
            keys = try await client.commit(batch.map(\.1), quality: quality)
        } catch {
            for (item, _) in batch { failure(item, error, into: &round) }
            return
        }
        for ((item, file), key) in zip(batch, keys) {
            var mediaKey = key
            if mediaKey == nil {
                do {
                    mediaKey = try await client.commitOne(file, quality: quality)
                } catch {
                    failure(item, error, into: &round)
                    continue
                }
            }
            guard let mediaKey else { continue }
            round.committed += 1
            round.uploaded += 1
            round.bytes += item.size
            await report(item.assetID, .committed(mediaKey: mediaKey, existing: false))
        }
        // A shorter answer than the batch: the rest had no key at all.
        for (item, _) in batch.dropFirst(keys.count) {
            failure(item, .invalidResponse("Google's commit answer left this item out."), into: &round)
        }
    }

    private func failure(_ item: StagedItem, _ error: GooglePhotosError, into round: inout Round) {
        if Task.isCancelled {
            round.unanswered.append(item)
            return
        }
        if error.failureClass == .rateLimited { round.rateLimited = true }
        round.failures.append((item, error))
    }
}
