// One app, one line: totals across its helper processes, with a count.
import SwiftUI
import PortmasterCore

struct AppRollupLine: View {
    @EnvironmentObject private var model: AppModel
    let rollup: AppRollup
    let onDetails: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: rollup.isAppBundle ? "app.fill" : "terminal")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(rollup.displayName)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if rollup.pidCount > 1 {
                        Text("\(rollup.pidCount) processes")
                    } else {
                        Text("1 process")
                    }
                    if !rollup.projectIDs.isEmpty {
                        Text("·")
                        Text("project")
                            .foregroundStyle(.teal)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer()

            CPUBar(percent: model.processCPUValue(rollup.totalCPU) ?? 0, tint: Theme.stateColor(cpuPercent: rollup.totalCPU))
                .frame(width: 110)
            Text(model.cpuText(rollup.totalCPU))
                .monospacedDigit()
                .foregroundStyle(Theme.stateColor(cpuPercent: rollup.totalCPU))
                .frame(width: 64, alignment: .trailing)
            Text(Fmt.bytes(rollup.totalMemory))
                .monospacedDigit()
                .frame(width: 76, alignment: .trailing)
            Text(rollup.memberNames.count > 1
                 ? "\(rollup.memberNames.count) kinds"
                 : rollup.memberNames.first ?? "—")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 90, alignment: .trailing)
                .lineLimit(1)

            Button("Details") { onDetails() }
                .buttonStyle(.borderless)
                .controlSize(.small)
            Button("Stop…") { onStop() }
                .buttonStyle(.borderless)
                .controlSize(.small)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "\(rollup.displayName), \(rollup.pidCount) processes, CPU \(model.cpuText(rollup.totalCPU)), memory \(Fmt.bytes(rollup.totalMemory))"
        )
    }
}
