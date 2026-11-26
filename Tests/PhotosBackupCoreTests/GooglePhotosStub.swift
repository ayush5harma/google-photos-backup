import Foundation
@testable import PhotosBackupCore

/// A fake Google for GooglePhotosClient tests: a URLProtocol injected through
/// the session configuration. Swift Testing runs tests in parallel, so each
/// stub owns a host of its own and the protocol routes by host.
///
/// @unchecked Sendable: the URL loading system calls the protocol on its own
/// threads; every mutable field is behind `lock`.
final class GooglePhotosStub: @unchecked Sendable {
    struct Request: Sendable {
        let method: String
        let url: URL
        let headers: [String: String]
        let body: Data

        var path: String { url.path }
        var isAuth: Bool { url.path.hasSuffix("/auth") }

        func header(_ name: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
    }

    enum Reply: Sendable {
        case http(Int, Data, [String: String])
        case failure(URLError.Code)

        static func ok(_ body: Data = Data(), headers: [String: String] = [:]) -> Reply { .http(200, body, headers) }
        static func text(_ status: Int, _ text: String) -> Reply { .http(status, Data(text.utf8), [:]) }
    }

    let base: URL
    private let lock = NSLock()
    private var handler: @Sendable (Request) -> Reply
    private var log: [Request] = []

    init(_ handler: @escaping @Sendable (Request) -> Reply) {
        base = URL(string: "https://stub-\(UUID().uuidString.lowercased()).test")!
        self.handler = handler
        StubURLProtocol.register(self)
    }

    deinit { StubURLProtocol.unregister(base.host!) }

    var requests: [Request] { lock.withLock { log } }
    var authRequests: [Request] { requests.filter(\.isAuth) }
    var dataRequests: [Request] { requests.filter { !$0.isAuth } }

    var endpoints: GooglePhotosEndpoints { .local(base) }

    var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    func respond(to request: Request) -> Reply {
        lock.withLock {
            log.append(request)
            return handler
        }(request)
    }

    // MARK: - Canned answers

    static func authAnswer(expiry: TimeInterval, token: String = "fake-bearer") -> Reply {
        .text(200, "SID=x\nAuth=\(token)\nExpiry=\(Int(expiry))\n")
    }

    /// A commit answer: one entry per (echoed receipt or nil, key or nil).
    static func commitAnswer(_ entries: [(Data?, String?)]) -> Data {
        entries.reduce(Data()) { data, entry in
            var item = Data()
            if let echo = entry.0 { item += ProtobufWire.bytes(1, echo) }
            item += ProtobufWire.int(2, 1)
            if let key = entry.1 { item += ProtobufWire.bytes(3, ProtobufWire.string(1, key)) }
            return data + ProtobufWire.bytes(1, item)
        }
    }

    static func rpcStatus(code: UInt64, message: String) -> Data {
        ProtobufWire.int(1, code) + ProtobufWire.string(2, message)
    }
}

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    // nonisolated(unsafe) behind `lock`: URLProtocol is instantiated by the
    // loading system, so the registry has to be static.
    private nonisolated(unsafe) static var stubs: [String: GooglePhotosStub] = [:]
    private static let lock = NSLock()

    static func register(_ stub: GooglePhotosStub) {
        lock.withLock { stubs[stub.base.host!] = stub }
    }

    static func unregister(_ host: String) {
        lock.withLock { stubs[host] = nil }
    }

    static func stub(for url: URL?) -> GooglePhotosStub? {
        guard let host = url?.host else { return nil }
        return lock.withLock { stubs[host] }
    }

    override class func canInit(with request: URLRequest) -> Bool { stub(for: request.url) != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let stub = Self.stub(for: url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let captured = GooglePhotosStub.Request(
            method: request.httpMethod ?? "GET", url: url,
            headers: request.allHTTPHeaderFields ?? [:], body: Self.body(of: request))
        switch stub.respond(to: captured) {
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .http(let status, let body, let headers):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    /// URLSession hands a protocol the body as a stream, not httpBody.
    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// A clock a test moves by hand.
final class StubClock: @unchecked Sendable {
    // @unchecked: `value` is only touched under `lock`.
    private let lock = NSLock()
    private var value: Date

    init(_ start: Date) { value = start }

    var now: Date { lock.withLock { value } }

    func set(_ date: Date) { lock.withLock { value = date } }

    var closure: @Sendable () -> Date { { [self] in now } }
}

extension Data {
    init(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
