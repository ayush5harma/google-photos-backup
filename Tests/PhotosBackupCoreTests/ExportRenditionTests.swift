import Foundation
import Testing
@testable import PhotosBackupCore

/// The export rules the iOS exporter shares with the Mac's AssetExporter:
/// which resource is uploaded, when it counts as edited, what identifies an
/// edit, and where each asset is staged.
@Suite struct ExportRenditionTests {
    @Test func anEditedPhotoUploadsItsRenderNotTheOriginal() {
        let resources: [ExportRendition.Resource] = [.photo, .adjustmentData, .fullSizePhoto]
        #expect(ExportRendition.choose(.image, among: resources) == 2)
        #expect(ExportRendition.isEdited(resources[2]))
        #expect(ExportRendition.original(among: resources) == 0)
    }

    @Test func anUneditedPhotoUploadsTheOriginal() {
        let resources: [ExportRendition.Resource] = [.photo]
        #expect(ExportRendition.choose(.image, among: resources) == 0)
        #expect(!ExportRendition.isEdited(.photo))
    }

    @Test func aLivePhotoUploadsItsStillNotItsMotion() {
        let resources: [ExportRendition.Resource] = [.pairedVideo, .photo]
        #expect(ExportRendition.choose(.image, among: resources) == 1)
    }

    @Test func anAlternatePhotoIsTheLastResort() {
        #expect(ExportRendition.choose(.image, among: [.alternatePhoto, .adjustmentData]) == 0)
        #expect(ExportRendition.choose(.image, among: [.alternatePhoto, .photo]) == 1)
    }

    @Test func anEditedVideoUploadsItsRender() {
        let resources: [ExportRendition.Resource] = [.video, .fullSizeVideo, .adjustmentData]
        #expect(ExportRendition.choose(.video, among: resources) == 1)
        #expect(ExportRendition.isEdited(.fullSizeVideo))
        #expect(ExportRendition.original(among: resources) == 0)
    }

    @Test func otherMediaTakesTheFirstResourceAndNothingIsNoChoice() {
        #expect(ExportRendition.choose(.other, among: [.other, .photo]) == 0)
        #expect(ExportRendition.choose(.image, among: []) == nil)
        #expect(ExportRendition.choose(.video, among: [.photo, .adjustmentData]) == nil)
    }

    @Test func theEditIdentityIsTheRecipesDigestAndEmptyHasNone() {
        let recipe = Data("crop 0.1 0.2; exposure +0.3".utf8)
        let identity = ExportRendition.editIdentity(of: recipe)
        #expect(identity?.count == 64)
        #expect(identity == ExportRendition.editIdentity(of: recipe))
        #expect(identity != ExportRendition.editIdentity(of: Data("crop 0.1 0.2".utf8)))
        #expect(ExportRendition.editIdentity(of: Data()) == nil)
    }

    @Test func eachAssetIsStagedInAFolderOfItsOwn() {
        let staging = URL(fileURLWithPath: "/tmp/Staging", isDirectory: true)
        let first = ExportRendition.folder(for: 0, in: staging)
        let second = ExportRendition.folder(for: 1, in: staging)
        #expect(first != second)
        #expect(first.deletingLastPathComponent().standardizedFileURL == staging.standardizedFileURL)
        // Two IMG_0001.JPG from different cameras must not meet.
        #expect(first.appendingPathComponent("IMG_0001.JPG") != second.appendingPathComponent("IMG_0001.JPG"))
    }
}
