import CryptoKit
import Foundation

/// The SHA-1 Google Photos dedupes by (gpmc's calculate_sha1_hash).
public enum ContentHash {
    static let chunkSize = 1 << 20

    /// Streamed in 1 MiB reads, each in its own autorelease pool where there
    /// is one: the loop never suspends, so on iOS an autoreleased buffer per
    /// read would otherwise live until a multi-gigabyte video was hashed
    /// (g8row/PhotosBackup, MIT, measured the memory limit there).
    public static func sha1(of file: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = Insecure.SHA1()
        var reachedEnd = false
        while !reachedEnd {
            try drainingPool {
                guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else {
                    reachedEnd = true
                    return
                }
                hasher.update(data: chunk)
            }
        }
        return Data(hasher.finalize())
    }

    private static func drainingPool(_ body: () throws -> Void) rethrows {
        #if canImport(ObjectiveC)
        try autoreleasepool(invoking: body)
        #else
        try body()
        #endif
    }
}
