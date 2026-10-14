import Foundation
import PhotosBackupCore

/// STUB (foundation commit): the Mac-shell piece replaces this file.
/// User notifications for finished automatic runs and for problems that
/// need a person (sign in again, Full Disk Access, storage full).
@MainActor
final class Notifier {
    func requestAuthorization() {}
    func runFinished(_ record: RunRecord, settings: BackupSettings) {}
    func problem(_ message: String, category: EventCategory, settings: BackupSettings) {}
}
