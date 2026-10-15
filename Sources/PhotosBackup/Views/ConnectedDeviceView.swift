import PhotosBackupCore
import SwiftUI

/// Explicit import screen for media Image Capture can see on a connected
/// phone or camera. It intentionally does not call this an album browser.
struct ConnectedDeviceView: View {
    @Environment(AppModel.self) private var model
    @State private var selected = Set<String>()
    @State private var destinationAlbum = ""
    @State private var query = ""

    var body: some View {
        let source = model.connectedDevice
        VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Connected device").font(.largeTitle.weight(.semibold))
                    Text(source.status.message).foregroundStyle(.secondary)
                }
                Spacer()
                Button { source.refresh(); selected = [] } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            }

            Card {
                Label("Choose individual photos and videos exposed by the connected device. Device albums are not available through Image Capture.", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
                Text("The app copies originals into private temporary storage for upload, then removes those copies. It never deletes from the device. iCloud Photos deletion would affect every synced device and remains unavailable until each uploaded original is independently verified.")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.top, 6)
            }

            switch source.status {
            case .ready, .importing:
                importList(source)
            case .searching:
                Spacer(); ProgressView("Looking for a connected device…").frame(maxWidth: .infinity)
            case .locked, .unavailable:
                Spacer(); ContentUnavailableView("Device media unavailable", systemImage: "iphone.slash",
                                                  description: Text(source.status.message))
                    .frame(maxWidth: .infinity)
            }
        }
        .readablePage()
        .navigationTitle("Connected device")
        .onChange(of: source.items.map(\.id)) { _, available in
            selected.formIntersection(Set(available))
        }
    }

    @ViewBuilder
    private func importList(_ source: ConnectedDeviceSource) -> some View {
        let visible = filtered(source.items)
        HStack {
            Text("\(selected.count.formatted()) selected").foregroundStyle(.secondary)
            Spacer()
            Button("Select visible") { selected.formUnion(visible.map(\.id)) }
            Button("Clear") { selected = [] }.disabled(selected.isEmpty)
        }
        TextField("Google Photos album name (optional)", text: $destinationAlbum,
                  prompt: Text("Creates or uses an album with this name"))
            .textFieldStyle(.roundedBorder)
        List(visible, selection: $selected) { item in
            HStack(spacing: 12) {
                Image(systemName: item.isMovie ? "video" : "photo")
                    .frame(width: 20).foregroundStyle(.secondary)
                VStack(alignment: .leading) {
                    Text(item.filename).lineLimit(1).truncationMode(.middle)
                    Text(detail(item)).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .tag(item.id)
        }
        .searchable(text: $query, prompt: "Search file names")
        HStack {
            Spacer()
            Button {
                let chosen = DeviceImportPlan.selected(source.items, ids: selected)
                model.engine.backUp(device: chosen, source: source, destinationAlbumName: destinationAlbum)
            } label: { Label("Back Up Selected", systemImage: "arrow.up") }
            .buttonStyle(.borderedProminent)
            .disabled(selected.isEmpty || model.engine.isActive || !model.hasAuthData)
        }
    }

    private func filtered(_ items: [DeviceMediaItem]) -> [DeviceMediaItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? items : items.filter { $0.filename.localizedStandardContains(trimmed) }
    }

    private func detail(_ item: DeviceMediaItem) -> String {
        let type = item.isMovie ? "Video" : "Photo"
        let date = item.createdAt.map { " · \($0.formatted(date: .abbreviated, time: .omitted))" } ?? ""
        return "\(type) · \(ByteCountFormatter.string(fromByteCount: item.byteCount, countStyle: .file))\(date)"
    }
}
