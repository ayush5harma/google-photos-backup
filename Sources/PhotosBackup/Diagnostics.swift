import Foundation
import Observation
import PhotosBackupCore

/// STUB (foundation commit): the engine-parity piece replaces this file.
/// Owns the run history (last 40) and the event timeline (400 events, 14
/// days), both persisted under Application Support, plus storage use, clean
/// up, and the shareable diagnostic report.
@MainActor
@Observable
final class Diagnostics {
    private(set) var runs: [RunRecord] = []
    private(set) var events: [EventRecord] = []

    @ObservationIgnored private let paths: AppPaths

    init(paths: AppPaths) {
        self.paths = paths
    }

    func record(_ run: RunRecord) {}
    func log(_ category: EventCategory, _ message: String, problem: Bool) {}
    func usage() async -> StorageUsage { StorageUsage() }
    /// Removes staging leftovers and rotated logs; returns the bytes freed.
    func cleanUp() async -> Int64 { 0 }
    /// A redacted plain-text report with a "What stands out" summary first.
    func report(model: AppModel) -> String { "" }
}
