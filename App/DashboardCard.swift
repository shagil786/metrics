// Reference overview anatomy: small colored header, rounded numeral,
// compact submetrics and an unboxed line sparkline.
import SwiftUI
import Charts

struct DashboardCard<Footer: View>: View {
    let title: String
    var showsChevron = true
    let symbol: String
    let tint: Color
    let context: String
    let numeral: String
    let unit: String?
    /// Optional state chip beside the numeral (e.g. memory pressure).
    var chip: (text: String, color: Color)? = nil
    var subMetrics: [(String, String)]
    let footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint)
                Spacer()
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                }
            }.frame(height: 16)
            Text(context).font(.system(size: 11)).foregroundStyle(.secondary)
                .lineLimit(1).frame(height: 14, alignment: .leading)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(numeral)
                    .font(.system(size: 36, weight: .semibold, design: .rounded))
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                if let unit {
                    Text(unit).font(.system(size: 17, weight: .semibold)).foregroundStyle(.secondary)
                }
                if let chip {
                    Spacer(minLength: 4)
                    Text(chip.text).font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(chip.color).lineLimit(1).minimumScaleFactor(0.7)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(chip.color.opacity(0.15), in: Capsule())
                }
            }.frame(height: 40, alignment: .leading)
            HStack(alignment: .top, spacing: 8) {
                ForEach(subMetrics.indices, id: \.self) { i in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(subMetrics[i].0).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        Text(subMetrics[i].1).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }.frame(height: 30, alignment: .top)
            Spacer(minLength: 0)
            footer.frame(height: 30).frame(maxWidth: .infinity)
        }
        .padding(16)
        .frame(height: 208, alignment: .top)
        .cardBackground(cornerRadius: 16)
        .accessibilityElement(children: .contain)
    }
}

/// Overview cards use the reference's thin line and faint area, without a boxed strip.
struct OverviewSparkline: View {
    let values: [Double]
    let tint: Color
    var bars = false
    var fixedMax: Double?
    var placeholder: String = "Sampling…"

    var body: some View {
        if values.count >= 2 {
            Chart {
                ForEach(values.indices, id: \.self) { index in
                    if bars {
                        BarMark(x: .value("Sample", index), y: .value("Value", values[index]))
                            .foregroundStyle(tint.opacity(0.8))
                    } else {
                    AreaMark(x: .value("Sample", index), y: .value("Value", values[index]))
                        .foregroundStyle(.linearGradient(colors: [tint.opacity(0.15), tint.opacity(0.01)], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Sample", index), y: .value("Value", values[index]))
                        .foregroundStyle(tint).lineStyle(StrokeStyle(lineWidth: 1.4))
                    }
                }
            }
            .chartXAxis(.hidden).chartYAxis(.hidden)
            .chartYScale(domain: 0...max(1, fixedMax ?? (values.max() ?? 1) * 1.15))
            .accessibilityHidden(true)
        } else {
            Text(placeholder).font(.system(size: 10)).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Bar sparkline sized for the tinted strip; honest placeholder while the
/// buffer fills.
struct StripSparkline: View {
    let values: [Double]
    let tint: Color
    var fixedMax: Double?
    var placeholder: String = "Sampling…"

    var body: some View {
        Group {
            if values.count >= 2 {
                BarSparkline(values: values, tint: tint, fixedMax: fixedMax)
            } else {
                Text(placeholder)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}
