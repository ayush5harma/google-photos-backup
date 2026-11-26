import Foundation
import Testing
@testable import PhotosBackupCore

/// The Swift client against bodies and headers gpmc 0.9.0 itself produced
/// (GooglePhotosGolden.swift, scripts/tests/make_gpmc_golden.py). Every body
/// is compared byte for byte; none needed a decoded-tree comparison.
@Suite struct GooglePhotosGoldenTests {
    typealias Golden = GooglePhotosGolden
    typealias Body = GooglePhotosRequestBody

    static let fileA = UploadedFile(receipt: Data(hex: Golden.receiptA), sha1: Data(hex: Golden.sha1A), fileName: Golden.fileA.name,
                                    timestamp: Date(timeIntervalSince1970: TimeInterval(Golden.fileA.timestamp) + 0.9), size: Golden.fileA.size)
    static let fileB = UploadedFile(receipt: Data(hex: Golden.receiptB), sha1: Data(hex: Golden.sha1B), fileName: Golden.fileB.name,
                                    timestamp: Date(timeIntervalSince1970: TimeInterval(Golden.fileB.timestamp)), size: Golden.fileB.size)
    static let now = Date(timeIntervalSince1970: Golden.now)

    static func golden(_ name: String) -> Data { Data(hex: Golden.calls[name]!.body) }

    // MARK: - Bodies, built directly

    @Test func authFormIsWhatRequestsEncodes() throws {
        let credential = try GooglePhotosCredential(authData: Golden.authData)
        #expect(credential.authForm == Self.golden("auth"))
    }

    @Test func hashLookupAndUploadStart() {
        #expect(Body.findRemoteMedia(sha1: Data(hex: Golden.sha1A)) == Self.golden("findRemoteMedia"))
        #expect(Body.uploadStart(size: Golden.fileA.size) == Self.golden("uploadStart"))
    }

    @Test(arguments: UploadQuality.allCases)
    func singleCommitPerQuality(quality: UploadQuality) {
        // The timestamp's fraction is dropped, as int(st_mtime) drops it.
        #expect(Body.commit([Self.fileA], quality: quality).hex == Golden.calls["commitOne_\(quality.rawValue)"]!.body)
    }

    @Test(arguments: UploadQuality.allCases)
    func batchedCommitPerQualityIsTheBridges(quality: UploadQuality) {
        #expect(Body.commit([Self.fileA, Self.fileB], quality: quality).hex == Golden.batchBodies["commitBatch_\(quality.rawValue)"]!)
    }

    @Test func albums() {
        #expect(Body.createAlbum(name: Golden.albumName, mediaKeys: Golden.mediaKeys, now: Self.now) == Self.golden("createAlbum"))
        #expect(Body.addMediaToAlbum(albumKey: Golden.albumKey, mediaKeys: Golden.mediaKeys, now: Self.now) == Self.golden("addToAlbum"))
    }

    @Test func readBack() {
        #expect(Body.downloadURLs(mediaKey: Golden.mediaKeys[0]) == Self.golden("downloadURLs"))
    }

    /// Only an answer carrying the original's URL reads as alive; a 404 is
    /// left to the caller, which takes it (and only it) for a dead key.
    @Test func aReadBackIsAliveOnlyWithAnOriginalAndA404Throws() async throws {
        let stub = GooglePhotosStub { request in
            if request.isAuth { return GooglePhotosStub.authAnswer(expiry: Golden.now + 3600) }
            switch request.body {
            case Body.downloadURLs(mediaKey: "dead"): return .text(404, "Not Found")
            case Body.downloadURLs(mediaKey: "edited-only"):
                return .ok(ProtobufWire.bytes(1, ProtobufWire.bytes(5, ProtobufWire.bytes(2, ProtobufWire.string(5, "https://example.com/e")))))
            default: return .ok()
            }
        }
        let client = GooglePhotosClient(credential: try GooglePhotosCredential(authData: Golden.authData), endpoints: stub.endpoints,
                                        session: stub.session, now: { Self.now })
        #expect(try await client.hasOriginalDownload(mediaKey: "edited-only") == false)
        #expect(try await client.hasOriginalDownload(mediaKey: "empty") == false)
        await #expect(throws: GooglePhotosError.self) { try await client.hasOriginalDownload(mediaKey: "dead") }
        do {
            _ = try await client.hasOriginalDownload(mediaKey: "dead")
        } catch {
            guard case .http(404, _) = error else { Issue.record("expected a 404, got \(error)"); return }
        }
    }

    // MARK: - The same calls through the client

    /// Headers URLSession owns or that cannot match by design.
    static let ignoredHeaders: Set<String> = ["accept-encoding", "connection", "content-length"]

    static func expectMatches(_ request: GooglePhotosStub.Request, _ name: String, ignoring extra: Set<String> = [],
                              body expected: String? = nil, sourceLocation: SourceLocation = #_sourceLocation) {
        let golden = Golden.calls[name]!
        let goldenURL = URL(string: golden.url)!
        #expect(request.method == golden.method, "\(name)", sourceLocation: sourceLocation)
        #expect(request.url.path == goldenURL.path, "\(name)", sourceLocation: sourceLocation)
        #expect(request.url.query == goldenURL.query, "\(name)", sourceLocation: sourceLocation)
        let skip = ignoredHeaders.union(extra)
        func normalized(_ headers: [String: String]) -> [String: String] {
            Dictionary(uniqueKeysWithValues: headers.filter { !skip.contains($0.key.lowercased()) }.map { ($0.key.lowercased(), $0.value) })
        }
        #expect(normalized(request.headers) == normalized(golden.headers), "\(name)", sourceLocation: sourceLocation)
        // A PUT's body is the file, which URLProtocol is not handed.
        if golden.method != "PUT" {
            #expect(request.body.hex == expected ?? golden.body, "\(name)", sourceLocation: sourceLocation)
        }
    }

    @Test func everyCallMatchesGpmcOnTheWire() async throws {
        let receipt = Data(hex: Golden.receiptA)
        let stub = GooglePhotosStub { request in
            if request.isAuth { return GooglePhotosStub.authAnswer(expiry: Golden.now + 3600) }
            if request.method == "PUT" { return .ok(receipt) }
            switch request.url.lastPathComponent {
            case "interactive": return .ok(headers: ["X-GUploader-UploadID": Golden.uploadID])
            case GooglePhotosMethod.findRemoteMediaByHash.rawValue: return .ok(Data([0x0A, 0x00]))
            case GooglePhotosMethod.commitUpload.rawValue:
                return .ok(GooglePhotosStub.commitAnswer([(Data(hex: Golden.receiptA), "AF1QipA"), (Data(hex: Golden.receiptB), "AF1QipB")]))
            case GooglePhotosMethod.createAlbum.rawValue:
                return .ok(ProtobufWire.bytes(1, ProtobufWire.string(1, Golden.albumKey)))
            case "PhotosPrepareDownload":
                let urls = ProtobufWire.string(5, "https://example.com/edited") + ProtobufWire.string(6, "https://example.com/original")
                return .ok(ProtobufWire.bytes(1, ProtobufWire.bytes(5, ProtobufWire.bytes(2, urls))))
            default: return .ok()
            }
        }
        let client = GooglePhotosClient(credential: try GooglePhotosCredential(authData: Golden.authData), endpoints: stub.endpoints,
                                        session: stub.session, now: { Self.now })
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("golden-\(UUID().uuidString).bin")
        try Data(count: Int(Golden.fileA.size)).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        #expect(try await client.findRemoteMedia(sha1: Data(hex: Golden.sha1A)) == nil)
        let uploaded = try await client.upload(file: file, fileName: Golden.fileA.name, sha1: Data(hex: Golden.sha1A),
                                               timestamp: Self.fileA.timestamp)
        #expect(uploaded == Self.fileA)
        for quality in UploadQuality.allCases {
            _ = try await client.commitOne(Self.fileA, quality: quality)
            #expect(try await client.commit([Self.fileA, Self.fileB], quality: quality) == ["AF1QipA", "AF1QipB"])
        }
        #expect(try await client.createAlbum(name: Golden.albumName, mediaKeys: Golden.mediaKeys) == Golden.albumKey)
        try await client.addToAlbum(Golden.albumKey, mediaKeys: Golden.mediaKeys)
        #expect(try await client.hasOriginalDownload(mediaKey: Golden.mediaKeys[0]))

        let sent = stub.requests
        let names = ["auth", "findRemoteMedia", "uploadStart", "uploadPut"]
            + UploadQuality.allCases.flatMap { ["commitOne_\($0.rawValue)", "commitBatch_\($0.rawValue)"] }
            + ["createAlbum", "addToAlbum", "downloadURLs"]
        try #require(sent.count == names.count)
        for (request, name) in zip(sent, names) {
            if name.hasPrefix("commitBatch_") {
                // A batch goes where a single commit goes, with its headers.
                Self.expectMatches(request, "commitOne_original", body: Golden.batchBodies[name]!)
            } else {
                // gpmc's PUT sends no Content-Type; the client sends
                // octet-stream on purpose (GooglePhotosClient.prepareUpload).
                Self.expectMatches(request, name, ignoring: name == "uploadPut" ? ["content-type"] : [])
            }
        }
        #expect(sent.first { $0.method == "PUT" }?.header("Content-Type") == "application/octet-stream")
    }
}
