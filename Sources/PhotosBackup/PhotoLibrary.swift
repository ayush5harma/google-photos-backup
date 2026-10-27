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

    /// How every album and All Photos are listed: the user's own library,
    /// newest first, hidden photos left out (PhotoKit's default, which the
    /// exporter relies on to upload a hidden photo only when it is picked).
    static var listing: PHFetchOptions {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        // Only the user's own library: shared-album items are someone
        // else's, and PhotoKit cannot hand out their originals anyway.
        options.includeAssetSourceTypes = [.typeUserLibrary]
        return options
    }

    private static func readAlbums() -> [LibraryAlbum] {
        let options = listing

        // The modification date comes with the asset row PhotoKit already
        // fetched, so edit detection costs no extra query; asset resources
        // are read later, and only for assets whose date moved.
        func snapshot(id: String, title: String, kind: AlbumKind, _ result: PHFetchResult<PHAsset>) -> AlbumSnapshot {
            var ids: [String] = []
            var modified: [String: Date] = [:]
            ids.reserveCapacity(result.count)
            modified.reserveCapacity(result.count)
            result.enumerateObjects { asset, _, _ in
                let id = asset.localIdentifier
                ids.append(id)
                if let date = asset.modificationDate { modified[id] = date }
            }
            return AlbumSnapshot(id: id, title: title, kind: kind, assetIDs: ids, modified: modified)
        }

        var albums = [LibraryAlbum(
            snapshot: snapshot(id: allPhotosID, title: "All Photos", kind: .allPhotos, PHAsset.fetchAssets(with: options)),
            symbol: "photo.on.rectangle.angled")]

        var smart: [PHAssetCollectionSubtype: PHAssetCollection] = [:]
        PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .any, options: nil)
            .enumerateObjects { collection, _, _ in smart[collection.assetCollectionSubtype] = collection }
        for (subtype, symbol) in smartAlbums {
            guard let collection = smart[subtype] else { continue }
            let album = snapshot(id: collection.localIdentifier, title: collection.localizedTitle ?? "Smart Album", kind: .smart,
                                 PHAsset.fetchAssets(in: collection, options: options))
            guard !album.assetIDs.isEmpty else { continue }
            albums.append(LibraryAlbum(snapshot: album, symbol: symbol))
        }

        var user: [LibraryAlbum] = []
        PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
            .enumerateObjects { collection, _, _ in
                let album = snapshot(id: collection.localIdentifier, title: collection.localizedTitle ?? "Untitled", kind: .user,
                                     PHAsset.fetchAssets(in: collection, options: options))
                guard !album.assetIDs.isEmpty else { return }
                user.append(LibraryAlbum(snapshot: album, symbol: "rectangle.stack"))
            }
        user.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return albums + user
    }
}
