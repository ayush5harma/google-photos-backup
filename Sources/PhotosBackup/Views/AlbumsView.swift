import PhotosBackupCore
import SwiftUI

struct AlbumsView: View {
    @Environment(AppModel.self) private var model
    @Binding var section: AppSection

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Albums").font(.largeTitle.bold())
                SetupBanners(section: $section)
                Banner(symbol: "arrow.triangle.2.circlepath",
                       text: model.settings.automatic ? "Selected albums back up automatically" : "Selected albums back up when you choose Back Up Now",
                       color: .green)
                group("Library", model.albums.filter { $0.snapshot.kind != .user })
                group("My Albums", model.albums.filter { $0.snapshot.kind == .user })
                if model.settings.mirrorAlbums {
                    Text("Your own albums are recreated in Google Photos under the same name. Smart albums and All Photos only back up their items.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
            }
            .padding(24)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Albums")
        .toolbar {
            ToolbarItem {
                Text("\(model.state.selectedAlbumIDs.intersection(model.albums.map(\.id)).count) selected")
                    .foregroundStyle(.secondary)
            }
            ToolbarItem {
                Button { Task { await model.reloadAlbums() } } label: { Label("Reload", systemImage: "arrow.clockwise") }
                    .help("Read the Photos library again")
            }
        }
    }

    @ViewBuilder
    private func group(_ title: String, _ albums: [LibraryAlbum]) -> some View {
        if !albums.isEmpty {
            SectionHeader(title: title)
            VStack(spacing: 10) {
                ForEach(albums) { album in
                    let selected = model.state.selectedAlbumIDs.contains(album.id)
                    Button { model.toggle(album) } label: {
                        AlbumRow(album: album, progress: model.progress(of: album), selected: selected) {
                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                .font(.title2)
                                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 4)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
    }
}
