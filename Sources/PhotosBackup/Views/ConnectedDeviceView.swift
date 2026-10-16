import PhotosBackupCore
import SwiftUI

/// Explicit import screen for media Image Capture can see on a connected
/// phone or camera. It intentionally does not call this an album browser.
struct ConnectedDeviceView: View {
    @Environment(AppModel.self) private var model
    @State private var selected = Set<String>()
    @State private var destinationAlbum = ""
    @State private var query = ""
    @State private var reclaimAfterVerification = false
    @State private var showReclaimConfirmation = false

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
                Text("The app copies originals into private temporary storage for upload, then removes those copies. Reclaim stays off unless every selected source original is independently read back from Google first.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }

            if !source.devices.isEmpty {
                Picker("Device", selection: Binding(
                    get: { source.selectedDeviceID ?? "" },
                    set: { id in
                        selected = []
                        source.selectDevice(id)
                    }
                )) {
                    Text("Choose a device").tag("")
                    ForEach(source.devices.filter(\.isConnected)) { device in
                        Text("\(device.name) · \(device.model)").tag(device.id)
                    }
                }
                .disabled(source.deviceSelectionLocked || model.engine.isActive)
                .help(source.deviceSelectionLocked
                      ? "The selected device stays fixed until this import finishes."
                      : "Choose the connected device to import from.")
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
                  prompt: Text("Google Photos album name (optional)"))
            .textFieldStyle(.roundedBorder)
        let blocker = source.reclaimBlocker(for: selected)
        Toggle("Remove verified originals from this device after backup", isOn: $reclaimAfterVerification)
            .disabled(blocker != nil)
            .help(blocker ?? "Requires an exact Google original readback before every deletion.")
        if let blocker {
            Text(blocker).font(.callout).foregroundStyle(.secondary)
        } else if reclaimAfterVerification {
            Text("Each selected item must match a fresh Google original download. iCloud Photos deletion may propagate to every synced device. Recently Deleted is never purged.")
                .font(.callout).foregroundStyle(.orange)
        }
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
                if reclaimAfterVerification {
                    showReclaimConfirmation = true
                } else {
                    startBackup(source)
                }
            } label: { Label("Back Up Selected", systemImage: "arrow.up") }
            .buttonStyle(.borderedProminent)
            .disabled(selected.isEmpty || model.engine.isActive || !model.hasAuthData)
        }
        .alert("Remove verified originals?", isPresented: $showReclaimConfirmation) {
            Button("Keep originals", role: .cancel) {}
            Button("Back Up and Remove Verified Originals", role: .destructive) { startBackup(source) }
        } message: {
            Text("Only items that match a fresh Google original readback will be removed. Every paired Live Photo component must be selected. If this iPhone uses iCloud Photos, removal can propagate to other devices. Recently Deleted is not purged.")
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

    private func startBackup(_ source: ConnectedDeviceSource) {
        let chosen = DeviceImportPlan.selected(source.items, ids: selected)
        model.engine.backUp(device: chosen, source: source, destinationAlbumName: destinationAlbum,
                            reclaimOriginals: reclaimAfterVerification)
    }
}
