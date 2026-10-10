// Overview: reference-style 3-column dashboard. CPU/Memory/GPU and
// Disk/Network/Power card rows, Memory by Type / Memory by App donuts, and
// Busiest Right Now — all real data; unavailable categories stay absent.
import SwiftUI
import Charts
import UniformTypeIdentifiers
import PortmasterCore

struct OverviewView: View {
    @EnvironmentObject private var model: AppModel
    @State private var cpuBuffer = SparklineBuffer()
    @State private var memBuffer = SparklineBuffer()
    @State private var netDownBuffer = SparklineBuffer()
    @State private var gpuBuffer = SparklineBuffer()
    @State private var diskBuffer = SparklineBuffer()
    @State private var showBarCharts = false
    @State private var exportError: String?

    var body: some View {
        GeometryReader { geo in
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if model.engine.isPaused {
                    pausedPill
                }
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Overview").font(.system(size: 22, weight: .semibold))
                        Text("\(SystemInfo.chipName() ?? "This Mac") · \(model.snapshot.system.cpu.coreCount) cores · \(Fmt.bytes(model.snapshot.system.memory.totalBytes))")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    HStack(spacing: 3) {
                        chartStyleButton("chart.bar.fill", bars: true)
                        chartStyleButton("chart.xyaxis.line", bars: false)
                    }.padding(3).background(Theme.card, in: Capsule())
                    // Two exports, two shapes of answer: a CSV is the raw
                    // readings for something that will read it, and a card is a
                    // picture for something that will only look at it. Both
                    // are refused before anything has been sampled — a card of
                    // no data would still look like data.
                    Menu {
                        Button(action: exportOverview) {
                            Label("Readings as CSV", systemImage: "tablecells")
                        }
                        Button(action: exportShareCard) {
                            Label("Share Card as PNG", systemImage: "photo")
                        }
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                            .font(.system(size: 11, weight: .semibold)).padding(.horizontal, 12).padding(.vertical, 8)
                    }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .background(Theme.card, in: Capsule())
                        .disabled(!hasReading)
                }.padding(.bottom, 4)
                if let exportError { ErrorBanner(message: exportError) { self.exportError = nil } }
                if let notice = model.contextPressureNotice { ContextPressureStrip(notice: notice) }
                cardGrid(ids: ["cpu", "memory", "gpu", "disk", "network", "power"], width: geo.size.width)
                worthALook
                overviewSection("Right Now", ids: ["memoryType", "memoryApps", "powerApps"], width: geo.size.width)
                hardwareSection(width: geo.size.width)
            }.padding(20)
        }
        }
        .onReceive(model.engine.$latest) { snap in
            guard snap.at != .distantPast else { return }
            cpuBuffer.push(snap.system.cpu.totalPercent)
            if snap.system.memory.totalBytes > 0 {
                memBuffer.push(Double(snap.system.memory.usedBytes) / 1_073_741_824)
            }
            if let net = snap.system.network {
                netDownBuffer.push(net.downBytesPerSec / 1024) // KB/s bars
            }
            if let gpu = snap.system.gpu, let util = gpu.utilizationPercent {
                gpuBuffer.push(util)
            }
            if let disk = snap.system.disk {
                diskBuffer.push(disk.writeBytesPerSec ?? 0)
            }
        }
    }

    /// Whether there is anything to export. `distantPast` is the engine's
    /// "nothing sampled yet" sentinel, so this is the same check the paused
    /// pill reasons about.
    private var hasReading: Bool { model.snapshot.at != .distantPast }

    /// The card's content, resolved and formatted before anything is drawn.
    ///
    /// Forced light rather than the app's adaptive `Theme`: `Theme.canvas` is a
    /// dynamic `NSColor` that resolves against the current appearance, so an
    /// adaptive card would silently come out dark on a Mac in dark mode — a
    /// share card's appearance should not be decided by a system setting the
    /// person posting it may not have meant.
    private var shareCardContent: ShareCardContent {
        ShareCardContent.make(
            snapshot: model.snapshot,
            machineName: ProcessInfo.processInfo.hostName,
            subtitle: [SystemInfo.chipName(), "\(model.snapshot.system.cpu.coreCount) cores"]
                .compactMap { $0 }.joined(separator: " · ")
        )
    }

    /// Render the card off-screen and write it as a PNG.
    ///
    /// A save panel rather than dropping the file in Downloads: the CSV export
    /// already asks, and a share card is going somewhere specific, so guessing
    /// the folder would guess wrong about as often as right.
    private func exportShareCard() {
        exportError = nil
        let content = shareCardContent
        guard content.hasReading else {
            exportError = "Nothing has been sampled yet. Open Portmaster and let it take a reading first."
            return
        }
        let renderer = ImageRenderer(
            content: ShareCardView(content: content)
                .frame(width: ShareCardContent.pixelWidth, height: ShareCardContent.pixelHeight)
                .environment(\.colorScheme, .light)
        )
        renderer.scale = ShareCardContent.renderScale
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            exportError = "Could not render the share card."
            return
        }
        let panel = NSSavePanel()
        panel.title = "Save Share Card"
        panel.nameFieldStringValue = "Portmaster-card.png"
        panel.allowedContentTypes = [.png]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { try png.write(to: url, options: .atomic) }
            catch { exportError = "Could not save the share card: \(error.localizedDescription)" }
        }
    }

    private func chartStyleButton(_ symbol: String, bars: Bool) -> some View {
        Button { showBarCharts = bars } label: {
            Image(systemName: symbol).font(.system(size: 12))
                .foregroundStyle(showBarCharts == bars ? Color.primary : .secondary)
                .frame(width: 25, height: 23)
                .background(showBarCharts == bars ? Color.primary.opacity(0.1) : .clear, in: Capsule())
        }.buttonStyle(.plain).accessibilityLabel(bars ? "Show bar charts" : "Show line charts")
            .accessibilityAddTraits(showBarCharts == bars ? [.isSelected] : [])
    }

    private func exportOverview() {
        exportError = nil
        let snap = model.snapshot
        let system = snap.system
        let rows: [(String, String, String)] = [
            ("cpu", String(system.cpu.totalPercent), "percent"),
            ("memory_used", String(system.memory.usedBytes), "bytes"),
            ("memory_total", String(system.memory.totalBytes), "bytes"),
            ("gpu", system.gpu?.utilizationPercent.map { String($0) } ?? "", "percent"),
            ("disk_free", system.disk.map { String($0.freeBytes) } ?? "", "bytes"),
            ("download", system.network.map { String($0.downBytesPerSec) } ?? "", "bytes_per_second"),
            ("upload", system.network.map { String($0.upBytesPerSec) } ?? "", "bytes_per_second"),
            ("battery", system.battery?.percentage.map { String($0) } ?? "", "percent"),
            ("hottest_sensor", system.thermal?.hottestTempC.map { String($0) } ?? "", "celsius"),
            ("fan_max", system.thermal?.fans.compactMap(\.currentRPM).max().map { String($0) } ?? "", "rpm")
        ]
        let timestamp = ISO8601DateFormatter().string(from: snap.at)
        let csv = "timestamp,metric,value,unit\n" + rows.map { "\(timestamp),\($0.0),\($0.1),\($0.2)" }.joined(separator: "\n") + "\n"
        let panel = NSSavePanel()
        panel.title = "Export Current Readings"
        panel.nameFieldStringValue = "Portmaster-overview.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { try csv.write(to: url, atomically: true, encoding: .utf8) }
            catch { exportError = "Could not export readings: \(error.localizedDescription)" }
        }
    }

    /// Sampling pauses after 5 idle minutes with no visible surface; the
    /// dashboard always says so instead of showing frozen numbers.
    private var pausedPill: some View {
        Label("Paused — sampling resumes when Portmaster is opened", systemImage: "pause.circle")
            .font(.callout.weight(.medium))
            .foregroundStyle(.orange)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    /// The dashboard's alert strip: newest acting-up observations, linking
    /// into the Alerts tab. Reuses the same alert objects Notifications use.
    @ViewBuilder
    private var worthALook: some View {
        if !model.alerts.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Worth a Look").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Button("Show All") {
                        NotificationCenter.default.post(name: .openPortmasterAlerts, object: nil)
                    }
                    .buttonStyle(.link)
                }

                VStack(spacing: 0) {
                ForEach(Array(model.alerts.prefix(3).enumerated()), id: \.element.id) { index, alert in
                    if index > 0 { Divider().padding(.leading, 42) }
                    HStack(alignment: .top, spacing: 10) {
                        let (symbol, tint) = Self.alertGlyph(alert.kind)
                        Image(systemName: symbol)
                            .foregroundStyle(tint)
                            .padding(.top, 2)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(alert.headline)
                                .font(.callout.weight(.semibold))
                            Text(alert.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(alert.at, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(12)
                    .accessibilityElement(children: .combine)
                }
                }.cardBackground(cornerRadius: 14)
            }.padding(.top, 14)
        }
    }

    /// Glyph per alert kind for the Worth-a-Look strip.
    static func alertGlyph(_ kind: ActingUpAlert.Kind) -> (String, Color) {
        switch kind {
        case .sustainedCPU: return ("flame.fill", .coral)
        case .memoryGrowth: return ("arrow.up.right.circle.fill", .indigo)
        case .diskHammering: return ("internaldrive.fill", .orange)
        case .networkHammering: return ("network", .green)
        }
    }

    private func visibleCards(_ ids: [String]) -> [String] {
        model.prefs.presentation.overviewCards.visible(LayoutCatalog.overview.map(\.0)).filter { ids.contains($0) }
    }

    private func cardGrid(ids: [String], width: CGFloat) -> some View {
        let maximum = 3
        let fit = min(maximum, max(1, Int((width - 26) / 294)))
        let count = fit
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: count), spacing: 14) {
            ForEach(visibleCards(ids), id: \.self) { id in overviewCard(id) }
        }
    }

    @ViewBuilder private func overviewSection(_ title: String, ids: [String], width: CGFloat) -> some View {
        if !visibleCards(ids).isEmpty {
            Text(title).font(.system(size: 15, weight: .semibold)).padding(.top, 16)
            cardGrid(ids: ids, width: width)
        }
    }

    @ViewBuilder private func overviewCard(_ id: String) -> some View {
        switch id {
        case "cpu": detailLink(.cpu) { cpuCard }
        case "memory": detailLink(.memory) { memoryCard }
        case "gpu": detailLink(.gpu) { gpuCard }
        case "disk": detailLink(.disk) { diskCard }
        case "network": detailLink(.network) { networkCard }
        case "power": detailLink(.power) { powerCard }
        case "hardware": hardwareCard
        case "sound": detailLink(.audio) { soundSummary }
        case "bluetooth": detailLink(.bluetooth) { bluetoothSummary }
        case "sessions": agentSessionsCard
        case "thermal": ThermalContextView()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(16).frame(height: 208).cardBackground(cornerRadius: 16)
        case "memoryType": memoryTypeDonut
        case "memoryApps": memoryByAppDonut
        case "powerApps": powerByAppCard
        default: EmptyView()
        }
    }

    private func detailLink<Content: View>(_ tab: MainTab, @ViewBuilder content: () -> Content) -> some View {
        Button { NotificationCenter.default.post(name: .openPortmasterTab, object: tab.rawValue) } label: { content().contentShape(Rectangle()) }
            .buttonStyle(.plain).help("Open \(tab.label) details")
            .accessibilityLabel("Open \(tab.label) details")
    }

    // MARK: - Row 1

    private var cpuCard: some View {
        let cpu = model.snapshot.system.cpu
        return DashboardCard(
            title: "CPU", symbol: "cpu", tint: .blue,
            context: "Now",
            numeral: cpu.coreCount > 0 ? String(format: "%.0f", cpu.totalPercent) : "—",
            unit: cpu.coreCount > 0 ? "%" : nil,
            subMetrics: cpu.coreCount > 0 ? [
                ("User", Fmt.percent(cpu.userPercent)),
                ("System", Fmt.percent(cpu.systemPercent)),
                ("Cores", "\(cpu.coreCount)"),
                ("Uptime", SystemInfo.uptimeLabel() ?? "—"),
            ] : [],
            footer: OverviewSparkline(values: model.cpuHistory.isEmpty ? cpuBuffer.values : model.cpuHistory, tint: .blue, bars: showBarCharts, fixedMax: 100)
        )
    }

    private var memoryCard: some View {
        let mem = model.snapshot.system.memory
        let usedGB = Double(mem.usedBytes) / 1_073_741_824
        return DashboardCard(
            title: "Memory", symbol: "memorychip", tint: .indigo,
            context: mem.totalBytes > 0 ? "In Use of \(Fmt.bytes(mem.totalBytes))" : " ",
            numeral: mem.totalBytes > 0 ? String(format: "%.2f", usedGB) : "—",
            unit: mem.totalBytes > 0 ? "GB" : nil,
            // Pressure word with the kernel-pressure share beside it — the
            // word alone hides how close to the edge the machine is.
            chip: (
                mem.totalBytes > 0
                    ? "\(Theme.stateWord(mem.pressureLevel)) · \(Fmt.percent(mem.pressureRatio * 100)) used"
                    : " ",
                Theme.stateColor(mem.pressureLevel)
            ),
            subMetrics: memorySubMetrics(mem),
            footer: OverviewSparkline(values: memBuffer.values, tint: .indigo, bars: showBarCharts)
        )
    }

    private func memorySubMetrics(_ mem: SystemMemory) -> [(String, String)] {
        var m: [(String, String)] = []
        if let app = mem.appBytes { m.append(("App", Fmt.bytes(app))) }
        if let wired = mem.wiredBytes { m.append(("Wired", Fmt.bytes(wired))) }
        if let compressed = mem.compressedBytes { m.append(("Compressed", Fmt.bytes(compressed))) }
        return m
    }

    private var gpuCard: some View {
        let gpu = model.snapshot.system.gpu
        return DashboardCard(
            title: "GPU", symbol: "square.3.layers.3d", tint: .pink,
            context: SystemInfo.chipName() ?? "Apple Silicon",
            numeral: gpu?.utilizationPercent.map { String(format: "%.0f", $0) } ?? "—",
            unit: gpu != nil ? "%" : nil,
            subMetrics: [
                ("Renderer", gpu?.rendererPercent.map { Fmt.percent($0) } ?? "—"),
                ("Tiler", gpu?.tilerPercent.map { Fmt.percent($0) } ?? "—"),
                ("Cores", gpu?.coreCount.map(String.init) ?? "—"),
            ],
            footer: OverviewSparkline(values: gpuBuffer.values, tint: .pink, bars: showBarCharts, fixedMax: 100,
                                   placeholder: gpu == nil ? "GPU stats unavailable on this Mac" : "Sampling…")
        )
    }

    /// AI agent sessions, with the token figures and costs they actually reported.
    ///
    /// Absent entirely until a session exists: a card reading "no sessions" teaches
    /// nothing and spends a slot that a machine reading should have. Present and
    /// empty is a different thing, and the empty state that does matter — the store
    /// would not open — is the one shown here.
    private var agentSessionsCard: some View {
        let sessions = model.agentSessions
        let priced = sessions.compactMap { session -> Decimal? in
            if case .priced(let usd, _, _) = session.cost { return usd }
            return nil
        }
        let total = priced.reduce(Decimal(0), +)
        let tokens = SessionTokens(sessions: sessions)

        return DashboardCard(
            title: "Agent Sessions",
            symbol: "sparkles",
            tint: .purple,
            context: sessionsContext(sessions: sessions, tokens: tokens),
            // Tokens, not a count of sessions that reported them: a session tally under
            // a "tokens" label is a number that reads as a measurement of something
            // other than itself. And nothing countable here is a dash with no unit,
            // because a dash labelled in tokens reads as a session that used none.
            numeral: tokens.hasCountableFigure ? Fmt.tokens(tokens.total) : "—",
            unit: tokens.hasCountableFigure ? "tokens" : nil,
            subMetrics: [
                ("Sessions", "\(sessions.count)"),
                // The two states kept apart on purpose: money that exists, and money
                // nobody could compute because a model has no price.
                ("Costed", priced.isEmpty ? "—" : Fmt.usd(total)),
                ("Not priced", "\(sessions.count - priced.count)"),
            ],
            footer: sessionsFooter(sessions: sessions)
        )
    }

    /// The card's own aggregate line. It names how many models the total covers,
    /// because a bare sum is what made an escalated session look like a single-model
    /// one, and it names the models nobody can count rather than leaving them out of
    /// the sum — a total that quietly drops a model is the same claim by subtraction.
    private func sessionsContext(sessions: [AgentSessionSnapshot], tokens: SessionTokens) -> String {
        var parts = ["\(sessions.count) recorded"]
        if tokens.modelCount > 1 { parts.append("\(tokens.modelCount) models") }
        if !tokens.contested.isEmpty {
            parts.append("\(tokens.contested.count) contested")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private func sessionsFooter(sessions: [AgentSessionSnapshot]) -> some View {
        if sessions.isEmpty {
            if model.agentSessionStore == nil {
                // An unavailable store is not an empty list. Saying "no sessions"
                // here would report that the user has never used an agent.
                Text("The session store could not be opened")
                    .font(.system(size: 11)).foregroundStyle(.orange)
            } else {
                Text("No agent has connected yet")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(sessions.prefix(3), id: \.id) { session in
                    SessionLine(session: session)
                }
                if sessions.count > 3 {
                    Text("and \(sessions.count - 3) more")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private func hardwareSection(width: CGFloat) -> some View {
        if !visibleCards(["hardware", "thermal", "sound", "bluetooth"]).isEmpty {
            Text("Hardware").font(.system(size: 15, weight: .semibold)).padding(.top, 16)
            cardGrid(ids: ["hardware", "sound", "bluetooth"], width: width)
            if visibleCards(["thermal"]).contains("thermal") {
                DisclosureGroup("Heat context") { ThermalContextView().padding(.top, 8) }
                    .font(.system(size: 12)).padding(14).cardBackground(cornerRadius: 14)
            }
        }
    }

    private var hardwareCard: some View {
        let thermal = model.snapshot.system.thermal
        let fan = thermal?.fans.compactMap(\.currentRPM).max()
        return hardwareSummary(title: "Sensors", symbol: "thermometer.medium", tint: .red,
            rows: [("CPU", thermal?.cpuTempC.map { model.temperatureText($0) } ?? "—"),
                   ("GPU", thermal?.gpuTempC.map { model.temperatureText($0) } ?? "—"),
                   ("Fan", fan.map { String(format: "%.0f RPM", $0) } ?? "—")])
            .help("Read-only sensor readings; heat context lists current CPU activity.")
    }

    private var soundSummary: some View {
        let output = model.snapshot.audio?.output
        return hardwareSummary(title: "Volume Mixer", symbol: "speaker.wave.2", tint: .purple,
            rows: [(output?.name ?? "Output", output?.volume.map { String(format: "%.0f%%", $0 * 100) } ?? "—"),
                   ("Audio clients", model.snapshot.audio?.clients.map { String($0.filter { $0.outputActive == true }.count) } ?? "—"),
                   ("Output", "System volume")])
    }

    private var bluetoothSummary: some View {
        let devices = model.snapshot.bluetooth?.devices ?? []
        let rows = devices.prefix(2).map { device in
            (device.name, device.batteries.values.min().map { "\($0)%" } ?? "—")
        }
        return hardwareSummary(title: "Bluetooth", symbol: "antenna.radiowaves.left.and.right", tint: .blue,
            rows: rows + [("Connected", model.snapshot.bluetooth == nil ? "—" : String(devices.count))])
    }

    private func hardwareSummary(title: String, symbol: String, tint: Color, rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint)
            VStack(spacing: 8) {
                ForEach(rows.indices, id: \.self) { index in
                    HStack(spacing: 8) {
                        Text(rows[index].0).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(rows[index].1).fontWeight(.medium).monospacedDigit().lineLimit(1)
                    }.font(.system(size: 12))
                }
            }
        }.padding(16).frame(maxWidth: .infinity, minHeight: 128, alignment: .topLeading).cardBackground(cornerRadius: 14)
    }

    // MARK: - Row 2

    private var diskCard: some View {
        let disk = model.snapshot.system.disk
        let freeGB = disk.map { Double($0.freeBytes) / 1_073_741_824 } ?? 0
        let totalLabel = disk.map { String(format: "%.2f GB", Double($0.totalBytes) / 1_073_741_824) } ?? "—"
        return DashboardCard(
            title: "Disk", symbol: "internaldrive", tint: .orange,
            context: disk != nil ? "Free of \(totalLabel)" : " ",
            numeral: disk != nil ? String(format: "%.2f", freeGB) : "—",
            unit: disk != nil ? "GB" : nil,
            subMetrics: [
                ("Reading", disk?.readBytesPerSec.map(Fmt.rate) ?? "—"),
                ("Writing", disk?.writeBytesPerSec.map(Fmt.rate) ?? "—"),
                ("Used", disk.map { Fmt.percent(diskUsedFraction($0) * 100) } ?? "—"),
            ],
            footer: OverviewSparkline(values: diskBuffer.values, tint: .orange, bars: showBarCharts, placeholder: "Measuring writes…")
        )
    }

    private func diskUsedFraction(_ disk: DiskSample) -> Double {
        guard disk.totalBytes > 0 else { return 0 }
        return 1 - Double(disk.freeBytes) / Double(disk.totalBytes)
    }

    private var networkCard: some View {
        let net = model.snapshot.system.network
        let down = net.map { model.networkParts($0.downBytesPerSec) }
        return DashboardCard(
            title: "Network", symbol: "network", tint: .green,
            context: "Downloading",
            numeral: down?.value ?? "—",
            unit: down?.unit,
            subMetrics: [
                ("Up", net.map { model.networkText($0.upBytesPerSec) } ?? "—"),
                ("Session In", model.snapshot.sessionNet.in.map(Fmt.bytes) ?? "—"),
                ("Session Out", model.snapshot.sessionNet.out.map(Fmt.bytes) ?? "—"),
            ],
            footer: OverviewSparkline(values: netDownBuffer.values, tint: .green, bars: showBarCharts, placeholder: "Measuring…")
        )
    }

    private var powerCard: some View {
        let battery = model.snapshot.system.battery
        if let b = battery {
            return AnyView(
                DashboardCard(
                    title: "Battery",
                    symbol: b.isCharging ? "bolt.fill" : "battery.100",
                    tint: .green,
                    context: b.isCharging ? "Charging" : "On Battery",
                    numeral: b.percentage.map { String(format: "%.0f", $0) } ?? "—",
                    unit: b.percentage != nil ? "%" : nil,
                    subMetrics: batteryMetrics(b),
                    footer: Group {
                        if let pct = b.percentage {
                            ProgressView(value: min(100, pct) / 100)
                                .tint(.green)
                                .padding(.horizontal, 10)
                        } else {
                            OverviewSparkline(values: [], tint: .green, bars: showBarCharts, placeholder: "Sampling…")
                        }
                    }
                )
            )
        }
        return AnyView(
            DashboardCard(
                title: "Power", symbol: "powerplug.fill", tint: .green,
                context: "Power Source",
                numeral: "AC",
                unit: "plugged in",
                subMetrics: [
                    ("Battery", "AC only"),
                    ("Uptime", SystemInfo.uptimeLabel() ?? "—"),
                    ("Per-App Power", "—"),
                ],
                footer: HStack(spacing: 6) {
                    Circle().fill(.green).frame(width: 8, height: 8)
                    Text("Running on AC power")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 10)
            )
        )
    }

    private func batteryMetrics(_ b: BatterySample) -> [(String, String)] {
        var m: [(String, String)] = []
        if let mins = b.timeToEmptyMinutes, mins > 0 {
            m.append(("Remaining", "\(mins / 60)h \(mins % 60)m"))
        }
        if let w = b.wattage { m.append(("Draw", String(format: "%.1f W", w))) }
        if let health = b.healthPercent { m.append(("Health", Fmt.percent(health))) }
        if m.isEmpty { m.append(("Source", b.isCharging ? "AC (charging)" : "Battery")) }
        return m
    }

    // MARK: - Row 3

    private var memoryTypeDonut: some View {
        let mem = model.snapshot.system.memory
        return DonutCard(title: "Memory by Type", symbol: "memorychip", tint: .indigo) {
            if mem.totalBytes > 0 {
                let free = mem.totalBytes > mem.usedBytes ? mem.totalBytes - mem.usedBytes : 0
                DonutChart(slices: [
                    .init(label: "App", value: Double(mem.appBytes ?? 0), color: .indigo),
                    .init(label: "Wired", value: Double(mem.wiredBytes ?? 0), color: .orange),
                    .init(label: "Compressed", value: Double(mem.compressedBytes ?? 0), color: .teal),
                    .init(label: "Free", value: Double(free), color: .gray.opacity(0.35)),
                ], centerTitle: mem.totalBytes > 0 ? Fmt.percent(mem.pressureRatio * 100) : "—",
                   centerSubtitle: "in use")
            } else {
                Text("Sampling…").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var memoryByAppDonut: some View {
        DonutCard(title: "Memory by App", symbol: "square.grid.2x2", tint: .indigo) {
            if let built = memoryByAppSlices() {
                DonutChart(slices: built.slices,
                           centerTitle: Fmt.bytes(built.total),
                           centerSubtitle: "all apps")
            } else {
                Text("Sampling…").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// The CPU ring uses measured app CPU. The stored powerApps identifier
    /// remains compatible with existing layout preferences; the visible label
    /// describes the actual readings rather than implying measured watts.
    private var powerByAppCard: some View {
        let topApps = Array(model.snapshot.rollups
            .filter { $0.totalCPU > 0.05 }
            .sorted { $0.totalCPU > $1.totalCPU }
            .prefix(4))
        let totalCPU = model.snapshot.rollups.reduce(0.0) { $0 + max(0, $1.totalCPU) }
        let otherCPU = max(0, totalCPU - topApps.reduce(0) { $0 + $1.totalCPU })
        // Legend shows each app's SHARE OF APP CPU (45%, 30%…) — meaningful
        // numbers, unlike machine-normalized 0.1% figures. Ring slices use
        // the same proportions, so rows and ring always agree.
        func appShare(_ v: Double) -> Double {
            totalCPU > 0 ? v / totalCPU * 100 : 0
        }
        var slices: [PowerSlice] = topApps.enumerated().map { index, app in
            .init(value: max(0, app.totalCPU), color: Color.blue.opacity(1 - Double(index) * 0.18))
        }
        // All sampled apps beyond the four leaders remain in the Other slice.
        if otherCPU > 0.05 { slices.append(.init(value: otherCPU, color: .gray.opacity(0.15))) }
        if slices.isEmpty { slices = [.init(value: 1, color: .green.opacity(0.15))] }

        return DonutCard(title: "CPU by App", symbol: "cpu", tint: .blue) {
            HStack(spacing: 12) {
                PowerRing(slices: slices) {
                    Text(model.cpuText(totalCPU))
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                    Text("all apps").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .frame(width: 124, height: 124)
                .help("Each slice shows that app's share of the CPU used by sampled apps.")

                VStack(alignment: .leading, spacing: 10) {
                    if topApps.isEmpty {
                        Text("Nothing significant running.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(topApps.enumerated()), id: \.element.id) { index, app in
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(Color.blue.opacity(1 - Double(index) * 0.18))
                                    .frame(width: 8, height: 8)
                                AppIconView(bundlePath: app.isAppBundle ? app.id : nil, name: app.displayName)
                                    .frame(width: 20, height: 20)
                                Text(app.displayName)
                                    .font(.system(size: 13))
                                    .lineLimit(1)
                                Spacer()
                                Text(Fmt.percent(appShare(app.totalCPU)))
                                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                            }
                        }
                        if otherCPU > 0.05 {
                            HStack(spacing: 8) {
                                Circle().fill(Color.gray.opacity(0.4)).frame(width: 8, height: 8)
                                Text("Other")
                                    .font(.system(size: 13))
                                Spacer()
                                Text(Fmt.percent(appShare(otherCPU)))
                                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }

    private func memoryByAppSlices() -> (slices: [DonutChart.Slice], total: UInt64)? {
        let apps = model.snapshot.rollups
            .sorted { $0.totalMemory > $1.totalMemory }
            .prefix(4)
        let totalBytes = model.snapshot.rollups.reduce(UInt64(0)) { $0 + $1.totalMemory }
        guard totalBytes > 0 else { return nil }
        var slices: [DonutChart.Slice] = apps.enumerated().map { index, app in
            DonutChart.Slice(
                label: app.displayName,
                value: Double(app.totalMemory),
                color: Color.indigo.opacity(1 - Double(index) * 0.18)
            )
        }
        let topBytes = apps.reduce(UInt64(0)) { $0 + $1.totalMemory }
        if totalBytes > topBytes {
            slices.append(.init(label: "Other", value: Double(totalBytes - topBytes), color: .gray.opacity(0.4)))
        }
        return (slices, totalBytes)
    }

    // MARK: - Busiest apps

    private var busiestAppsCard: some View {
        let apps = model.snapshot.rollups
            .filter { $0.totalCPU > 0.05 || $0.totalMemory > 64_000_000 }
            .sorted { $0.totalCPU > $1.totalCPU }
            .prefix(6)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "flame")
                    .foregroundStyle(.blue)
                    .accessibilityHidden(true)
                Text("Busiest Right Now")
                    .font(.headline)
                Spacer()
            }

            if apps.isEmpty {
                EmptyStateView(
                    symbol: "tray",
                    title: model.engine.isPaused ? "Sampling paused" : "Gathering process data",
                    detail: model.engine.isPaused
                        ? "Open any Portmaster window to resume."
                        : "The first sweep is completing.",
                    buttonTitle: model.engine.isPaused ? "Resume now" : "Refresh",
                    action: { model.engine.refreshNow() }
                )
                .frame(minHeight: 100)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(apps)) { app in
                        HStack(spacing: 10) {
                            AppIconView(bundlePath: app.isAppBundle ? app.id : nil, name: app.displayName)
                                .frame(width: 22, height: 22)
                            Text(app.displayName)
                                .font(.callout)
                                .lineLimit(1)
                            Spacer()
                            CPUBar(percent: model.processCPUValue(app.totalCPU) ?? 0, tint: Theme.stateColor(cpuPercent: app.totalCPU))
                                .frame(width: 90)
                            Text(model.cpuText(app.totalCPU))
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(Theme.stateColor(cpuPercent: app.totalCPU))
                                .frame(width: 56, alignment: .trailing)
                        }
                        .padding(.vertical, 6)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(app.displayName), \(model.cpuText(app.totalCPU)) CPU, \(Fmt.bytes(app.totalMemory)) memory")
                        Divider().opacity(0.4)
                    }
                }
            }
        }
        .padding(14)
        .cardBackground(cornerRadius: 12)
        .accessibilityElement(children: .contain)
    }

    private func chartHint(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
    }
}

/// The log's own words, deliberately: the number's meaning is mode-dependent and
/// unverified, so we quote what Claude Code printed and assert nothing about it.
struct ContextPressureStrip: View {
    let notice: AppModel.ContextPressureNotice
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "gauge.with.dots.needle.67percent")
            Text("\(notice.clientName ?? "Agent") — \(Fmt.tokens(notice.tokensLeftWorst)) tokens left (worst observed)")
                .font(.callout)
            Spacer()
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel("\(notice.clientName ?? "Agent"), \(Fmt.tokens(notice.tokensLeftWorst)) tokens left, worst observed")
    }
}

/// One proportional band of the Power ring.
struct PowerSlice: Identifiable {
    let value: Double
    let color: Color
    var id: String { "\(color.description)-\(value)" }
}

/// Thin donut ring for the Power card — reference proportions (thin band,
/// 88pt diameter), real proportional slices, honest empty state.
struct PowerRing<Center: View>: View {

    let slices: [PowerSlice]
    private let center: Center

    init(slices: [PowerSlice], @ViewBuilder center: () -> Center) {
        self.slices = slices
        self.center = center()
    }

    var body: some View {
        ZStack {
            // Hand-drawn ring: no Charts, no layout inference — angles are
            // computed numerically and filled directly, so what you see is
            // exactly the math.
            Canvas { context, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let outer = min(size.width, size.height) / 2 - 1
                let band: CGFloat = 15
                let inner = outer - band
                let total = max(0.0001, slices.reduce(0) { $0 + max(0, $1.value) })
                let gap = slices.count > 1 ? 1.6 : 0.0
                var startDeg = -90.0
                for s in slices {
                    let sweep = 360 * max(0, s.value) / total
                    if sweep > gap * 2 {
                        var p = Path()
                        p.addArc(
                            center: c, radius: outer,
                            startAngle: .degrees(startDeg + gap),
                            endAngle: .degrees(startDeg + sweep - gap),
                            clockwise: false
                        )
                        p.addArc(
                            center: c, radius: inner,
                            startAngle: .degrees(startDeg + sweep - gap),
                            endAngle: .degrees(startDeg + gap),
                            clockwise: true
                        )
                        p.closeSubpath()
                        context.fill(p, with: .color(s.color))
                    }
                    startDeg += sweep
                }
            }
            .frame(width: 104, height: 104)
            VStack(spacing: 1) { center }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("CPU distribution by app CPU share")
    }
}

/// Real app icon from the bundle, or a symbol fallback for CLI tools.
struct AppIconView: View {
    let bundlePath: String?
    let name: String

    var body: some View {
        Group {
            if let bundlePath {
                let icon = NSWorkspace.shared.icon(forFile: bundlePath)
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 26, height: 26)
            } else {
                Image(systemName: "terminal")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Compact colored heading and neutral surface, matching the metric cards.
struct DonutCard<Content: View>: View {
    let title: String
    let symbol: String
    var tint: Color = .indigo
    /// Temporary build marker so we can verify which binary is on screen.
    var badge: String? = nil
    /// Hover explanation carried by the badge during verification.
    var badgeHelp: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                if let badge {
                    Text(badge)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.red, in: Capsule())
                        .help(badgeHelp ?? "")
                }
                Spacer()
            }
            .frame(height: 16)
            Spacer(minLength: 0)
            content
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(height: 208, alignment: .center)
        .cardBackground(cornerRadius: 16)
        .accessibilityElement(children: .contain)
    }
}

/// Donut chart with legend, center label, and honest zero-handling.
/// Compact metrics: smaller ring, tighter rows — sized so three cards fit a
/// row without feeling crowded.
struct DonutChart: View {
    struct Slice: Identifiable {
        let label: String
        let value: Double
        let color: Color
        var id: String { label }
    }

    let slices: [Slice]
    let centerTitle: String
    let centerSubtitle: String

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Chart(slices) { s in
                    SectorMark(
                        angle: .value("Value", max(0.0001, s.value)),
                        innerRadius: .ratio(0.60),
                        angularInset: 1.2
                    )
                    .foregroundStyle(s.color)
                    .cornerRadius(2)
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(width: 124, height: 124)

                VStack(spacing: 0) {
                    Text(centerTitle)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .minimumScaleFactor(0.7)
                    Text(centerSubtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                "\(centerSubtitle) \(centerTitle). " +
                slices.map { "\($0.label) \(Fmt.bytes(UInt64(max(0, $0.value))))" }.joined(separator: ", ")
            )

            VStack(alignment: .leading, spacing: 7) {
                ForEach(slices) { s in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(s.color)
                            .frame(width: 8, height: 8)
                        Text(s.label)
                            .font(.system(size: 13))
                            .lineLimit(1)
                        Spacer()
                        Text(Fmt.bytes(UInt64(max(0, s.value))))
                            .font(.system(size: 13).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

/// The token figures the sessions card is allowed to print, for one session or for
/// the card as a whole.
///
/// Resolution is `believableSegments`, the rule the MCP wire runs for the same question:
/// `preferredProvenance` first, so summing what remains cannot report a session twice when
/// two sources measured it, and then **no figure at all** for a model whose two readers
/// disagree past the costing tolerance. The wire hands such a model a segment with null
/// counts; printing one reader's number here would be a third answer to a question already
/// answered twice, and printing a dash would claim the session spent nothing when what is
/// missing is a reason to believe either reading.
private struct SessionTokens {
    /// One segment per model whose count is believed, across every session summed here.
    /// Empty when nothing is countable, which is not the same as a measured zero — that
    /// arrives as a segment reading 0.
    private(set) var counted: [TokenUsageSegment] = []
    /// Models two sources counted too differently to choose between: present, unnumbered.
    private(set) var contested: Set<String> = []

    init(sessions: [AgentSessionSnapshot]) {
        for session in sessions {
            guard case .reported = session.usage else { continue }
            let part = session.usage.believableSegments(cost: session.cost)
            counted += part.countable
            contested.formUnion(part.contestedModels)
        }
    }

    /// One session's share, resolved by the same rule the card-wide sum is.
    init(_ resolved: BelievableSegments) {
        counted = resolved.countable
        contested = resolved.contestedModels
    }

    /// Whether any model's count survives to be printed. **A contested model is not one
    /// of them**: it has a reading and no reason to believe it, so a session whose models
    /// are all contested has no figure to print and must not print a zero.
    var hasCountableFigure: Bool { !counted.isEmpty }

    /// **Cache reads and reasoning count, because the money beside this figure bills
    /// them.** A total of input plus output alone describes less work than the dollar
    /// figure on the same row, and the gap is worst in the case a user is most likely to
    /// hit: a session whose only tokens are cache reads totals 0 and would print `0 tok`
    /// beside a real price. The four components are all on the wire, so an audit that needs
    /// them can have them; a 208pt card does not have room for a cache column beside the
    /// model names, and a separate cache figure would be a second number to keep agreeing
    /// with this one.
    var total: Int { counted.reduce(0) { $0 + $1.billableTotal } }

    var modelCount: Int { Set(counted.map(\.modelID)).count }

    /// One clause per model, sorted so the row does not reorder between reads. A
    /// contested model joins the split without a number rather than being dropped: a
    /// split listing a model and no figure reads as a model that used nothing.
    var split: String {
        let counted = self.counted
            .sorted { $0.modelID < $1.modelID }
            .map { "\($0.modelID) \(Fmt.tokens($0.billableTotal))" }
        return (counted + contested.sorted().map { "\($0) contested" })
            .joined(separator: " · ")
    }
}

/// One session, in one line.
///
/// The line is built around what is *missing* as much as what is there: a session
/// that reported nothing and a session that cost nothing look identical in a
/// number-only row, and they are opposite facts. So the reason travels with the
/// figure rather than being dropped for want of space.
private struct SessionLine: View {
    let session: AgentSessionSnapshot

    var body: some View {
        HStack(spacing: 6) {
            Text(session.clientName ?? "agent")
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            Text(usage)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(cost)
                .font(.system(size: 10, design: .monospaced))
        }
    }

    private var usage: String {
        switch session.usage {
        case .reported:
            // One source's reading per model: two sources describing one session are
            // alternative measurements of the same work, so showing both would report
            // the tokens twice — and disagree with the cost on the right of the row,
            // which bills one of them.
            let tokens = SessionTokens(session.usage.believableSegments(cost: session.cost))
            guard tokens.hasCountableFigure else {
                // Nothing survived to print. Contested models are named, because the
                // repair is a user choosing a source; a fold that yielded no segment at
                // all is the shape the three-state type exists to rule out, and "0 tok"
                // is the one answer that must not be given either way.
                guard !tokens.contested.isEmpty else { return "no count" }
                return tokens.contested.count == 1
                    ? "1 model contested"
                    : "\(tokens.contested.count) models contested"
            }
            // One model prints as it always did. Several print with their split, because
            // a single number cannot say two rates were involved — or that one of them
            // has no count at all.
            guard tokens.modelCount + tokens.contested.count > 1 else {
                return "\(Fmt.tokens(tokens.total)) tok"
            }
            return "\(Fmt.tokens(tokens.total)) tok (\(tokens.split))"
        case .notReported(let reason):
            // Every reason in one short phrase each, so a row says which rather
            // than showing a dash that reads as zero.
            switch reason {
            case .noSource: return "no source"
            case .logUnreadable: return "log unreadable"
            case .unrecognizedFormat: return "log format unknown"
            case .awaitingFirstReport: return "not reported yet"
            // **One state, two causes, so the string names the state and not a cause.**
            // `ambiguousMatch` means either one conversation that several connections fell
            // inside, or several conversations one connection fell inside — and the second
            // reading, "2 logs match", was wrong for the first, which is the ordinary case:
            // a user with one agent and two MCP connections reads "2 logs match", looks for
            // two, finds one, and concludes the tool is broken. The hardcoded `2` was
            // loose for five candidates long before it and is categorically wrong now.
            //
            // Neither cause is an action the user can take — a Portmaster MCP connection is
            // not something a person closes, and there is nothing to close an agent window
            // for — so the old "you may be able to resolve it by closing one" was advice
            // that could not be acted on.
            //
            // **No count, and no "which".** `UsageUnavailableReason` names both causes the
            // same way, and a withdrawal record cannot carry which: `TokenUsageRecord` has
            // no column for it and adding one is a schema migration. Showing the real count
            // or naming the cause needs somewhere to carry it first.
            case .ambiguousMatch: return "log not attributable"
            }
        }
    }

    private var cost: String {
        switch session.cost {
        case .priced(let usd, _, let lines):
            guard lines.count > 1 else { return Fmt.usd(usd) }
            let split = lines
                .map { "\($0.modelID) \(Fmt.usd($0.usd))" }
                .joined(separator: " · ")
            return "\(Fmt.usd(usd)) (\(split))"
        case .notPriced(let models):
            // Name the models: entering one price does not make the total computable
            // while another is still unpriced.
            return models.count == 1 ? "not priced: \(models[0])" : "not priced: \(models.count) models"
        case .conflict(let disagreements):
            // A word with nothing to act on is the wrong thing to show. The repair here
            // is choosing a source, so the two totals it is choosing between go on the
            // row along with which source reported each — **all of them**, because the
            // usage cell on this same row already says how many models are contested and
            // showing one pair here would contradict that count inside one line. A model
            // id repeated per pair is what keeps the row unambiguous once it runs long.
            guard !disagreements.isEmpty else { return "sources differ" }
            let parts = disagreements.map { disagreement in
                let totals = disagreement.totals
                    .sorted { $0.key.rawValue < $1.key.rawValue }
                    .map { "\($0.key.rawValue) \(Fmt.tokens($0.value))" }
                    .joined(separator: " / ")
                return "\(disagreement.modelID) \(totals)"
            }
            .joined(separator: " · ")
            return "sources differ (\(parts))"
        case .noUsage:
            // Not a dash: a dash reads as free, and a session nobody counted is not a
            // session that cost nothing.
            return "no usage"
        }
    }
}
