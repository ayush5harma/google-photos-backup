import Foundation

/// Why a Google Photos call failed, in the terms the engine acts on.
/// Associated strings are built from Google's error codes and this file's
/// own words, never from a request, so none of them carries a token or the
/// credential; Google's own error text goes through Redactor all the same.
public enum GooglePhotosError: Error, Sendable, Equatable {
    /// The saved auth_data cannot be used: a field gpmc needs is missing.
    case invalidCredential(String)
    /// Google refused the account: an `Error=` line from the token endpoint
    /// (BadAuthentication and the like), a bound token (TokenEncrypted=1),
    /// or 401/403 on a call that already had one fresh token.
    case auth(String)
    /// The request never got an answer (URLError).
    case network(String)
    /// HTTP 429.
    case rateLimited
    /// google.rpc.Status RESOURCE_EXHAUSTED on anything but a 429: the
    /// account has no room left.
    case storageFull
    case http(status: Int, message: String)
    /// Google answered, but not with what the call needs (no upload id, no
    /// media key, a body that is not protobuf).
    case invalidResponse(String)

    /// The existing RetryPolicy classes: the same split FailureClassifier
    /// makes of gpmc's messages, so both engines retry alike.
    public var failureClass: FailureClass {
        switch self {
        case .rateLimited:
            return .rateLimited
        case .network:
            return .retryable
        case .http(let status, _):
            if status == 429 { return .rateLimited }
            return status == 408 || status >= 500 ? .retryable : .permanent
        case .invalidCredential, .auth, .storageFull:
            // The person has to reconnect the account or free space first.
            return .permanent
        case .invalidResponse:
            // gpmc's UploadRejectedError ("File upload rejected by api", a
            // commit without a key) is permanent to FailureClassifier too;
            // the next run sends the item again.
            return .permanent
        }
    }

    public var message: String {
        switch self {
        case .invalidCredential(let text), .auth(let text), .invalidResponse(let text):
            return text
        case .network(let text):
            return "Could not reach Google: \(text)"
        case .rateLimited:
            return "429 Client Error: Too Many Requests (Google Photos is slowing uploads down)"
        case .storageFull:
            return "The Google account is out of storage."
        case .http(let status, let text):
            return text.isEmpty ? "HTTP \(status) from Google Photos" : "HTTP \(status) from Google Photos: \(text)"
        }
    }
}

/// The google.rpc.Status Google puts in a protobuf error body: the code in
/// field 1, an English message in field 2 (English because every request
/// pins Accept-Language en_US). Adapted from g8row/PhotosBackup (MIT),
/// GPMCClient.swift's GoogleStatus.
struct GoogleRPCStatus: Equatable, Sendable {
    static let resourceExhausted = 8

    let code: Int
    let message: String?

    /// Nil unless the body is protobuf with a non-zero code (0 is OK and
    /// cannot describe a failure).
    init?(_ body: Data) {
        guard !body.isEmpty,
              let raw = try? ProtobufWire.firstVarint(1, in: body), raw > 0, raw < 64,
              let code = Int(exactly: raw) else { return nil }
        self.code = code
        message = (try? ProtobufWire.string(at: [2], in: body)) ?? nil
    }
}
