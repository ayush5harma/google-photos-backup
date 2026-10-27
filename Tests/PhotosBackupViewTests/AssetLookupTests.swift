import Photos
@testable import PhotosBackup
import XCTest

/// The exporter finds each asset it is asked for by identifier, and PhotoKit's
/// default options leave out non-pick burst frames and hidden photos. Measured
/// on a real library: 195 burst frames filed in albums (2026-10-27) and 62
/// photos chosen from the unlocked Hidden album (2026-10-28) all failed as "No
/// longer in the Photos library". PhotoKit cannot run here, so this holds the
/// two options the fix depends on.
@MainActor
final class AssetLookupTests: XCTestCase {
    func testLookupFindsBurstFramesAndHiddenPhotos() {
        let options = AssetExporter.lookup
        XCTAssertTrue(options.includeAllBurstAssets)
        XCTAssertTrue(options.includeHiddenAssets)
    }
}
