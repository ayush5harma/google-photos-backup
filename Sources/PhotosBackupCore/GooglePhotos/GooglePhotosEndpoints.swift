import Foundation

/// Where the client sends each kind of call. The paths are gpmc 0.9.0's
/// (gpmc/api.py); `local` keeps them on another host so an end-to-end run can
/// point the app at Tests/E2E/fake_google_photos.py.
public struct GooglePhotosEndpoints: Sendable, Equatable {
    /// The Android token endpoint that turns the master token into a bearer.
    public var auth: URL
    /// photosdata-pa's RPC root; each call appends its method id.
    public var data: URL
    /// The upload start (POST) and the bytes (PUT ?upload_id=).
    public var upload: URL

    public init(auth: URL, data: URL, upload: URL) {
        self.auth = auth
        self.data = data
        self.upload = upload
    }

    public static let google = GooglePhotosEndpoints(
        auth: URL(string: "https://android.googleapis.com/auth")!,
        data: URL(string: "https://photosdata-pa.googleapis.com/6439526531001121323")!,
        upload: URL(string: "https://photos.googleapis.com/data/upload/uploadmedia/interactive")!
    )

    /// Every endpoint on one local base with the same paths, for the E2E fake server.
    public static func local(_ base: URL) -> GooglePhotosEndpoints {
        GooglePhotosEndpoints(
            auth: base.appendingPathComponent("auth"),
            data: base.appendingPathComponent("6439526531001121323"),
            upload: base.appendingPathComponent("data/upload/uploadmedia/interactive")
        )
    }

    func method(_ id: GooglePhotosMethod) -> URL {
        data.appendingPathComponent(id.rawValue)
    }

    /// gpmc's get_download_urls answers at the data host's root, not under
    /// the method root the other calls share.
    var prepareDownload: URL {
        data.deletingLastPathComponent()
            .appendingPathComponent("$rpc/social.frontend.photos.preparedownloaddata.v1.PhotosPrepareDownloadDataService/PhotosPrepareDownload")
    }
}

/// photosdata-pa method ids, as gpmc 0.9.0 calls them.
enum GooglePhotosMethod: String, Sendable, CaseIterable {
    case findRemoteMediaByHash = "5084965799730810217"
    case commitUpload = "16538846908252377752"
    case createAlbum = "8386163679468898444"
    case addMediaToAlbum = "484917746253879292"
}
