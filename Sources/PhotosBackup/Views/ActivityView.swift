import SwiftUI

struct ActivityView: View {
    @Environment(AppModel.self) private var model
    @Binding var section: AppSection

    var body: some View {
        let engine = model.engine
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Activity").font(.largeTitle.bold())
                SetupBanners(section: $section)
                PickPhotosButton {
                    Card {
                        HStack(spacing: 14) {
                            AlbumIcon(symbol: "photo.badge.plus")
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Choose Photos or Videos").font(.title3.weight(.semibold))
                                Text("Back up a hand-picked selection now").foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .contentShape(Rectangle())
                }

                SectionHeader(title: "Queue Controls")
                Card {
                    if engine.phase == .paused || engine.phase == .pausing {
                        control("Resume Backup", "play.circle", .accentColor) { engine.resume() }
                    } else {
                        control("Pause After Current Uploads", "pause.circle", .accentColor) { engine.pauseAfterCurrent() }
                            .disabled(engine.phase != .running)
                    }
                    Divider().padding(.leading, 40)
                    control("Stop Backup", "stop.circle", .red) { model.stopBackup() }
                        .disabled((engine.phase == .idle && !model.isMessagesScanning) || engine.phase == .stopping)
                    Divider().padding(.leading, 40)
                    control("Clear Finished Uploads", "checkmark.circle", .accentColor) { engine.clearFinished() }
                        .disabled(!engine.activity.contains { $0.status.isFinished })
                }

                SectionHeader(title: "Uploads", trailing: "\(engine.remaining) remaining")
                Card {
                    HStack {
                        Text("Overall Progress").font(.headline)
                        Spacer()
                        Text(engine.runFraction, format: .percent.precision(.fractionLength(0))).foregroundStyle(.secondary)
                    }
                    ProgressView(value: engine.runFraction).padding(.top, 6)
                    if engine.activity.isEmpty {
                        Text("Nothing uploaded in this session yet.")
                            .foregroundStyle(.secondary)
                            .padding(.top, 16)
                    }
                    ForEach(engine.activity) { item in
                        Divider().padding(.vertical, 6)
                        ActivityRow(item: item)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Activity")
    }

    private func control(_ title: String, _ symbol: String, _ color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.title3)
                .foregroundStyle(color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ActivityRow: View {
    let item: ActivityItem

    var body: some View {
        HStack(spacing: 14) {
            icon
                .frame(width: 42, height: 42)
                .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.filename).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Text(item.status.label)
                    .foregroundStyle(isFailure ? Color.red : Color.secondary)
                    .lineLimit(2)
                    .help(item.status.label)
            }
            Spacer()
            if let size = item.size { Text(size.byteString).foregroundStyle(.secondary).monospacedDigit() }
        }
    }

    private var isFailure: Bool {
        if case .failed = item.status { true } else { false }
    }

    private var tint: Color {
        switch item.status {
        case .uploaded, .existing: .green
        case .failed: .red
        case .stopped: .secondary
        default: .accentColor
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch item.status {
        case .uploaded, .existing: Image(systemName: "checkmark").font(.title3.bold()).foregroundStyle(.green)
        case .failed: Image(systemName: "xmark").font(.title3.bold()).foregroundStyle(.red)
        case .stopped: Image(systemName: "stop.fill").foregroundStyle(.secondary)
        case let .uploading(fraction): ProgressRing(fraction: fraction, lineWidth: 3).padding(10)
        default: ProgressView().controlSize(.small)
        }
    }
}
