import AppKit
import PhotosBackupCore
import SwiftUI

struct WelcomePage: View {
    var body: some View {
        OnboardingPageLayout(title: "Welcome to Photos Backup",
                             message: "Your Photos library, kept safe in Google Photos.") {
            AppMark(size: 92)
                .shadow(color: .accentColor.opacity(0.25), radius: 16, y: 8)
        } content: {
            VStack(alignment: .leading, spacing: 18) {
                FeatureRow(symbol: "photo.on.rectangle.angled", tint: .accentColor, title: "Back up your library",
                           text: "Photos and videos you choose go to Google Photos in original quality, and new ones follow on their own.")
                FeatureRow(symbol: "rectangle.stack", tint: .orange, title: "Recreate your albums",
                           text: "Albums you made in Photos appear in Google Photos under the same names.")
                FeatureRow(symbol: "message", tint: .green, title: "Keep Messages safe",
                           text: "If you like, archive your conversations to a folder on this Mac and back up their photos too.")
            }
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
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct PhotosAccessPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        OnboardingPageLayout(title: "Allow access to Photos",
                             message: "Photos Backup reads the albums you choose and uploads copies. It never changes or deletes anything in your library.") {
            OnboardingSymbol(name: "photo.on.rectangle.angled")
        } content: {
            if model.canReadPhotos {
                OnboardingDone(text: "Photos Backup can read your library")
            } else if model.photosStatus == .notDetermined {
                Button("Allow Access") { Task { await model.requestPhotosAccess() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            } else {
                VStack(spacing: 12) {
                    Text("Access is turned off. Turn on Photos Backup in System Settings > Privacy & Security > Photos.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Open Privacy Settings") { model.perform(.openPhotosPrivacy) }
                        .controlSize(.large)
                }
            }
        }
    }
}

struct AccountPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        OnboardingPageLayout(title: "Connect Google Photos",
                             message: "Sign in on Google's own page. The account stays in your keychain on this Mac.") {
            OnboardingSymbol(name: "person.crop.circle", tint: .accentColor)
        } content: {
            VStack(spacing: 14) {
                if model.hasAuthData {
                    HStack(spacing: 12) {
                        AccountAvatar(size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.accountEmail ?? "Google account").font(.headline)
                            if case let .failed(message) = model.account {
                                Text(message).font(.callout).foregroundStyle(.orange).lineLimit(2)
                            } else {
                                Text("Connected").font(.callout).foregroundStyle(.green)
                            }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: 360)
                    .panelBackground()
                    Button("Use Another Account…") { model.beginSignIn() }
                        .buttonStyle(.link)
                } else {
                    Button("Sign In with Google…") { model.beginSignIn() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(model.connectState == .connecting)
                    if case let .failed(message) = model.connectState {
                        Text(message).font(.callout).foregroundStyle(.orange).multilineTextAlignment(.center)
                    }
                }
            }
        }
    }
}

struct ChooseAlbumsPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        OnboardingPageLayout(title: "Choose what to back up",
                             message: "All Photos covers your whole library. You can change this any time in Albums.") {
            OnboardingSymbol(name: "rectangle.stack", tint: .orange)
        } content: {
            if !model.canReadPhotos {
                Text("Albums appear here once Photos access is allowed.")
                    .foregroundStyle(.secondary)
            } else if !model.albumsLoaded {
                ProgressView()
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(model.albums.enumerated()), id: \.element.id) { index, album in
                            if index > 0 { Divider().padding(.leading, 46) }
                            Toggle(isOn: Binding(get: { model.state.selectedAlbumIDs.contains(album.id) },
                                                 set: { _ in model.toggle(album) })) {
                                HStack(spacing: 10) {
                                    AlbumIcon(symbol: album.symbol, size: 26)
                                    Text(album.title).lineLimit(1)
                                    Spacer()
                                    Text(album.snapshot.assetIDs.count.formatted())
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                            }
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                        }
                    }
                }
                .frame(maxHeight: 210)
                .panelBackground()
            }
        }
    }
}

struct MessagesPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        OnboardingPageLayout(title: "Keep your messages safe",
                             message: "Optional. Both stay off unless you turn them on, and you can change them in Settings.") {
            OnboardingSymbol(name: "message", tint: .green)
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                VStack(spacing: 0) {
                    Toggle(isOn: Binding(get: { model.settings.messagesMedia }, set: { model.setMessagesMedia($0) })) {
                        OptionLabel(title: "Back up photos and videos from Messages",
                                    text: "Copies go to Google Photos. Message text never leaves your Mac.")
                    }
                    .padding(12)
                    Divider().padding(.leading, 12)
                    Toggle(isOn: Binding(get: { model.settings.messagesArchive },
                                         set: { $0 ? model.archive.turnOn() : model.archive.turnOff() })) {
                        OptionLabel(title: "Archive my conversations on this Mac",
                                    text: "A readable copy of every chat, updated daily, in a Messages Archive folder in your home folder.")
                    }
                    .padding(12)
                }
                .toggleStyle(.switch)
                .panelBackground()
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "lock.shield").foregroundStyle(.secondary).font(.title3)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("macOS keeps Messages private until you give Photos Backup Full Disk Access.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Open Full Disk Access") { model.openFullDiskAccess() }
                            .buttonStyle(.link)
                    }
                }
                .font(.callout)
                .opacity(model.settings.messagesMedia || model.settings.messagesArchive ? 1 : 0.6)
            }
        }
    }
}

private struct OptionLabel: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct StartupPage: View {
    @Environment(AppModel.self) private var model
    @State private var loginItem = LoginItem.shared

    var body: some View {
        @Bindable var model = model
        OnboardingPageLayout(title: "Menu bar and startup",
                             message: "Photos Backup works from the menu bar, so backups carry on with the window closed.") {
            OnboardingSymbol(name: "menubar.rectangle", tint: .indigo)
        } content: {
            VStack(spacing: 0) {
                Toggle(isOn: Binding(get: { loginItem.state == .enabled || loginItem.state == .requiresApproval },
                                     set: { loginItem.setEnabled($0) })) {
                    OptionLabel(title: "Open at login", text: "Start in the menu bar when you log in.")
                }
                .disabled(loginItem.state == .unavailable)
                .padding(12)
                Divider().padding(.leading, 12)
                Toggle(isOn: Binding(get: { model.settings.showInDock }, set: { show in
                    model.settings.showInDock = show
                    NSApp.setActivationPolicy(show ? .regular : .accessory)
                    DispatchQueue.main.async { NSApp.activate() }
                })) {
                    OptionLabel(title: "Show in Dock", text: "Or keep Photos Backup in the menu bar only.")
                }
                .padding(12)
                Divider().padding(.leading, 12)
                Toggle(isOn: Binding(get: { model.notifier.authorization == .allowed && model.settings.notifyWhenFinished },
                                     set: { on in
                                         model.settings.notifyWhenFinished = on
                                         model.settings.notifyAboutProblems = on
                                         if on { model.notifier.requestAuthorization() }
                                     })) {
                    OptionLabel(title: "Allow notifications", text: "When a backup finishes, and when something needs you.")
                }
                .disabled(model.notifier.authorization == .unavailable || model.notifier.authorization == .denied)
                .padding(12)
            }
            .toggleStyle(.switch)
            .panelBackground()
            .task { loginItem.refresh() }
        }
    }
}

struct DonePage: View {
    @Environment(AppModel.self) private var model
    let finish: () -> Void

    var body: some View {
        OnboardingPageLayout(title: "You're all set",
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
                    model.startBackupNow()
                    finish()
                } label: {
                    Label("Back Up Now", systemImage: "arrow.up")
                        .padding(.horizontal, 10)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.extraLarge)
            }
        }
    }

    private var ready: Bool { model.hasAuthData && model.canReadPhotos }
}
