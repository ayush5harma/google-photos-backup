import PhotosBackupCore
import SwiftUI
import UIKit
import WebKit

/// Google's own Embedded Setup sign-in page, in a web view that keeps
/// nothing: the session lives in a non-persistent store and is gone when the
/// sheet closes. The one thing taken from it is the oauth_token cookie
/// Google sets on a google.com domain after "I agree", exchanged at once by
/// GoogleAccountLink. A port of the Mac's GoogleSignInSheet.
struct GoogleSignInSheet: View {
    @Environment(AppModel.self) private var model
    @State private var attempt = 0
    @State private var loading = true

    var body: some View {
        NavigationStack {
            ZStack {
                if model.isFixture {
                    // Fixture mode never touches the network.
                    ContentUnavailableView("Google's sign-in page", systemImage: "globe",
                                           description: Text("Shown here when the app is not in fixture mode."))
                } else {
                    EmbeddedSetupView(loading: $loading) { token in Task { await model.signIn(oauthToken: token) } }
                        // Inside the safe area: under the footer, Google's
                        // Next button was hidden (simulator, 2026-11-26).
                        .id(attempt)
                }
                if model.connectState == .connecting {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Connecting to Google Photos…").font(.headline)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.regularMaterial)
                } else if loading, !model.isFixture {
                    ProgressView("Loading Google sign-in…")
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                footer
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.bar)
            }
            .navigationTitle("Sign in to Google")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.cancelSignIn() }
                }
            }
        }
        .interactiveDismissDisabled(model.connectState == .connecting)
    }

    @ViewBuilder
    private var footer: some View {
        if case let .failed(message) = model.connectState {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(message).font(.footnote).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Try Again") {
                    model.beginSignIn()
                    loading = true
                    attempt += 1
                }
            }
        } else {
            Text("Sign in, then choose I agree. The page may keep loading after that; this sheet closes by itself once Google Photos accepts the account.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

/// The web view and the cookie-store watch. Cookie technique adapted from
/// g8row/PhotosBackup (MIT), AccountConnectWebView.swift: a mobile Safari
/// user agent (a bare WKWebView one trips Google's "browser may not be
/// secure" check), and polling the store as well as observing it, because
/// cookiesDidChange does not reliably fire for a Set-Cookie header after
/// "I agree" while the page keeps spinning.
struct EmbeddedSetupView: UIViewRepresentable {
    @Binding var loading: Bool
    let onToken: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(loading: $loading, onToken: onToken) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = Self.safariUserAgent
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        let store = configuration.websiteDataStore.httpCookieStore
        context.coordinator.cookieStore = store
        store.add(context.coordinator)
        context.coordinator.startPolling()
        webView.load(URLRequest(url: GoogleSignIn.embeddedSetupURL))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.stop()
        webView.stopLoading()
    }

    static var safariUserAgent: String {
        let version = UIDevice.current.systemVersion
        let underscored = version.replacingOccurrences(of: ".", with: "_")
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "iPad; CPU OS" : "iPhone; CPU iPhone OS"
        return "Mozilla/5.0 (\(device) \(underscored) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) "
            + "Version/\(version) Mobile/15E148 Safari/604.1"
    }

    final class Coordinator: NSObject, WKHTTPCookieStoreObserver, WKNavigationDelegate {
        private let loading: Binding<Bool>
        private let onToken: (String) -> Void
        private var delivered = false
        private var timer: Timer?
        weak var cookieStore: WKHTTPCookieStore?

        init(loading: Binding<Bool>, onToken: @escaping (String) -> Void) {
            self.loading = loading
            self.onToken = onToken
        }

        /// google.com or a subdomain of it; not evilgoogle.com.
        static func isGoogle(_ domain: String) -> Bool {
            let host = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
            return host == "google.com" || host.hasSuffix(".google.com")
        }

        func startPolling() {
            let timer = Timer(timeInterval: 0.6, repeats: true) { [weak self] _ in
                guard let self, let store = self.cookieStore else { return }
                self.check(store)
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }

        func stop() {
            timer?.invalidate()
            timer = nil
            cookieStore?.remove(self)
        }

        func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            check(cookieStore)
        }

        private func check(_ store: WKHTTPCookieStore) {
            guard !delivered else { return }
            store.getAllCookies { [weak self] cookies in
                guard let self, !self.delivered,
                      let cookie = cookies.first(where: { $0.name == GoogleSignIn.cookieName && Self.isGoogle($0.domain) }),
                      !cookie.value.isEmpty
                else { return }
                self.delivered = true
                self.stop()
                self.onToken(cookie.value)
            }
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { loading.wrappedValue = false }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loading.wrappedValue = false }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { loading.wrappedValue = false }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            loading.wrappedValue = false
        }
    }
}
