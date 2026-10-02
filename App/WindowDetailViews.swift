// Window detail tabs: the same real data as before, laid out with the
// reference anatomy — full-width hero (numeral + stat rows + live area
// chart), a four-card strip, and a full-width per-app table. Shared
// building blocks live in TabBuildingBlocks.swift; every figure traces to
// a real collector, and unavailable values render "—", never guesses.
import SwiftUI
import Charts
import PortmasterCore

/// Strip card for the busiest app of a metric: real icon, name, value,
/// process count. Clicking deep-links into the Processes tab.
private struct TopAppCard: View {
    let tint: Color
    let title: String
    let name: String?
    let bundlePath: String?
    let value: String
    let context: String

    var body: some View {
        Button {
            NotificationCenter.default.post(name: .openPortmasterProcesses, object: nil)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(tint)
                    Text(title).font(.callout.weight(.medium))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                if let name {
                    HStack(spacing: 8) {
                        AppIconView(bundlePath: bundlePath, name: name)
                            .frame(width: 26, height: 26)
                        Text(name)
                            .font(.system(size: 17, weight: .bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    HStack(spacing: 6) {
                        Text(value)
                            .font(.callout.monospacedDigit().weight(.semibold))
                        Text("·")
                            .foregroundStyle(.secondary)
                        Text(context)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                } else {
                    Text("—")
                        .font(.system(size: 28, weight: .heavy, design: .rounded))
                    Text("Nothing significant")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardBackground(cornerRadius: 12)
        }
        .buttonStyle(.plain)
        .disabled(name == nil)
        .help(name != nil ? "See this app's processes" : "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name.map { "\(title): \($0), \(value)" } ?? "\(title): none")
    }
}

/// Cores card with the reference's P/E chips — only when the kernel reports
/// the split; otherwise the plain count, never a guess.
private struct CoresCard: View {
    let coreCount: Int?
    let perf: Int?
    let eff: Int?

    var body: some View {
        MiniStatCard(icon: "cpu.fill", tint: .blue, title: "Cores",
                     value: coreCount.map(String.init) ?? "—") {
            HStack(spacing: 6) {
                if let perf, let eff {
                    Text("\(perf) P")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.blue.opacity(0.16), in: Capsule())
                    Text("\(eff) E")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.blue.opacity(0.16), in: Capsule())
                } else {
                    Text("logical")
                }
            }
        }
    }
}

// MARK: - CPU

/// The CPU tab: hero (Now % + Average today / Load + area chart), strip
/// (User / System / Cores / Top App), per-app table. "Average today" is the
/// mean of persisted samples since midnight — "—" until two samples exist.
struct WindowCpuDetail: View {
    @EnvironmentObject private var model: AppModel
    @State private var buffer = SparklineBuffer()
    /// Daily averages use the background reader and update every 30 seconds.
    @State private var dayStats = CpuWindowStats(averageTodayPercent: nil, averageSeries: [], sampleCount: 0)

    var body: some View {
        // Fixed layout: hero + card strip stay pinned, the per-app table
        // expands to fill the rest and scrolls INSIDE itself — the whole
        // tab never scrolls (reference behavior).
        content
            .onReceive(model.engine.$latest) { snap in
                guard snap.at != .distantPast else { return }
                let cpuValue = snap.system.cpu.totalPercent
                // Defer mutations off the attach/layout pass: @Published
                // delivers the current value to a new subscriber
                // synchronously during view attachment, and mutating @State
                // inside that pass made NSHostingView invalidate the
                // window's size constraints reentrantly — an AppKit
                // exception crash on switching to this tab.
                Task { @MainActor in
                    buffer.push(cpuValue)
                }
            }
            .task {
                while !Task.isCancelled {
                    await refreshDayStats()
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                }
            }
    }

    @MainActor private func refreshDayStats() async {
        guard let reader = model.historyReader else { return }
        do {
            let stats = try await reader.dayStats(metric: "cpu")
            try Task.checkCancellation(); dayStats = stats
        } catch { if !Task.isCancelled { dayStats = .init(averageTodayPercent: nil, averageSeries: [], sampleCount: 0) } }
    }

    private var content: some View {
        let cpu = model.snapshot.system.cpu
        let live = cpu.coreCount > 0
        let avg = dayStats.averageTodayPercent
        let load = SystemInfo.loadAverage1()
        let (perf, eff) = SystemInfo.performanceCoreCounts()
        let apps = model.snapshot.rollups
            .filter { $0.totalCPU > 0.05 }
            .sorted { $0.totalCPU > $1.totalCPU }
        let topApp = apps.first
        let maxCPU = max(0.1, apps.first?.totalCPU ?? 0.1)

        return ArrangedSections(scope: "cpu", sections: [
            (id: "hero", title: "Reading and chart", view: AnyView(TabHeroCard(
                label: "Now",
                numeral: live ? String(format: "%.0f", cpu.totalPercent) : "—",
                unit: "%", tint: .blue,
                rows: [
                    ("Average today", avg.map { String(format: "%.0f%%", $0) } ?? "—"),
                    ("Load", load.map { String(format: "%.2f", $0) } ?? "—"),
                ]
            ) {
                MetricAreaChartView(values: buffer.values, mean: avg, tint: .blue, domainMax: 100)
            })),
            (id: "stats", title: "Statistics", view: AnyView(HStack(spacing: 12) {
                MiniStatCard(icon: "person.fill", tint: .blue, title: "User",
                             value: live ? Fmt.percent(cpu.userPercent) : "—", subText: "Your apps")
                MiniStatCard(icon: "gearshape.fill", tint: .blue, title: "System",
                             value: live ? Fmt.percent(cpu.systemPercent) : "—", subText: "macOS")
                CoresCard(coreCount: live ? cpu.coreCount : nil, perf: perf, eff: eff)
                TopAppCard(tint: .blue, title: "Top App",
                           name: topApp?.displayName,
                           bundlePath: topApp?.isAppBundle == true ? topApp?.id : nil,
                           value: topApp.map { model.cpuText($0.totalCPU) } ?? "—",
                           context: topApp.map { "\($0.pidCount) processes" } ?? "")
            })),
            (id: "apps", title: "Apps", view: AnyView(AppTableCard(metricLabel: "CPU", tint: .blue, rows: apps.map { app in
                AppTableCard.Row(
                    id: app.id, name: app.displayName,
                    bundlePath: app.isAppBundle ? app.id : nil, fallbackSymbol: "terminal",
                    context: "\(app.pidCount) processes",
                    value: model.cpuText(app.totalCPU),
                    fraction: app.totalCPU / maxCPU
                )
            })
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)))
        ])
        .padding(16)
    }
}

// MARK: - Memory

/// Memory tab: hero (In Use GB + Swap / Pressure rows + live chart), strip
/// (App / Wired / Compressed / Top App), per-app table by bytes.
struct WindowMemoryDetail: View {
    @EnvironmentObject private var model: AppModel
    @State private var buffer = SparklineBuffer()
    @State private var dayAvgGB: Double?

    var body: some View {
        // Fixed layout with an internally-scrolling table (see CPU tab).
        content
            .onReceive(model.engine.$latest) { snap in
                guard snap.at != .distantPast, snap.system.memory.totalBytes > 0 else { return }
                let usedGB = Double(snap.system.memory.usedBytes) / 1_073_741_824
                // Defer state mutation off the attach pass (see CPU tab note).
                Task { @MainActor in
                    buffer.push(usedGB)
                }
            }
            .task {
                while !Task.isCancelled {
                    await refreshDayStats()
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                }
            }
    }

    /// Same windowed-stats math as the CPU tab, applied to persisted
    /// memory samples (mean used GB since midnight).
    @MainActor private func refreshDayStats() async {
        guard let reader = model.historyReader else { return }
        do {
            let stats = try await reader.dayStats(metric: "memory")
            try Task.checkCancellation(); dayAvgGB = stats.averageTodayPercent
        } catch { if !Task.isCancelled { dayAvgGB = nil } }
    }

    private var content: some View {
        let mem = model.snapshot.system.memory
        let hasMem = mem.totalBytes > 0
        let usedGB = Double(mem.usedBytes) / 1_073_741_824
        let totalGB = Double(mem.totalBytes) / 1_073_741_824
        let apps = model.snapshot.rollups
            .filter { $0.totalMemory > 32_000_000 }
            .sorted { $0.totalMemory > $1.totalMemory }
        let topApp = apps.first
        let maxMem = max(1, apps.first?.totalMemory ?? 1)

        return ArrangedSections(scope: "memory", sections: [
            (id: "hero", title: "Reading and chart", view: AnyView(TabHeroCard(
                label: "In Use",
                numeral: hasMem ? String(format: "%.1f", usedGB) : "—",
                unit: "GB", tint: .indigo,
                rows: [
                    ("Average today", dayAvgGB.map { String(format: "%.1f GB", $0) } ?? "—"),
                    ("Pressure", Theme.stateWord(mem.pressureLevel)),
                ]
            ) {
                MetricAreaChartView(values: buffer.values, mean: dayAvgGB, tint: .indigo,
                                    domainMax: max(8, ceil(totalGB)))
            })),
            (id: "stats", title: "Statistics", view: AnyView(HStack(spacing: 12) {
                MiniStatCard(icon: "app.badge.fill", tint: .indigo, title: "App",
                             value: mem.appBytes.map(Fmt.bytes) ?? "—", subText: "Applications")
                MiniStatCard(icon: "nut.fill", tint: .indigo, title: "Wired",
                             value: mem.wiredBytes.map(Fmt.bytes) ?? "—", subText: "macOS kernel")
                MiniStatCard(icon: "arrow.triangle.compress", tint: .indigo, title: "Compressed",
                             value: mem.compressedBytes.map(Fmt.bytes) ?? "—", subText: "By macOS")
                TopAppCard(tint: .indigo, title: "Top App",
                           name: topApp?.displayName,
                           bundlePath: topApp?.isAppBundle == true ? topApp?.id : nil,
                           value: topApp.map { Fmt.bytes($0.totalMemory) } ?? "—",
                           context: topApp.map { "\($0.pidCount) processes" } ?? "")
            })),
            (id: "apps", title: "Apps", view: AnyView(AppTableCard(metricLabel: "Memory", tint: .indigo, rows: apps.map { app in
                AppTableCard.Row(
                    id: app.id, name: app.displayName,
                    bundlePath: app.isAppBundle ? app.id : nil, fallbackSymbol: "terminal",
                    context: "\(app.pidCount) processes",
                    value: Fmt.bytes(app.totalMemory),
                    fraction: Double(app.totalMemory) / Double(maxMem)
                )
            })
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)))
        ])
        .padding(16)
    }
}

// MARK: - Disk

/// Disk tab: hero (Free GB + Reading / Writing rows + write-rate chart),
/// strip (Used / Reading / Writing / Top App), per-app table by writes.
struct WindowDiskDetail: View {
    @EnvironmentObject private var model: AppModel
    @State private var buffer = SparklineBuffer()

    var body: some View {
        // Fixed layout with an internally-scrolling table (see CPU tab).
        content
            .onReceive(model.engine.$latest) { snap in
                guard snap.at != .distantPast, let d = snap.system.disk else { return }
                let writes = d.writeBytesPerSec ?? 0
                // Defer state mutation off the attach pass (see CPU tab note).
                Task { @MainActor in buffer.push(writes) }
            }
    }

    private var content: some View {
        let disk = model.snapshot.system.disk
        let freeGB = disk.map { Double($0.freeBytes) / 1_073_741_824 } ?? 0
        let usedFraction = disk.map { 1 - Double($0.freeBytes) / max(1, Double($0.totalBytes)) } ?? 0
        let apps = model.snapshot.rollups
            .compactMap { app -> (AppRollup, Double)? in
                guard let r = app.totalDiskWriteBytesPerSec, r > 0 else { return nil }
                return (app, r)
            }
            .sorted { $0.1 > $1.1 }
        let top = apps.first
        let maxWrite = max(1.0, top?.1 ?? 1.0)

        return ArrangedSections(scope: "disk", sections: [
            (id: "hero", title: "Reading and chart", view: AnyView(TabHeroCard(
                label: "Free",
                numeral: disk != nil ? String(format: "%.1f", freeGB) : "—",
                unit: "GB", tint: .orange,
                rows: [
                    ("Reading", disk?.readBytesPerSec.map(Fmt.rate) ?? "—"),
                    ("Writing", disk?.writeBytesPerSec.map(Fmt.rate) ?? "—"),
                ]
            ) {
                MetricAreaChartView(values: buffer.values, tint: .orange,
                                    domainMax: 1_048_576) // 1 MB/s floor; grows with real peaks
            })),
            (id: "stats", title: "Statistics", view: AnyView(HStack(spacing: 12) {
                MiniStatCard(icon: "internaldrive.fill", tint: .orange, title: "Used",
                             value: disk != nil ? Fmt.percent(usedFraction * 100) : "—",
                             subText: disk.map { "of \(Fmt.bytes($0.totalBytes))" } ?? "Capacity unknown")
                MiniStatCard(icon: "arrow.down.circle", tint: .orange, title: "Reading",
                             value: disk?.readBytesPerSec.map(Fmt.rate) ?? "—", subText: "From disk")
                MiniStatCard(icon: "arrow.up.circle", tint: .orange, title: "Writing",
                             value: disk?.writeBytesPerSec.map(Fmt.rate) ?? "—", subText: "To disk")
                TopAppCard(tint: .orange, title: "Top App",
                           name: top?.0.displayName,
                           bundlePath: top?.0.isAppBundle == true ? top?.0.id : nil,
                           value: top.map { Fmt.rate($0.1) } ?? "—",
                           context: top.map { "\($0.0.pidCount) processes" } ?? "")
            })),
            (id: "apps", title: "Apps", view: AnyView(AppTableCard(metricLabel: "Writes", tint: .orange, rows: apps.map { pair in
                AppTableCard.Row(
                    id: pair.0.id, name: pair.0.displayName,
                    bundlePath: pair.0.isAppBundle ? pair.0.id : nil, fallbackSymbol: "terminal",
                    context: "\(pair.0.pidCount) processes",
                    value: Fmt.rate(pair.1),
                    fraction: pair.1 / maxWrite
                )
            })
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)))
        ])
        .padding(16)
    }
}

// MARK: - Network

/// Network tab: hero (Down rate + Up / Session rows + download chart),
/// strip (Session In / Session Out / Listeners / Top App), per-app table
/// by download.
struct WindowNetworkDetail: View {
    @EnvironmentObject private var model: AppModel
    @State private var buffer = SparklineBuffer()

    var body: some View {
        // Fixed layout with an internally-scrolling table (see CPU tab).
        content
            .onReceive(model.engine.$latest) { snap in
                guard snap.at != .distantPast, let net = snap.system.network else { return }
                let downKB = net.downBytesPerSec / 1024 // KB/s series
                // Defer state mutation off the attach pass (see CPU tab note).
                Task { @MainActor in buffer.push(downKB) }
            }
    }

    private var content: some View {
        let net = model.snapshot.system.network
        let down = net.map { model.networkParts($0.downBytesPerSec) }
        let apps = model.snapshot.rollups
            .compactMap { app -> (AppRollup, Double)? in
                guard let r = app.totalNetInBytesPerSec, r > 0 else { return nil }
                return (app, r)
            }
            .sorted { $0.1 > $1.1 }
        let top = apps.first
        let maxDown = max(1.0, top?.1 ?? 1.0)

        return ArrangedSections(scope: "network", sections: [
            (id: "hero", title: "Reading and chart", view: AnyView(TabHeroCard(
                label: "Down",
                numeral: down?.value ?? "—",
                unit: down?.unit ?? "", tint: .green,
                rows: [
                    ("Up", net.map { model.networkText($0.upBytesPerSec) } ?? "—"),
                    ("Listening", String(model.snapshot.services.count)),
                ]
            ) {
                MetricAreaChartView(values: buffer.values, tint: .green,
                                    domainMax: 1024) // KB/s floor; grows with real peaks
            })),
            (id: "stats", title: "Statistics", view: AnyView(HStack(spacing: 12) {
                MiniStatCard(icon: "arrow.down.to.line", tint: .green, title: "Session In",
                             value: model.snapshot.sessionNet.in.map(Fmt.bytes) ?? "—",
                             subText: "Since launch")
                MiniStatCard(icon: "arrow.up.to.line", tint: .green, title: "Session Out",
                             value: model.snapshot.sessionNet.out.map(Fmt.bytes) ?? "—",
                             subText: "Since launch")
                MiniStatCard(icon: "antenna.radiowaves.left.and.right", tint: .green,
                             title: "Listeners", value: String(model.snapshot.services.count),
                             subText: "Open ports")
                TopAppCard(tint: .green, title: "Top App",
                           name: top?.0.displayName,
                           bundlePath: top?.0.isAppBundle == true ? top?.0.id : nil,
                           value: top.map { model.networkText($0.1) } ?? "—",
                           context: top.map { "\($0.0.pidCount) processes" } ?? "")
            })),
            (id: "apps", title: "Apps", view: AnyView(AppTableCard(metricLabel: "Download", tint: .green, rows: apps.map { pair in
                AppTableCard.Row(
                    id: pair.0.id, name: pair.0.displayName,
                    bundlePath: pair.0.isAppBundle ? pair.0.id : nil, fallbackSymbol: "terminal",
                    context: "\(pair.0.pidCount) processes",
                    value: model.networkText(pair.1),
                    fraction: pair.1 / maxDown
                )
            })
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)))
        ])
        .padding(16)
    }
}

// MARK: - GPU

/// GPU tab: hero (Utilization % + Renderer / Tiler rows + live chart) and
/// strip (Renderer / Tiler / Memory / Cores). No per-app table: macOS does
/// not expose per-app GPU attribution, so none is implied.
struct WindowGpuDetail: View {
    @EnvironmentObject private var model: AppModel
    @State private var buffer = SparklineBuffer()

    var body: some View {
        // Short fixed content: no scrolling anywhere on this tab.
        content
            .onReceive(model.engine.$latest) { snap in
                guard snap.at != .distantPast, let util = snap.system.gpu?.utilizationPercent else { return }
                // Defer state mutation off the attach pass (see CPU tab note).
                Task { @MainActor in buffer.push(util) }
            }
    }

    private var content: some View {
        let gpu = model.snapshot.system.gpu

        return ArrangedSections(scope: "gpu", sections: [
            (id: "hero", title: "Reading and chart", view: AnyView(TabHeroCard(
                label: SystemInfo.chipName() ?? "GPU",
                numeral: gpu?.utilizationPercent.map { String(format: "%.0f", $0) } ?? "—",
                unit: gpu != nil ? "%" : "", tint: .pink,
                rows: [
                    ("Renderer", gpu?.rendererPercent.map { Fmt.percent($0) } ?? "—"),
                    ("Tiler", gpu?.tilerPercent.map { Fmt.percent($0) } ?? "—"),
                ]
            ) {
                MetricAreaChartView(
                    values: buffer.values, tint: .pink, domainMax: 100
                )
            })),
            (id: "stats", title: "Statistics", view: AnyView(HStack(spacing: 12) {
                MiniStatCard(icon: "chart.xyaxis.line", tint: .pink, title: "Average",
                             value: buffer.values.isEmpty ? "—" : Fmt.percent(buffer.values.reduce(0, +) / Double(buffer.values.count)),
                             subText: "Recent samples")
                MiniStatCard(icon: "arrow.up.right", tint: .pink, title: "Peak",
                             value: buffer.values.max().map(Fmt.percent) ?? "—",
                             subText: "Recent samples")
                MiniStatCard(icon: "memorychip", tint: .pink, title: "GPU Memory",
                             value: gpu?.inUseMemoryBytes.map(Fmt.bytes) ?? "—",
                             subText: "Unified memory")
                MiniStatCard(icon: "cpu", tint: .pink, title: "Cores",
                             value: gpu?.coreCount.map(String.init) ?? "—",
                             subText: "GPU cores")
            })),
            (id: "about", title: "About", view: AnyView(DisclosureGroup("About GPU readings") {
                Text("Usage measures the whole chip. Renderer and tiler show shader and geometry activity; per-app GPU usage is unavailable on this Mac.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 8)
            }.font(.system(size: 12)).padding(14).cardBackground(cornerRadius: 14)))
        ])
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Power

/// Power tab. On battery Macs: percentage hero + Remaining / Draw rows.
/// On desktops (no internal battery): the honest AC state, with the same
/// receipts the Overview card carries — no fabricated watts.
struct WindowPowerDetail: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        ScrollView {
            ArrangedSections(scope: "power", sections: [
                (id: "power", title: "Power source", view: AnyView(powerSource)),
                (id: "awake", title: "Keeping awake", view: AnyView(AwakeCard(assertions: model.snapshot.sleepAssertions)))
            ]).padding(16)
        }
    }
    private var powerSource: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let b = model.snapshot.system.battery {
                TabHeroCard(label: b.isCharging ? "Charging" : b.source == .power ? "Plugged in" : b.source == .battery ? "On battery" : "Battery",
                    numeral: b.percentage.map { String(format: "%.0f", $0) } ?? "—",
                    unit: b.percentage != nil ? "%" : "", tint: .green,
                    rows: [("Remaining", b.timeToEmptyMinutes.map { "\($0 / 60)h \($0 % 60)m" } ?? "—"),
                           ("Cycles", b.cycleCount.map(String.init) ?? "—")]) {
                    VStack(spacing: 8) {
                        if let pct = b.percentage { ProgressView(value: min(100, max(0, pct)), total: 100).tint(.green) }
                        else { Text("Battery level unavailable").font(.caption).foregroundStyle(.secondary) }
                    }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                HStack(spacing: 12) {
                    MiniStatCard(icon: "bolt.fill", tint: .green, title: "Power Draw", value: b.wattage.map { String(format: "%.1f W", $0) } ?? "—", subText: "Battery reading")
                    MiniStatCard(icon: "heart", tint: .green, title: "Health", value: b.healthPercent.map(Fmt.percent) ?? "—", subText: "Maximum capacity")
                    MiniStatCard(icon: "clock", tint: .green, title: "Uptime", value: SystemInfo.uptimeLabel() ?? "—", subText: "Since restart")
                }
            } else {
                HStack(spacing: 14) {
                    Image(systemName: "powerplug.fill").foregroundStyle(.green)
                        .frame(width: 32, height: 32).background(.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Running on AC power").font(.system(size: 13, weight: .semibold))
                        Text("This Mac has no internal battery").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(SystemInfo.uptimeLabel() ?? "—").font(.system(size: 13, weight: .semibold)).monospacedDigit()
                        Text("Uptime").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }.padding(16).frame(minHeight: 70).cardBackground(cornerRadius: 14)
            }
            DisclosureGroup("About power readings") {
                Text("Readings are reported by macOS. Power draw appears when the battery reports it; total power draw on this desktop and power use by individual app are unavailable.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 8)
            }.font(.system(size: 12)).padding(14).cardBackground(cornerRadius: 14)
        }
    }
}

/// "Keeping This Mac Awake": the sleep-preventing power assertions macOS
/// attributes to each process, read from `pmset -g assertions` — the same
/// supported-tool pattern as the lsof and nettop collectors.
struct AwakeCard: View {
    let assertions: [SleepAssertion]

    private var grouped: [(name: String, assertions: [SleepAssertion])] {
        Dictionary(grouping: assertions, by: \.processName)
            .map { (name: $0.key, assertions: $0.value) }
            .sorted { $0.assertions.count > $1.assertions.count }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Color.purple.opacity(0.9), in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityHidden(true)
                Text("Keeping This Mac Awake")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.purple)
                Spacer()
                Text(grouped.isEmpty ? "Nobody" : "\(grouped.count) app\(grouped.count == 1 ? "" : "s")")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if grouped.isEmpty {
                Text("No apps are preventing sleep.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(grouped.prefix(6), id: \.name) { entry in
                    HStack(spacing: 10) {
                        Image(systemName: "app.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(entry.name)
                            .font(.callout)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        ForEach(entry.assertions.prefix(2)) { assertion in
                            Text(assertion.kindLabel)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.purple)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.purple.opacity(0.14), in: Capsule())
                                .help(assertion.detail ?? assertion.kind)
                        }
                        Spacer()

                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(entry.name): \(entry.assertions.map(\.kindLabel).joined(separator: ", "))")
                }
                if grouped.count > 6 {
                    Text("and \(grouped.count - 6) more")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Apps with active sleep assertions reported by macOS.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground(cornerRadius: 12)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Projects

struct WindowProjectsDetail: View {
    @EnvironmentObject private var model: AppModel
    @State private var stopTarget: AppModel.StopTarget?
    @State private var search = ""

    var body: some View {
        let projects = ProjectSummary.build(processes: model.snapshot.processes, ports: model.snapshot.ports)
        let visibleProjects = projects.filter { search.isEmpty || $0.displayName.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search) }
        let totalMemory = projects.reduce(UInt64(0)) { total, project in
            let sum = total.addingReportingOverflow(project.memoryBytes)
            return sum.overflow ? UInt64.max : sum.partialValue
        }
        let totalPorts = Set(model.snapshot.ports.map { $0.port }).count
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(systemName: "folder.fill").foregroundStyle(.orange).frame(width: 32, height: 32)
                    .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(projects.count) projects running").font(.system(size: 13, weight: .semibold))
                    Text("\(Fmt.bytes(totalMemory)) attributed · \(totalPorts) open ports · \(model.snapshot.services.count) listening services")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                TextField("Search projects or paths", text: $search).textFieldStyle(.roundedBorder).frame(width: 240)
                    .accessibilityLabel("Search projects")
            }.padding(16).frame(minHeight: 70).cardBackground(cornerRadius: 14)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Text("Project").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Ports").frame(width: 180, alignment: .leading)
                    Text("Memory").frame(width: 80, alignment: .trailing)
                    Text("\(visibleProjects.count) of \(projects.count)").frame(width: 70, alignment: .trailing)
                }.font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 10)
                Divider().padding(.horizontal, 14)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if visibleProjects.isEmpty {
                            Text(projects.isEmpty ? "No projects detected yet." : "No projects match your search.")
                                .font(.system(size: 12)).foregroundStyle(.secondary).padding(20)
                        }
                        ForEach(visibleProjects) { p in
                            HStack(spacing: 12) {
                                Image(systemName: "folder").foregroundStyle(.orange).frame(width: 24, height: 24)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(p.displayName).font(.system(size: 13, weight: .medium)).lineLimit(1).help(p.id)
                                    Text("\(p.processCount) processes").font(.system(size: 11)).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                HStack(spacing: 5) {
                                    ForEach(p.ports.prefix(3), id: \.self) { port in
                                        Text(verbatim: ":\(port)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.green)
                                            .padding(.horizontal, 5).padding(.vertical, 3).background(.green.opacity(0.1), in: Capsule())
                                    }
                                    if p.ports.count > 3 { Text("+\(p.ports.count - 3)").font(.system(size: 10)).help(p.ports.map { ":\($0)" }.joined(separator: ", ")) }
                                }.frame(width: 180, alignment: .leading)
                                Text(Fmt.bytes(p.memoryBytes)).font(.system(size: 12, weight: .medium)).monospacedDigit().frame(width: 80, alignment: .trailing)
                                Button("Quit…") { stopTarget = model.projectStopTarget(p.id) }
                                    .disabled(model.prefs.fixtureMode).frame(width: 70)
                                    .accessibilityLabel("Quit \(p.displayName)…").help("Review processes before quitting \(p.displayName)")
                            }.padding(.horizontal, 14).padding(.vertical, 9)
                                .accessibilityElement(children: .contain)
                            if p.id != visibleProjects.last?.id { Divider().padding(.leading, 50) }
                        }
                    }
                }
            }.cardBackground(cornerRadius: 14)
        }.padding(16)
            .sheet(item: $stopTarget) { StopSheet(target: $0).environmentObject(model) }
    }
}
