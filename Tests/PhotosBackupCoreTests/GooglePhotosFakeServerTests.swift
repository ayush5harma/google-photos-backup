import Foundation
import Testing
@testable import PhotosBackupCore

/// The client against Tests/E2E/fake_google_photos.py over real HTTP, the
/// way the iOS app's E2E run uses it. Opt-in, so `swift test` needs no
/// Python: start a fresh server and point the test at it.
///
///     python3 -I Tests/E2E/fake_google_photos.py --port 8765 &
///     GPB_FAKE_GOOGLE_PHOTOS=http://127.0.0.1:8765 swift test --filter GooglePhotosFakeServerTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["GPB_FAKE_GOOGLE_PHOTOS"] != nil),
       .serialized)
struct GooglePhotosFakeServerTests {
    static var base: URL { URL(string: ProcessInfo.processInfo.environment["GPB_FAKE_GOOGLE_PHOTOS"]!)! }

    static func client() throws -> GooglePhotosClient {
        GooglePhotosClient(credential: try GooglePhotosCredential(authData: GooglePhotosGolden.authData), endpoints: .local(base))
    }

    @Test func backsUpCommitsInABatchFillsAnAlbumAndDedupes() async throws {
        let client = try Self.client()
        try await client.checkAuth()

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("gpb-fake-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var uploaded: [UploadedFile] = []
        for index in 0..<3 {
            let file = folder.appendingPathComponent("IMG_\(index).jpg")
            try Data("photo \(index) \(UUID())".utf8).write(to: file)
            let sha1 = try ContentHash.sha1(of: file)
            #expect(try await client.findRemoteMedia(sha1: sha1) == nil)
            uploaded.append(try await client.upload(file: file, fileName: file.lastPathComponent, sha1: sha1, timestamp: Date()))
        }
        let keys = try await client.commit(uploaded, quality: .original)
        let committed = keys.compactMap { $0 }
        #expect(committed.count == 3)

        let album = try await client.createAlbum(name: "E2E album", mediaKeys: Array(committed.prefix(2)))
        try await client.addToAlbum(album, mediaKeys: [committed[2]])
        for (file, key) in zip(uploaded, committed) {
            #expect(try await client.findRemoteMedia(sha1: file.sha1) == key)
        }
    }
}
