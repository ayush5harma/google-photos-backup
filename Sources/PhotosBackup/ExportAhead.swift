import Foundation
import PhotosBackupCore

/// Exports batches ahead of the one uploading (issue #50), so the network
/// does not wait on PhotoKit between batches. One export at a time, in the
/// order asked; the next starts only once the last has finished, so the
/// StagingWindow check sees every byte already on disk (one batch in
/// progress may take it past the byte cap, never two).
@MainActor
final class ExportAhead<Batch> {
    private var ready: [Int: Batch] = [:]
    private var running: (index: Int, task: Task<Batch, Never>)?
    private var queue: [Int] = []
    private var export: ((Int) async -> Batch)?
    /// Bytes of batches exported and not yet taken.
    private(set) var bytesReady: Int64 = 0
    private let bytes: (Batch) -> Int64

    init(bytes: @escaping (Batch) -> Int64) {
        self.bytes = bytes
    }

    /// Batches exported or exporting, not yet taken.
    var count: Int { ready.count + (running == nil ? 0 : 1) }

    /// Exports `candidates` (step indices, in order) as the window allows,
    /// replacing any earlier list; an index already exported is kept.
    func stage(_ candidates: [Int], export: @escaping (Int) async -> Batch) {
        self.export = export
        queue = candidates.filter { ready[$0] == nil && running?.index != $0 }
        pump()
    }

    /// The batch for `index`, waiting for its export to finish; nil when it
    /// was never started (the caller exports it then).
    func take(_ index: Int) async -> Batch? {
        queue.removeAll { $0 == index }
        if let running, running.index == index { _ = await running.task.value }
        guard let batch = ready.removeValue(forKey: index) else { return nil }
        bytesReady -= bytes(batch)
        pump()
        return batch
    }

    /// Ends every export not taken: the one running is cancelled (an export
    /// checks Task.isCancelled between items), and every batch is handed back
    /// for cleanup.
    func discard() async -> [Batch] {
        queue = []
        export = nil
        if let running {
            running.task.cancel()
            _ = await running.task.value
        }
        let batches = ready.sorted { $0.key < $1.key }.map(\.value)
        ready = [:]
        bytesReady = 0
        return batches
    }

    private func pump() {
        guard running == nil, let export, let next = queue.first,
              StagingWindow.mayStage(batchesReady: ready.count, bytesReady: bytesReady) else { return }
        queue.removeFirst()
        let task = Task { () -> Batch in
            let batch = await export(next)
            // Bookkept inside the task, so whoever awaits it sees it done.
            self.ready[next] = batch
            self.bytesReady += self.bytes(batch)
            self.running = nil
            self.pump()
            return batch
        }
        running = (next, task)
    }
}
