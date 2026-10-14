import Foundation
import Observation
import PhotosBackupCore

/// STUB (foundation commit): the engine-parity piece replaces this file.
/// Watches the network (NWPathMonitor: offline, expensive, constrained) and
/// power (battery, Low Power Mode) and says whether a setting blocks uploads.
@MainActor
@Observable
final class ConditionsMonitor {
    /// The network and power right now, in words, for the run history.
    private(set) var summary = "Unknown"
    @ObservationIgnored var onChange: (() -> Void)?

    func start(settings: BackupSettings) {}

    /// The first condition that holds uploads under these settings, or nil.
    func blocking(for settings: BackupSettings) -> WaitReason? { nil }
}
