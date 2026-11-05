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

    /// What one read of the library finds.
    struct Listing {
        /// Every offered album with its asset identifiers, newest first.
        var albums: [LibraryAlbum]
        /// User albums with nothing to list, kept out of the window but
        /// still read by the re-baseline (BackupState.rebaselineUnknownMirrors):
        /// an album empty when its record was lost gets an empty record, so
        /// photos added later go in instead of all being taken as known.
        var unlisted: [AlbumSnapshot]
    }

    /// Runs off the main thread: a large library takes a noticeable moment.
    static func loadAlbums() async -> Listing {
        await Task.detached(priority: .utility) { readAlbums() }.value
    }

    /// How every album and All Photos are listed: the user's own library,
    /// newest first, hidden photos left out (the exporter relies on it to
    /// upload a hidden photo only when it is picked). Said here rather than
    /// left to PhotoKit's default, and the planner checks each asset's
    /// isHidden as well (AlbumSnapshot.hiddenAssetIDs): a hidden photo
    /// never joins a Google album, nor goes to an account but the primary.
    static var listing: PHFetchOptions {
        let options = PHFetchOptions()
        options.includeHiddenAssets = false
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        // Only the user's own library: shared-album items are someone
        // else's, and PhotoKit cannot hand out their originals anyway.
        options.includeAssetSourceTypes = [.typeUserLibrary]
        return options
    }

    private static func readAlbums() -> Listing {
        let options = listing

        // The modification date comes with the asset row PhotoKit already
        // fetched, so edit detection costs no extra query; asset resources
        // are read later, and only for assets whose date moved.
        func snapshot(id: String, title: String, kind: AlbumKind, _ result: PHFetchResult<PHAsset>) -> AlbumSnapshot {
            var ids: [String] = []
            var modified: [String: Date] = [:]
            var hidden = Set<String>()
            ids.reserveCapacity(result.count)
            modified.reserveCapacity(result.count)
            result.enumerateObjects { asset, _, _ in
                let id = asset.localIdentifier
                ids.append(id)
                if let date = asset.modificationDate { modified[id] = date }
                if asset.isHidden { hidden.insert(id) }
            }
            return AlbumSnapshot(id: id, title: title, kind: kind, assetIDs: ids, modified: modified, hiddenAssetIDs: hidden)
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

        // A user album's hidden members, looked up on their own (read-only,
        // ids only) so the re-baseline can record them; never uploaded. With
        // the Hidden album locked PhotoKit hands out none (measured
        // 2026-10-28, PickedFile), so this then finds nothing.
        let hiddenOnly = PHFetchOptions()
        hiddenOnly.includeHiddenAssets = true
        hiddenOnly.includeAssetSourceTypes = [.typeUserLibrary]
        hiddenOnly.predicate = NSPredicate(format: "isHidden == YES")
        func withHidden(_ album: AlbumSnapshot, in collection: PHAssetCollection) -> AlbumSnapshot {
            var hidden = album.hiddenAssetIDs
            PHAsset.fetchAssets(in: collection, options: hiddenOnly).enumerateObjects { asset, _, _ in hidden.insert(asset.localIdentifier) }
            guard hidden != album.hiddenAssetIDs else { return album }
            return AlbumSnapshot(id: album.id, title: album.title, kind: album.kind, assetIDs: album.assetIDs, modified: album.modified,
                                 hiddenAssetIDs: hidden)
        }

        var user: [LibraryAlbum] = []
        var unlisted: [AlbumSnapshot] = []
        PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
            .enumerateObjects { collection, _, _ in
                let album = withHidden(snapshot(id: collection.localIdentifier, title: collection.localizedTitle ?? "Untitled", kind: .user,
                                                PHAsset.fetchAssets(in: collection, options: options)), in: collection)
                guard !album.assetIDs.isEmpty else { return unlisted.append(album) }
                user.append(LibraryAlbum(snapshot: album, symbol: "rectangle.stack"))
            }
        user.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return Listing(albums: albums + user, unlisted: unlisted)
    }
}
