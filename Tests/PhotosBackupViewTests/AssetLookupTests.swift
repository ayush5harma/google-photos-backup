import Photos
@testable import PhotosBackup
import XCTest

/// A hidden photo may go up only when the owner picked it. The exporter finds
/// assets by identifier, and PhotoKit's default options leave out hidden
/// photos and non-pick burst frames: measured on a real library, 195 burst
/// frames filed in albums (2026-10-27) and 62 photos chosen from the unlocked
/// Hidden album (2026-10-28) failed as "No longer in the Photos library".
/// PhotoKit cannot run here, so these hold the options the rule rests on.
@MainActor
final class AssetLookupTests: XCTestCase {
    func testOnlyAPickLooksUpHiddenPhotos() {
        XCTAssertTrue(AssetExporter.lookup(includingHidden: true).includeHiddenAssets)
        // An album's batch was listed at the start of a pass; a photo hidden
        // since then must still fail to export rather than go up.
        XCTAssertFalse(AssetExporter.lookup(includingHidden: false).includeHiddenAssets)
    }

    func testBurstFramesFiledInAlbumsAreFoundEitherWay() {
        XCTAssertTrue(AssetExporter.lookup(includingHidden: false).includeAllBurstAssets)
        XCTAssertTrue(AssetExporter.lookup(includingHidden: true).includeAllBurstAssets)
    }

    func testAlbumsAndAllPhotosAreListedWithoutHiddenPhotos() {
        XCTAssertFalse(PhotoLibrary.listing.includeHiddenAssets)
    }
}
