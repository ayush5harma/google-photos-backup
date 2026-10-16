import XCTest
@testable import PhotosBackupCore

final class DeviceImportTests: XCTestCase {
    func testUniquePreservesFirstStableDeviceIdentity() {
        let first = DeviceMediaItem(id: "device:1", filename: "one.jpg", byteCount: 1, createdAt: nil, isMovie: false)
        let duplicate = DeviceMediaItem(id: "device:1", filename: "renamed.jpg", byteCount: 2, createdAt: nil, isMovie: false)
        let second = DeviceMediaItem(id: "device:2", filename: "two.mov", byteCount: 3, createdAt: nil, isMovie: true)
        XCTAssertEqual(DeviceImportPlan.unique([first, duplicate, second]), [first, second])
        XCTAssertEqual(DeviceImportPlan.selected([first, duplicate, second], ids: ["device:2"]), [second])
    }

    func testStableIdentityScopesFallbackHandlesToTheirCamera() {
        let first = DeviceImportPlan.stableIdentifier(deviceID: "camera-one", fingerprint: nil, objectHandle: 7, filename: "IMG_0001.JPG")
        let again = DeviceImportPlan.stableIdentifier(deviceID: "camera-one", fingerprint: nil, objectHandle: 7, filename: "IMG_0001.JPG")
        let second = DeviceImportPlan.stableIdentifier(deviceID: "camera-two", fingerprint: nil, objectHandle: 7, filename: "IMG_0001.JPG")
        XCTAssertEqual(first, again)
        XCTAssertNotEqual(first, second)
    }

    func testReclaimBatchNeverSplitsPairedComponents() {
        let one = DeviceMediaItem(id: "one", filename: "one.jpg", byteCount: 1, createdAt: nil, isMovie: false)
        let movie = DeviceMediaItem(id: "movie", filename: "one.mov", byteCount: 1, createdAt: nil, isMovie: true)
        let next = DeviceMediaItem(id: "next", filename: "two.jpg", byteCount: 1, createdAt: nil, isMovie: false)
        let batch = DeviceImportPlan.batchKeepingGroupsTogether([one, movie, next], limit: 1,
                                                                 groups: ["one": ["movie"], "movie": ["one"]])
        XCTAssertEqual(batch, [one, movie])
    }
    func testOversizedCameraGroupCannotExpandStagingBatch() {
        let items = (0..<1000).map { DeviceMediaItem(id: String($0), filename: "frame.jpg", byteCount: 1, createdAt: nil, isMovie: false) }
        let members = Set(items.map(\.id))
        let batch = DeviceImportPlan.batchKeepingGroupsTogether(items, limit: 10, groups: ["0": members])
        XCTAssertEqual(batch.count, 10)
        XCTAssertFalse(members.isSubset(of: Set(batch.map(\.id))))
    }

    func testSelectedDeviceNeverFallsThroughToAnotherDeviceDuringImport() {
        var selection = ConnectedDeviceSelection()
        XCTAssertTrue(selection.select("iphone"))
        XCTAssertTrue(selection.beginImport(available: ["iphone", "ipad"]))
        XCTAssertFalse(selection.select("ipad"))
        selection.disconnected("iphone")
        XCTAssertNil(selection.selectedID)
        selection.endImport()
        XCTAssertTrue(selection.select("ipad"))
        XCTAssertEqual(selection.selectedID, "ipad")
    }

    func testEndingAnIdleImportReleasesDeviceSelection() {
        var selection = ConnectedDeviceSelection()
        XCTAssertTrue(selection.select("iphone"))
        XCTAssertTrue(selection.beginImport(available: ["iphone", "ipad"]))
        selection.endImport() // Mirrors stop before a queued task starts.
        XCTAssertTrue(selection.select("ipad"))
        XCTAssertEqual(selection.selectedID, "ipad")
    }

}
