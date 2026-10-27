import CoreGraphics
import Foundation
import ImageIO
@testable import PhotosBackup
import UniformTypeIdentifiers
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

    private func export(_ id: String, file: URL?, includingHidden: Bool = true) async -> (Result<ExportedAsset, Error>?, [String]) {
        var result: Result<ExportedAsset, Error>?
        var started: [String] = []
        await AssetExporter().export([id], includingHidden: includingHidden, pickedFiles: file.map { [id: $0] } ?? [:],
                                     into: scratch.appendingPathComponent("batch"), shouldStop: { false },
                                     started: { _, name in started.append(name) }, finished: { _, outcome in result = outcome })
        return (result, started)
    }

    /// A one-pixel JPEG carrying an EXIF capture time, as a camera writes it.
    private func jpeg(named name: String, taken: String, offset: String) throws -> URL {
        let url = scratch.appendingPathComponent(name)
        let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        let exif: [CFString: Any] = [kCGImagePropertyExifDateTimeOriginal: taken, kCGImagePropertyExifOffsetTimeOriginal: offset]
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyExifDictionary: exif] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    func testAnUnseenPickExportsFromThePickersFileWithItsCaptureTime() async throws {
        let picked = try jpeg(named: "IMG_4405.JPG", taken: "2025:11:29 16:32:36", offset: "+05:30")
        let (outcome, started) = await export("hidden-1/L0/001", file: picked)

        let exported = try XCTUnwrap(outcome).get()
        XCTAssertEqual(exported.filename, "IMG_4405.JPG")
        XCTAssertEqual(started, ["IMG_4405.JPG"])
        XCTAssertEqual(try Data(contentsOf: exported.url), try Data(contentsOf: picked))
        // gpmc sends the mtime, which Google Photos falls back on.
        let mtime = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: exported.url.path)[.modificationDate] as? Date)
        XCTAssertEqual(mtime.timeIntervalSince1970, 1_764_414_156, accuracy: 1)
        // Copied, not moved: a retry still has it until Google confirms it.
        XCTAssertTrue(FileManager.default.fileExists(atPath: picked.path))
    }

    func testAHiddenPickWithoutAFileSaysSoAndAnAlbumAssetStillReadsMissing() async throws {
        let (hidden, _) = await export("hidden-2/L0/001", file: nil, includingHidden: true)
        guard case let .failure(error) = try XCTUnwrap(hidden) else { return XCTFail("exported without a file") }
        XCTAssertEqual(error.localizedDescription, "Photos did not hand over this hidden item; choose it again")

        let (album, _) = await export("gone/L0/001", file: nil, includingHidden: false)
        guard case let .failure(missing) = try XCTUnwrap(album) else { return XCTFail("exported without a file") }
        XCTAssertEqual(missing.localizedDescription, "No longer in the Photos library")
    }

    func testExifCaptureTimesReadWithAndWithoutAnOffset() throws {
        let withOffset = try XCTUnwrap(PickedFile.exifDate("2025:11:29 16:32:36", offset: "+05:30"))
        XCTAssertEqual(withOffset.timeIntervalSince1970, 1_764_414_156, accuracy: 0.5)
        XCTAssertNotNil(PickedFile.exifDate("2025:11:29 16:32:36", offset: nil))
        XCTAssertNil(PickedFile.exifDate("not a date", offset: nil))
    }

    private func local(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int) -> Date? {
        Calendar(identifier: .gregorian).date(from: DateComponents(timeZone: .current, year: year, month: month, day: day,
                                                                   hour: hour, minute: minute, second: second))
    }

    func testCaptureTimesReadFromPhoneAndCameraFileNames() {
        XCTAssertEqual(PickedFile.dateInName("Screenshot_2018-11-13-17-37-06-131_com.google.a.png"), local(2018, 11, 13, 17, 37, 6))
        XCTAssertEqual(PickedFile.dateInName("2025-11-29_16-32-36.heic"), local(2025, 11, 29, 16, 32, 36))
        XCTAssertEqual(PickedFile.dateInName("IMG_20230324_015637.jpg"), local(2023, 3, 24, 1, 56, 37))
        // Pixel names its files in UTC.
        XCTAssertEqual(PickedFile.dateInName("PXL_20230324_015637359.NIGHT.JPG"), Date(timeIntervalSince1970: 1_679_622_997))
        XCTAssertNil(PickedFile.dateInName("IMG_4405.HEIC"))
        XCTAssertNil(PickedFile.dateInName("Screenshot_2018-13-45-17-37-06.png"))
    }

    func testAnUnparseableOffsetFallsBackToLocalTime() {
        XCTAssertEqual(PickedFile.exifDate("2025:11:29 16:32:36", offset: ""), local(2025, 11, 29, 16, 32, 36))
        XCTAssertEqual(PickedFile.exifDate("2025:11:29 16:32:36", offset: "garbage"), local(2025, 11, 29, 16, 32, 36))
    }

    func testAScreenshotWithNoMetadataTakesItsDateFromItsName() async throws {
        // The first hidden pick on 2026-10-28: a PNG with no EXIF whose mtime
        // was its import into Photos, eight years after it was taken.
        let url = scratch.appendingPathComponent("Screenshot_2018-11-13-17-37-06-131_com.google.a.png")
        let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_791_000_000)], ofItemAtPath: url.path)

        let (outcome, _) = await export("hidden-4/L0/001", file: url)
        let exported = try XCTUnwrap(outcome).get()
        let mtime = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: exported.url.path)[.modificationDate] as? Date)
        XCTAssertEqual(mtime, local(2018, 11, 13, 17, 37, 6))
        XCTAssertEqual(exported.filename, "Screenshot_2018-11-13-17-37-06-131_com.google.a.png")
    }

    func testGeneratedOrRenditionNamesGiveWayToTheCaptureTime() {
        let taken = Date(timeIntervalSince1970: 1_764_414_156)
        XCTAssertEqual(PickedFile.uploadName("IMG_4405.HEIC", captured: taken), "IMG_4405.HEIC")
        let stamp = { (date: Date) -> String in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            return formatter.string(from: date)
        }(taken)
        XCTAssertEqual(PickedFile.uploadName("version=1&uuid=AB12&mode=current.heic", captured: taken), "\(stamp).heic")
        XCTAssertEqual(PickedFile.uploadName("FullSizeRender.mov", captured: taken), "\(stamp).mov")
        XCTAssertEqual(PickedFile.uploadName("FullSizeRender.jpeg", captured: nil), "Photo.jpeg")
    }

    func testAPickedFileIsCopiedOutOfThePickersFolderAndDiscarded() throws {
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
