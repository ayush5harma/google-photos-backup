import Foundation
import Photos
import PhotosBackupCore

struct LibraryAlbum: Identifiable, Equatable {
    let snapshot: AlbumSnapshot
    let symbol: String

    var id: String { snapshot.id }
    var title: String { snapshot.title }
}

/// Reads albums out of the system Photos library and reports changes to it.
final class PhotoLibrary: NSObject, PHPhotoLibraryChangeObserver {
    static let allPhotosID = "all-photos"

    /// Smart albums worth offering, in display order. Hidden, Recently
    /// Deleted and the library itself ("All Photos" covers it) stay out.
    private static let smartAlbums: [(PHAssetCollectionSubtype, String)] = [
        (.smartAlbumFavorites, "heart"),
        (.smartAlbumRecentlyAdded, "clock"),
        (.smartAlbumVideos, "video"),
        (.smartAlbumSelfPortraits, "person.crop.square"),
        (.smartAlbumLivePhotos, "livephoto"),
        (.smartAlbumDepthEffect, "cube"),
        (.smartAlbumPanoramas, "pano"),
        (.smartAlbumScreenshots, "camera.viewfinder"),
        (.smartAlbumBursts, "square.stack.3d.down.right"),
        (.smartAlbumSlomoVideos, "slowmo"),
        (.smartAlbumTimelapses, "timelapse"),
        (.smartAlbumCinematic, "film"),
        (.smartAlbumRAW, "r.square"),
    ]

    var onChange: (() -> Void)?
    private var observing = false

    var status: PHAuthorizationStatus { PHPhotoLibrary.authorizationStatus(for: .readWrite) }

    var isAuthorized: Bool { status == .authorized || status == .limited }

    func requestAccess() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    func startObserving() {
        guard !observing, isAuthorized else { return }
        PHPhotoLibrary.shared().register(self)
        observing = true
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        DispatchQueue.main.async { self.onChange?() }
    }

    /// Every offered album with its asset identifiers, newest first. Runs off
    /// the main thread: a large library takes a noticeable moment.
    static func loadAlbums() async -> [LibraryAlbum] {
        await Task.detached(priority: .utility) { readAlbums() }.value
    }

    private static func readAlbums() -> [LibraryAlbum] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        // Only the user's own library: shared-album items are someone
        // else's, and PhotoKit cannot hand out their originals anyway.
        options.includeAssetSourceTypes = [.typeUserLibrary]

        func ids(_ result: PHFetchResult<PHAsset>) -> [String] {
            var ids: [String] = []
            ids.reserveCapacity(result.count)
            result.enumerateObjects { asset, _, _ in ids.append(asset.localIdentifier) }
            return ids
        }

        var albums = [LibraryAlbum(
            snapshot: AlbumSnapshot(id: allPhotosID, title: "All Photos", kind: .allPhotos, assetIDs: ids(PHAsset.fetchAssets(with: options))),
            symbol: "photo.on.rectangle.angled")]

        var smart: [PHAssetCollectionSubtype: PHAssetCollection] = [:]
        PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .any, options: nil)
            .enumerateObjects { collection, _, _ in smart[collection.assetCollectionSubtype] = collection }
        for (subtype, symbol) in smartAlbums {
            guard let collection = smart[subtype] else { continue }
            let assets = ids(PHAsset.fetchAssets(in: collection, options: options))
            guard !assets.isEmpty else { continue }
            albums.append(LibraryAlbum(snapshot: AlbumSnapshot(id: collection.localIdentifier, title: collection.localizedTitle ?? "Smart Album",
                                                               kind: .smart, assetIDs: assets),
                                       symbol: symbol))
        }

        var user: [LibraryAlbum] = []
        PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
            .enumerateObjects { collection, _, _ in
                let assets = ids(PHAsset.fetchAssets(in: collection, options: options))
                guard !assets.isEmpty else { return }
                user.append(LibraryAlbum(snapshot: AlbumSnapshot(id: collection.localIdentifier, title: collection.localizedTitle ?? "Untitled",
                                                                 kind: .user, assetIDs: assets),
                                         symbol: "rectangle.stack"))
            }
        user.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return albums + user
    }
}
