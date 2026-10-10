import Foundation
import PhotosBackupCore

/// Exchanges an Embedded Setup oauth_token for gpmc's auth_data.
///
/// Done here rather than in the Python bridge: Apple's TLS stack is the one
/// Safari and every iPhone present to Google, whereas Python's has a history
/// of `BadAuthentication` from this endpoint (gpsoauth had to pin cipher
/// suites to get past it).
enum GoogleAccountLink {
    struct Linked {
        let credential: String
        let email: String
    }

    /// The cookie works once and expires within minutes, so a failure here
    /// usually means signing in again.
    static func link(oauthToken: String) async throws -> Linked {
        let token = try GoogleSignIn.normalizedOAuthToken(oauthToken)
        let androidID = GoogleSignIn.newAndroidID()
        let body = Data(GoogleSignIn.exchangeForm(oauthToken: token, androidID: androidID).utf8)
        var unreachable: Error?
        for endpoint in GoogleSignIn.exchangeEndpoints {
            var request = URLRequest(url: endpoint, timeoutInterval: 30)
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            request.setValue("GoogleAuth/1.4", forHTTPHeaderField: "User-Agent")
            let metrics = SentRequest()
            do {
                let (data, _) = try await session.data(for: request, delegate: metrics)
                let account = try GoogleSignIn.parseExchange(String(decoding: data.prefix(64 * 1024), as: UTF8.self))
                return Linked(credential: GoogleSignIn.credential(for: account, androidID: androidID), email: account.email)
            } catch let error as URLError where neverReachedGoogle(error, sent: metrics.sent) {
                // Only then is the single-use token still unspent, and the
                // next host worth a try.
                unreachable = error
            }
        }
        throw GoogleSignIn.Failure("Google's sign-in service could not be reached (\(unreachable?.localizedDescription ?? "no route")).")
    }

    private static func neverReachedGoogle(_ error: URLError, sent: Bool) -> Bool {
        switch error.code {
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .notConnectedToInternet, .secureConnectionFailed: true
        // A timeout can come after the token went out (Google slow to
        // answer); only one before the request was written is safe to retry.
        case .timedOut: !sent
        default: false
        }
    }

    /// Records whether the request body ever left, from the task's metrics.
    /// Refuses redirects itself as well: a task delegate stands in front of
    /// the session's, and this one must not be the gap.
    private final class SentRequest: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var requestSent = false

        var sent: Bool { lock.withLock { requestSent } }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            nil
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
            let sent = metrics.transactionMetrics.contains { $0.requestEndDate != nil }
            lock.withLock { requestSent = sent }
        }
    }

    /// Ephemeral (nothing cached or stored) and never redirected: the token
    /// goes to these two Google hosts and nowhere else.
    private static let session = URLSession(configuration: .ephemeral, delegate: RefuseRedirects(), delegateQueue: nil)

    private final class RefuseRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            nil
        }
    }
}
