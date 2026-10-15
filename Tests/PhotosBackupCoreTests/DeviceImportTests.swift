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
}
