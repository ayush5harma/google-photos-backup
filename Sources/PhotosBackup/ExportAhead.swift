import Foundation
import PhotosBackupCore

/// Exports batches ahead of the one uploading (issue #50), so the network
/// does not wait on PhotoKit between batches: one export at a time, in the
/// order asked, never more than StagingWindow allows to sit on disk.
@MainActor
final class ExportAhead<Batch> {
    private var tasks: [Int: Task<Batch, Never>] = [:]
    /// The most recently started export; the next one waits for it.
    private var last: Task<Batch, Never>?
    /// Bytes of batches exported and not yet taken.
    private(set) var bytesReady: Int64 = 0
    private let bytes: (Batch) -> Int64

    init(bytes: @escaping (Batch) -> Int64) {
        self.bytes = bytes
    }

    var count: Int { tasks.count }

    /// Starts exporting `candidates` (step indices, in order) for as many as
    /// the window has room for; an index already started is skipped.
    func stage(_ candidates: [Int], export: @escaping (Int) async -> Batch) {
        for index in candidates where tasks[index] == nil {
            guard StagingWindow.mayStage(batchesReady: tasks.count, bytesReady: bytesReady) else { return }
            let previous = last
            let task = Task { () -> Batch in
                _ = await previous?.value
                let batch = await export(index)
                self.bytesReady += self.bytes(batch)
                return batch
            }
            tasks[index] = task
            last = task
        }
    }

    /// The batch for `index`, waiting for its export to finish; nil when it
    /// was never started.
    func take(_ index: Int) async -> Batch? {
        guard let task = tasks.removeValue(forKey: index) else { return nil }
        let batch = await task.value
        bytesReady -= bytes(batch)
        return batch
    }

    /// Ends every export not taken: each is cancelled (an export checks
    /// Task.isCancelled between items) and its batch handed back for cleanup.
    func discard() async -> [Batch] {
        let pending = tasks.sorted { $0.key < $1.key }.map(\.value)
        tasks = [:]
        last = nil
        pending.forEach { $0.cancel() }
        var batches: [Batch] = []
        for task in pending {
            let batch = await task.value
            bytesReady -= bytes(batch)
            batches.append(batch)
        }
        return batches
    }
}
