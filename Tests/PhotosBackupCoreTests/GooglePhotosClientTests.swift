import CryptoKit
import Foundation
import Testing
@testable import PhotosBackupCore

@Suite struct GooglePhotosClientTests {
    typealias Stub = GooglePhotosStub
    static let start = Date(timeIntervalSince1970: 1_800_000_000)
    static let sha1 = Data(repeating: 7, count: 20)

    static func client(_ stub: Stub, clock: StubClock = StubClock(start)) throws -> GooglePhotosClient {
        GooglePhotosClient(credential: try GooglePhotosCredential(authData: GooglePhotosGolden.authData),
                           endpoints: stub.endpoints, session: stub.session, now: clock.closure)
    }

    static func file(_ name: String, receipt: UInt8) -> UploadedFile {
        UploadedFile(receipt: ProtobufWire.int(1, UInt64(receipt)) + ProtobufWire.bytes(2, Data([0xFF, receipt])),
                     sha1: Data(repeating: receipt, count: 20), fileName: name, timestamp: start, size: 10)
    }

    /// A stub whose auth always works and whose data calls answer `reply`.
    static func stub(_ reply: @escaping @Sendable (Stub.Request) -> Stub.Reply) -> Stub {
        Stub { request in
            request.isAuth ? Stub.authAnswer(expiry: Self.start.timeIntervalSince1970 + 3600) : reply(request)
        }
    }

    static func error(_ body: () async throws -> Void) async -> GooglePhotosError? {
        do {
            try await body()
            return nil
        } catch let error as GooglePhotosError {
            return error
        } catch {
            Issue.record("not a GooglePhotosError: \(error)")
            return nil
        }
    }

    // MARK: - Headers

    @Test func extHeadersGoOnlyWhereGpmcSendsThem() async throws {
        let stub = Self.stub { request in
            switch request.url.lastPathComponent {
            case GooglePhotosMethod.findRemoteMediaByHash.rawValue: .ok(Data([0x0A, 0x00]))
            case GooglePhotosMethod.commitUpload.rawValue: .ok(Stub.commitAnswer([(nil, "AF1QipK")]))
            case GooglePhotosMethod.createAlbum.rawValue: .ok(ProtobufWire.bytes(1, ProtobufWire.string(1, "AF1QipAlbum")))
            default: .ok()
            }
        }
        let client = try Self.client(stub)
        try await client.checkAuth()
        _ = try await client.commitOne(Self.file("a.jpg", receipt: 1), quality: .original)
        _ = try await client.createAlbum(name: "A", mediaKeys: ["k"])
        try await client.addToAlbum("AF1QipAlbum", mediaKeys: ["k"])

        let data = stub.dataRequests
        #expect(data.count == 4)
        #expect(data[0].header("x-goog-ext-173412678-bin") == nil)
        for request in data.dropFirst() {
            #expect(request.header("x-goog-ext-173412678-bin") == "CgcIAhClARgC")
            #expect(request.header("x-goog-ext-174067345-bin") == "CgIIAg==")
        }
        for request in data {
            #expect(request.header("Authorization") == "Bearer fake-bearer")
            #expect(request.header("User-Agent") == GooglePhotosClient.userAgent)
        }
        // check-auth is the bridge's: a lookup of 20 zero bytes.
        #expect(data[0].body == GooglePhotosRequestBody.findRemoteMedia(sha1: Data(count: 20)))
        let auth = try #require(stub.authRequests.first)
        #expect(auth.header("Authorization") == nil)
        #expect(auth.header("device") == "3a1b2c3d4e5f6071")
        #expect(auth.header("app") == "com.google.android.apps.photos")
    }

    @Test func uploadStartCarriesTheHashAndLength() async throws {
        let stub = Self.stub { _ in .ok(headers: ["X-GUploader-UploadID": "id 1/2"]) }
        let put = try await Self.client(stub).prepareUpload(sha1: Self.sha1, size: 4_294_967_296)
        let start = try #require(stub.dataRequests.first)
        #expect(start.header("X-Goog-Hash") == "sha1=" + Self.sha1.base64EncodedString())
        #expect(start.header("X-Upload-Content-Length") == "4294967296")
        #expect(start.header("x-goog-ext-173412678-bin") == nil)
        #expect(put.httpMethod == "PUT")
        #expect(put.url?.path == "/data/upload/uploadmedia/interactive")
        #expect(URLComponents(url: put.url!, resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "upload_id", value: "id 1/2")])
        #expect(put.value(forHTTPHeaderField: "Authorization") == "Bearer fake-bearer")
    }

    @Test func anUploadStartWithoutAnIdIsNotAnUpload() async throws {
        let stub = Self.stub { _ in .ok() }
        let error = await Self.error { _ = try await Self.client(stub).prepareUpload(sha1: Self.sha1, size: 1) }
        #expect(error == .invalidResponse("Google did not return an upload id."))
    }

    // MARK: - Bearer token

    @Test func theTokenIsCachedUntilThirtySecondsBeforeExpiry() async throws {
        let clock = StubClock(Self.start)
        let stub = Self.stub { _ in .ok(Data([0x0A, 0x00])) }
        let client = try Self.client(stub, clock: clock)
        try await client.checkAuth()
        try await client.checkAuth()
        #expect(stub.authRequests.count == 1)
        clock.set(Self.start.addingTimeInterval(3600 - 31))
        try await client.checkAuth()
        #expect(stub.authRequests.count == 1)
        clock.set(Self.start.addingTimeInterval(3600 - 30))
        try await client.checkAuth()
        #expect(stub.authRequests.count == 2)
    }

    @Test func concurrentCallersShareOneRenewal() async throws {
        let stub = Self.stub { _ in .ok(Data([0x0A, 0x00])) }
        let client = try Self.client(stub)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 { group.addTask { try await client.checkAuth() } }
            try await group.waitForAll()
        }
        #expect(stub.authRequests.count == 1)
        #expect(stub.dataRequests.count == 8)
    }

    @Test(arguments: [401, 403])
    func aRefusedTokenIsRenewedOnceAndTheCallRetried(status: Int) async throws {
        let calls = Counter()
        let stub = Stub { request in
            if request.isAuth { return Stub.authAnswer(expiry: Self.start.timeIntervalSince1970 + 3600, token: "t\(calls.next("auth"))") }
            return request.header("Authorization") == "Bearer t0" ? .text(status, "") : .ok(Data([0x0A, 0x00]))
        }
        try await Self.client(stub).checkAuth()
        #expect(stub.authRequests.count == 2)
        #expect(stub.dataRequests.map { $0.header("Authorization") } == ["Bearer t0", "Bearer t1"])
    }

    @Test func aSecondRefusalIsAnAuthFailure() async throws {
        let stub = Self.stub { _ in .text(401, "") }
        let error = await Self.error { try await Self.client(stub).checkAuth() }
        guard case .auth = error else { Issue.record("expected .auth, got \(String(describing: error))"); return }
        #expect(stub.authRequests.count == 2)
        #expect(stub.dataRequests.count == 2)
        #expect(error?.failureClass == .permanent)
    }

    @Test(arguments: [200, 403])
    func badAuthenticationIsReadBeforeTheStatus(status: Int) async throws {
        let stub = Stub { _ in .text(status, "Error=BadAuthentication\n") }
        let error = await Self.error { try await Self.client(stub).checkAuth() }
        #expect(error == .auth("Google refused the sign-in (BadAuthentication). Sign in again."))
        #expect(stub.dataRequests.isEmpty)
    }

    @Test func aBoundTokenIsRefused() async throws {
        let stub = Stub { _ in .text(200, "Auth=encrypted\nTokenEncrypted=1\nExpiry=9999999999\n") }
        let error = await Self.error { try await Self.client(stub).checkAuth() }
        guard case .auth = error else { Issue.record("expected .auth, got \(String(describing: error))"); return }
        #expect(stub.dataRequests.isEmpty)
    }

    @Test func aRenewalFailureIsNotCachedAsAToken() async throws {
        let calls = Counter()
        let stub = Stub { request in
            if request.isAuth {
                return calls.next("auth") == 0 ? .failure(.timedOut) : Stub.authAnswer(expiry: Self.start.timeIntervalSince1970 + 3600)
            }
            return .ok(Data([0x0A, 0x00]))
        }
        let client = try Self.client(stub)
        let error = await Self.error { try await client.checkAuth() }
        guard case .network = error else { Issue.record("expected .network, got \(String(describing: error))"); return }
        try await client.checkAuth()
    }

    // MARK: - Status mapping

    @Test func statusesMapToTypedErrors() async throws {
        let cases: [(Stub.Reply, GooglePhotosError)] = [
            (.text(429, "slow down"), .rateLimited),
            (.http(429, Stub.rpcStatus(code: 8, message: "Quota exceeded"), [:]), .rateLimited),
            (.http(400, Stub.rpcStatus(code: 8, message: "Storage quota exceeded"), [:]), .storageFull),
            (.http(400, Stub.rpcStatus(code: 3, message: "Invalid blueprint"), [:]), .http(status: 400, message: "Invalid blueprint")),
            (.text(503, "Service Unavailable"), .http(status: 503, message: "Service Unavailable")),
            (.failure(.notConnectedToInternet), .network("")),
        ]
        for (reply, expected) in cases {
            let stub = Self.stub { _ in reply }
            let error = await Self.error { _ = try await Self.client(stub).findRemoteMedia(sha1: Self.sha1) }
            if case .network = expected {
                guard case .network(let text) = error else { Issue.record("expected .network, got \(String(describing: error))"); continue }
                #expect(text.contains("URLError \(URLError.Code.notConnectedToInternet.rawValue)"))
            } else {
                #expect(error == expected)
            }
        }
    }

    @Test func googlesErrorTextIsRedacted() async throws {
        let stub = Self.stub { _ in .text(400, "bad token Token=aas_et/AKppINaSecret for first.last@gmail.com") }
        let error = await Self.error { _ = try await Self.client(stub).findRemoteMedia(sha1: Self.sha1) }
        let message = try #require(error?.message)
        #expect(!message.contains("AKppINaSecret"))
        #expect(!message.contains("first.last@gmail.com"))
    }

    @Test func failureClassesFollowTheRetryPolicy() {
        let cases: [(GooglePhotosError, FailureClass)] = [
            (.invalidCredential("x"), .permanent),
            (.auth("x"), .permanent),
            (.network("x"), .retryable),
            (.rateLimited, .rateLimited),
            (.storageFull, .permanent),
            (.http(status: 408, message: ""), .retryable),
            (.http(status: 429, message: ""), .rateLimited),
            (.http(status: 500, message: ""), .retryable),
            (.http(status: 503, message: ""), .retryable),
            (.http(status: 400, message: ""), .permanent),
            (.http(status: 404, message: ""), .permanent),
            (.invalidResponse("x"), .permanent),
        ]
        for (error, expected) in cases {
            #expect(error.failureClass == expected, "\(error)")
            // Same verdict FailureClassifier gives the bridge's wording.
            if case .http = error {
                #expect(FailureClassifier.classify(message: error.message, bridgeRetryable: nil) == expected)
            }
        }
        #expect(FailureClassifier.classify(message: GooglePhotosError.rateLimited.message, bridgeRetryable: nil) == .rateLimited)
    }

    // MARK: - Lookup

    @Test func aHashMatchReturnsTheKeyAndAnEmptyAnswerIsAnError() async throws {
        let match = ProtobufWire.bytes(1, ProtobufWire.bytes(2, ProtobufWire.bytes(2, ProtobufWire.string(1, "AF1QipFound"))))
        #expect(try await Self.client(Self.stub { _ in .ok(match) }).findRemoteMedia(sha1: Self.sha1) == "AF1QipFound")
        #expect(try await Self.client(Self.stub { _ in .ok(Data([0x0A, 0x00])) }).findRemoteMedia(sha1: Self.sha1) == nil)
        // gpmc reads decoded["1"] unguarded; no field 1 is no answer.
        let empty = await Self.error { _ = try await Self.client(Self.stub { _ in .ok() }).findRemoteMedia(sha1: Self.sha1) }
        guard case .invalidResponse = empty else { Issue.record("expected .invalidResponse, got \(String(describing: empty))"); return }
    }

    // MARK: - Upload

    @Test func uploadSendsTheFileAndReturnsTheReceipt() async throws {
        let receipt = ProtobufWire.int(1, 5) + ProtobufWire.bytes(2, Data([0xAB, 0xCD]))
        let stub = Self.stub { request in
            request.method == "PUT" ? .ok(receipt) : .ok(headers: ["X-GUploader-UploadID": "u1"])
        }
        let file = try Self.temporaryFile(Data(repeating: 1, count: 1000))
        defer { try? FileManager.default.removeItem(at: file) }
        let uploaded = try await Self.client(stub).upload(file: file, fileName: "a.jpg", sha1: Self.sha1, timestamp: Self.start)
        #expect(uploaded == UploadedFile(receipt: receipt, sha1: Self.sha1, fileName: "a.jpg", timestamp: Self.start, size: 1000))
        #expect(stub.dataRequests.map(\.method) == ["POST", "PUT"])
        #expect(stub.dataRequests[1].url.query == "upload_id=u1")
    }

    @Test func aBackgroundPutIsReauthorizedWithoutANewUploadStart() async throws {
        let calls = Counter()
        let stub = Stub { request in
            request.isAuth
                ? Stub.authAnswer(expiry: Self.start.timeIntervalSince1970 + 3600, token: "t\(calls.next("auth"))")
                : .ok(headers: ["X-GUploader-UploadID": "u1"])
        }
        let client = try Self.client(stub)
        let put = try await client.prepareUpload(sha1: Self.sha1, size: 3)
        let again = try await client.reauthorized(put)
        #expect(put.value(forHTTPHeaderField: "Authorization") == "Bearer t0")
        #expect(again.value(forHTTPHeaderField: "Authorization") == "Bearer t1")
        #expect(again.url == put.url)
        #expect(stub.dataRequests.count == 1)
    }

    @Test func aRefusedPutIsSentAgainWithAFreshToken() async throws {
        let calls = Counter()
        let receipt = ProtobufWire.int(1, 5) + ProtobufWire.bytes(2, Data([0xAB]))
        let stub = Stub { request in
            if request.isAuth { return Stub.authAnswer(expiry: Self.start.timeIntervalSince1970 + 3600, token: "t\(calls.next("auth"))") }
            if request.method == "PUT" { return request.header("Authorization") == "Bearer t0" ? .text(401, "") : .ok(receipt) }
            return .ok(headers: ["X-GUploader-UploadID": "u1"])
        }
        let file = try Self.temporaryFile(Data([1, 2, 3]))
        defer { try? FileManager.default.removeItem(at: file) }
        let uploaded = try await Self.client(stub).upload(file: file, fileName: "a", sha1: Self.sha1, timestamp: Self.start)
        #expect(uploaded.receipt == receipt)
        #expect(stub.dataRequests.filter { $0.method == "PUT" }.map { $0.url.query } == ["upload_id=u1", "upload_id=u1"])
    }

    @Test func aReceiptNeedsAnUploadToken() throws {
        let client = try Self.client(Self.stub { _ in .ok() })
        let good = ProtobufWire.int(1, 5) + ProtobufWire.bytes(2, Data([1]))
        #expect(try client.receipt(fromUploadResponse: good, status: 200) == good)
        for body in [Data(), ProtobufWire.int(1, 5), ProtobufWire.int(1, 5) + ProtobufWire.bytes(2, Data()), Data([0xFF, 0xFF])] {
            #expect(throws: GooglePhotosError.self) { try client.receipt(fromUploadResponse: body, status: 200) }
        }
        #expect(throws: GooglePhotosError.rateLimited) { try client.receipt(fromUploadResponse: good, status: 429) }
        #expect(throws: GooglePhotosError.self) { try client.receipt(fromUploadResponse: good, status: 401) }
    }

    // MARK: - Commit

    @Test func batchResultsAreMatchedByTheEchoedReceiptInAnyOrder() async throws {
        let files = (1...3).map { Self.file("f\($0)", receipt: UInt8($0)) }
        let stub = Self.stub { _ in
            .ok(Stub.commitAnswer([(files[2].receipt, "K3"), (files[0].receipt, "K1"), (files[1].receipt, "K2")]))
        }
        #expect(try await Self.client(stub).commit(files, quality: .original) == ["K1", "K2", "K3"])
        #expect(stub.dataRequests.count == 1)
    }

    @Test func aBatchItemWithoutAKeyIsNil() async throws {
        let files = (1...3).map { Self.file("f\($0)", receipt: UInt8($0)) }
        let stub = Self.stub { _ in
            .ok(Stub.commitAnswer([(files[0].receipt, "K1"), (files[1].receipt, nil), (files[2].receipt, "")]))
        }
        #expect(try await Self.client(stub).commit(files, quality: .saver) == ["K1", nil, nil])
    }

    @Test func entriesWithoutAnEchoAreMatchedByPosition() throws {
        let files = (1...2).map { Self.file("f\($0)", receipt: UInt8($0)) }
        let answer = Stub.commitAnswer([(nil, "K1"), (nil, "K2")])
        #expect(try GooglePhotosClient.matchCommitResults(answer, to: files) == ["K1", "K2"])
        // A re-encoded echo (fields reordered) is still the same token.
        let reordered = ProtobufWire.bytes(2, Data([0xFF, 2])) + ProtobufWire.int(1, 2)
        #expect(try GooglePhotosClient.matchCommitResults(Stub.commitAnswer([(reordered, "K2")]), to: files) == [nil, "K2"])
    }

    @Test func moreThanTwentyGoInSeveralRequests() async throws {
        let files = (1...45).map { Self.file("f\($0)", receipt: UInt8($0)) }
        let stub = Self.stub { request in
            let items = (try? ProtobufWire.allBytes(1, in: request.body)) ?? []
            return .ok(Stub.commitAnswer(items.map { item in
                let receipt = try! ProtobufWire.firstBytes(1, in: item)!
                return (receipt, "K\(try! ProtobufWire.firstVarint(1, in: receipt)!)")
            }))
        }
        let keys = try await Self.client(stub).commit(files, quality: .original)
        #expect(keys == (1...45).map { "K\($0)" })
        #expect(stub.dataRequests.map { try! ProtobufWire.allBytes(1, in: $0.body).count } == [20, 20, 5])
    }

    @Test func aRefusedBatchIsAllNilForTheSingleFallback() async throws {
        let files = (1...2).map { Self.file("f\($0)", receipt: UInt8($0)) }
        #expect(try await Self.client(Self.stub { _ in .text(500, "") }).commit(files, quality: .original) == [nil, nil])
        // A single item's failure is its own.
        let error = await Self.error { _ = try await Self.client(Self.stub { _ in .text(500, "") }).commit([files[0]], quality: .original) }
        #expect(error == .http(status: 500, message: ""))
    }

    @Test func aRateLimitedBatchThrowsUnlessKeysWereAlreadyIssued() async throws {
        let files = (1...25).map { Self.file("f\($0)", receipt: UInt8($0)) }
        let error = await Self.error { _ = try await Self.client(Self.stub { _ in .text(429, "") }).commit(files, quality: .original) }
        #expect(error == .rateLimited)

        let calls = Counter()
        let stub = Self.stub { request in
            guard calls.next("commit") == 0 else { return .text(429, "") }
            let items = (try? ProtobufWire.allBytes(1, in: request.body)) ?? []
            return .ok(Stub.commitAnswer(items.map { (try! ProtobufWire.firstBytes(1, in: $0)!, "K") }))
        }
        let keys = try await Self.client(stub).commit(files, quality: .original)
        #expect(keys == Array(repeating: "K", count: 20) + Array(repeating: nil, count: 5))
    }

    @Test func commitOneWithoutAKeyIsRejected() async throws {
        let error = await Self.error {
            _ = try await Self.client(Self.stub { _ in .ok(Stub.commitAnswer([(nil, nil)])) }).commitOne(Self.file("a", receipt: 1), quality: .quota)
        }
        guard case .invalidResponse = error else { Issue.record("expected .invalidResponse, got \(String(describing: error))"); return }
    }

    // MARK: - Albums

    @Test func albumWithoutAKeyIsAnErrorAndAnEmptyAddSendsNothing() async throws {
        let stub = Self.stub { _ in .ok() }
        let client = try Self.client(stub)
        let error = await Self.error { _ = try await client.createAlbum(name: "A", mediaKeys: ["k"]) }
        guard case .invalidResponse = error else { Issue.record("expected .invalidResponse, got \(String(describing: error))"); return }
        try await client.addToAlbum("album", mediaKeys: [])
        #expect(stub.dataRequests.count == 1)
    }

    // MARK: - Credential, endpoints, hashing

    @Test func aCredentialNeedsEveryFieldGpmcReads() throws {
        let credential = try GooglePhotosCredential(authData: GooglePhotosGolden.authData)
        #expect(credential.email == "first.last+tag@gmail.com")
        #expect(!credential.description.contains("first.last"))
        #expect(!credential.description.contains("aas_et"))
        let withoutToken = GooglePhotosGolden.authData.replacingOccurrences(of: "&Token=", with: "&Tokn=")
        #expect(throws: GooglePhotosError.self) { try GooglePhotosCredential(authData: withoutToken) }
        #expect(throws: GooglePhotosError.self) { try GooglePhotosCredential(authData: "") }
    }

    @Test func theMacAppsCredentialParses() throws {
        let account = GoogleSignIn.Account(email: "someone@gmail.com", masterToken: "aas_et/abc+def==")
        let credential = try GooglePhotosCredential(authData: GoogleSignIn.credential(for: account, androidID: "0123456789abcdef"))
        #expect(credential.email == "someone@gmail.com")
        #expect(credential.values["Token"] == "aas_et/abc+def==")
    }

    @Test func localEndpointsKeepGooglesPaths() {
        let local = GooglePhotosEndpoints.local(URL(string: "http://127.0.0.1:8765")!)
        #expect(local.auth.absoluteString == "http://127.0.0.1:8765/auth")
        #expect(local.data.path == GooglePhotosEndpoints.google.data.path)
        #expect(local.upload.path == GooglePhotosEndpoints.google.upload.path)
        #expect(local.method(.commitUpload).absoluteString == "http://127.0.0.1:8765/6439526531001121323/16538846908252377752")
    }

    @Test func contentHashStreamsTheWholeFile() throws {
        let abc = try Self.temporaryFile(Data("abc".utf8))
        defer { try? FileManager.default.removeItem(at: abc) }
        #expect(try ContentHash.sha1(of: abc).hex == "a9993e364706816aba3e25717850c26c9cd0d89d")
        // Over two chunks and a partial third.
        let big = Data((0..<(2 * ContentHash.chunkSize + 12345)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let file = try Self.temporaryFile(big)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(try ContentHash.sha1(of: file) == Data(Insecure.SHA1.hash(data: big)))
    }

    static func temporaryFile(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gpc-\(UUID().uuidString)")
        try data.write(to: url)
        return url
    }
}

/// Per-name call counts for stubs that answer differently over time.
final class Counter: @unchecked Sendable {
    // @unchecked: `counts` is only touched under `lock`.
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    /// The count before this call.
    func next(_ name: String) -> Int {
        lock.withLock {
            defer { counts[name, default: 0] += 1 }
            return counts[name, default: 0]
        }
    }
}
