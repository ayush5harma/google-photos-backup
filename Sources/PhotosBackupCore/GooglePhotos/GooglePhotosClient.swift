import Foundation

/// Google Photos' mobile upload protocol without the Python bridge: the
/// calls gpmc 0.9.0 makes (gpmc/api.py) and the bridge's batched commit
/// (Bridge/gpmc_bridge.py CommitBatcher), for the iOS app, which cannot run
/// Python. Every body is byte-equal to gpmc's (GooglePhotosGoldenTests).
///
/// Where it differs from gpmc, on purpose:
/// - The bearer is renewed 30 s before Google's Expiry, not at it, so a call
///   never leaves with a token that dies in flight; and a 401/403 earns one
///   forced renewal and one retry (a token revoked elsewhere dies early).
/// - The token endpoint's `Error=` and `TokenEncrypted=1` lines are read
///   before its status: it answers a dead master token with 200 or 403 and
///   that line. Both techniques from g8row/PhotosBackup (MIT), GPMCClient.swift.
/// - No transport retries (gpmc's urllib3 retries 502/503/504 ten times):
///   failures come back typed and RetryTracker/RateLimiter decide, as they do
///   for the bridge.
public actor GooglePhotosClient {
    static let userAgent = "com.google.android.apps.photos/49029607 (Linux; U; Android 9; en_US; Pixel XL; Build/PQ2A.190205.001; Cronet/127.0.6510.5) (gzip)"
    static let authUserAgent = "GoogleAuth/1.4 (Pixel XL PQ2A.190205.001); gzip"
    static let language = "en_US"
    /// Sent on commit, create album and add to album only, as gpmc does; on
    /// the hash lookup Google answers them with HTTP 400 (g8row/PhotosBackup).
    static let extHeaders = ["x-goog-ext-173412678-bin": "CgcIAhClARgC", "x-goog-ext-174067345-bin": "CgIIAg=="]
    /// The bridge's COMMIT_BATCH, the largest batch measured.
    public static let commitBatchSize = 20
    /// The bridge's ALBUM_BATCH, gpmc 0.9.0's own per-call album limit.
    public static let albumBatchSize = 500
    static let renewalMargin: TimeInterval = 30
    /// gpmc's DEFAULT_TIMEOUT.
    static let timeout: TimeInterval = 60
    /// When the token endpoint names no Expiry (gpmc would then renew on
    /// every call).
    static let fallbackTokenLifetime: TimeInterval = 300

    struct BearerToken: Sendable {
        let value: String
        let expiry: Date
    }

    private let credential: GooglePhotosCredential
    private let endpoints: GooglePhotosEndpoints
    private let session: URLSession
    private let now: @Sendable () -> Date
    private var token: BearerToken?
    private var renewal: Task<Result<BearerToken, GooglePhotosError>, Never>?

    public init(credential: GooglePhotosCredential, endpoints: GooglePhotosEndpoints = .google, session: URLSession? = nil,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.credential = credential
        self.endpoints = endpoints
        self.now = now
        self.session = session ?? Self.defaultSession()
    }

    static func defaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = timeout
        // Authenticated, stateful protobuf calls: a response cache only
        // keeps private answers on disk.
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }

    // MARK: - Calls

    /// The bridge's check-auth: a bearer proves the sign-in, a hash lookup
    /// of 20 zero bytes proves Google Photos accepts the account.
    public func checkAuth() async throws(GooglePhotosError) {
        _ = try await findRemoteMedia(sha1: Data(count: 20))
    }

    /// The media key Google already has for these bytes, or nil.
    public func findRemoteMedia(sha1: Data) async throws(GooglePhotosError) -> String? {
        let answer = try await dataCall(.findRemoteMediaByHash, body: GooglePhotosRequestBody.findRemoteMedia(sha1: sha1), ext: false)
        do {
            // gpmc reads decoded["1"] unguarded: an answer without field 1
            // is an error there, not "no match".
            guard try ProtobufWire.firstBytes(1, in: answer) != nil else {
                throw ProtobufWire.Malformed()
            }
            return try ProtobufWire.string(at: [1, 2, 2, 1], in: answer)
        } catch {
            throw .invalidResponse("Google's answer to the hash lookup could not be read.")
        }
    }

    /// Start, send and receive one file's bytes, ready to commit. The hash
    /// lookup is the caller's: a forced re-upload skips it (BridgeItem.force).
    public func upload(file: URL, fileName: String, sha1: Data, timestamp: Date,
                       progress: (@Sendable (Int64) -> Void)? = nil) async throws(GooglePhotosError) -> UploadedFile {
        let size = try Self.fileSize(file)
        var request = try await prepareUpload(sha1: sha1, size: size)
        var (body, status) = try await put(request, file: file, progress: progress)
        if status == 401 || status == 403 {
            request = try await reauthorized(request)
            (body, status) = try await put(request, file: file, progress: progress)
        }
        let receipt = try receipt(fromUploadResponse: body, status: status)
        return UploadedFile(receipt: receipt, sha1: sha1, fileName: fileName, timestamp: timestamp, size: size)
    }

    /// The upload start, and the PUT that sends the bytes, for a transport
    /// of the caller's own (a background URLSession). The PUT carries a
    /// bearer that lives at least 30 s; a background transfer that answers
    /// 401/403 gets a fresh one from `reauthorized(_:)`.
    public func prepareUpload(sha1: Data, size: Int64) async throws(GooglePhotosError) -> URLRequest {
        let (_, response) = try await authorized { bearer in
            var request = self.request(self.endpoints.upload, bearer: bearer)
            request.httpBody = GooglePhotosRequestBody.uploadStart(size: size)
            request.setValue("sha1=\(sha1.base64EncodedString())", forHTTPHeaderField: "X-Goog-Hash")
            request.setValue(String(size), forHTTPHeaderField: "X-Upload-Content-Length")
            return request
        }
        guard let uploadID = response.value(forHTTPHeaderField: "X-GUploader-UploadID"), !uploadID.isEmpty,
              var components = URLComponents(url: endpoints.upload, resolvingAgainstBaseURL: false) else {
            throw .invalidResponse("Google did not return an upload id.")
        }
        components.queryItems = [URLQueryItem(name: "upload_id", value: uploadID)]
        guard let url = components.url else { throw .invalidResponse("Google returned an unusable upload id.") }
        var put = URLRequest(url: url)
        put.httpMethod = "PUT"
        put.timeoutInterval = Self.timeout
        put.setValue("Bearer \(try await bearer())", forHTTPHeaderField: "Authorization")
        put.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        put.setValue(Self.language, forHTTPHeaderField: "Accept-Language")
        // gpmc's requests sends none; set so CFNetwork cannot default a
        // bodied request to a form type (g8row/PhotosBackup sends the same).
        put.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        return put
    }

    /// The same request with a renewed bearer, for a background PUT that
    /// came back 401/403: the upload id outlives the token, so the bytes can
    /// go again without a new upload start.
    public func reauthorized(_ request: URLRequest) async throws(GooglePhotosError) -> URLRequest {
        invalidate(bearerIn: request)
        var request = request
        request.setValue("Bearer \(try await bearer())", forHTTPHeaderField: "Authorization")
        return request
    }

    /// The PUT's answer as a receipt to commit. Its field 2 is the upload
    /// token; an answer without one (an empty message, a protobuf error
    /// body that parses) is never a receipt.
    public nonisolated func receipt(fromUploadResponse body: Data, status: Int) throws(GooglePhotosError) -> Data {
        try Self.check(body, status: status)
        guard let token = try? ProtobufWire.firstBytes(2, in: body), !token.isEmpty else {
            throw .invalidResponse("Google did not return a usable upload receipt; the file must be sent again.")
        }
        return body
    }

    /// Commits in requests of up to 20, as the bridge's CommitBatcher does.
    /// The result is aligned with `files`; nil means the batch did not
    /// commit that item, and the caller commits it alone with `commitOne`
    /// (the bridge's fallback), so its failure reads as a single commit's.
    ///
    /// A batch of several that Google refuses as a whole (an HTTP error or
    /// an unreadable answer) is all nil, for the same fallback. A rate
    /// limit, an auth failure, a full account or a network failure throws,
    /// unless an earlier request already committed something: then the
    /// rest is nil, so no key Google issued is lost.
    public func commit(_ files: [UploadedFile], quality: UploadQuality) async throws(GooglePhotosError) -> [String?] {
        var results: [String?] = []
        var start = 0
        while start < files.count {
            let chunk = Array(files[start..<min(start + Self.commitBatchSize, files.count)])
            do {
                results += try await commitBatch(chunk, quality: quality)
            } catch {
                if chunk.count > 1, Self.batchFallsBack(error) {
                    results += Array(repeating: nil, count: chunk.count)
                } else if results.contains(where: { $0 != nil }) {
                    return results + Array(repeating: nil, count: files.count - results.count)
                } else {
                    throw error
                }
            }
            start += chunk.count
        }
        return results
    }

    /// gpmc's commit_upload: one file, its key or an error.
    public func commitOne(_ file: UploadedFile, quality: UploadQuality) async throws(GooglePhotosError) -> String {
        let answer = try await dataCall(.commitUpload, body: GooglePhotosRequestBody.commit([file], quality: quality), ext: true)
        // decoded["1"]["3"]["1"], as gpmc reads it; anything else is its
        // UploadRejectedError.
        guard let key = try? ProtobufWire.string(at: [1, 3, 1], in: answer) else {
            throw .invalidResponse("File upload rejected by api: Google's commit answer held no media key.")
        }
        return key
    }

    /// gpmc's create_album, one request: up to 500 keys (albumBatchSize);
    /// the caller appends the rest with `addToAlbum` once it holds the key,
    /// as the bridge does, so a failed append never loses the album.
    public func createAlbum(name: String, mediaKeys: [String]) async throws(GooglePhotosError) -> String {
        let body = GooglePhotosRequestBody.createAlbum(name: name, mediaKeys: mediaKeys, now: now())
        let answer = try await dataCall(.createAlbum, body: body, ext: true)
        guard let key = try? ProtobufWire.string(at: [1, 1], in: answer) else {
            throw .invalidResponse("Google created no album key.")
        }
        return key
    }

    /// gpmc's add_media_to_album, one request: up to 500 keys.
    public func addToAlbum(_ albumKey: String, mediaKeys: [String]) async throws(GooglePhotosError) {
        guard !mediaKeys.isEmpty else { return }
        let body = GooglePhotosRequestBody.addMediaToAlbum(albumKey: albumKey, mediaKeys: mediaKeys, now: now())
        _ = try await dataCall(.addMediaToAlbum, body: body, ext: true)
    }

    /// gpmc's get_download_urls, read-only: whether Google hands out this
    /// item's original (answer field 1.5.2.6). The bridge's _read_back uses it
    /// only to tell a dead key (404) from a deleted album when an album step
    /// put nothing in; nothing is ever added to find out.
    public func hasOriginalDownload(mediaKey: String) async throws(GooglePhotosError) -> Bool {
        let answer = try await call(endpoints.prepareDownload, body: GooglePhotosRequestBody.downloadURLs(mediaKey: mediaKey), ext: true)
        return ((try? ProtobufWire.string(at: [1, 5, 2, 6], in: answer)) ?? nil)?.isEmpty == false
    }

    // MARK: - Commit results

    private func commitBatch(_ files: [UploadedFile], quality: UploadQuality) async throws(GooglePhotosError) -> [String?] {
        let answer = try await dataCall(.commitUpload, body: GooglePhotosRequestBody.commit(files, quality: quality), ext: true)
        do {
            return try Self.matchCommitResults(answer, to: files)
        } catch {
            throw .invalidResponse("Google's answer to a commit could not be read.")
        }
    }

    /// Each answer entry (field 1, repeated) echoes its item's upload token
    /// in field 1 and carries the media item in field 3. Matched by the echo
    /// (measured by the bridge: always there, in order), by position only
    /// for an entry without one, as CommitBatcher._batch_call does.
    static func matchCommitResults(_ answer: Data, to files: [UploadedFile]) throws(ProtobufWire.Malformed) -> [String?] {
        var keys = [String?](repeating: nil, count: files.count)
        var matched = Set<Int>()
        for (position, entry) in try ProtobufWire.allBytes(1, in: answer).enumerated() {
            guard let key = try ProtobufWire.string(at: [3, 1], in: entry) else { continue }
            let index: Int?
            if let echoed = try ProtobufWire.firstBytes(1, in: entry) {
                index = files.indices.first { !matched.contains($0) && sameReceipt(files[$0].receipt, echoed) }
            } else {
                index = position < files.count && !matched.contains(position) ? position : nil
            }
            if let index {
                matched.insert(index)
                keys[index] = key
            }
        }
        return keys
    }

    /// Byte-equal, or equal as the bridge compares them: gpmc decodes the
    /// receipt and the echo alike, so a re-encoding that orders or sizes
    /// fields differently is still the same token.
    static func sameReceipt(_ receipt: Data, _ echoed: Data) -> Bool {
        if receipt == echoed { return true }
        guard let mine = try? ProtobufWire.decode(receipt), let theirs = try? ProtobufWire.decode(echoed),
              mine.contains(where: { $0.number == 2 }) else { return false }
        return mine.sorted { $0.number < $1.number } == theirs.sorted { $0.number < $1.number }
    }

    static func batchFallsBack(_ error: GooglePhotosError) -> Bool {
        switch error {
        case .http, .invalidResponse: true
        default: false
        }
    }

    // MARK: - Bearer token

    /// The cached bearer while it has 30 s left; otherwise one renewal that
    /// every concurrent caller waits for.
    func bearer() async throws(GooglePhotosError) -> String {
        if let token, token.expiry > now().addingTimeInterval(Self.renewalMargin) {
            return token.value
        }
        if let renewal {
            return try await renewal.value.get().value
        }
        let task = Task { [credential, endpoints, session, now] in
            await Self.fetchToken(credential: credential, endpoints: endpoints, session: session, now: now)
        }
        renewal = task
        let result = await task.value
        renewal = nil
        if case .success(let fresh) = result { token = fresh }
        return try result.get().value
    }

    /// Drops the cached bearer if it is the one a refused request carried;
    /// a newer one another caller already fetched stays.
    private func invalidate(bearer used: String) {
        if token?.value == used { token = nil }
    }

    private func invalidate(bearerIn request: URLRequest) {
        let header = request.value(forHTTPHeaderField: "Authorization") ?? ""
        invalidate(bearer: String(header.dropFirst("Bearer ".count)))
    }

    static func fetchToken(credential: GooglePhotosCredential, endpoints: GooglePhotosEndpoints, session: URLSession,
                           now: @Sendable () -> Date) async -> Result<BearerToken, GooglePhotosError> {
        var request = URLRequest(url: endpoints.auth)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.httpBody = credential.authForm
        request.setValue("com.google.android.apps.photos", forHTTPHeaderField: "app")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(credential.androidID, forHTTPHeaderField: "device")
        request.setValue(authUserAgent, forHTTPHeaderField: "User-Agent")
        do throws(GooglePhotosError) {
            let (body, response) = try await send(request, session: session)
            let fields = parseAuthAnswer(body)
            if fields["TokenEncrypted"] == "1" {
                throw .auth("Google issued a bound (encrypted) token, which this app cannot use. Sign in again.")
            }
            if let code = fields["Error"], !code.isEmpty {
                throw .auth("Google refused the sign-in (\(safeCode(code))). Sign in again.")
            }
            try check(body, status: response.statusCode)
            guard let value = fields["Auth"], !value.isEmpty else {
                throw .auth("Google issued no token for this sign-in. Sign in again.")
            }
            let expiry = fields["Expiry"].flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
                ?? now().addingTimeInterval(fallbackTokenLifetime)
            return .success(BearerToken(value: value, expiry: expiry))
        } catch {
            return .failure(error)
        }
    }

    /// `Key=Value` lines, split at the first "=" as gpmc splits them.
    static func parseAuthAnswer(_ body: Data) -> [String: String] {
        var fields: [String: String] = [:]
        for line in String(decoding: body, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 { fields[String(parts[0])] = String(parts[1]) }
        }
        return fields
    }

    /// Google's codes are words like BadAuthentication; anything else is
    /// cut down so an odd answer cannot put arbitrary text in a log line.
    static func safeCode(_ code: String) -> String {
        String(code.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }.prefix(64))
    }

    // MARK: - Transport

    private func request(_ url: URL, bearer: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.timeout
        // Accept-Encoding is URLSession's own: it decompresses only what it
        // asked for.
        request.setValue(Self.language, forHTTPHeaderField: "Accept-Language")
        request.setValue("application/x-protobuf", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func dataCall(_ method: GooglePhotosMethod, body: Data, ext: Bool) async throws(GooglePhotosError) -> Data {
        try await call(endpoints.method(method), body: body, ext: ext)
    }

    private func call(_ url: URL, body: Data, ext: Bool) async throws(GooglePhotosError) -> Data {
        try await authorized { bearer in
            var request = self.request(url, bearer: bearer)
            request.httpBody = body
            if ext {
                for (name, value) in Self.extHeaders { request.setValue(value, forHTTPHeaderField: name) }
            }
            return request
        }.0
    }

    /// Sends with the current bearer; on 401/403 renews it once and sends
    /// again (every call here is a small replayable request).
    private func authorized(_ make: (String) -> URLRequest) async throws(GooglePhotosError) -> (Data, HTTPURLResponse) {
        var renewed = false
        while true {
            let bearer = try await bearer()
            let (body, response) = try await Self.send(make(bearer), session: session)
            if !renewed, response.statusCode == 401 || response.statusCode == 403 {
                invalidate(bearer: bearer)
                renewed = true
                continue
            }
            try Self.check(body, status: response.statusCode)
            return (body, response)
        }
    }

    private func put(_ request: URLRequest, file: URL, progress: (@Sendable (Int64) -> Void)?) async throws(GooglePhotosError) -> (Data, Int) {
        do {
            let delegate = progress.map(UploadProgressDelegate.init)
            let (body, response) = try await session.upload(for: request, fromFile: file, delegate: delegate)
            guard let http = response as? HTTPURLResponse else { throw GooglePhotosError.invalidResponse("Google's answer was not HTTP.") }
            return (body, http.statusCode)
        } catch {
            throw Self.transportError(error)
        }
    }

    static func send(_ request: URLRequest, session: URLSession) async throws(GooglePhotosError) -> (Data, HTTPURLResponse) {
        do {
            let (body, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw GooglePhotosError.invalidResponse("Google's answer was not HTTP.") }
            return (body, http)
        } catch {
            throw transportError(error)
        }
    }

    static func transportError(_ error: any Error) -> GooglePhotosError {
        if let error = error as? GooglePhotosError { return error }
        if let error = error as? URLError {
            // URLError's localizedDescription names the host at most, never
            // a header; the code keeps an "unknown error" actionable.
            return .network("\(error.localizedDescription) (URLError \(error.code.rawValue))")
        }
        if error is CancellationError { return .network("The request was cancelled.") }
        let nsError = error as NSError
        return .network("\(nsError.domain) \(nsError.code)")
    }

    /// Google's status, typed: 429 is a rate limit whatever the body says,
    /// RESOURCE_EXHAUSTED on anything else is a full account.
    static func check(_ body: Data, status: Int) throws(GooglePhotosError) {
        guard !(200..<300).contains(status) else { return }
        if status == 429 { throw .rateLimited }
        let rpcStatus = GoogleRPCStatus(body)
        if rpcStatus?.code == GoogleRPCStatus.resourceExhausted { throw .storageFull }
        if status == 401 || status == 403 {
            throw .auth("Google refused the account (HTTP \(status)) with a fresh token. Sign in again.")
        }
        throw .http(status: status, message: explanation(body, rpcStatus: rpcStatus))
    }

    /// Google's own words for a refusal: the status message, else a short
    /// printable body, else a hex prefix; always through Redactor.
    static func explanation(_ body: Data, rpcStatus: GoogleRPCStatus?) -> String {
        guard !body.isEmpty else { return "" }
        let limit = 200
        let text = rpcStatus?.message ?? String(decoding: body, as: UTF8.self)
        let printable = text.unicodeScalars.allSatisfy { $0 == "\n" || $0 == "\t" || ($0.value >= 0x20 && $0.value != 0x7F && $0 != "\u{FFFD}") }
        let detail = printable
            ? String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
            : "0x" + body.prefix(32).map { String(format: "%02x", $0) }.joined()
        return Redactor().redact(detail)
    }

    static func fileSize(_ file: URL) throws(GooglePhotosError) -> Int64 {
        do {
            let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, let size = values.fileSize else {
                throw GooglePhotosError.invalidResponse("The file to upload is not a regular file.")
            }
            return Int64(size)
        } catch let error as GooglePhotosError {
            throw error
        } catch {
            throw .invalidResponse("The file to upload cannot be read (\((error as NSError).code)).")
        }
    }
}

/// Forwards one PUT's sent-byte count. Immutable, so Sendable as is.
private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let report: @Sendable (Int64) -> Void

    init(_ report: @escaping @Sendable (Int64) -> Void) {
        self.report = report
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        report(totalBytesSent)
    }
}
