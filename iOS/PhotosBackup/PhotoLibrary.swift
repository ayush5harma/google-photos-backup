import Foundation
import Photos
import PhotosBackupCore
import PhotosUI
import UIKit

struct LibraryAlbum: Identifiable, Equatable {
    let snapshot: AlbumSnapshot
    let symbol: String

    var id: String { snapshot.id }
    var title: String { snapshot.title }
}

/// Reads albums out of the Photos library and reports changes to it. A port
/// of the Mac app's PhotoLibrary: the same albums, ids, order and fetch
/// options, so the same AlbumSnapshot reaches Core's planner on both.
final class PhotoLibrary: NSObject, PHPhotoLibraryChangeObserver {
    /// The Mac's id for the whole library, so accounts.json's selection
    /// means the same thing on both.
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

    /// Limited access counts: the albums then hold only what the person
    /// chose to share, and the Overview says so.
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

    /// With limited access: the system sheet for sharing more photos.
    @MainActor
    static func presentLimitedPicker() {
        guard let root = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController else { return }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: top)
    }

    /// What one read of the library finds.
    struct Listing {
        /// Every offered album with its asset identifiers, newest first.
        var albums: [LibraryAlbum]
        /// User albums with nothing to list, kept out of view but read by the
        /// re-baseline (BackupState.rebaselineUnknownMirrors) in phase 2.
        var unlisted: [AlbumSnapshot]
    }

    /// Runs off the main thread: a large library takes a noticeable moment.
    static func loadAlbums() async -> Listing {
        await Task.detached(priority: .utility) { readAlbums() }.value
    }

    /// The user's own library, newest first, hidden photos left out, as on
    /// the Mac: shared-album items are someone else's, and a hidden photo
    /// never joins a Google album.
    static var listing: PHFetchOptions {
        let options = PHFetchOptions()
        options.includeHiddenAssets = false
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.includeAssetSourceTypes = [.typeUserLibrary]
        return options
    }

    private static func readAlbums() -> Listing {
        let options = listing

        // The modification date comes with the asset row PhotoKit already
        // fetched, so edit detection costs no extra query.
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

        // A user album's hidden members, ids only, so a re-baseline can
        // record them; never uploaded.
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
