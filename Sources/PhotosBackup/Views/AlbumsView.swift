import PhotosBackupCore
import SwiftUI

/// Albums: what is backed up, chosen album by album.
struct AlbumsView: View {
    @Environment(AppModel.self) private var model
    @Binding var section: AppSection
    @State private var query = ""

    var body: some View {
        content
            .navigationTitle("Albums")
            .navigationSubtitle(subtitle)
            .searchable(text: $query, placement: .toolbar, prompt: "Search albums")
            .toolbar {
                ToolbarItem {
                    Button { Task { await model.reloadAlbums() } } label: { Label("Reload", systemImage: "arrow.clockwise") }
                        .help("Read the Photos library again")
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
                     : "Turn on Photos Backup in System Settings > Privacy & Security > Photos.")
            } actions: {
                if model.photosStatus == .notDetermined {
                    Button("Allow Access") { Task { await model.requestPhotosAccess() } }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Open Privacy Settings") { model.perform(.openPhotosPrivacy) }
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
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds(.disabled)
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
        return selected == 0 ? "None selected" : "\(selected.formatted()) selected"
    }
}

/// Whether selected albums back up by themselves, with the switch.
private struct AutomaticLine: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Toggle(isOn: $model.settings.automatic) {
            HStack(spacing: 10) {
                Image(systemName: model.settings.automatic ? "arrow.triangle.2.circlepath" : "pause.circle")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(model.settings.automatic ? .green : .orange)
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Back up automatically")
                    Text(model.settings.automatic ? "Selected albums back up when Photos changes, and every 30 minutes."
                                                  : "Selected albums back up when you choose Back Up Now.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.switch)
        .padding(.vertical, 4)
    }
}

private struct AlbumToggleRow: View {
    @Environment(AppModel.self) private var model
    let album: LibraryAlbum

    var body: some View {
        let selected = model.state.selectedAlbumIDs.contains(album.id)
        let progress = model.progress(of: album)
        // The switch beside the row rather than as its label, so it centres
        // on the row instead of sitting on the first line.
        AlbumRow(album: album, progress: progress, selected: selected, showsBar: true) {
            HStack(spacing: 14) {
                if selected { AlbumStatusMark(backedUp: progress.backedUp, total: progress.total) }
                Toggle("Back up \(album.title)", isOn: Binding(get: { selected }, set: { _ in model.toggle(album) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
