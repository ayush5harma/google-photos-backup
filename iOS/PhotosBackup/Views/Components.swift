import SwiftUI
import UIKit

// The Mac app's small design system (Sources/PhotosBackup/Views/Components.swift)
// on UIKit colours: grouped panels, stat tiles, the progress ring, banners
// and the app mark. Content surfaces are quiet fills like a grouped list's
// sections; Liquid Glass is left to the system chrome (tab bar, navigation
// bars), which adopts it by itself on iOS 26.

enum Metrics {
    static let panelRadius: CGFloat = 12
    /// The Mac's readable width: on iPad a page stays a column, not a banner.
    static let readableWidth: CGFloat = 760
    static let pagePadding: CGFloat = 16
    static let sectionSpacing: CGFloat = 20
}

extension Color {
    /// A grouped section's fill on the grouped background, light and dark.
    static let panelFill = Color(uiColor: .secondarySystemGroupedBackground)
    static let pageBackground = Color(uiColor: .systemGroupedBackground)
    static let panelStroke = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor.white.withAlphaComponent(0.07) : UIColor.black.withAlphaComponent(0.05)
    })
}

/// A grouped panel, as on the Mac.
struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .panelBackground()
    }
}

extension View {
    func panelBackground(radius: CGFloat = Metrics.panelRadius) -> some View {
        background {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Color.panelFill)
                .strokeBorder(Color.panelStroke, lineWidth: 1)
        }
    }

    /// The page layout every tab shares: a readable column on iPad.
    func readablePage() -> some View {
        padding(Metrics.pagePadding)
            .frame(maxWidth: Metrics.readableWidth)
            .frame(maxWidth: .infinity)
    }
}

struct SectionHeader: View {
    let title: String
    var trailing: String?
    var action: (title: String, run: () -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.headline)
            Spacer()
            if let trailing { Text(trailing).foregroundStyle(.secondary).monospacedDigit() }
            if let action {
                Button(action.title, action: action.run)
                    .font(.subheadline)
            }
        }
        .padding(.horizontal, 2)
    }
}

/// Album glyph in a tinted rounded square.
struct AlbumIcon: View {
    let symbol: String
    var size: CGFloat = 32
    var tint: Color = .accentColor

    var body: some View {
        Image(systemName: symbol)
            .symbolRenderingMode(.hierarchical)
            .font(.system(size: size * 0.45, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A ring that fills with progress, dashed while there is nothing yet.
/// Colour comes from the environment's tint.
struct ProgressRing<Center: View>: View {
    let fraction: Double
    var lineWidth: CGFloat = 3
    @ViewBuilder var center: Center
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if fraction <= 0 {
                Circle().stroke(.tint.opacity(0.5), style: StrokeStyle(lineWidth: lineWidth, dash: [lineWidth * 1.2, lineWidth * 1.6]))
            } else {
                Circle().stroke(.tint.opacity(0.16), lineWidth: lineWidth)
                Circle()
                    .trim(from: 0, to: min(fraction, 1))
                    .stroke(.tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            center
        }
        .padding(lineWidth / 2)
        .animation(reduceMotion ? nil : .smooth(duration: 0.5), value: fraction)
    }
}

extension ProgressRing where Center == EmptyView {
    init(fraction: Double, lineWidth: CGFloat = 3) {
        self.init(fraction: fraction, lineWidth: lineWidth) { EmptyView() }
    }
}

/// An album's progress at the end of its row: a check once complete.
struct AlbumStatusMark: View {
    let backedUp: Int
    let total: Int

    var body: some View {
        Group {
            if total > 0, backedUp >= total {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 20))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .green)
            } else {
                ProgressRing(fraction: total == 0 ? 0 : Double(backedUp) / Double(total), lineWidth: 2.5)
                    .frame(width: 20, height: 20)
            }
        }
        .accessibilityLabel(total > 0 && backedUp >= total ? "Backed up" : "\(backedUp) of \(total) backed up")
    }
}

/// A value with its label, the way the Overview reports counts.
struct StatTile: View {
    let value: String
    let label: String
    let symbol: String
    var tint: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(tint)
                .frame(height: 18)
            Text(value)
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .panelBackground()
        .accessibilityElement(children: .combine)
    }
}

/// A full-width capsule button tinted like the iOS Pause / Stop pair.
struct TintedButtonStyle: ButtonStyle {
    let color: Color
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(color.opacity(configuration.isPressed ? 0.28 : 0.15), in: Capsule())
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Capsule())
    }
}

/// The primary action: a full-width filled capsule in the accent colour.
struct ProminentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(Color.accentColor.opacity(configuration.isPressed ? 0.8 : 1), in: Capsule())
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Capsule())
    }
}

/// Something the person should know or do, with at most one action.
struct Banner: View {
    let symbol: String
    let text: String
    let color: Color
    var title: String?
    var action: (title: String, run: () -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 20))
                .foregroundStyle(color)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                if let title { Text(title).font(.headline) }
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(title == nil ? .primary : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let action {
                Button(action.title, action: action.run)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .tint(color == .secondary ? .accentColor : color)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous)
                .fill(color.opacity(0.09))
                .strokeBorder(color.opacity(0.22), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The app's icon artwork (AppMark in the asset catalog, light and dark).
struct AppMark: View {
    var size: CGFloat = 32

    var body: some View {
        Image("AppMark")
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// An initial in a circle: the account at a glance.
struct AccountAvatar: View {
    var size: CGFloat = 28
    let email: String?

    var body: some View {
        let initial = email?.first.map { String($0).uppercased() }
        ZStack {
            Circle().fill(initial == nil ? AnyShapeStyle(.quaternary) : AnyShapeStyle(Color.accentColor.gradient))
            if let initial {
                Text(initial)
                    .font(.system(size: size * 0.45, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.45))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

extension Int64 {
    var byteString: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}

extension Date {
    /// "5 minutes ago", "yesterday"; "just now" under a minute.
    var relativeDescription: String {
        if abs(timeIntervalSinceNow) < 60 { return "just now" }
        return formatted(.relative(presentation: .named))
    }

    /// "in 2 minutes" for a time still ahead; "shortly" once it has passed.
    var comingDescription: String {
        timeIntervalSinceNow > 1 ? formatted(.relative(presentation: .named)) : "shortly"
    }
}
