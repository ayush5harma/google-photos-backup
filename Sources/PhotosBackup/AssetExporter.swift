import Foundation
import Photos
import PhotosBackupCore

struct ExportedAsset {
    let assetID: String
    let url: URL
    let filename: String
    let size: Int64
    /// Which version of the asset this file is; nil when Photos gave no
    /// modification date.
    let stamp: EditStamp?
}

struct ExportError: LocalizedError {
    let errorDescription: String?
}

/// Writes the bytes Photos holds for each asset into a staging folder for
/// gpmc. Originals still in iCloud ("Optimize Mac Storage") are downloaded.
@MainActor
struct AssetExporter {
    /// - Parameters:
    ///   - shouldStop: checked before each asset; an export in progress (an
    ///     iCloud download) cannot be interrupted.
    ///   - started: called with each asset's upload filename before its export.
    ///   - finished: called with each asset's result as soon as it has one.
    func export(_ assetIDs: [String], into directory: URL,
                shouldStop: () -> Bool,
                started: (String, String) -> Void,
                finished: (String, Result<ExportedAsset, Error>) -> Void) async {
        var assets: [String: PHAsset] = [:]
        PHAsset.fetchAssets(withLocalIdentifiers: assetIDs, options: nil)
            .enumerateObjects { asset, _, _ in assets[asset.localIdentifier] = asset }

        for (index, id) in assetIDs.enumerated() {
            if shouldStop() { return }
            guard let asset = assets[id] else {
                finished(id, .failure(ExportError(errorDescription: "No longer in the Photos library")))
                continue
            }
            let resources = PHAssetResource.assetResources(for: asset)
            guard let resource = Self.rendition(of: asset, in: resources) else {
                finished(id, .failure(ExportError(errorDescription: "Photos has no file for this item")))
                continue
            }
            let original = resources.first { $0.type == .photo || $0.type == .video }?.originalFilename
            let filename = ExportNaming.uploadFilename(original: original, rendition: resource.originalFilename)
            // Read before the export: an edit made while it runs then shows
            // up as newer than the stamp, and is picked up next time.
            let stamp = asset.modificationDate.map { EditStamp(modified: $0, edited: Self.isEdited(resource)) }
            started(id, filename)
            do {
                // One folder per asset: two IMG_0001.JPG from different
                // cameras must not overwrite each other.
                let folder = directory.appendingPathComponent(String(index), isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = folder.appendingPathComponent(filename)
                try await Self.write(resource, to: url)
                // gpmc sends the file's mtime as the item's timestamp, which
                // Google Photos falls back on when the file has no EXIF date
                // (screenshots, many videos).
                if let date = asset.creationDate {
                    try? FileManager.default.setAttributes([.modificationDate: date, .creationDate: date], ofItemAtPath: url.path)
                }
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
                finished(id, .success(ExportedAsset(assetID: id, url: url, filename: filename, size: size, stamp: stamp)))
            } catch {
                finished(id, .failure(ExportError(errorDescription: "Export failed: \(error.localizedDescription)")))
            }
        }
    }

    /// Whether each asset's current rendition is an edited one, and its
    /// date now. Reads resources for these assets only (the ones whose date
    /// moved), never for the library.
    static func editStates(of assetIDs: [String]) -> [String: (edited: Bool, modified: Date?)] {
        var states: [String: (edited: Bool, modified: Date?)] = [:]
        PHAsset.fetchAssets(withLocalIdentifiers: assetIDs, options: nil).enumerateObjects { asset, _, _ in
            let resources = PHAssetResource.assetResources(for: asset)
            let edited = rendition(of: asset, in: resources).map(isEdited) ?? false
            states[asset.localIdentifier] = (edited, asset.modificationDate)
        }
        return states
    }

    /// The version Photos shows: the edited rendition when there is one,
    /// else the original. A Live Photo uploads as its still.
    static func rendition(of asset: PHAsset, in resources: [PHAssetResource]) -> PHAssetResource? {
        func first(_ types: PHAssetResourceType...) -> PHAssetResource? {
            for type in types { if let match = resources.first(where: { $0.type == type }) { return match } }
            return nil
        }
        switch asset.mediaType {
        case .image: return first(.fullSizePhoto, .photo, .alternatePhoto)
        case .video: return first(.fullSizeVideo, .video)
        default: return resources.first
        }
    }

    /// Photos keeps an edit's render as a full-size resource beside the original.
    private static func isEdited(_ resource: PHAssetResource) -> Bool {
        resource.type == .fullSizePhoto || resource.type == .fullSizeVideo
    }

    private static func write(_ resource: PHAssetResource, to url: URL) async throws {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
}
