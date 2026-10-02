// SystemCard: the reference-style category card — icon + label, big numeral,
// sub-metrics, and a bar sparkline built from a small in-memory ring buffer.
// Only real samples are drawn; the buffer holds what was observed.
import SwiftUI
import Charts
import PortmasterCore

/// In-memory per-metric history for bar sparklines (not persisted).
final class SparklineBuffer: ObservableObject {
    @Published private(set) var values: [Double] = []
    let capacity: Int

    init(capacity: Int = 40) { self.capacity = capacity }

    func push(_ value: Double) {
        values.append(value)
        if values.count > capacity {
            values.removeFirst(values.count - capacity)
        }
    }
}

struct SystemCard: View {
    let title: String
    let symbol: String
    let tint: Color
    let headline: String
    let unit: String?
    var subMetrics: [(String, String)] = []
    let footer: AnyView

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.headline)
                Spacer()
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(headline)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let unit {
                    Text(unit)
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title) \(headline)\(unit != nil ? " " + unit! : "")")

            if !subMetrics.isEmpty {
                HStack(spacing: 0) {
                    ForEach(subMetrics.indices, id: \.self) { i in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(subMetrics[i].0)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(subMetrics[i].1)
                                .font(.callout.monospacedDigit().weight(.medium))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            footer
        }
        .padding(14)
        .cardBackground(cornerRadius: 12)
        .accessibilityElement(children: .contain)
    }
}

/// Lightweight chart card wrapper (History tab).
struct ChartCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            content
                .frame(height: 120)
        }
        .padding(12)
        .cardBackground(cornerRadius: 12)
        .accessibilityElement(children: .contain)
    }
}

/// Vertical bar sparkline (no animation; values only).
/// The X domain is FIXED to the buffer capacity with fixed-width bars, so
/// early samples pack from the left edge and the strip looks like a dense
/// history from the first sample — instead of 3 bars stretched across the
/// full width (Charts' automatic domain did that).
struct BarSparkline: View {
    let values: [Double]
    let tint: Color
    /// Scale ceiling; nil = max of data (min 1.0).
    var fixedMax: Double?
    /// X domain size; match the buffer capacity for left-packed bars.
    var domainCount: Int = 40

    var body: some View {
        let maxValue = fixedMax ?? max(1.0, (values.max() ?? 1) * 1.1)
        let domain = max(2, domainCount) - 1
        Chart {
            ForEach(0..<max(1, values.count), id: \.self) { i in
                BarMark(
                    x: .value("Index", i),
                    y: .value("Value", min(values[i], maxValue)),
                    width: .fixed(3)
                )
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .foregroundStyle(tint.opacity(0.85))
        .chartYScale(domain: 0...maxValue)
        .chartXScale(domain: 0...Double(domain))
        .accessibilityHidden(true)
    }
}

/// Area sparkline for continuous series (network, memory).
struct AreaSparkline: View {
    let values: [Double]
    let tint: Color
    var fixedMax: Double?

    var body: some View {
        let maxValue = fixedMax ?? max(1.0, (values.max() ?? 1) * 1.1)
        Chart {
            ForEach(0..<max(1, values.count), id: \.self) { i in
                AreaMark(
                    x: .value("Index", i),
                    y: .value("Value", min(values[i], maxValue))
                )
                .foregroundStyle(
                    .linearGradient(
                        colors: [tint.opacity(0.35), tint.opacity(0.05)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .interpolationMethod(.catmullRom)
                LineMark(
                    x: .value("Index", i),
                    y: .value("Value", min(values[i], maxValue))
                )
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(lineWidth: 1.8))
                .interpolationMethod(.catmullRom)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: 0...maxValue)
        .accessibilityHidden(true)
    }
}
