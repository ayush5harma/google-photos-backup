import SwiftUI

/// The rounded panels the iOS app is built from.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.cardFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct SectionHeader: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack {
            Text(title).font(.headline).foregroundStyle(.secondary)
            Spacer()
            if let trailing { Text(trailing).font(.headline).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 4)
    }
}

/// Album glyph in a tinted square, as in the iOS album rows.
struct AlbumIcon: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(.tint)
            .frame(width: 42, height: 42)
            .background(.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// A ring that fills with progress; dashed while nothing is backed up yet
/// and a check mark once everything is.
struct ProgressRing<Center: View>: View {
    let fraction: Double
    var lineWidth: CGFloat = 3
    @ViewBuilder var center: Center

    var body: some View {
        ZStack {
            if fraction <= 0 {
                Circle().stroke(.tint, style: StrokeStyle(lineWidth: lineWidth, dash: [4, 4]))
            } else {
                Circle().stroke(.tint.opacity(0.18), lineWidth: lineWidth)
                Circle()
                    .trim(from: 0, to: min(fraction, 1))
                    .stroke(.tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            center
        }
        .animation(.easeInOut, value: fraction)
    }
}

extension ProgressRing where Center == EmptyView {
    init(fraction: Double, lineWidth: CGFloat = 3) {
        self.init(fraction: fraction, lineWidth: lineWidth) { EmptyView() }
    }
}

struct AlbumStatusMark: View {
    let backedUp: Int
    let total: Int

    var body: some View {
        if total > 0, backedUp >= total {
            Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.green)
        } else {
            ProgressRing(fraction: total == 0 ? 0 : Double(backedUp) / Double(total), lineWidth: 2.5)
                .frame(width: 22, height: 22)
        }
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
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(color.opacity(configuration.isPressed ? 0.32 : 0.2), in: Capsule())
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Capsule())
    }
}

struct Banner: View {
    let symbol: String
    let text: String
    let color: Color
    var action: (title: String, run: () -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.title3).foregroundStyle(color)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let action { Button(action.title, action: action.run) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

extension Color {
    /// Cards must read as raised in both appearances; the semantic
    /// background levels are too close to the window's own.
    static let cardFill = Color.primary.opacity(0.07)
}

extension Int64 {
    var byteString: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}
