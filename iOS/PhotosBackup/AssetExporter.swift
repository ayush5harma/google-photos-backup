import Foundation
import Photos
import PhotosBackupCore

struct ExportedAsset: Equatable {
    let assetID: String
    let url: URL
    let filename: String
    let size: Int64
    /// Which version of the asset this file is; nil when Photos gave no
    /// modification date.
    let stamp: EditStamp?
    /// PHAsset.creationDate: the timestamp Google Photos is given.
    let created: Date?
}

struct ExportError: LocalizedError, Equatable {
    let errorDescription: String?
}

/// Where exported copies wait for their upload: under Caches, readable
/// after the first unlock (a background run starts with the phone locked)
/// and never in an iCloud or Finder backup of the phone.
enum StagingArea {
    static let root = AppEnvironment.cachesDirectory.appendingPathComponent("Staging", isDirectory: true)

    /// Creates `directory` with those protections; anything left from an
    /// earlier run stays until `clear`.
    static func prepare(_ directory: URL = root) throws {
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true,
                                  attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        try files.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = directory
        try url.setResourceValues(values)
    }

    /// A crash mid-batch leaves exported copies behind.
    static func clear(_ directory: URL = root) {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Writes the bytes Photos holds for each asset into the staging area for
/// the uploader. A port of the Mac AssetExporter: which resource is taken,
/// how it is named and what marks an edit come from Core's ExportRendition
/// and ExportNaming; only the PhotoKit calls live here. Originals kept in
/// iCloud ("Optimize iPhone Storage") are downloaded. Used by NativeBackupEngine.
@MainActor
struct AssetExporter {
    /// Burst frames filed in an album one by one are dropped by default
    /// lookups (Mac, 2026-10-27: 195 frames failed every run as "No longer
    /// in the Photos library"); hidden photos are looked up for picks alone.
    static func lookup(includingHidden: Bool) -> PHFetchOptions {
        let options = PHFetchOptions()
        options.includeAllBurstAssets = true
        options.includeHiddenAssets = includingHidden
        return options
    }

    /// - Parameters:
    ///   - shouldStop: checked before each asset; an export in progress (an
    ///     iCloud download) cannot be interrupted.
    ///   - started: each asset's upload filename, before its export.
    ///   - finished: each asset's result as soon as it has one.
    func export(_ assetIDs: [String], includingHidden: Bool = false, into directory: URL = StagingArea.root,
                shouldStop: () -> Bool,
                started: (String, String) -> Void,
                finished: (String, Result<ExportedAsset, Error>) -> Void) async {
        do {
            try StagingArea.prepare(directory)
        } catch {
            for id in assetIDs { finished(id, .failure(ExportError(errorDescription: "Could not prepare the upload folder: \(error.localizedDescription)"))) }
            return
        }
        var assets: [String: PHAsset] = [:]
        PHAsset.fetchAssets(withLocalIdentifiers: assetIDs, options: Self.lookup(includingHidden: includingHidden))
            .enumerateObjects { asset, _, _ in assets[asset.localIdentifier] = asset }

        for (position, id) in assetIDs.enumerated() {
            if shouldStop() { return }
            guard let asset = assets[id] else {
                finished(id, .failure(ExportError(errorDescription: "No longer in the Photos library")))
                continue
            }
            let resources = PHAssetResource.assetResources(for: asset)
            let kinds = resources.map(Self.kind)
            guard let chosen = ExportRendition.choose(Self.media(asset.mediaType), among: kinds) else {
                finished(id, .failure(ExportError(errorDescription: "Photos has no file for this item")))
                continue
            }
            let resource = resources[chosen]
            let original = ExportRendition.original(among: kinds).map { resources[$0].originalFilename }
            let filename = ExportNaming.uploadFilename(original: original, rendition: resource.originalFilename)
            // Read before the export: an edit made while it runs then shows
            // up as newer than the stamp, and is picked up next time.
            let edited = ExportRendition.isEdited(kinds[chosen])
            let modified = asset.modificationDate
            started(id, filename)
            let identity = edited ? await Self.editIdentity(in: resources) : nil
            let stamp = modified.map { EditStamp(modified: $0, edited: edited, editIdentity: identity) }
            do {
                let folder = ExportRendition.folder(for: position, in: directory)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = folder.appendingPathComponent(filename)
                try await Self.write(resource, to: url)
                // The uploader sends the file's date as the item's timestamp,
                // which Google Photos falls back on when the file has no EXIF
                // date (screenshots, many videos).
                if let date = asset.creationDate {
                    try? FileManager.default.setAttributes([.modificationDate: date, .creationDate: date], ofItemAtPath: url.path)
                }
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
                finished(id, .success(ExportedAsset(assetID: id, url: url, filename: filename, size: size, stamp: stamp,
                                                    created: asset.creationDate)))
            } catch {
                finished(id, .failure(ExportError(errorDescription: "Export failed: \(error.localizedDescription)")))
            }
        }
    }

    struct EditState {
        let edited: Bool
        let modified: Date?
        /// The edit's identity; nil when unedited or unreadable.
        let identity: String?
    }

    /// Whether each asset's current rendition is an edited one, which edit,
    /// and its date now. Reads resources for these assets only (the ones
    /// whose date moved), never for the library. The Mac's editStates.
    static func editStates(of assetIDs: [String]) async -> [String: EditState] {
        var assets: [PHAsset] = []
        PHAsset.fetchAssets(withLocalIdentifiers: assetIDs, options: lookup(includingHidden: false))
            .enumerateObjects { asset, _, _ in assets.append(asset) }
        var states: [String: EditState] = [:]
        for asset in assets {
            let resources = PHAssetResource.assetResources(for: asset)
            let kinds = resources.map(kind)
            let edited = ExportRendition.choose(media(asset.mediaType), among: kinds).map { ExportRendition.isEdited(kinds[$0]) } ?? false
            let identity = edited ? await editIdentity(in: resources) : nil
            states[asset.localIdentifier] = EditState(edited: edited, modified: asset.modificationDate, identity: identity)
        }
        return states
    }

    static func media(_ type: PHAssetMediaType) -> ExportRendition.Media {
        switch type {
        case .image: .image
        case .video: .video
        default: .other
        }
    }

    static func kind(_ resource: PHAssetResource) -> ExportRendition.Resource {
        switch resource.type {
        case .photo: .photo
        case .fullSizePhoto: .fullSizePhoto
        case .alternatePhoto: .alternatePhoto
        case .video: .video
        case .fullSizeVideo: .fullSizeVideo
        case .pairedVideo, .fullSizePairedVideo: .pairedVideo
        case .adjustmentData: .adjustmentData
        default: .other
        }
    }

    /// The edit's identity from its adjustment data; nil when there is none
    /// or it cannot be read, and the caller falls back to uploading.
    static func editIdentity(in resources: [PHAssetResource]) async -> String? {
        guard let adjustments = resources.first(where: { $0.type == .adjustmentData }) else { return nil }
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        let data: Data? = await withCheckedContinuation { continuation in
            var collected = Data()
            PHAssetResourceManager.default().requestData(for: adjustments, options: options, dataReceivedHandler: { chunk in
                collected.append(chunk)
            }, completionHandler: { error in
                continuation.resume(returning: error == nil ? collected : nil)
            })
        }
        return data.flatMap(ExportRendition.editIdentity(of:))
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
