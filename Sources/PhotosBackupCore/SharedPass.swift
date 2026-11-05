import Foundation

/// One pass of several accounts backed up at the same time (issue #66): each
/// account's own plan, merged so that every photo is exported from Photos
/// once and its staged file is sent to each account that planned it.
///
/// Measured 2026-11-05: Google takes about 4 to 6 upload commits at once from
/// one account (at 16 to one account, 58 of 100 photos failed with 500/503),
/// while the uplink (177 Mbit/s) had room for several times that. Each
/// account has its own limit, so accounts uploading side by side fill the
/// link where more uploads to one account cannot.
///
/// The merge never decides what an account gets: every send carries only
/// assets that account's own plan put in one of its upload steps, with that
/// step's album, so the planner's guards (no hidden photo for an account but
/// the primary and never in an album, no bulk re-adds, held album adds) hold
/// per account exactly as when the accounts ran one after another.
public struct SharedPass: Equatable, Sendable {
    /// What one account sends from one batch: the assets of one of its
    /// upload steps that this batch staged.
    public struct Send: Equatable, Sendable {
        public let account: String
        public let albumID: String
        public let albumTitle: String?
        public let assetIDs: [String]

        public init(account: String, albumID: String, albumTitle: String?, assetIDs: [String]) {
            self.account = account
            self.albumID = albumID
            self.albumTitle = albumTitle
            self.assetIDs = assetIDs
        }
    }

    /// One export from Photos and what each account sends from it. Its files
    /// go once every account has finished with them.
    public struct Batch: Equatable, Sendable {
        public let assetIDs: [String]
        /// Exported with hidden photos and picker files: hand-picked steps
        /// only (BackupPlanner.pickedAlbumID), which only the primary plans.
        public let includingHidden: Bool
        /// In account order, each account's in its plan's order.
        public let sends: [Send]

        public init(assetIDs: [String], includingHidden: Bool, sends: [Send]) {
            self.assetIDs = assetIDs
            self.includingHidden = includingHidden
            self.sends = sends
        }

        public var accounts: [String] {
            var seen = Set<String>()
            return sends.map(\.account).filter { seen.insert($0).inserted }
        }

        public func sends(for account: String) -> [Send] { sends.filter { $0.account == account } }
    }

    public let batches: [Batch]
    /// Each account's steps that are not uploads of new photos (album adds,
    /// edits to check), in its plan's order; they run per account after the
    /// shared batches.
    public let rest: [String: [PlannedStep]]
    /// How many assets each account's upload steps hold.
    public let uploads: [String: Int]

    /// - Parameter plans: each account's steps in run order (the primary
    ///   first), as BackupPlanner made them for that account.
    public init(plans: [(account: String, steps: [PlannedStep])], batchSize: Int) {
        let batchSize = max(1, batchSize)
        var picked = OrderedIDs()
        var others = OrderedIDs()
        var rest: [String: [PlannedStep]] = [:]
        var uploads: [String: Int] = [:]
        for (account, steps) in plans {
            if uploads[account] == nil { uploads[account] = 0 }
            for step in steps {
                guard case let .upload(albumID, _, assetIDs) = step else {
                    rest[account, default: []].append(step)
                    continue
                }
                uploads[account, default: 0] += assetIDs.count
                if albumID == BackupPlanner.pickedAlbumID {
                    picked.append(assetIDs)
                } else {
                    others.append(assetIDs)
                }
            }
        }
        let chunks = picked.ids.chunked(batchSize).map { ($0, true) } + others.ids.chunked(batchSize).map { ($0, false) }
        batches = chunks.map { ids, hidden in
            let inBatch = Set(ids)
            var sends: [Send] = []
            for (account, steps) in plans {
                for case let .upload(albumID, title, assetIDs) in steps where (albumID == BackupPlanner.pickedAlbumID) == hidden {
                    let here = assetIDs.filter { inBatch.contains($0) }
                    if !here.isEmpty { sends.append(Send(account: account, albumID: albumID, albumTitle: title, assetIDs: here)) }
                }
            }
            return Batch(assetIDs: ids, includingHidden: hidden, sends: sends)
        }
        self.rest = rest
        self.uploads = uploads
    }

    public var isEmpty: Bool { batches.isEmpty && rest.values.allSatisfy(\.isEmpty) }
}

/// Asset ids in the order first seen, each once.
private struct OrderedIDs {
    private(set) var ids: [String] = []
    private var seen = Set<String>()

    mutating func append(_ more: [String]) {
        for id in more where seen.insert(id).inserted { ids.append(id) }
    }
}
