import Foundation
@testable import PhotosBackup
import XCTest

/// A pick PhotoKit cannot see goes up from the file the picker handed over.
/// Measured 2026-10-28: with the Hidden album locked, PhotoKit returned none
/// of the library's 62 hidden photos, so 62 hidden picks failed as "No longer
/// in the Photos library" even with includeHiddenAssets. The test process
/// has no Photos access, so every identifier here is one PhotoKit cannot see.
@MainActor
final class PickedFileTests: XCTestCase {
    private var scratch: URL!

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    func testAnUnseenPickExportsFromThePickersFile() async throws {
        let picked = scratch.appendingPathComponent("IMG_4405.HEIC")
        try Data("photo".utf8).write(to: picked)
        var results: [String: Result<ExportedAsset, Error>] = [:]
        var started: [String] = []
        await AssetExporter().export(["hidden-1/L0/001"], includingHidden: true, pickedFiles: ["hidden-1/L0/001": picked],
                                     into: scratch.appendingPathComponent("batch"), shouldStop: { false },
                                     started: { _, name in started.append(name) }, finished: { id, result in results[id] = result })

        let exported = try XCTUnwrap(results["hidden-1/L0/001"]).get()
        XCTAssertEqual(exported.filename, "IMG_4405.HEIC")
        XCTAssertEqual(exported.size, 5)
        XCTAssertEqual(try Data(contentsOf: exported.url), Data("photo".utf8))
        XCTAssertEqual(started, ["IMG_4405.HEIC"])
        // Copied, not moved: a retry still has it until Google confirms it.
        XCTAssertTrue(FileManager.default.fileExists(atPath: picked.path))
    }

    func testWithoutAPickedFileItStillFailsAsMissing() async throws {
        var results: [String: Result<ExportedAsset, Error>] = [:]
        await AssetExporter().export(["hidden-2/L0/001"], includingHidden: true, into: scratch, shouldStop: { false },
                                     started: { _, _ in }, finished: { id, result in results[id] = result })

        guard case let .failure(error) = try XCTUnwrap(results["hidden-2/L0/001"]) else { return XCTFail("exported without a file") }
        XCTAssertEqual(error.localizedDescription, "No longer in the Photos library")
    }

    func testOnlyIdentifiersPhotoKitCannotSeeAreCopiedOut() {
        XCTAssertEqual(AssetExporter.unseen(["hidden-3/L0/001"]), ["hidden-3/L0/001"])
    }

    func testAPickedFileIsCopiedOutOfThePickersFolder() throws {
        let source = scratch.appendingPathComponent("clip.mov")
        try Data("video".utf8).write(to: source)
        let file = try PickedFile(copying: source)
        XCTAssertEqual(file.url.lastPathComponent, "clip.mov")
        try FileManager.default.removeItem(at: source)
        XCTAssertEqual(try Data(contentsOf: file.url), Data("video".utf8))
        PickedFile.discard(file.url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.deletingLastPathComponent().path))
    }
}
