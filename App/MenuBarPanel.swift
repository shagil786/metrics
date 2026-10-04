// Menu bar panel: working navigation — Overview grid plus per-metric detail
// screens. Width is fixed at 340pt; height MEASURES the content's natural
// size (fixedSize + GeometryReader) so the window ends exactly at the
// controls — no estimated heights, no dead space. GPU shows "—" honestly:
// macOS exposes no supported utilization metric.
import SwiftUI
import PortmasterCore

enum PanelTab: String, CaseIterable {
    case overview, cpu, memory, disk, network, gpu, battery, sensors, services, files, containers, audio, bluetooth
}

struct MenuBarPanel: View {
    @EnvironmentObject private var model: AppModel
    /// Supported way to open the SwiftUI Settings scene (macOS 14+).
    @Environment(\.openSettings) private var openSettings

    private var snap: ObservationSnapshot { model.snapshot }

    @State private var hoveredCard: String?
    /// Initial tab: .overview normally; PORTMASTER_PANEL_TAB=<tab> overrides
    /// (debug/UI-testing affordance, same spirit as PORTMASTER_TAB).
    @State private var tab: PanelTab = {
        if let raw = ProcessInfo.processInfo.environment["PORTMASTER_PANEL_TAB"]?.lowercased(),
           let t = PanelTab(rawValue: raw) {
            return t
        }
        return .overview
    }()

    private let panelWidth: CGFloat = 340
    /// Content reports its real height; the window uses exactly that.
    @State private var contentHeight: CGFloat = 552

    var body: some View {
        // Inner VStack: natural height only — fixedSize breaks the circular
        // constraint (an outer frame height would otherwise stretch this view
        // to that height and the measurement would just echo it).
        VStack(alignment: .leading, spacing: 7) {
            navTiles
            header
            content
            if model.engine.isPaused {
                pausedBadge
            }
            controls
        }
        .padding(9)
        .background(model.prefs.presentation.glass ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(Color(nsColor: .windowBackgroundColor)))
        .frame(width: panelWidth)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { contentHeight = geo.size.height; NotificationCenter.default.post(name: .portmasterPanelSize, object: NSSize(width: panelWidth, height: geo.size.height)) }
                    .onChange(of: geo.size.height) { contentHeight = $1; NotificationCenter.default.post(name: .portmasterPanelSize, object: NSSize(width: panelWidth, height: $1)) }
            }
        )
        // The window frame equals the measured natural height exactly.
        .frame(width: panelWidth, height: contentHeight, alignment: .top)
        .onAppear {
            if !visibleTabs.contains(tab) { tab = visibleTabs.first ?? .overview }
            model.start()
            if ProcessInfo.processInfo.environment["PORTMASTER_POPOVER"] == "1" { model.surfaceAppeared() }
        }
        .onChange(of: visibleTabs) { _, tabs in if !tabs.contains(tab) { tab = tabs.first ?? .overview } }
        .onReceive(NotificationCenter.default.publisher(for: .portmasterPanelNavigate)) { note in
            if let index = note.object as? Int, visibleTabs.indices.contains(index) { tab = visibleTabs[index] }
        }
        .onReceive(NotificationCenter.default.publisher(for: .portmasterPanelStep)) { note in
            guard let delta = note.object as? Int, let index = visibleTabs.firstIndex(of: tab), !visibleTabs.isEmpty else { return }
            tab = visibleTabs[(index + delta + visibleTabs.count) % visibleTabs.count]
        }
        .onDisappear {
            if ProcessInfo.processInfo.environment["PORTMASTER_POPOVER"] == "1" { model.surfaceDisappeared() }
        }
    }

    // MARK: - Nav + header

    private var visibleTabs: [PanelTab] {
        model.prefs.presentation.panelTabs.visible(PanelTab.allCases.map(\.rawValue)).compactMap(PanelTab.init(rawValue:))
    }
    private var navTiles: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 1) {
                ForEach(visibleTabs, id: \.rawValue) { tile($0.symbol, tab: $0) }
            }.padding(3)
        }.frame(height: 30).cardBackground(cornerRadius: 10)
    }

    private func tile(_ symbol: String, tab t: PanelTab) -> some View {
        let active = tab == t
        let tint = Self.tabTint(t)
        return Button { withAnimation(.easeOut(duration: 0.12)) { tab = t } } label: {
            Image(systemName: symbol).font(.footnote)
                .foregroundStyle(active ? Color.white : .secondary)
                .frame(width: 22, height: 22)
                .background(active ? tint : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).help(t.rawValue.capitalized)
            .accessibilityLabel("\(t.rawValue.capitalized) tab")
            .accessibilityAddTraits(active ? .isSelected : [])
    }

    /// Per-tab accent: the active pill takes the metric's color, matching the
    /// reference (blue CPU, orange Disk, green Network, …).
    static func tabTint(_ t: PanelTab) -> Color {
        switch t {
        case .overview: return .blue
        case .cpu: return .blue
        case .memory: return .purple
        case .disk: return .orange
        case .network: return .green
        case .gpu: return Color(red: 0.95, green: 0.45, blue: 0.55)
        case .battery: return .mint
        case .sensors: return .red
        case .services: return .teal
        case .files: return .orange
        case .containers: return .green
        case .audio: return .purple
        case .bluetooth: return .blue
        }
    }

    @ViewBuilder
    private var header: some View {
        switch tab {
        case .overview:
            HStack {
                sectionLabel("OVERVIEW")
                Spacer()
                if let uptime = SystemInfo.uptimeLabel() {
                    Label("Up \(uptime)", systemImage: "clock")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
        default:
            Text(tab.rawValue.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(0.9)
                .foregroundStyle(.secondary)
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .tracking(0.8)
            .foregroundStyle(.secondary)
    }

    // MARK: - Content switch

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .overview: if model.prefs.presentation.panelLayout == .list { overviewList } else { overviewContent }
        case .cpu: cpuScreen
        case .memory: memoryScreen
        case .network: networkScreen
        case .disk: diskScreen
        case .gpu: gpuScreen
        case .battery: batteryScreen
        case .sensors: sensorsScreen
        case .services: servicesScreen
        case .files: filesScreen
        case .containers: containersScreen
        case .audio: ScrollView { AudioPane(controls: model.audioControls, compact: true) }.frame(height: 480)
        case .bluetooth: ScrollView { BluetoothPane(compact: true) }.frame(height: 400)
        }
    }

    private var overviewList: some View {
        VStack(spacing: 6) {
            ForEach(MenuBarMetric.allCases) { metric in
                HStack {
                    Label(metric.label, systemImage: metric.symbol)
                    Spacer(); Text(model.statusText(metric)).monospacedDigit()
                }.padding(8).cardBackground(cornerRadius: 8)
            }
            busiestCard
        }
    }

    // MARK: - Overview grid (eager layout: exact heights, no lazy estimates)

    private var overviewContent: some View {
        VStack(spacing: 6) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible())], spacing: 6) {
                ForEach(model.prefs.presentation.panelTiles.visible(LayoutCatalog.panelTiles.map(\.0)), id: \.self) { overviewTile($0) }
            }
            busiestCard
        }
    }

    @ViewBuilder private func overviewTile(_ id: String) -> some View {
        let cpu = snap.system.cpu
        let mem = snap.system.memory
        let net = snap.system.network
        let disk = snap.system.disk
        let gpu = snap.system.gpu
        let load = SystemInfo.loadAverage1()

        switch id {
        case "cpu":
            MetricCard(id: "cpu", symbol: "cpu", tint: .blue, title: "CPU",
                           hovered: hoveredCard == "cpu", onHover: { hoveredCard = $0 ? "cpu" : nil }) {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        cardNumber(cpu.coreCount > 0 ? Fmt.percent(cpu.totalPercent) : "—")
                        Spacer()
                        if let load {
                            Text("load \(String(format: "%.1f", load))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .frame(minHeight: 24)
                    spark(history: model.cpuHistory, tint: .blue, fixedMax: 100)
                }
        case "memory":
            MetricCard(id: "memory", symbol: "memorychip", tint: .purple, title: "Memory",
                           hovered: hoveredCard == "memory", onHover: { hoveredCard = $0 ? "memory" : nil }) {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        cardNumber(mem.totalBytes > 0 ? String(format: "%.2f", Double(mem.usedBytes) / 1_073_741_824) : "—")
                        Text("GB").font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                        Spacer()
                        Text(mem.totalBytes > 0 ? "of \(String(format: "%.0f", Double(mem.totalBytes) / 1_073_741_824))" : "")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(minHeight: 24)
                    spark(history: model.memHistoryGB, tint: .purple)
                }
        case "network":
            MetricCard(id: "network", symbol: "network", tint: .green, title: "Network",
                           hovered: hoveredCard == "network", onHover: { hoveredCard = $0 ? "network" : nil }) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
                        if let net {
                            cardNumber(model.networkParts(net.downBytesPerSec).value, size: 19)
                            Text(model.networkParts(net.downBytesPerSec).unit)
                                .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                            Spacer()
                            HStack(spacing: 2) {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
                            Text(model.networkParts(net.upBytesPerSec).value + " " + model.networkParts(net.upBytesPerSec).unit)
                                .font(.caption2).foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                            }
                        } else {
                            cardNumber("—", size: 19)
                        }
                    }
                    .frame(minHeight: 24)
                    spark(history: model.netDownHistoryKB, tint: .green)
                }
        case "disk":
            MetricCard(id: "disk", symbol: "internaldrive", tint: .orange, title: "Disk",
                           hovered: hoveredCard == "disk", onHover: { hoveredCard = $0 ? "disk" : nil }) {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        cardNumber(disk.map { String(format: "%.0f", Double($0.freeBytes) / 1_073_741_824) } ?? "—", size: 19)
                        Text("GB").font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                        Spacer()
                        Text("free").font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(minHeight: 24)
                    diskBar(disk)
                }
        case "gpu":
            MetricCard(id: "gpu", symbol: "square.3.layers.3d", tint: .pink, title: "GPU",
                           hovered: hoveredCard == "gpu", onHover: { hoveredCard = $0 ? "gpu" : nil }) {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        cardNumber(gpu?.utilizationPercent.map { Fmt.percent($0) } ?? "—", size: 19)
                        Spacer()
                        Text(gpu == nil ? "n/a" : "util")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(minHeight: 24)
                    if model.gpuHistory.count >= 2 {
                        spark(history: model.gpuHistory, tint: Color(red: 0.95, green: 0.45, blue: 0.55), fixedMax: 100)
                    } else {
                        gpuPlaceholder
                    }
                }
        case "power":
            if let battery = snap.system.battery { MetricCard(id: "battery", symbol: "battery.100", tint: .green, title: "Battery",
                               hovered: hoveredCard == "battery", onHover: { hoveredCard = $0 ? "battery" : nil }) {
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            cardNumber(battery.percentage.map { Fmt.percent($0) } ?? "—", size: 19)
                            Spacer()
                            if let mins = battery.timeToEmptyMinutes, mins > 0 {
                                Text("\(mins / 60)h \(mins % 60)m").font(.caption2).foregroundStyle(.secondary)
                            } else if battery.isCharging {
                                Text("charging").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .frame(minHeight: 24)
                        batteryBar(battery)
                    } } else { MetricCard(id: "power", symbol: "powerplug.fill", tint: .mint, title: "Power",
                               hovered: hoveredCard == "power", onHover: { hoveredCard = $0 ? "power" : nil }) {
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.mint)
                            Text("AC")
                                .font(.system(size: 19, weight: .bold, design: .rounded))
                            Spacer()
                            Text("plugged in")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(minHeight: 24)
                        HStack(spacing: 4) {
                            Capsule().fill(.mint.opacity(0.85)).frame(height: 5)
                            Text("").font(.caption2)
                        }
                        .frame(height: 24, alignment: .center)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Power source: AC power")
                    } }
        default: EmptyView()
        }
    }

    // MARK: - CPU screen (reference layout: one card, Top Apps inside)

    private var cpuScreen: some View {
        let cpu = snap.system.cpu
        let load = SystemInfo.loadAverage1()
        let topApps = snap.rollups
            .filter { $0.totalCPU > 0.05 }
            .sorted { $0.totalCPU > $1.totalCPU }
            .prefix(5)

        return BigCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(cpu.coreCount > 0 ? String(format: "%.0f", cpu.totalPercent) : "—")
                                .font(.system(size: 40, weight: .heavy, design: .rounded))
                                .monospacedDigit()
                            Text("%")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        Text(SystemInfo.chipName() ?? "Apple Silicon")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.cpuHistory.count >= 2 {
                        AreaSparkline(values: model.cpuHistory, tint: .blue, fixedMax: 100)
                            .frame(width: 120, height: 44)
                    }
                }

                Divider().opacity(0.4)

                detailRow("User", cpu.coreCount > 0 ? Fmt.percent(cpu.userPercent) : "—")
                detailRow("System", cpu.coreCount > 0 ? Fmt.percent(cpu.systemPercent) : "—")
                detailRow("Load Average", load.map { String(format: "%.2f", $0) } ?? "—")

                Divider().opacity(0.4)

                Text("Top Apps")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)

                ForEach(Array(topApps)) { app in
                    HStack(spacing: 8) {
                        AppIconView(bundlePath: app.isAppBundle ? app.id : nil, name: app.displayName)
                            .frame(width: 18, height: 18)
                        Text(app.displayName)
                            .font(.callout)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        Spacer()
                        CPUBar(percent: model.processCPUValue(app.totalCPU) ?? 0, tint: .blue, height: 6)
                            .frame(width: 118)
                        Text(model.cpuText(app.totalCPU))
                            .font(.subheadline.monospacedDigit().weight(.medium))
                            .frame(width: 52, alignment: .trailing)
                    }
                    .accessibilityElement(children: .ignore)
                    .modifier(MenuAppActions(app: app))
                    .accessibilityLabel("\(app.displayName), \(model.cpuText(app.totalCPU)) CPU")
                }
            }
        }
    }

    // MARK: - Memory screen

    private var memoryScreen: some View {
        let mem = snap.system.memory
        let topApps = snap.rollups
            .filter { $0.totalMemory > 32_000_000 }
            .sorted { $0.totalMemory > $1.totalMemory }
            .prefix(5)
        let maxMem = topApps.first?.totalMemory ?? 0

        return BigCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(mem.totalBytes > 0 ? String(format: "%.2f", Double(mem.usedBytes) / 1_073_741_824) : "—")
                                .font(.system(size: 40, weight: .heavy, design: .rounded))
                                .monospacedDigit()
                            Text("GB")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        Text(mem.totalBytes > 0 ? "of \(Fmt.bytes(mem.totalBytes))" : " ")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.memHistoryGB.count >= 2 {
                        AreaSparkline(values: model.memHistoryGB, tint: .purple)
                            .frame(width: 120, height: 44)
                    }
                }

                Divider().opacity(0.4)

                detailRow("App", mem.appBytes.map(Fmt.bytes) ?? "—")
                detailRow("Wired", mem.wiredBytes.map(Fmt.bytes) ?? "—")
                detailRow("Compressed", mem.compressedBytes.map(Fmt.bytes) ?? "—")
                detailRow("Swap", mem.swapBytes.map(Fmt.bytes) ?? "0 B")
                detailRow("Pressure", Theme.stateWord(mem.pressureLevel))

                Divider().opacity(0.4)

                Text("Top Apps")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)

                ForEach(Array(topApps)) { app in
                    HStack(spacing: 8) {
                        AppIconView(bundlePath: app.isAppBundle ? app.id : nil, name: app.displayName)
                            .frame(width: 18, height: 18)
                        Text(app.displayName)
                            .font(.callout)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        Spacer()
                        CPUBar(
                            percent: maxMem > 0 ? Double(app.totalMemory) / Double(maxMem) * 100 : 0,
                            tint: .purple, height: 6
                        )
                        .frame(width: 118)
                        Text(Fmt.bytes(app.totalMemory))
                            .font(.subheadline.monospacedDigit().weight(.medium))
                            .frame(width: 64, alignment: .trailing)
                    }
                    .accessibilityElement(children: .ignore)
                    .modifier(MenuAppActions(app: app))
                    .accessibilityLabel("\(app.displayName), \(Fmt.bytes(app.totalMemory)) of memory")
                }
            }
        }
    }

    // MARK: - Network screen

    private var networkScreen: some View {
        let net = snap.system.network
        let down = net.map { model.networkParts($0.downBytesPerSec) }
        let up = net.map { model.networkParts($0.upBytesPerSec) }
        // Top downloaders: apps with an observed download rate, biggest first.
        let topDownloaders = snap.rollups
            .compactMap { app -> (app: AppRollup, rate: Double)? in
                guard let rate = app.totalNetInBytesPerSec, rate > 0 else { return nil }
                return (app, rate)
            }
            .sorted { $0.rate > $1.rate }
            .prefix(5)
        let maxRate = topDownloaders.first?.rate ?? 0

        return BigCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Image(systemName: "arrow.down")
                                .font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                            Text(down?.value ?? "—")
                                .font(.system(size: 30, weight: .heavy, design: .rounded))
                                .monospacedDigit()
                            Text(down?.unit ?? "")
                                .font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                        }
                        if let up {
                            Text("↑ \(up.value) \(up.unit)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if model.netDownHistoryKB.count >= 2 {
                        AreaSparkline(values: model.netDownHistoryKB, tint: .green)
                            .frame(width: 100, height: 40)
                    }
                }

                Divider().opacity(0.4)

                detailRow("Downloaded This Session", snap.sessionNet.in.map(Fmt.bytes) ?? "—")
                    .help("Total bytes received since Portmaster launched, summed from per-process counters.")
                detailRow("Uploaded This Session", snap.sessionNet.out.map(Fmt.bytes) ?? "—")
                    .help("Total bytes sent since Portmaster launched, summed from per-process counters.")

                Divider().opacity(0.4)

                Text("Top Apps by Download")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)

                if topDownloaders.isEmpty {
                    Text("No app downloads observed yet — rates appear after the first network pass.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(topDownloaders), id: \.app.id) { entry in
                        HStack(spacing: 8) {
                            AppIconView(bundlePath: entry.app.isAppBundle ? entry.app.id : nil, name: entry.app.displayName)
                                .frame(width: 18, height: 18)
                            Text(entry.app.displayName)
                                .font(.callout)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                            Spacer()
                            CPUBar(
                                percent: maxRate > 0 ? entry.rate / maxRate * 100 : 0,
                                tint: .green, height: 6
                            )
                            .frame(width: 118)
                            Text(model.networkText(entry.rate))
                                .font(.subheadline.monospacedDigit().weight(.medium))
                                .frame(width: 64, alignment: .trailing)
                        }
                        .accessibilityElement(children: .ignore)
                        .modifier(MenuAppActions(app: entry.app))
                        .accessibilityLabel("\(entry.app.displayName), downloading \(model.networkText(entry.rate))")
                    }
                }
            }
        }
    }

    // MARK: - Disk screen

    private var diskScreen: some View {
        let disk = snap.system.disk
        let usedFraction = (disk?.totalBytes ?? 0) > 0
            ? 1 - Double(disk!.freeBytes) / Double(disk!.totalBytes)
            : 0
        // Top writers: apps with an observed write rate, biggest first.
        let topWriters = snap.rollups
            .compactMap { app -> (app: AppRollup, rate: Double)? in
                guard let rate = app.totalDiskWriteBytesPerSec, rate > 0 else { return nil }
                return (app, rate)
            }
            .sorted { $0.rate > $1.rate }
            .prefix(5)
        let maxWriterRate = topWriters.first?.rate ?? 0

        return BigCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(disk.map { String(format: "%.2f", Double($0.freeBytes) / 1_073_741_824) } ?? "—")
                        .font(.system(size: 34, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                    Text("GB free")
                        .font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    Text(disk.map { String(format: "%.2f GB used of %.2f GB", Double($0.totalBytes - $0.freeBytes) / 1_073_741_824, Double($0.totalBytes) / 1_073_741_824) } ?? " ")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer()
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.10))
                            Capsule().fill(.orange)
                                .frame(width: max(4, usedFraction * geo.size.width))
                        }
                    }
                    .frame(width: 120, height: 6)
                    .accessibilityHidden(true)
                }

                Divider().opacity(0.4)

                detailRow("Reading", disk.map { $0.readBytesPerSec.map(Fmt.rate) ?? "—" } ?? "—")
                    .help("Bytes read per second, summed across processes owned by you. Other users' system processes are not readable without privileges.")
                detailRow("Writing", disk.map { $0.writeBytesPerSec.map(Fmt.rate) ?? "—" } ?? "—")
                    .help("Bytes written per second, summed across processes owned by you. Other users' system processes are not readable without privileges.")

                Divider().opacity(0.4)

                Text("Top Apps by Disk Writes")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)

                if topWriters.isEmpty {
                    Text("No app disk writes in the last sample interval.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(topWriters), id: \.app.id) { entry in
                        HStack(spacing: 8) {
                            AppIconView(bundlePath: entry.app.isAppBundle ? entry.app.id : nil, name: entry.app.displayName)
                                .frame(width: 18, height: 18)
                            Text(entry.app.displayName)
                                .font(.callout)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                            Spacer()
                            CPUBar(
                                percent: maxWriterRate > 0 ? entry.rate / maxWriterRate * 100 : 0,
                                tint: .orange, height: 6
                            )
                            .frame(width: 118)
                            Text(Fmt.rate(entry.rate))
                                .font(.subheadline.monospacedDigit().weight(.medium))
                                .frame(width: 64, alignment: .trailing)
                        }
                        .accessibilityElement(children: .ignore)
                        .modifier(MenuAppActions(app: entry.app))
                        .accessibilityLabel("\(entry.app.displayName), writing \(Fmt.rate(entry.rate))")
                    }
                }
            }
        }
    }

    // MARK: - GPU screen (honest)

    private var gpuScreen: some View {
        let gpu = snap.system.gpu
        return BigCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(gpu?.utilizationPercent.map { String(format: "%.0f", $0) } ?? "—")
                                .font(.system(size: 40, weight: .heavy, design: .rounded))
                                .monospacedDigit()
                            Text("%")
                                .font(.title3.weight(.semibold)).foregroundStyle(.secondary)
                        }
                        Text(SystemInfo.chipName() ?? "Apple Silicon")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.gpuHistory.count >= 2 {
                        AreaSparkline(values: model.gpuHistory, tint: Color(red: 0.95, green: 0.45, blue: 0.55), fixedMax: 100)
                            .frame(width: 120, height: 44)
                    }
                }
                if gpu == nil {
                    Text("GPU statistics are not available on this Mac — showing hardware facts only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Divider().opacity(0.4)
                detailRow("Renderer", gpu?.rendererPercent.map { Fmt.percent($0) } ?? "—")
                    .help("Shader/fragment workload utilization from the GPU's IORegistry performance statistics.")
                detailRow("Tiler", gpu?.tilerPercent.map { Fmt.percent($0) } ?? "—")
                    .help("Geometry/vertex workload utilization from the GPU's IORegistry performance statistics.")
                detailRow("GPU Memory In Use", gpu?.inUseMemoryBytes.map(Fmt.bytes) ?? "—")
                detailRow("GPU Cores", gpu?.coreCount.map(String.init) ?? "—")
                detailRow("Displays", displaysSummary())
            }
        }
    }

    private var sensorsScreen: some View {
        let thermal = snap.system.thermal
        return BigCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(thermal?.hottestTempC.map { model.temperatureText($0).replacingOccurrences(of: model.prefs.presentation.temperatureUnit == .celsius ? "°C" : "°F", with: "") } ?? "—")
                        .font(.system(size: 40, weight: .heavy, design: .rounded)).monospacedDigit()
                    Text(model.prefs.presentation.temperatureUnit == .celsius ? "°C" : "°F").font(.title3).foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "thermometer.medium").foregroundStyle(.red)
                }
                Text("Hottest sensor").font(.caption).foregroundStyle(.secondary)
                Divider().opacity(0.4)
                detailRow("CPU maximum", thermal?.cpuTempC.map { model.temperatureText($0, decimals: 1) } ?? "—")
                detailRow("GPU maximum", thermal?.gpuTempC.map { model.temperatureText($0, decimals: 1) } ?? "—")
                Divider().opacity(0.4)
                ThermalContextView()
                Text("Fans").font(.callout.weight(.semibold))
                if let thermal, !thermal.fans.isEmpty {
                    ForEach(thermal.fans.indices, id: \.self) { index in
                        let fan = thermal.fans[index]
                        detailRow(fan.name ?? "Fan \(index + 1)",
                                  fan.currentRPM.map { String(format: "%.0f RPM", $0) } ?? "—")
                    }
                } else {
                    Text("No fan readings available").font(.caption).foregroundStyle(.secondary)
                }
                // Only a pass that actually produced readings may claim sensors are being
                // refreshed; "nothing has been observed yet" and "no recognized
                // sensor produced a plausible reading" both mean there is
                // nothing here to describe, and saying otherwise would assert
                // sensors this Mac has not been shown to have.
                Text(thermal?.availability == .available ? "Read-only sensors. CPU and GPU show the maximum observed in each group. Refreshed about every 5 seconds while open; slower in the background." : "SMC sensor readings are unavailable on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var batteryScreen: some View {
        let battery = snap.system.battery
        return BigCard {
            VStack(alignment: .leading, spacing: 8) {
                if let b = battery {
                    // Laptop: real battery header — level, estimate, bar.
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text(String(format: "%.0f", b.percentage ?? 0))
                                    .font(.system(size: 40, weight: .heavy, design: .rounded))
                                    .monospacedDigit()
                                Text("%")
                                    .font(.title3.weight(.semibold)).foregroundStyle(.secondary)
                            }
                            Text(b.isCharging ? "charging" : (b.timeToEmptyMinutes.map { "\($0)m left" } ?? " " ))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let pct = b.percentage {
                            CPUBar(percent: pct, tint: .mint, height: 6)
                                .frame(width: 120)
                        }
                    }
                } else {
                    // Desktop: lead with the real power state, not a stub.
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Image(systemName: "bolt.fill")
                                    .font(.system(size: 30, weight: .bold))
                                    .foregroundStyle(.mint)
                                Text("AC Power")
                                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                            }
                            Text("No internal battery on this Mac")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }

                Divider().opacity(0.4)

                if let b = battery {
                    detailRow("Power Source", b.isCharging ? "AC power (charging)" : "internal battery")
                    detailRow("Power Draw", b.wattage.map { String(format: "%.1f W", $0) } ?? "—")
                        .help("Voltage × amperage from the power source, magnitude only — sign conventions vary across Macs.")
                    detailRow("Time Left", b.timeToEmptyMinutes.map { "\($0)m" } ?? "—")
                    detailRow("Capacity Health", b.healthPercent.map { String(format: "%.0f%%", $0) } ?? "—")
                        .help("Estimated full-charge capacity divided by design capacity, when reported by the battery registry.")
                    detailRow("Charge Cycles", b.cycleCount.map(String.init) ?? "—")
                } else {
                    detailRow("Power Source", "AC power")
                        .help("From the same IOKit power-source list macOS's menu-bar battery item uses — your machine reports AC with no battery.")
                    detailRow("System Uptime", SystemInfo.uptimeLabel() ?? "—")
                        .help("Time since the last boot — the power-related stat that exists on every Mac.")
                }

                Divider().opacity(0.4)

                awakeSection

                Divider().opacity(0.4)

                Text("Top Apps by Power")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("macOS does not expose per-app power draw through supported APIs (only averaged Energy Impact in private frameworks). Portmaster shows “—” rather than an invented number.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// "Keeping This Mac Awake": real sleep assertions macOS attributes to
    /// each process (via pmset -g assertions), grouped per app.
    @ViewBuilder
    private var awakeSection: some View {
        let grouped = Dictionary(grouping: snap.sleepAssertions, by: \.processName)
        let apps = grouped.sorted { $0.value.count > $1.value.count }

        HStack {
            Label("Keeping This Mac Awake", systemImage: "moon.zzz.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.purple)
            Spacer()
            Text(apps.isEmpty ? "nobody" : "\(apps.count) app\(apps.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if apps.isEmpty {
            Text("No apps are holding sleep assertions right now — the Mac can sleep normally.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ForEach(apps.prefix(3), id: \.key) { name, assertions in
                HStack(spacing: 8) {
                    AppIconView(bundlePath: nil, name: name)
                        .frame(width: 18, height: 18)
                    Text(name)
                        .font(.callout)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Text(assertions.first?.kindLabel ?? "")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.purple)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.purple.opacity(0.14), in: Capsule())
                        .lineLimit(1)
                    Spacer()
                    if let detail = assertions.first?.detail {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help(detail)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(name) is \(assertions.first?.kindLabel ?? "keeping this Mac awake")")
            }
            if apps.count > 3 {
                Text("and \(apps.count - 3) more")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var filesScreen: some View {
        let projects = ProjectSummary.build(processes: snap.processes, ports: snap.ports)
        let totalMemory = projects.reduce(0) { $0 + $1.memoryBytes }
        let totalPorts = Set(snap.ports.map { $0.port }).count
        let shown = projects.prefix(6)

        return BigCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(projects.isEmpty ? "—" : String(projects.count))
                        .font(.system(size: 40, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                    Text("projects")
                        .font(.title3.weight(.semibold)).foregroundStyle(.secondary)
                }
                Text("\(Fmt.bytes(totalMemory)) · \(totalPorts) ports open")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Divider().opacity(0.4)

                Text("Running Now")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)

                if projects.isEmpty {
                    Text("No projects detected. Attribution appears when processes run inside a repository directory.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(shown)) { project in
                        HStack(spacing: 8) {
                            Image(systemName: "folder")
                                .font(.caption)
                                .foregroundStyle(.orange)
                            Text(project.displayName)
                                .font(.callout)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                            ForEach(project.ports.prefix(2), id: \.self) { port in
                                Text(verbatim: String(format: ":%d", port))
                                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.green)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(.quaternary, in: Capsule())
                            }
                            Spacer()
                            Text(Fmt.bytes(project.memoryBytes))
                                .font(.subheadline.monospacedDigit().weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(project.displayName), \(project.processCount) processes, \(Fmt.bytes(project.memoryBytes))")
                    }
                    if projects.count > shown.count {
                        Text("and \(projects.count - shown.count) more")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if totalPorts == 0 {
                        Text("No listening ports — only memory attribution.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Containers screen (docker CLI, honest availability states)

    private func containerRate(_ value: Double?) -> String {
        value.map { Fmt.rate($0) } ?? "—"
    }

    private var containersScreen: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Docker Containers")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            switch snap.docker {
            case nil:
                Text("Gathering container data…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .center)
                    .cardBackground(cornerRadius: 10)
            case .some(let docker):
                switch docker.availability {
                case .notInstalled:
                    Text("Docker isn't installed on this Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 30, alignment: .center)
                        .cardBackground(cornerRadius: 10)
                case .daemonDown:
                    Text("Docker isn't running. Start Docker Desktop and this list fills in.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 30, alignment: .center)
                        .cardBackground(cornerRadius: 10)
                case .running:
                    let running = docker.runningContainers
                    let totalMemory = docker.totalMemoryBytes
                    if running.isEmpty {
                        Text("No containers are running.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 30, alignment: .center)
                            .cardBackground(cornerRadius: 10)
                    } else {
                        HStack {
                            Text("\(running.count) container\(running.count == 1 ? "" : "s")")
                                .font(.caption.weight(.semibold))
                            Spacer()
                            Text(Fmt.bytes(totalMemory))
                                .font(.caption.monospacedDigit().weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        ForEach(Array(running.prefix(5))) { c in
                            HStack(spacing: 8) {
                                Image(systemName: "shippingbox")
                                    .font(.caption2)
                                    .foregroundStyle(.green)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(c.name).font(.caption).lineLimit(1)
                                    Text(c.image)
                                        .font(.system(size: 9))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.7)
                                }
                                Spacer()
                                CPUBar(percent: c.cpuPercent ?? 0, tint: .green, height: 5)
                                    .frame(width: 44)
                                Text(Fmt.bytes(c.memoryBytes))
                                    .font(.caption.monospacedDigit().weight(.medium))
                                    .frame(width: 64, alignment: .trailing)
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 9)
                            .cardBackground(cornerRadius: 8)
                            HStack {
                                Text("Net ↓ " + model.networkText(c.networkInBytesPerSec) + " ↑ " + model.networkText(c.networkOutBytesPerSec))
                                Spacer()
                                Text("Disk R " + containerRate(c.diskReadBytesPerSec) + " W " + containerRate(c.diskWriteBytesPerSec))
                            }.font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                        if running.count > 5 {
                            Text("and \(running.count - 5) more in the window")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    /// Displays attached to this Mac: count + resolution of the main one
    /// (real hardware facts from CoreGraphics, no utilization claim).
    private func displaysSummary() -> String {
        let id = CGMainDisplayID()
        let w = CGDisplayPixelsWide(id)
        let h = CGDisplayPixelsHigh(id)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else {
            return w > 0 && h > 0 ? "1 · \(w)×\(h)" : "—"
        }
        return w > 0 && h > 0 ? "\(count) · \(w)×\(h)" : "\(count)"
    }

    // MARK: - Services screen

    private var servicesScreen: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Development Services")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if snap.services.isEmpty {
                Text("No listening services detected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .center)
                    .cardBackground(cornerRadius: 10)
            } else {
                ForEach(snap.services.prefix(6)) { svc in
                    HStack(spacing: 8) {
                        Text(verbatim: String(format: ":%d", svc.primaryPort ?? 0))
                            .font(.system(.caption, design: .monospaced).weight(.semibold))
                            .foregroundStyle(.teal)
                            .frame(width: 42, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(svc.displayName).font(.caption).lineLimit(1)
                            if let project = svc.projectID {
                                Text(project.components(separatedBy: "/").last ?? project)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if svc.activity.isQuiet {
                            Text("quiet")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 9)
                    .cardBackground(cornerRadius: 8)
                }
            }
        }
    }

    // MARK: - Shared pieces

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.callout.monospacedDigit().weight(.medium))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value)")
    }

    private func cardNumber(_ text: String, size: CGFloat = 22) -> some View {
        Text(text)
            .font(.system(size: size, weight: .bold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }

    @ViewBuilder
    private func spark(history: [Double], tint: Color, fixedMax: Double? = nil) -> some View {
        Group {
            if history.count >= 2 {
                AreaSparkline(values: history, tint: tint, fixedMax: fixedMax)
            } else {
                Text(" ").frame(maxWidth: .infinity, minHeight: 24)
            }
        }
        .frame(height: 24)
    }

    @ViewBuilder
    private func diskBar(_ disk: DiskSample?) -> some View {
        let usedFraction = (disk?.totalBytes ?? 0) > 0
            ? 1 - Double(disk!.freeBytes) / Double(disk!.totalBytes)
            : 0
        ProgressView(value: min(1, max(0, usedFraction)))
            .tint(.orange)
            .scaleEffect(x: 1, y: 0.6, anchor: .center)
            .frame(height: 24, alignment: .center)
    }

    private var gpuPlaceholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.primary.opacity(0.05))
            Text("not exposed by macOS")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
        .frame(height: 24)
    }

    @ViewBuilder
    private func batteryBar(_ battery: BatterySample?) -> some View {
        ProgressView(value: min(100, battery?.percentage ?? 0) / 100)
            .tint((battery?.percentage ?? 100) < 20 ? Color.coral : .green)
            .scaleEffect(x: 1, y: 0.6, anchor: .center)
            .frame(height: 24, alignment: .center)
    }

    /// Always exactly 3 rows (placeholder rows keep height constant).
    private var busiestCard: some View {
        let apps = Array(
            snap.rollups
                .filter { $0.totalCPU > 0.05 || $0.totalMemory > 64_000_000 }
                .sorted { $0.totalCPU > $1.totalCPU }
                .prefix(3)
        )

        return VStack(alignment: .leading, spacing: 7) {
            Text("Busiest Right Now")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(0..<3, id: \.self) { i in
                if i < apps.count {
                    let app = apps[i]
                    HStack(spacing: 8) {
                        AppIconView(bundlePath: app.isAppBundle ? app.id : nil, name: app.displayName)
                            .frame(width: 18, height: 18)
                        Text(app.displayName)
                            .font(.callout)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        Spacer()
                        CPUBar(percent: model.processCPUValue(app.totalCPU) ?? 0, tint: .blue, height: 6)
                            .frame(width: 84)
                        Text(model.cpuText(app.totalCPU))
                            .font(.subheadline.monospacedDigit().weight(.medium))
                            .frame(width: 52, alignment: .trailing)
                    }
                    .accessibilityElement(children: .ignore)
                    .modifier(MenuAppActions(app: app))
                    .accessibilityLabel("\(app.displayName), \(model.cpuText(app.totalCPU)) CPU")
                } else {
                    Color.clear.frame(height: 20)
                }
            }
        }
        .padding(9)
        .cardBackground(cornerRadius: 10)
        .accessibilityElement(children: .contain)
    }

    private var controls: some View {
        HStack(spacing: 6) {
            Button {
                // openMainWindow handles the show-then-activate order that
                // accessory apps need on macOS 14+.
                AppDelegate.shared?.openMainWindow()
            } label: {
                Label("Open Portmaster", systemImage: "macwindow")
                    .font(.callout)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .center)
            }
            .buttonStyle(.bordered)

            Button {
                AppDelegate.shared?.openSettingsWindow()
            } label: {
                Image(systemName: "gearshape")
                    .font(.callout)
                    .frame(width: 36, height: 28)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Settings")

            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
                    .font(.callout)
                    .frame(minWidth: 64, minHeight: 28)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Quit Portmaster")
        }
        .controlSize(.regular)
    }

    private var pausedBadge: some View {
        Label("Paused — opens to live data", systemImage: "pause.circle")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.orange)
    }
}

/// Big detail card (CPU/Memory/Network/Disk/GPU screens).
struct BigCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground(cornerRadius: 12)
        .accessibilityElement(children: .contain)
    }
}

/// One uniform metric card for the overview grid.
struct MetricCard<Content: View>: View {
    let id: String
    let symbol: String
    let tint: Color
    let title: String
    let hovered: Bool
    let onHover: (Bool) -> Void
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.caption.weight(.semibold))
                Spacer()
            }
            content
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(hovered ? Color.primary.opacity(0.08) : Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(hovered ? Color.primary.opacity(0.15) : Color.clear, lineWidth: 1)
        )
        .onHover { onHover($0) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

extension PanelTab {
    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .disk: return "internaldrive"
        case .network: return "network"
        case .gpu: return "square.3.layers.3d"
        case .battery: return "battery.100"
        case .sensors: return "thermometer.medium"
        case .services: return "number"
        case .files: return "folder"
        case .containers: return "shippingbox"
        case .audio: return "speaker.wave.2"
        case .bluetooth: return "antenna.radiowaves.left.and.right"
        }
    }
}
