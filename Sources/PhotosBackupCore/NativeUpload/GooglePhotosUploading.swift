import Foundation

/// The Google Photos calls an upload lane and the album step make: the
/// native client's, behind a protocol so the decisions around them are
/// tested against a fake (Tests/PhotosBackupCoreTests/NativeUpload*).
public protocol GooglePhotosUploading: Sendable {
    func findRemoteMedia(sha1: Data) async throws(GooglePhotosError) -> String?
    func upload(file: URL, fileName: String, sha1: Data, timestamp: Date,
                progress: (@Sendable (Int64) -> Void)?) async throws(GooglePhotosError) -> UploadedFile
    func commit(_ files: [UploadedFile], quality: UploadQuality) async throws(GooglePhotosError) -> [String?]
    func commitOne(_ file: UploadedFile, quality: UploadQuality) async throws(GooglePhotosError) -> String
    func createAlbum(name: String, mediaKeys: [String]) async throws(GooglePhotosError) -> String
    func addToAlbum(_ albumKey: String, mediaKeys: [String]) async throws(GooglePhotosError)
    /// Read-only: whether Google hands out the item's original (gpmc's
    /// get_download_urls), for the album step's read-back.
    func hasOriginalDownload(mediaKey: String) async throws(GooglePhotosError) -> Bool
}

extension GooglePhotosClient: GooglePhotosUploading {}
