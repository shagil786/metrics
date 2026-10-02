// Visual identity: ink + teal/amber/coral state palette. Color is always
// paired with a glyph or label so state never relies on hue alone.
import SwiftUI
import PortmasterCore

enum Theme {
    static let ink = Color.primary
    static let canvas = adaptive(light: 0xffffff, dark: 0x1b1b1b)
    static let card = adaptive(light: 0xf5f5f7, dark: 0x252525)
    static let chrome = adaptive(light: 0xf5f5f7, dark: 0x222222)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                           green: CGFloat((rgb >> 8) & 255) / 255,
                           blue: CGFloat(rgb & 255) / 255, alpha: 1)
        })
    }

    static func stateColor(_ level: MemoryPressureLevel) -> Color {
        switch level {
        case .normal: .teal
        case .elevated: .orange
        case .critical: .coral
        }
    }

    static func stateColor(cpuPercent: Double) -> Color {
        switch cpuPercent {
        case ..<50: .teal
        case ..<80: .orange
        default: .coral
        }
    }

    static func stateSymbol(_ level: MemoryPressureLevel) -> String {
        switch level {
        case .normal: "circle.checkmark"
        case .elevated: "circle.warning"
        case .critical: "circle.exclamation"
        }
    }

    static func stateWord(_ level: MemoryPressureLevel) -> String {
        switch level {
        case .normal: "Normal"
        case .elevated: "Elevated"
        case .critical: "Critical"
        }
    }
}

extension Color {
    /// Original accent: desaturated coral, distinct from system red.
    static let coral = Color(red: 0.88, green: 0.36, blue: 0.32)
    /// Secondary state hue for "normal" observations.
    static let teal = Color(red: 0.15, green: 0.55, blue: 0.52)
}

/// Small status dot + accessible word. Never color-only: the accompanying
/// text carries the state for VoiceOver and colorblind users.
struct StateDot: View {
    let color: Color
    let word: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(word)
                .font(.caption)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(word)
    }
}

/// Numerals in monospaced digits so values don't jiggle between samples.
struct MetricBadge: View {
    let label: String
    let value: String
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.4)
            Text(value)
                .font(.system(.title3, design: .monospaced).weight(.medium))
                .foregroundStyle(tint)
                .contentTransition(.numericText())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value)")
    }
}

/// Honest empty/loading/error state with an optional retry path.
struct EmptyStateView: View {
    let symbol: String
    let title: String
    let detail: String
    var buttonTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.title)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            if let buttonTitle, let action {
                Button(buttonTitle, action: action)
                    .buttonStyle(.bordered)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }
}

/// Non-blocking inline error banner.
struct ErrorBanner: View {
    let message: String
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(message)
                .font(.callout)
            Spacer()
            if let onDismiss {
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss error")
            }
        }
        .padding(8)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .combine)
    }
}

/// Section header with consistent, restrained styling.
struct SectionHeader: View {
    let title: String
    var accessory: AnyView? = nil

    init(title: String, @ViewBuilder accessory: () -> AnyView? = { nil }) {
        self.title = title
        self.accessory = accessory()
    }

    var body: some View {
        HStack {
            Text(title)
                .font(.headline)
            Spacer()
            accessory
        }
    }
}

/// Horizontal usage bar — the visual backbone of every list row.
struct CPUBar: View {
    let percent: Double
    var tint: Color
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                Capsule().fill(tint)
                    .frame(width: max(3, min(100, percent) / 100 * geo.size.width))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

extension View {
    /// Flat neutral surfaces match the reference in both system appearances.
    func cardBackground(cornerRadius: CGFloat = 10) -> some View {
        background(Theme.card, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}
