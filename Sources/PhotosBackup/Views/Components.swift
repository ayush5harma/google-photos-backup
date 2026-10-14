import AppKit
import SwiftUI

// The app's small design system: grouped panels, stat tiles, the progress
// ring, banners, the app mark and the glass helpers. Content surfaces are
// quiet fills like a grouped Form's sections; Liquid Glass is for chrome
// only (the menu bar panel's controls, bottom bars), gated on macOS 26.

enum Metrics {
    static let panelRadius: CGFloat = 12
    static let readableWidth: CGFloat = 760
    static let pagePadding: CGFloat = 24
    static let sectionSpacing: CGFloat = 20
}

extension Color {
    /// A grouped section's fill: white on the light window background, a
    /// lift above the dark one (controlBackgroundColor is darker than the
    /// window in Dark Mode, so it would read as a hole).
    static let panelFill = Color(nsColor: NSColor(name: "PanelFill") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.055)
            : NSColor.controlBackgroundColor
    })

    static let panelStroke = Color(nsColor: NSColor(name: "PanelStroke") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.07)
            : NSColor.black.withAlphaComponent(0.07)
    })

    /// Kept for views written against the first design.
    static let cardFill = panelFill
}

/// A grouped panel, the Mac counterpart of the iOS app's cards.
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

    /// The page layout every sidebar section shares.
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
                    .buttonStyle(.link)
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
                    .font(.system(size: 18))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .green)
            } else {
                ProgressRing(fraction: total == 0 ? 0 : Double(backedUp) / Double(total), lineWidth: 2.5)
                    .frame(width: 18, height: 18)
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
    var detail: String?

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
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
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
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(color.opacity(configuration.isPressed ? 0.28 : 0.15), in: Capsule())
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
                    .foregroundStyle(title == nil ? .primary : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let action {
                Button(action.title, action: action.run)
                    .controlSize(.regular)
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

struct AppMark: View {
    @Environment(\.colorScheme) private var colorScheme
    var size: CGFloat = 32
    private static let lightArtwork = loadArtwork(variant: "light")
    private static let darkArtwork = loadArtwork(variant: "dark")

    private static func loadArtwork(variant: String) -> NSImage? {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["PHOTOS_BACKUP_FIXTURE_ICON"],
           AppEnvironment.isSandboxed {
            let url = URL(fileURLWithPath: path)
            if variant == "dark" {
                let sibling = url.deletingLastPathComponent()
                    .appendingPathComponent(url.deletingPathExtension().lastPathComponent + "-dark")
                    .appendingPathExtension(url.pathExtension)
                if let artwork = NSImage(contentsOf: sibling) { return artwork }
            }
            return NSImage(contentsOf: url)
        }
        #endif
        if let url = Bundle.main.url(forResource: "AppIcon-\(variant)", withExtension: "png"),
           let artwork = NSImage(contentsOf: url) {
            return artwork
        }
        return Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
            .flatMap { NSImage(contentsOf: $0) }
    }

    var body: some View {
        Group {
            if let artwork = colorScheme == .dark ? Self.darkArtwork : Self.lightArtwork {
                Image(nsImage: artwork).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: "photo.on.rectangle.angled")
                    .resizable().scaledToFit().foregroundStyle(.blue)
                    .padding(size * 0.16)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Liquid Glass with fallbacks

extension View {
    /// The primary action in chrome: prominent glass on macOS 26, a
    /// prominent bordered button before it.
    @ViewBuilder
    func prominentGlassButton() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    func glassButton() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }

    /// A bar pinned to the bottom of a view: the system's soft edge on
    /// macOS 26, a bar background with a divider before it.
    @ViewBuilder
    func bottomBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        if #available(macOS 26, *) {
            safeAreaBar(edge: .bottom) { bar() }
        } else {
            safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Divider()
                    bar().background(.bar)
                }
            }
        }
    }
}

/// Adjacent glass controls, merged as one shape family on macOS 26.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
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

    /// "in 2 minutes" for a time still ahead; "shortly" once it has passed,
    /// never "Resumes 3 seconds ago" while a timed wait winds down.
    var comingDescription: String {
        timeIntervalSinceNow > 1 ? formatted(.relative(presentation: .named)) : "shortly"
    }
}
