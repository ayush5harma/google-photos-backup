import Foundation
import Photos
import PhotosBackupCore

struct ExportedAsset {
    let assetID: String
    let url: URL
    let filename: String
    let size: Int64
}

struct ExportError: LocalizedError {
    let errorDescription: String?
}

/// Writes the bytes Photos holds for each asset into a staging folder for
/// gpmc. Originals still in iCloud ("Optimize Mac Storage") are downloaded.
@MainActor
struct AssetExporter {
    /// - Parameters:
    ///   - started: called with each asset's upload filename before its export.
    ///   - finished: called with each asset's result as soon as it has one.
    func export(_ assetIDs: [String], into directory: URL,
                started: (String, String) -> Void,
                finished: (String, Result<ExportedAsset, Error>) -> Void) async {
        var assets: [String: PHAsset] = [:]
        PHAsset.fetchAssets(withLocalIdentifiers: assetIDs, options: nil)
            .enumerateObjects { asset, _, _ in assets[asset.localIdentifier] = asset }

        for (index, id) in assetIDs.enumerated() {
            if Task.isCancelled { return }
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
                finished(id, .success(ExportedAsset(assetID: id, url: url, filename: filename, size: size)))
            } catch {
                finished(id, .failure(ExportError(errorDescription: "Export failed: \(error.localizedDescription)")))
            }
        }
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
