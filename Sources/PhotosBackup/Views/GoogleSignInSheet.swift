import PhotosBackupCore
import SwiftUI
import WebKit

/// Google's own Embedded Setup sign-in page, in a web view that keeps
/// nothing: the session lives in a non-persistent store and is gone when the
/// sheet closes. The one thing taken from it is the oauth_token cookie Google
/// sets after "I agree", which the app exchanges for its credential at once.
struct GoogleSignInSheet: View {
    @Environment(AppModel.self) private var model
    @State private var attempt = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Sign in to Google", systemImage: "person.crop.circle.badge.checkmark")
                    .font(.headline)
                Spacer()
                Button("Cancel") { model.cancelSignIn() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(14)
            Divider()
            ZStack {
                EmbeddedSetupView { token in Task { await model.signIn(oauthToken: token) } }
                    .id(attempt)
                if model.connectState == .connecting {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Connecting to Google Photos…").font(.headline)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.regularMaterial)
                }
            }
            Divider()
            footer.padding(14)
        }
        .frame(width: 520, height: 720)
    }

    @ViewBuilder
    private var footer: some View {
        if case let .failed(message) = model.connectState {
            HStack {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(message).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Try Again") {
                    model.beginSignIn()
                    attempt += 1
                }
            }
        } else {
            Text("Sign in, then choose I agree. The page may keep loading after that; this window closes by itself once Google Photos accepts the account.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct EmbeddedSetupView: NSViewRepresentable {
    let onToken: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onToken: onToken) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        // Google turns away sign-ins from web views it takes for embedded
        // browsers; this one is WebKit like Safari, and says so the way
        // Safari does.
        configuration.applicationNameForUserAgent = "Version/\(Self.safariVersion) Safari/605.1.15"
        let webView = WKWebView(frame: .zero, configuration: configuration)
        configuration.websiteDataStore.httpCookieStore.add(context.coordinator)
        webView.load(URLRequest(url: GoogleSignIn.embeddedSetupURL))
        #if DEBUG
        Snapshots.signInWebView = webView
        #endif
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.websiteDataStore.httpCookieStore.remove(coordinator)
        webView.stopLoading()
    }

    private static var safariVersion: String {
        Bundle(path: "/Applications/Safari.app")?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "18.0"
    }

    final class Coordinator: NSObject, WKHTTPCookieStoreObserver {
        private let onToken: (String) -> Void
        private var delivered = false

        /// google.com or a subdomain of it; not evilgoogle.com.
        static func isGoogle(_ domain: String) -> Bool {
            let host = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
            return host == "google.com" || host.hasSuffix(".google.com")
        }

        init(onToken: @escaping (String) -> Void) {
            self.onToken = onToken
        }

        func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            guard !delivered else { return }
            cookieStore.getAllCookies { [weak self] cookies in
                guard let self, !self.delivered,
                      let cookie = cookies.first(where: { $0.name == GoogleSignIn.cookieName && Self.isGoogle($0.domain) }),
                      !cookie.value.isEmpty
                else { return }
                self.delivered = true
                self.onToken(cookie.value)
            }
        }
    }
}
