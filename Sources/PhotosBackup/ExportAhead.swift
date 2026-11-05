import Foundation
import PhotosBackupCore

/// Exports batches ahead of the one uploading (issue #50), so the network
/// does not wait on PhotoKit between batches. One export at a time, in the
/// order asked. Before each item, an export asks mayExport(_:after:freeSpace:),
/// so what waits on disk stays within StagingWindow.bytesAhead.
///
/// Nothing here waits for an export to finish once the run has let it go.
/// An item PhotoKit is writing (an iCloud download) cannot be interrupted, so
/// a discarded export stops before its next item, and its batch goes to
/// `abandoned` when the item in progress is done.
@MainActor
final class ExportAhead<Batch> {
    /// What discard() leaves the caller.
    struct Discarded {
        /// Batches exported and not taken.
        var ready: [Batch]
        /// The step whose export was still running; its batch goes to
        /// `abandoned` later.
        var exporting: Int?
    }

    private struct Running {
        let index: Int
        let task: Task<Void, Never>
        /// Let go by discard(): nobody takes it, but the next export still
        /// waits for it, so two never run at once.
        var discarded = false
    }

    private var ready: [Int: Batch] = [:]
    private var running: Running?
    private var queue: [Int] = []
    private var export: ((Int) async -> Batch)?
    /// take() calls waiting for the running export to finish or be let go.
    private var waiting: [CheckedContinuation<Void, Never>] = []
    /// Bytes of batches exported and not yet taken.
    private(set) var bytesReady: Int64 = 0
    private let bytes: (Batch) -> Int64
    private let isComplete: (Batch) -> Bool
    private let abandoned: (Batch) -> Void

    /// - Parameters:
    ///   - isComplete: false for a batch whose export stopped part-way; its
    ///     step exports the rest on its turn, so no export starts while it
    ///     waits to be taken.
    ///   - abandoned: a discarded export's batch, once its last item is
    ///     written; nobody takes it, so its files go.
    init(bytes: @escaping (Batch) -> Int64, isComplete: @escaping (Batch) -> Bool = { _ in true },
         abandoned: @escaping (Batch) -> Void = { _ in }) {
        self.bytes = bytes
        self.isComplete = isComplete
        self.abandoned = abandoned
    }

    /// Batches exported or exporting, not yet taken.
    var count: Int { ready.count + (running.map { $0.discarded ? 0 : 1 } ?? 0) }

    /// Exports `candidates` (step indices, in order) as the window allows,
    /// replacing any earlier list; an index already exported is kept.
    func stage(_ candidates: [Int], export: @escaping (Int) async -> Batch) {
        self.export = export
        let exporting = running.flatMap { $0.discarded ? nil : $0.index }
        queue = candidates.filter { ready[$0] == nil && exporting != $0 }
        pump()
    }

    /// The batch for `index`, waiting for its export to finish; nil when it
    /// was never started or was discarded meanwhile (the caller exports it
    /// then). Nothing new starts until the caller stages again: the step may
    /// still export what this batch lacks, and only one export runs at a time.
    func take(_ index: Int) async -> Batch? {
        queue.removeAll { $0 == index }
        if let running, running.index == index, !running.discarded {
            await withCheckedContinuation { waiting.append($0) }
        }
        guard let batch = ready.removeValue(forKey: index) else { return nil }
        bytesReady -= bytes(batch)
        return batch
    }

    /// Whether the export running ahead may write its next item of `next`
    /// bytes (nil: not known until written), having written `exporting` so
    /// far. Judged with what is ready: see StagingWindow.mayExportAhead.
    func mayExport(_ next: Int64?, after exporting: Int64, freeSpace: Int64?) -> Bool {
        StagingWindow.mayExportAhead(staged: bytesReady + exporting, next: next, freeSpace: freeSpace)
    }

    /// Ends every export not taken, at once. The running one is cancelled
    /// (an export checks Task.isCancelled before each item) and not waited
    /// for, a take() waiting for it returns nil, and the batches exported
    /// are handed back for cleanup.
    func discard() -> Discarded {
        queue = []
        export = nil
        var exporting: Int?
        if var current = running, !current.discarded {
            current.discarded = true
            current.task.cancel()
            running = current
            exporting = current.index
        }
        release()
        let batches = ready.sorted { $0.key < $1.key }.map(\.value)
        ready = [:]
        bytesReady = 0
        return Discarded(ready: batches, exporting: exporting)
    }

    private func pump() {
        // A batch that stopped part-way (a hold, the cap, low disk) is
        // finished by its step's own export, so nothing starts until that
        // step has taken it, wherever it is in the window: two steps ahead,
        // its step's turn comes while the next export would still run.
        guard running == nil, let export, let next = queue.first,
              !ready.values.contains(where: { !isComplete($0) }),
              StagingWindow.mayStage(batchesReady: ready.count, bytesReady: bytesReady) else { return }
        queue.removeFirst()
        let task = Task { @MainActor in
            let batch = await export(next)
            self.finished(next, batch)
        }
        running = Running(index: next, task: task)
    }

    private func finished(_ index: Int, _ batch: Batch) {
        let discarded = running?.discarded ?? true
        running = nil
        if discarded {
            abandoned(batch)
        } else {
            ready[index] = batch
            bytesReady += bytes(batch)
        }
        release()
        pump()
    }

    private func release() {
        let waiters = waiting
        waiting = []
        waiters.forEach { $0.resume() }
    }
}
