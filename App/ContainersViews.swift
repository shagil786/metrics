// Containers tab: Docker containers via the docker CLI, with the same
// honesty rules as every other surface — availability is reported verbatim
// (not installed / daemon down / running), rates appear only when docker
// stats answered, and nothing is fabricated when Docker is absent.
import SwiftUI
import Charts
import PortmasterCore

struct WindowContainersDetail: View {
    @EnvironmentObject private var model: AppModel
    @State private var stopContainer: DockerContainer?
    @State private var historyMetric = "Memory"

    var body: some View {
        content
            // A refresh kick when the tab opens: the slow lane runs on the
            // engine's cadence, so arriving cold means at most one wait.
            .onAppear { model.engine.refreshContainers() }
            .sheet(item: $stopContainer) { c in
                DockerStopSheet(container: c).environmentObject(model)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.snapshot.docker {
        case nil:
            VStack {
                EmptyStateView(
                    symbol: "shippingbox",
                    title: "Gathering container data",
                    detail: "Portmaster asks the docker CLI on a slow cadence. This fills in within a few seconds.",
                    buttonTitle: "Refresh",
                    action: { model.engine.refreshContainers() }
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(16)
        case .some(let docker):
            switch docker.availability {
            case .notInstalled:
                VStack {
                    EmptyStateView(
                        symbol: "shippingbox",
                        title: "Docker isn't installed",
                        detail: "Portmaster watches Docker through the docker CLI in its standard locations. Install Docker Desktop or OrbStack and this tab fills in.",
                        buttonTitle: "Refresh",
                        action: { model.engine.refreshContainers() }
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(16)
            case .daemonDown:
                VStack {
                    EmptyStateView(
                        symbol: "shippingbox",
                        title: "Docker isn't running",
                        detail: "The docker CLI is installed but its daemon did not answer. Start Docker Desktop (or your Docker runtime) and the container list appears.",
                        buttonTitle: "Refresh",
                        action: { model.engine.refreshContainers() }
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(16)
            case .running:
                runningContent(docker)
            }
        }
    }

    private func rate(_ value: Double?) -> String {
        value.map { Fmt.rate($0) } ?? "—"
    }

    private func historyValue(_ point: DockerHistory.Point) -> Double? {
        switch historyMetric {
        case "Network": return point.networkBytesPerSec.map { model.prefs.presentation.networkUnit == .bits ? $0 * 8 : $0 }
        case "Disk I/O": return point.diskBytesPerSec
        default: return point.memoryBytes.map(Double.init)
        }
    }

    private var historyChart: some View {
        let points = model.dockerHistory.points
        let measured = points.filter { historyValue($0) != nil }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Container history").font(.callout.weight(.semibold))
                Spacer()
                Picker("Metric", selection: $historyMetric) {
                    ForEach(["Memory", "Network", "Disk I/O"], id: \.self) { Text($0) }
                }.pickerStyle(.segmented).frame(width: 280)
            }
            if measured.count >= 2 {
                Chart(measured) { point in
                    PointMark(x: .value("Time", point.at), y: .value("Bytes", historyValue(point) ?? 0))
                        .foregroundStyle(by: .value("Container", point.name + " · " + point.containerID.prefix(6)))
                }
                .chartYAxisLabel(historyMetric == "Memory" ? "Bytes" : historyMetric == "Network" && model.prefs.presentation.networkUnit == .bits ? "Bits / second" : "Bytes / second")
                .frame(height: 120)
            } else {
                Text("Waiting for measured readings. Rates need two successful samples.")
                    .font(.caption).foregroundStyle(.secondary).frame(height: 120)
            }
            Text("Last 30 minutes of this session • Network: received + sent • Disk: read + written • Updated about every 15 seconds")
                .font(.caption2).foregroundStyle(.secondary)
        }.padding(12).cardBackground(cornerRadius: 12)
    }

    private func runningContent(_ docker: DockerSample) -> some View {
        let containers = docker.containers
        let running = docker.runningContainers
        let totalMemory = docker.totalMemoryBytes
        let totalCPU = containers.reduce(0.0) { $0 + ($1.cpuPercent ?? 0) }
        let allPorts = Array(Set(containers.flatMap(\.ports))).sorted()
        let sorted = containers.sorted { ($0.memoryBytes ?? 0) > ($1.memoryBytes ?? 0) }

        return ArrangedSections(scope: "containers", sections: [
            (id: "stats", title: "Statistics", view: AnyView(HStack(spacing: 12) {
                MiniStatCard(icon: "shippingbox", tint: .green, title: "Containers",
                             value: "\(running.count)", subText: "\(containers.count - running.count) stopped")
                MiniStatCard(icon: "memorychip", tint: .green, title: "Memory",
                             value: Fmt.bytes(totalMemory), subText: "In use by containers")
                MiniStatCard(icon: "cpu", tint: .green, title: "CPU",
                             value: Fmt.cpu(totalCPU), subText: "All containers")
                MiniStatCard(icon: "number", tint: .green, title: "Published Ports",
                             value: "\(allPorts.count)",
                             subText: allPorts.isEmpty ? "None" : allPorts.prefix(4).map(String.init).joined(separator: ", "))
            })),
            (id: "history", title: "History", view: AnyView(historyChart)),
            (id: "containers", title: "Containers", view: AnyView(VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Container").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Text("CPU").font(.callout).foregroundStyle(.secondary)
                    Text("Memory").font(.callout).foregroundStyle(.secondary)
                        .padding(.leading, 18)
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 8)

                if containers.isEmpty {
                    Text("No containers exist yet — docker reports an empty list.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 60, alignment: .center)
                        .padding(.bottom, 12)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(sorted.enumerated()), id: \.element.id) { i, c in
                                containerRow(c)
                                if i < sorted.count - 1 {
                                    Divider().opacity(0.5)
                                }
                            }
                            // Faint placeholder stripes below the rows, like
                            // the reference table — the card keeps its
                            // full-height layout without looking unfinished.
                            ForEach(0..<6, id: \.self) { _ in
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.primary.opacity(0.03))
                                    .frame(height: 26)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 10)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .cardBackground(cornerRadius: 14)))
        ])
        .padding(16)
    }

    private func containerRow(_ c: DockerContainer) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "shippingbox")
                .font(.system(size: 15))
                .foregroundStyle(c.isRunning ? .green : .secondary)
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.name)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text(c.image)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            ForEach(c.ports.prefix(4), id: \.self) { port in
                Text(verbatim: String(format: ":%d", port))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
            if c.ports.count > 4 {
                Text("+\(c.ports.count - 4)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text("Net ↓ " + model.networkText(c.networkInBytesPerSec) + " ↑ " + model.networkText(c.networkOutBytesPerSec))
                Text("Disk R " + rate(c.diskReadBytesPerSec) + " W " + rate(c.diskWriteBytesPerSec))
            }.font(.caption2).foregroundStyle(.secondary)
            Button("Stop…", role: .destructive) { stopContainer = c }
                .buttonStyle(.borderless)
                .disabled(!c.isRunning || model.prefs.fixtureMode)
            Text(c.statusText)
                .font(.callout)
                .foregroundStyle(c.isRunning ? .primary : .secondary)
                .frame(width: 90, alignment: .leading)
                .lineLimit(1)
            Text(Fmt.cpu(c.cpuPercent))
                .font(.system(size: 15, weight: .bold).monospacedDigit())
                .frame(width: 70, alignment: .trailing)
            Text(Fmt.bytes(c.memoryBytes))
                .font(.system(size: 15, weight: .bold).monospacedDigit())
                .frame(width: 90, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(c.name), \(c.statusText), CPU \(Fmt.cpu(c.cpuPercent)), memory \(Fmt.bytes(c.memoryBytes))")
    }
}
