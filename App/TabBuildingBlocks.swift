// Shared building blocks for the reference-style detail tabs: full-width
// hero (context numeral + stat rows + live area chart), a four-card stat
// strip, and a full-width per-app table. CPU, Memory, Disk, Network, and
// GPU tabs all compose these; figures stay per-tab real data.
import SwiftUI
import Charts

// MARK: - Area chart (hero)

/// Smoothed area + line from real samples; the optional dashed rule is a
/// persisted average (day mean) where history exists. Isolated into its own
/// struct so the Charts expression type-checks fast (a large inline Chart
/// inside a big body blows the compiler's time budget).
struct MetricAreaChartView: View {
    let values: [Double]
    /// Persisted average drawn as the reference's dashed line, if known.
    var mean: Double? = nil
    let tint: Color
    /// Y-domain floor: CPU is naturally 0–100; memory GB and MB/s are not.
    var domainMax: Double = 100

    private struct Point: Identifiable {
        let id: Int
        let v: Double
    }

    private var points: [Point] {
        (0..<values.count).map { Point(id: $0, v: values[$0]) }
    }

    var body: some View {
        if values.count >= 2 {
            chart
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(tint.opacity(0.06))
                Text("Gathering samples…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var chart: some View {
        let top = max(domainMax, (values.max() ?? 0) + domainMax * 0.1)
        return Chart {
            ForEach(points) { p in
                AreaMark(
                    x: .value("Sample", p.id),
                    y: .value("Value", p.v)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(.linearGradient(
                    colors: [tint.opacity(0.18), tint.opacity(0.01)],
                    startPoint: .top, endPoint: .bottom
                ))
            }
            ForEach(points) { p in
                LineMark(
                    x: .value("Sample", p.id),
                    y: .value("Value", p.v)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            if let mean {
                RuleMark(y: .value("Average", mean))
                    .foregroundStyle(tint.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: 0...top)
    }
}

// MARK: - Hero card

/// Full-width hero: label + big numeral + unit on the left, two stat rows
/// beneath, and the live area chart filling the rest — the reference's
/// "Now 27% / Average today / Load" anatomy, tinted per tab.
struct TabHeroCard<Chart: View>: View {
    let label: String
    let numeral: String
    let unit: String
    let tint: Color
    let rows: [(String, String)]
    @ViewBuilder let chart: Chart

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(numeral)
                            .font(.system(size: 40, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                        Text(unit)
                            .font(.system(size: 18, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                            // Long units ("plugged in") must never wrap
                            // mid-phrase in the 170pt hero column.
                            .fixedSize(horizontal: true, vertical: false)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(rows.indices, id: \.self) { i in
                        HStack {
                            Text(rows[i].0).font(.callout).foregroundStyle(.secondary)
                            Spacer()
                            Text(rows[i].1)
                                .font(.callout.monospacedDigit().weight(.semibold))
                        }
                    }
                }
            }
            .frame(width: 170, alignment: .leading)

            chart
                .frame(height: 144)
                .frame(maxWidth: .infinity)
        }
        .padding(16)
        .cardBackground(cornerRadius: 14)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Mini stat card

/// One card of the four-card strip: tinted icon tile + title, big numeral,
/// and a context line (or custom content for chips/icons).
struct MiniStatCard<Sub: View>: View {
    let icon: String
    let tint: Color
    let title: String
    let value: String
    @ViewBuilder let sub: Sub

    init(icon: String, tint: Color, title: String, value: String,
         @ViewBuilder sub: () -> Sub) {
        self.icon = icon; self.tint = tint; self.title = title
        self.value = value; self.sub = sub()
    }

    init(icon: String, tint: Color, title: String, value: String, subText: String)
    where Sub == Text {
        self.icon = icon; self.tint = tint; self.title = title
        self.value = value; self.sub = Text(subText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title).font(.system(size: 12, weight: .medium))
                Spacer()
            }
            Text(value)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            sub
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground(cornerRadius: 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(value)")
    }
}

// MARK: - Per-app table

/// Full-width reference table: "App / Metric" header, rows of
/// icon · name (+ context line) · value · bar. Bars scale to the top row.
struct AppTableCard: View {
    @EnvironmentObject private var model: AppModel
    let metricLabel: String
    let tint: Color
    let rows: [Row]
    /// When true (default), the row list scrolls INSIDE the card: the tab
    /// layout pins the hero and card strip and gives this card all remaining
    /// height, so only the apps data scrolls — the header never moves.
    var scrollable: Bool = true

    struct Row: Identifiable {
        let id: String
        let name: String
        /// Icon source: bundle path for apps, nil falls back to a symbol.
        let bundlePath: String?
        let fallbackSymbol: String
        let context: String
        let value: String
        /// 0...1 share of the top row, for the bar fill.
        let fraction: Double
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("App")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(metricLabel)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)

            if rows.isEmpty {
                Text("Nothing significant in the current sample.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .center)
                    .padding(.bottom, 12)
            } else if scrollable {
                ScrollView {
                    rowsList
                        .padding(.horizontal, 8)
                        .padding(.bottom, 10)
                }
            } else {
                rowsList
                    .padding(.horizontal, 8)
                    .padding(.bottom, 10)
            }
        }
        .cardBackground(cornerRadius: 14)
        .accessibilityElement(children: .contain)
    }

    private var rowsList: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                Button {
                    if let app = model.snapshot.rollups.first(where: { $0.id == row.id }) { model.openApp(app) }
                } label: { rowView(row).contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .help("Open Inside \(row.name)")
                .accessibilityLabel("\(row.name), \(row.context), \(row.value)")
                .accessibilityHint("Opens app details")
                if i < rows.count - 1 {
                    Divider().opacity(0.5)
                }
            }
        }
    }

    private func rowView(_ row: Row) -> some View {
        HStack(spacing: 12) {
            iconView(row)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(row.context)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 5) {
                Text(row.value)
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                CPUBar(percent: min(1, max(0, row.fraction)) * 100, tint: tint, height: 5)
                    .frame(width: 140)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.name), \(row.context), \(row.value)")
    }

    @ViewBuilder
    private func iconView(_ row: Row) -> some View {
        if let bundlePath = row.bundlePath {
            Image(nsImage: NSWorkspace.shared.icon(forFile: bundlePath))
                .resizable()
        } else {
            Image(systemName: row.fallbackSymbol)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
        }
    }
}
