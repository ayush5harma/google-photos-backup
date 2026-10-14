import PhotosBackupCore
import SwiftUI

/// The menu bar item: one template symbol per state, and the run's percent
/// beside it while a backup moves (Settings > General can hide it).
/// Template images take the menu bar's own colour, so the item stays legible
/// in light and dark menu bars and over any wallpaper.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let status = model.status
        let engine = model.engine
        let cloud = model.iCloudMenuStatus
        let cloudActive = cloud.takesMenuBarLabel
        let moving = status.kind == .backingUp
        HStack(spacing: 4) {
            Image(systemName: cloudActive ? cloud.symbol : status.symbol)
                .symbolEffect(.pulse, options: .repeating,
                              isActive: (cloudActive ? cloud.phase == .backingUp : moving) && !reduceMotion)
            if model.settings.menuBarShowsProgress, cloudActive, let fraction = cloud.fraction {
                Text(fraction, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
            } else if model.settings.menuBarShowsProgress, !cloudActive, moving, engine.runTotal > 0 {
                Text(engine.runFraction, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(cloudActive ? "Photos Backup: iCloud Photos, \(cloud.headline)" : "Photos Backup: \(status.headline)")
    }
}
