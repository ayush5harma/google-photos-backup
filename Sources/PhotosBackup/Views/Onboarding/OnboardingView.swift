import PhotosBackupCore
import SwiftUI

/// The welcome guide: a sheet over the main window on a fresh install, and
/// again from Settings > General. Every page can be skipped; nothing here is
/// needed that the window and Settings do not also offer.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page: OnboardingPage

    static let size = CGSize(width: 640, height: 600)

    init(page: OnboardingPage = .welcome) {
        _page = State(initialValue: page)
    }

    var body: some View {
        content(for: page)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .id(page)
            .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                                              removal: .move(edge: .leading).combined(with: .opacity)))
            .bottomBar { bar }
            .frame(width: Self.size.width, height: Self.size.height)
            .sheet(isPresented: Binding(get: { model.showingSignIn }, set: { if !$0 { model.cancelSignIn() } })) {
                GoogleSignInSheet().environment(model)
            }
    }

    @ViewBuilder
    func content(for page: OnboardingPage) -> some View {
        switch page {
        case .welcome: WelcomePage()
        case .photos: PhotosAccessPage()
        case .account: AccountPage()
        case .albums: ChooseAlbumsPage()
        case .messages: MessagesPage()
        case .startup: StartupPage()
        case .done: DonePage(finish: finish)
        }
    }

    private var bar: some View {
        HStack(spacing: 12) {
            if page != .done {
                Button("Skip") { finish() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
            }
            Spacer()
            PageDots(current: page)
            Spacer()
            GlassGroup(spacing: 8) {
                HStack(spacing: 8) {
                    if page != .welcome {
                        Button("Back") { move(-1) }
                            .glassButton()
                    }
                    Button(page == .done ? "Done" : "Continue") {
                        page == .done ? finish() : move(1)
                    }
                    .prominentGlassButton()
                    .keyboardShortcut(.defaultAction)
                }
            }
            .controlSize(.large)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func move(_ step: Int) {
        let pages = OnboardingPage.allCases
        guard let index = pages.firstIndex(of: page), pages.indices.contains(index + step) else { return }
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) { page = pages[index + step] }
    }

    private func finish() {
        model.settings.onboardingCompleted = true
        AppRouter.shared.showingWelcome = false
    }
}

enum OnboardingPage: Int, CaseIterable, Identifiable {
    case welcome, photos, account, albums, messages, startup, done
    var id: Int { rawValue }
}

private struct PageDots: View {
    let current: OnboardingPage

    var body: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingPage.allCases) { page in
                Capsule()
                    .fill(page == current ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                    .frame(width: page == current ? 16 : 6, height: 6)
            }
        }
        .animation(.smooth(duration: 0.25), value: current)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(current.rawValue + 1) of \(OnboardingPage.allCases.count)")
    }
}

/// The frame every page shares: artwork, a title, a sentence or two, then
/// the page's own controls.
struct OnboardingPageLayout<Artwork: View, Content: View>: View {
    let title: String
    let message: String
    @ViewBuilder var artwork: Artwork
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            artwork
                .padding(.bottom, 18)
            Text(title)
                .font(.largeTitle.weight(.bold))
                .multilineTextAlignment(.center)
            Text(message)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 460)
                .padding(.top, 8)
            content
                .frame(maxWidth: 480)
                .padding(.top, 26)
            // One spacer above, two below: the page sits a third of the way
            // down, at the optical centre rather than the geometric one.
            Spacer(minLength: 24)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity)
    }
}

/// A page's symbol in a soft tinted circle.
struct OnboardingSymbol: View {
    let name: String
    var tint: Color = .accentColor

    var body: some View {
        Image(systemName: name)
            .symbolRenderingMode(.hierarchical)
            .font(.system(size: 34, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 76, height: 76)
            .background(tint.opacity(0.12), in: Circle())
            .accessibilityHidden(true)
    }
}

/// A done state for a step: a green check and what is now true.
struct OnboardingDone: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(.headline)
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, .green)
            .labelStyle(OnboardingDoneLabelStyle())
    }
}

private struct OnboardingDoneLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon.font(.title2)
            configuration.title.foregroundStyle(.primary)
        }
    }
}
