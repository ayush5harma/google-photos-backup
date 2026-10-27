import CryptoKit
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
    /// A lookup by identifier with default options leaves out some of what
    /// was asked for. Albums hand out the burst frames someone filed in them
    /// one by one, but default options drop every frame but a burst's pick
    /// (2026-10-27: 195 such frames failed every run as "No longer in the
    /// Photos library"). Choose Photos hands out photos from the Hidden album
    /// once it is unlocked, and default options drop hidden ones (2026-10-28:
    /// all 62 picks from it failed the same way). Hidden photos are looked up
    /// for picks alone: an album's batch was listed at the start of a pass,
    /// and a photo hidden since then must still stay behind.
    static func lookup(includingHidden: Bool) -> PHFetchOptions {
        let options = PHFetchOptions()
        options.includeAllBurstAssets = true
        options.includeHiddenAssets = includingHidden
        return options
    }

    /// - Parameters:
    ///   - shouldStop: checked before each asset; an export in progress (an
    ///     iCloud download) cannot be interrupted.
    ///   - started: called with each asset's upload filename before its export.
    ///   - finished: called with each asset's result as soon as it has one.
    ///   - includingHidden: the owner picked these assets themselves.
    func export(_ assetIDs: [String], includingHidden: Bool = false, into directory: URL,
                shouldStop: () -> Bool,
                started: (String, String) -> Void,
                finished: (String, Result<ExportedAsset, Error>) -> Void) async {
        var assets: [String: PHAsset] = [:]
        PHAsset.fetchAssets(withLocalIdentifiers: assetIDs, options: Self.lookup(includingHidden: includingHidden))
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
            let edited = Self.isEdited(resource)
            let modified = asset.modificationDate
            started(id, filename)
            let identity = edited ? await Self.editIdentity(in: resources) : nil
            let stamp = modified.map { EditStamp(modified: $0, edited: edited, editIdentity: identity) }
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

    struct EditState {
        let edited: Bool
        let modified: Date?
        /// The edit's identity (see editIdentity); nil when unedited or unreadable.
        let identity: String?
    }

    /// Whether each asset's current rendition is an edited one, which edit,
    /// and its date now. Reads resources for these assets only (the ones
    /// whose date moved), never for the library.
    static func editStates(of assetIDs: [String]) async -> [String: EditState] {
        var assets: [PHAsset] = []
        PHAsset.fetchAssets(withLocalIdentifiers: assetIDs, options: lookup(includingHidden: false)).enumerateObjects { asset, _, _ in assets.append(asset) }
        var states: [String: EditState] = [:]
        for asset in assets {
            let resources = PHAssetResource.assetResources(for: asset)
            let edited = rendition(of: asset, in: resources).map(isEdited) ?? false
            let identity = edited ? await editIdentity(in: resources) : nil
            states[asset.localIdentifier] = EditState(edited: edited, modified: asset.modificationDate, identity: identity)
        }
        return states
    }

    /// A SHA-256 of the asset's adjustment data: the recipe of the edit, a
    /// small plist that changes when the edit changes and not when Photos
    /// re-renders it or the asset is favourited. nil when there is none or
    /// it cannot be read, and the caller falls back to uploading.
    static func editIdentity(in resources: [PHAssetResource]) async -> String? {
        guard let adjustments = resources.first(where: { $0.type == .adjustmentData }) else { return nil }
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            var hasher = SHA256()
            var empty = true
            PHAssetResourceManager.default().requestData(for: adjustments, options: options, dataReceivedHandler: { chunk in
                hasher.update(data: chunk)
                empty = empty && chunk.isEmpty
            }, completionHandler: { error in
                guard error == nil, !empty else { return continuation.resume(returning: nil) }
                continuation.resume(returning: hasher.finalize().map { String(format: "%02x", $0) }.joined())
            })
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
