import PhotosBackupCore
import SwiftUI

/// Albums: what is backed up, chosen album by album. The selection is the
/// shared one in accounts.json (selectedAlbumIDs), as on the Mac.
struct AlbumsView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""

    var body: some View {
        content
            .navigationTitle("Albums")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await model.reloadAlbums() } } label: { Label("Reload", systemImage: "arrow.clockwise") }
                        .disabled(!model.canReadPhotos)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if !model.canReadPhotos {
            ContentUnavailableView {
                Label("Photos access is needed", systemImage: "photo.on.rectangle.angled")
            } description: {
                Text(model.photosStatus == .notDetermined
                     ? "Photos Backup reads the albums you choose and uploads copies. It never changes your library."
                     : "Turn on Photos for Photos Backup in Settings.")
            } actions: {
                if model.photosStatus == .notDetermined {
                    Button("Allow Access") { Task { await model.requestPhotosAccess() } }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Open Settings") { model.perform(.openAppSettings) }
                }
            }
        } else if !model.albumsLoaded {
            ProgressView("Reading your library…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.albums.isEmpty {
            ContentUnavailableView("No albums", systemImage: "rectangle.stack",
                                   description: Text("Your Photos library is empty."))
        } else {
            list
        }
    }

    private var list: some View {
        let library = filtered.filter { $0.snapshot.kind != .user }
        let mine = filtered.filter { $0.snapshot.kind == .user }
        return List {
            if query.isEmpty {
                Section {
                    AutomaticLine()
                } footer: {
                    Text(subtitle)
                }
                if model.photosStatus == .limited {
                    Section {
                        Banner(symbol: "photo.badge.exclamationmark",
                               text: "Photos Backup sees only the photos you shared with it, so each album lists those alone.",
                               color: .accentColor, title: "Limited access",
                               action: ("Choose", { PhotoLibrary.presentLimitedPicker() }))
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                }
            }
            if !library.isEmpty {
                Section("Library") {
                    ForEach(library) { AlbumToggleRow(album: $0) }
                }
            }
            if !mine.isEmpty {
                Section {
                    ForEach(mine) { AlbumToggleRow(album: $0) }
                } header: {
                    Text("My Albums")
                } footer: {
                    if model.settings.mirrorAlbums {
                        Text("Your own albums are recreated in Google Photos under the same name. Smart albums and All Photos back up their items only.")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $query, prompt: "Search albums")
        .overlay {
            if filtered.isEmpty { ContentUnavailableView.search(text: query) }
        }
    }

    private var filtered: [LibraryAlbum] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return model.albums }
        return model.albums.filter { $0.title.localizedStandardContains(trimmed) }
    }

    private var subtitle: String {
        let selected = model.state.selectedAlbumIDs.intersection(model.albums.map(\.id)).count
        return selected == 0 ? "No albums selected." : "\(selected.formatted()) album\(selected == 1 ? "" : "s") selected."
    }
}

/// Whether selected albums back up by themselves, with the switch.
private struct AutomaticLine: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Toggle(isOn: $model.settings.automatic) {
            HStack(spacing: 12) {
                Image(systemName: model.settings.automatic ? "arrow.triangle.2.circlepath" : "pause.circle")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(model.settings.automatic ? .green : .orange)
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Back up automatically")
                    Text(model.settings.automatic ? "Selected albums back up when Photos changes and when iOS gives the app time."
                                                  : "Selected albums back up when you choose Back Up Now.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct AlbumToggleRow: View {
    @Environment(AppModel.self) private var model
    let album: LibraryAlbum

    var body: some View {
        let selected = model.state.selectedAlbumIDs.contains(album.id)
        let progress = model.progress(of: album)
        AlbumRow(album: album, progress: progress, selected: selected, showsBar: true) {
            HStack(spacing: 12) {
                if selected { AlbumStatusMark(backedUp: progress.backedUp, total: progress.total) }
                Toggle("Back up \(album.title)", isOn: Binding(get: { selected }, set: { _ in model.toggle(album) }))
                    .labelsHidden()
            }
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
