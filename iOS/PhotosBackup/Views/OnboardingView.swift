import PhotosBackupCore
import SwiftUI

/// The welcome guide: the Mac's pages minus Messages and the login item.
struct OnboardingView: View {
    enum Page: Int, CaseIterable {
        case welcome, photos, account, albums, done
    }

    @Environment(AppModel.self) private var model
    @State private var page: Page = .welcome

    var body: some View {
        NavigationStack {
            ScrollView {
                content
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
                    .frame(maxWidth: 520)
                    .frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { controls }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if page != .done { Button("Skip") { model.finishOnboarding() } }
                }
            }
            .animation(.smooth(duration: 0.25), value: page)
        }
        .interactiveDismissDisabled()
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case .welcome: WelcomePage()
        case .photos: PhotosAccessPage()
        case .account: AccountPage()
        case .albums: ChooseAlbumsPage()
        case .done: DonePage()
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 6) {
                ForEach(Page.allCases, id: \.self) { item in
                    Circle()
                        .fill(item == page ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                        .frame(width: 7, height: 7)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Page \(page.rawValue + 1) of \(Page.allCases.count)")
            HStack(spacing: 10) {
                if page != .welcome {
                    Button("Back") { move(-1) }
                        .buttonStyle(TintedButtonStyle(color: .secondary))
                }
                if page == .done {
                    Button("Done") { model.finishOnboarding() }
                        .buttonStyle(ProminentButtonStyle())
                } else {
                    Button("Continue") { move(1) }
                        .buttonStyle(ProminentButtonStyle())
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private func move(_ step: Int) {
        page = Page(rawValue: page.rawValue + step) ?? page
    }
}

/// The frame every page shares: artwork, a title, a sentence or two, then
/// the page's own controls.
private struct PageLayout<Artwork: View, Content: View>: View {
    let title: String
    let message: String
    @ViewBuilder var artwork: Artwork
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            artwork.padding(.bottom, 18).padding(.top, 24)
            Text(title)
                .font(.largeTitle.weight(.bold))
                .multilineTextAlignment(.center)
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            content
                .padding(.top, 26)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct PageSymbol: View {
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

private struct DoneLine: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .green)
            Text(text).font(.headline)
        }
    }
}

private struct FeatureRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct WelcomePage: View {
    var body: some View {
        PageLayout(title: "Welcome to Photos Backup", message: "Your Photos library, kept safe in Google Photos.") {
            AppMark(size: 92)
        } content: {
            VStack(alignment: .leading, spacing: 18) {
                FeatureRow(symbol: "photo.on.rectangle.angled", tint: .accentColor, title: "Back up your library",
                           text: "Photos and videos you choose go to Google Photos in original quality, and new ones follow on their own.")
                FeatureRow(symbol: "rectangle.stack", tint: .orange, title: "Recreate your albums",
                           text: "Albums you made in Photos appear in Google Photos under the same names.")
                FeatureRow(symbol: "person.2", tint: .green, title: "One or several accounts",
                           text: "Back up to one Google account, or to several at the same time.")
            }
        }
    }
}

private struct PhotosAccessPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        PageLayout(title: "Allow access to Photos",
                   message: "Photos Backup reads the albums you choose and uploads copies. It never changes or deletes anything in your library.") {
            PageSymbol(name: "photo.on.rectangle.angled")
        } content: {
            switch model.photosStatus {
            case .authorized:
                DoneLine(text: "Photos Backup can read your library")
            case .limited:
                VStack(spacing: 12) {
                    DoneLine(text: "Photos Backup can read the photos you chose")
                    Text("Only those are backed up. Choose more at any time, or allow all photos in Settings.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Choose More Photos") { PhotoLibrary.presentLimitedPicker() }
                }
            case .notDetermined:
                Button("Allow Access") { Task { await model.requestPhotosAccess() } }
                    .buttonStyle(ProminentButtonStyle())
            default:
                VStack(spacing: 12) {
                    Text("Access is turned off. Turn on Photos for Photos Backup in Settings.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Open Settings") { model.perform(.openAppSettings) }
                }
            }
        }
    }
}

private struct AccountPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        PageLayout(title: "Connect Google Photos",
                   message: "Sign in on Google's own page. The account stays in the Keychain on this device.") {
            PageSymbol(name: "person.crop.circle")
        } content: {
            VStack(spacing: 14) {
                if model.hasAuthData, let email = model.primaryAccount?.title {
                    DoneLine(text: email)
                    Button("Add Another Account") { model.beginSignIn() }
                } else {
                    Button("Sign In with Google") { model.beginSignIn() }
                        .buttonStyle(ProminentButtonStyle())
                }
                if case let .failed(message) = model.connectState {
                    Text(message).font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center)
                }
            }
        }
    }
}

private struct ChooseAlbumsPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        PageLayout(title: "Choose what to back up",
                   message: "All Photos covers your whole library. You can change this any time in Albums.") {
            PageSymbol(name: "rectangle.stack", tint: .orange)
        } content: {
            if !model.canReadPhotos {
                Text("Albums appear here once Photos access is allowed.").foregroundStyle(.secondary)
            } else {
                Card(padding: 0) {
                    ForEach(Array(model.albums.prefix(6).enumerated()), id: \.element.id) { index, album in
                        if index > 0 { Divider().padding(.leading, 52) }
                        HStack(spacing: 12) {
                            AlbumIcon(symbol: album.symbol, size: 28)
                            Text(album.title).lineLimit(1)
                            Spacer()
                            Toggle(album.title, isOn: Binding(get: { model.state.selectedAlbumIDs.contains(album.id) },
                                                              set: { _ in model.toggle(album) }))
                                .labelsHidden()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                }
            }
        }
    }
}

private struct DonePage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        PageLayout(title: "You're all set",
                   message: ready ? "Photos Backup keeps your selection backed up from here on. Start the first backup now, or let it begin by itself."
                                  : "Finish signing in and allowing Photos access, and backups start by themselves.") {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .green)
                .accessibilityHidden(true)
        } content: {
            if ready {
                Button {
                    model.finishOnboarding()
                    model.backUpNow()
                } label: {
                    Label("Back Up Now", systemImage: "arrow.up")
                }
                .buttonStyle(ProminentButtonStyle())
            }
        }
    }

    private var ready: Bool { model.hasAuthData && model.canReadPhotos }
}
