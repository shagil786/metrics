// Live app breakdown, presented beside the current tab in the main window.
import SwiftUI
import PortmasterCore

struct InsideAppSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    /// The rollup the sheet was opened for. Only its identity is trusted;
    /// displayed values come from the latest snapshot so the sheet follows
    /// sampling while open.
    var sidebar: Bool = false
    let initial: AppRollup
    @State private var metric: Metric = .memory
    @State private var expanded: Set<String> = []

    enum Metric: String, CaseIterable, Identifiable {
        case memory, cpu
        var id: String { rawValue }
        var label: String { self == .cpu ? "CPU" : "Memory" }
    }

    init(rollup: AppRollup, sidebar: Bool = false) {
        self.initial = rollup
        self.sidebar = sidebar
    }

    /// Latest sampled rollup with the same identity; nil once the app quits.
    private var live: AppRollup? {
        model.snapshot.rollups.first { $0.id == initial.id }
    }

    /// Live values when the app is still running; the last-seen values
    /// (labelled as such in the header) after it exits.
    private var rollup: AppRollup { live ?? initial }

    var body: some View {
        let groups = AppBreakdown.build(for: rollup)
        let totalMemory = Double(rollup.totalMemory)
        let totalCPU = rollup.totalCPU

        VStack(alignment: .leading, spacing: 12) {
            header

            if sidebar {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Memory", systemImage: "memorychip").font(.system(size: 12, weight: .semibold)).foregroundStyle(.indigo)
                    Text(Fmt.bytes(rollup.totalMemory)).font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                    let total = model.snapshot.system.memory.totalBytes
                    let share = total > 0 ? Double(rollup.totalMemory) / Double(total) * 100 : 0
                    Text("\(Fmt.percent(share)) of this Mac's RAM").font(.system(size: 11)).foregroundStyle(.secondary)
                    CPUBar(percent: share, tint: .indigo, height: 5)
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading).cardBackground(cornerRadius: 12)
                HStack(spacing: 8) {
                    statChip("CPU", model.cpuText(rollup.totalCPU), "cpu", .blue)
                    statChip("Processes", "\(rollup.pidCount)", "square.stack.3d.up", .teal)
                }
            } else {
                HStack(spacing: 8) {
                    statChip("Memory", Fmt.bytes(rollup.totalMemory), "memorychip", .indigo)
                    statChip("CPU", model.cpuText(rollup.totalCPU), "cpu", .blue)
                    statChip("Processes", "\(rollup.pidCount)", "square.stack.3d.up", .teal)
                }
            }

            Divider()

            if groups.isEmpty {
                Text("Gathering process data for this app…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Inside \(rollup.displayName)")
                        .font(.headline)
                    Picker("Metric", selection: $metric) {
                        ForEach(Metric.allCases) { m in
                            Text(m.label).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .labelsHidden()
                    .accessibilityLabel("Show breakdown by \(metric.label)")
                }

                headlineSentence(groups, totalMemory: totalMemory, totalCPU: totalCPU)
                shareBar(groups, totalMemory: totalMemory, totalCPU: totalCPU)

                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(groups.enumerated()), id: \.element.id) { i, group in
                            groupRow(group, totalMemory: totalMemory, totalCPU: totalCPU)
                            if i < groups.count - 1 {
                                Divider().opacity(0.5)
                            }
                        }
                    }
                }

                if groups.contains(where: { $0.id == "tabs" }) {
                    Text("Browsers don't tell macOS which tab each helper draws, so same-kind helpers are counted together.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
        .frame(width: sidebar ? 340 : 560)
        .frame(height: sidebar ? nil : 470)
        .frame(maxHeight: sidebar ? .infinity : nil, alignment: .topLeading)
        .background(Theme.canvas)
        .onExitCommand { close() }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: 10) {
            AppIconView(bundlePath: rollup.isAppBundle ? rollup.id : nil, name: rollup.displayName)
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(rollup.displayName)
                    .font(.headline)
                    .lineLimit(1)
                Text(live == nil ? "No longer running — last observed values" : "App")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            }.buttonStyle(.plain).accessibilityLabel("Close app details")
        }
    }

    private func close() {
        if sidebar { model.selectedMenuApp = nil } else { dismiss() }
    }

    private func statChip(_ title: String, _ value: String, _ symbol: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(tint)
            Text(value).font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .cardBackground(cornerRadius: 12)
            .accessibilityElement(children: .ignore).accessibilityLabel("\(title): \(value)")
    }

    /// The reference sentence: "<Tabs> use 82% of its memory" — the largest
    /// group leads, and the verb follows the label's natural number.
    @ViewBuilder
    private func headlineSentence(
        _ groups: [AppBreakdownGroup], totalMemory: Double, totalCPU: Double
    ) -> some View {
        if let top = groups.first {
            let value = metric == .memory ? Double(top.memoryBytes) : top.cpuPercent
            let total = metric == .memory ? totalMemory : totalCPU
            if total > 0 {
                let share = Int((value / total * 100).rounded())
                Text("\(top.label) \(top.label.hasSuffix("s") ? "use" : "uses") \(share)% of its \(metric == .memory ? "memory" : "CPU")")
                    .font(.system(size: 15, weight: .semibold)).fixedSize(horizontal: false, vertical: true)

            }
        }
    }

    /// One capsule per group, widths proportional to the chosen metric.
    private func shareBar(
        _ groups: [AppBreakdownGroup], totalMemory: Double, totalCPU: Double
    ) -> some View {
        GeometryReader { geo in
            HStack(spacing: 1.5) {
                ForEach(groups) { group in
                    let value = metric == .memory ? Double(group.memoryBytes) : group.cpuPercent
                    let total = metric == .memory ? totalMemory : totalCPU
                    let fraction = total > 0 ? max(0.012, min(1, value / total)) : 0
                    Capsule()
                        .fill(groupTint(group.id))
                        .frame(width: max(4, fraction * (geo.size.width - CGFloat(groups.count) * 1.5)))
                }
            }
        }
        .frame(height: 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Share bar by group")
    }

    private func groupRow(
        _ group: AppBreakdownGroup, totalMemory: Double, totalCPU: Double
    ) -> some View {
        let value = metric == .memory ? Double(group.memoryBytes) : group.cpuPercent
        let total = metric == .memory ? totalMemory : totalCPU
        let share = total > 0 ? value / total * 100 : 0
        let isExpanded = expanded.contains(group.id)

        return VStack(spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    if isExpanded { expanded.remove(group.id) } else { expanded.insert(group.id) }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: groupSymbol(group.id))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(groupTint(group.id))
                        .frame(width: 26, height: 26)
                        .background(groupTint(group.id).opacity(0.16), in: RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(group.label)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text("\(group.count) process\(group.count == 1 ? "" : "es") · \(Fmt.bytes(group.averageMemoryBytes)) each")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !sidebar {
                        CPUBar(percent: share, tint: groupTint(group.id), height: 6).frame(width: 110)
                    }
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(metric == .memory ? Fmt.bytes(group.memoryBytes) : model.cpuText(group.cpuPercent))
                            .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                        Text(Fmt.percent(share)).font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                    }.frame(width: sidebar ? 60 : 78, alignment: .trailing)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(group.label), \(group.count) processes, \(Fmt.percent(share)) of \(metric.label)")
            .accessibilityHint(isExpanded ? "Collapses the process list" : "Expands the process list")

            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(group.processes) { row in
                        HStack(spacing: 8) {
                            Text(row.displayName)
                                .font(.caption)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            if !sidebar {
                                Text("PID \(row.pid)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Text(model.cpuText(row.cpuPercent))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 56, alignment: .trailing)
                            Text(Fmt.bytes(row.memoryBytes))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 76, alignment: .trailing)
                        }
                        .padding(.vertical, 4)
                        .padding(.leading, sidebar ? 10 : 36)
                        Divider().opacity(0.3)
                    }
                }
                .padding(.trailing, 4)
                .padding(.bottom, 6)
            }
        }
    }

    private func groupSymbol(_ id: String) -> String {
        switch id {
        case "tabs": "macwindow.on.rectangle"
        case "gpu": "square.3.layers.3d"
        case "extensions": "puzzlepiece.extension"
        case "network": "network"
        case "browser", "main": "app.fill"
        case "engine": "shippingbox"
        default: "ellipsis.circle"
        }
    }

    private func groupTint(_ id: String) -> Color {
        switch id {
        case "tabs": .blue
        case "gpu": .pink
        case "extensions": .orange
        case "network": .teal
        case "browser", "main": .indigo
        case "engine": .green
        default: .gray
        }
    }
}
