import Foundation
@testable import PhotosBackup
import PhotosBackupCore
import XCTest

/// Settings saved before "Choose parallel uploads automatically" existed:
/// the old default of 2 (stored for everyone who never touched it) becomes
/// Automatic, a number someone chose stays the most a run uses.
final class BackupSettingsTests: XCTestCase {
    private func decode(_ json: String) throws -> BackupSettings {
        try JSONDecoder().decode(BackupSettings.self, from: Data(json.utf8))
    }

    func testTheOldDefaultBecomesAutomatic() throws {
        let settings = try decode(#"{"threads": 2}"#)
        XCTAssertTrue(settings.threadsAutomatic)
        XCTAssertEqual(settings.parallelUploadCap, UploadParallelism.automaticCap)
        XCTAssertTrue(try decode("{}").threadsAutomatic)
    }

    func testAChosenNumberStaysTheMost() throws {
        for threads in [1, 3, 8, 16] {
            let settings = try decode(#"{"threads": \#(threads)}"#)
            XCTAssertFalse(settings.threadsAutomatic, "\(threads)")
            XCTAssertEqual(settings.parallelUploadCap, threads)
        }
    }

    func testTheChosenNumberIsClampedToTheBridgesSixteen() throws {
        XCTAssertEqual(BackupSettings.threadRange, 1...16)
        XCTAssertEqual(try decode(#"{"threads": 40}"#).threads, 16)
        XCTAssertEqual(try decode(#"{"threads": 0}"#).threads, 1)
    }

    func testTheChoiceRoundTrips() throws {
        var settings = BackupSettings()
        settings.threadsAutomatic = false
        settings.threads = 2
        let again = try JSONDecoder().decode(BackupSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertFalse(again.threadsAutomatic)
        XCTAssertEqual(again.parallelUploadCap, 2)
        XCTAssertEqual(BackupSettings().quality, .original)
    }
}
