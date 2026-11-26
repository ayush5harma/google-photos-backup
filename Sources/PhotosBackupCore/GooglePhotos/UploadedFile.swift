import Foundation

/// A file whose bytes Google has, waiting for its commit. Plain data so the
/// app can persist it between the PUT and the commit (a background transfer
/// may finish in another process launch).
public struct UploadedFile: Sendable, Equatable, Codable {
    /// The PUT's response body as Google sent it: gpmc decodes it and
    /// re-encodes it as commit field 1.1, which for Google's canonical
    /// encoding is these same bytes. Its field 2 is the upload token.
    public let receipt: Data
    /// SHA-1 of the file's bytes, 20 bytes.
    public let sha1: Data
    public let fileName: String
    /// Commit field 4.1, whole seconds since 1970. gpmc sends the file's
    /// mtime; the Mac app stamps exports with PHAsset.creationDate, so this
    /// is the capture date Google falls back on without EXIF.
    public let timestamp: Date
    public let size: Int64

    public init(receipt: Data, sha1: Data, fileName: String, timestamp: Date, size: Int64) {
        self.receipt = receipt
        self.sha1 = sha1
        self.fileName = fileName
        self.timestamp = timestamp
        self.size = size
    }
}
