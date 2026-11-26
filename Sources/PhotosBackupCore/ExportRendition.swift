import CryptoKit
import Foundation

/// What an exporter takes out of Photos for one asset, decided without
/// PhotoKit so it can be tested: the iOS exporter maps PHAssetResource types
/// onto `Resource` and asks here. The rules are the Mac AssetExporter's.
public enum ExportRendition {
    /// PHAssetMediaType, as far as the choice cares.
    public enum Media: Sendable {
        case image, video, other
    }

    /// PHAssetResourceType, as far as the choice cares.
    public enum Resource: Equatable, Sendable {
        case photo, fullSizePhoto, alternatePhoto
        case video, fullSizeVideo
        /// A Live Photo's motion: never uploaded on its own.
        case pairedVideo
        /// The recipe of an edit (a small plist).
        case adjustmentData
        case other
    }

    /// The version Photos shows: the edited render when there is one, else
    /// the original. A Live Photo uploads as its still. nil when the asset
    /// has nothing to upload.
    public static func choose(_ media: Media, among resources: [Resource]) -> Int? {
        func first(_ kinds: Resource...) -> Int? {
            for kind in kinds { if let index = resources.firstIndex(of: kind) { return index } }
            return nil
        }
        switch media {
        case .image: return first(.fullSizePhoto, .photo, .alternatePhoto)
        case .video: return first(.fullSizeVideo, .video)
        case .other: return resources.isEmpty ? nil : 0
        }
    }

    /// Photos keeps an edit's render as a full-size resource beside the original.
    public static func isEdited(_ resource: Resource) -> Bool {
        resource == .fullSizePhoto || resource == .fullSizeVideo
    }

    /// The original, whose file name the upload keeps (ExportNaming).
    public static func original(among resources: [Resource]) -> Int? {
        resources.firstIndex { $0 == .photo || $0 == .video }
    }

    /// A SHA-256 of the adjustment data: it changes when the edit changes,
    /// not when Photos re-renders the asset or it is favourited. nil for no
    /// data, and the caller then uploads the edit again to be safe.
    public static func editIdentity(of adjustmentData: Data) -> String? {
        guard !adjustmentData.isEmpty else { return nil }
        return SHA256.hash(data: adjustmentData).map { String(format: "%02x", $0) }.joined()
    }

    /// One folder per asset in a batch: two IMG_0001.JPG from different
    /// cameras must not overwrite each other.
    public static func folder(for position: Int, in staging: URL) -> URL {
        staging.appendingPathComponent(String(position), isDirectory: true)
    }
}
