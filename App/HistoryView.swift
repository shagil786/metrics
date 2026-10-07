import SwiftUI
import Charts
import PortmasterCore

struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var window: HistoryRange = .hours24
    @State private var metric = "cpu"
    @State private var appID = ""
    @State private var points: [HistoryPlot.Point] = []
    @State private var trends: [AppHistoryTrend] = []
    @State private var legacy: [HistoryStore.ProcessTrend] = []
    @State private var confirmingClear = false
    @State private var chartRefresh = Date()
    @State private var rankingRefresh = Date()
    @State private var loadingChart = false
    @State private var loadingRankings = false
    @State private var chartError: String?
    @State private var rankingError: String?
    @State private var legacyError: String?
    @State private var legacyExpanded = false
    @State private var loadingLegacy = false
    private var appMetrics: [String] { ["cpu", "memory", "download", "upload", "diskRead", "diskWrite"] }
    private var metrics: [String] { appID.isEmpty ? ["cpu", "memory"] + HistoryResource.allCases.map(\.rawValue) : appMetrics }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Picker("Reading", selection: $metric) {
                            ForEach(metrics, id: \.self) { Text(label($0)).tag($0) }
                        }.frame(width: 270)
                        Picker("Scope", selection: $appID) {
                            Text("This Mac").tag("")
                            ForEach(trends) { Text($0.displayName).tag($0.id) }
                            if !appID.isEmpty && !trends.contains(where: { $0.id == appID }) {
                                Text(appID.components(separatedBy: "/").last ?? appID).tag(appID)
                            }
                        }.frame(width: 310)
                        Spacer()
                    }
                    Text("Recorded while Portmaster runs · retention: \(model.prefs.retention.label). Gaps indicate unavailable readings or paused sampling.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let status = model.historyActionStatus {
                        Label(status, systemImage: "checkmark.circle").font(.caption).foregroundStyle(.teal)
                    }
                    if let error = model.historyError ?? chartError ?? model.clearHistoryError {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(error).foregroundStyle(.red)
                            Button("Try Again", action: reload)
                        }.frame(maxWidth: .infinity, minHeight: 230, alignment: .leading)
                    } else if loadingChart {
                        ProgressView("Loading \(label(metric).lowercased()) history…")
                            .frame(maxWidth: .infinity, minHeight: 230)
                    } else if points.isEmpty {
                        EmptyStateView(symbol: "clock.arrow.circlepath", title: "No readings in this window", detail: "This resource may be unavailable on this Mac, or its history has not been recorded yet.", buttonTitle: "Refresh", action: reload)
                            .frame(height: 230)
                    } else {
                        ChartCard(title: "\(label(metric)) · \(unit)") {
                            Chart(points) { p in
                                LineMark(x: .value("Time", p.at), y: .value(unit, convert(p.value)), series: .value("Segment", p.segment))
                                    .foregroundStyle(.teal)
                                if points.count == 1 {
                                    PointMark(x: .value("Time", p.at), y: .value(unit, convert(p.value))).foregroundStyle(.teal)
                                }
                            }
                            .chartXScale(domain: chartRefresh.addingTimeInterval(-window.seconds)...chartRefresh)
                            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) }
                            .chartYScale(domain: metric == "cpu" && appID.isEmpty || metric == "gpu" || metric == "battery" ? 0...100 : automaticDomain)
                        }.frame(height: 245)
                    }
                    rankings
                    DisclosureGroup("Legacy process/project rankings", isExpanded: $legacyExpanded) {
                        if loadingLegacy { ProgressView("Loading legacy rankings…") }
                        if let error = legacyError { Text(error).foregroundStyle(.red) }
                        Text("Older records have no app identity or elapsed-time weighting. These rankings are shown separately.")
                            .font(.caption).foregroundStyle(.secondary)
                        if !loadingLegacy && legacy.isEmpty && legacyError == nil {
                            Text("No legacy records in this window.").foregroundStyle(.secondary)
                        }
                        ForEach(legacy.prefix(8)) { t in
                            HStack {
                                Text(t.projectID == nil ? t.key : (t.key.components(separatedBy: "/").last ?? t.key)).lineLimit(1).help(t.key)
                                Spacer(); Text("peak \(Fmt.bytes(UInt64(max(0, t.peakMemory))))").foregroundStyle(.secondary)
                            }
                        }
                    }
                    .task(id: LegacyRequest(since: rankingSince, expanded: legacyExpanded)) {
                        guard legacyExpanded else { return }
                        await loadLegacy(since: rankingSince)
                    }
                }.padding(16)
            }
        }
        .task(id: ChartRequest(since: chartSince, metric: metric, appID: appID)) {
            await loadChart(since: chartSince, metric: metric, appID: appID)
        }
        .task(id: rankingSince) { await loadRankings(since: rankingSince) }
        .onChange(of: appID) { if !metrics.contains(metric) { metric = "cpu" } }
        .task {
            // Keep the chart current without restarting expensive rankings every sample.
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                if !loadingChart { chartRefresh = Date() }
                if !loadingRankings && Date().timeIntervalSince(rankingRefresh) >= 60 { rankingRefresh = Date() }
            }
        }
        .confirmationDialog("Clear all stored history?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Clear All History", role: .destructive) { model.clearHistory(); reload() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This deletes all system, app, process and port history, and every recorded agent session and its token usage, stored on this Mac. It cannot be undone.") }
    }

    private var controls: some View {
        HStack {
            Picker("Window", selection: $window) {
                ForEach(HistoryRange.allCases) { Text($0.label).tag($0) }
            }.pickerStyle(.segmented).fixedSize()
            Spacer()
            Button("Refresh", action: reload).disabled(loadingChart || loadingRankings)
            Button("Clear…") { confirmingClear = true }
        }.padding(12)
    }

    private var rankings: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Busiest apps · observed CPU time").font(.headline)
                Spacer()
                if loadingRankings { ProgressView().controlSize(.small).accessibilityLabel("Loading app rankings") }
            }
            if let error = rankingError { Text(error).foregroundStyle(.red) }
            Text("CPU seconds include all cores. Average CPU covers recorded intervals, not time while Portmaster was closed. App helpers are combined by their bundle path; CLI groups use their executable name.")
                .font(.caption).foregroundStyle(.secondary)
            if trends.isEmpty && !loadingRankings && rankingError == nil { Text("New app history will appear after sampling begins.").foregroundStyle(.secondary) }
            ForEach(trends.prefix(12)) { t in
                HStack {
                    Button { appID = t.id } label: { Label(t.displayName, systemImage: "chart.xyaxis.line").lineLimit(1) }.buttonStyle(.link).help("Show history for " + t.displayName)
                    Spacer()
                    Text(String(format: "%.1f CPU s", t.cpuSeconds)).monospacedDigit()
                    Text("avg \(model.cpuText(t.averageCPU))").monospacedDigit().frame(width: 120, alignment: .trailing)
                    Text("peak \(Fmt.bytes(UInt64(max(0, t.peakMemory))))").monospacedDigit().frame(width: 100, alignment: .trailing)
                }
                Divider().opacity(0.4)
            }
        }
    }
    private func label(_ key: String) -> String {
        key == "cpu" ? "CPU" : key == "memory" ? "Memory used" : HistoryResource(rawValue: key)?.label ?? key
    }
    private var unit: String {
        switch metric {
        case "cpu", "gpu", "battery": "%"
        case "memory": "GiB"
        case "download", "upload": model.prefs.presentation.networkUnit == .bits ? "Mbit/s" : "MiB/s"
        case "diskRead", "diskWrite": "MiB/s"
        case "cpuTemperature", "gpuTemperature", "hottestTemperature": model.prefs.presentation.temperatureUnit == .fahrenheit ? "°F" : "°C"
        case "fan": "RPM"
        default: "W"
        }
    }
    private var automaticDomain: ClosedRange<Double> { 0...max(1, (points.map { convert($0.value) }.max() ?? 1) * 1.1) }
    private func convert(_ value: Double) -> Double {
        switch metric {
        case "cpu": return appID.isEmpty ? value : model.processCPUValue(value) ?? value
        case "memory", "diskRead", "diskWrite": return value / (metric == "memory" ? 1_073_741_824 : 1_048_576)
        case "download", "upload": return model.prefs.presentation.networkUnit == .bits ? value * 8 / 1_000_000 : value / 1_048_576
        case "cpuTemperature", "gpuTemperature", "hottestTemperature": return model.prefs.presentation.temperatureUnit == .fahrenheit ? value * 1.8 + 32 : value
        default: return value
        }
    }
    private var chartSince: Date { chartRefresh.addingTimeInterval(-window.seconds) }
    private var rankingSince: Date { rankingRefresh.addingTimeInterval(-window.seconds) }
    private struct ChartRequest: Hashable { let since: Date; let metric: String; let appID: String }
    private struct LegacyRequest: Hashable { let since: Date; let expanded: Bool }
    private func reload() { chartRefresh = Date(); rankingRefresh = chartRefresh }

    @MainActor private func loadChart(since: Date, metric: String, appID: String) async {
        guard let reader = model.historyReader else { return }
        loadingChart = true; chartError = nil; points = []
        do {
            let result = try await reader.chart(since: since, metric: metric, appID: appID)
            try Task.checkCancellation()
            points = result; loadingChart = false
        } catch {
            guard !Task.isCancelled else { return }
            chartError = "Could not read history: \(error.localizedDescription)"; loadingChart = false
        }
    }
    @MainActor private func loadRankings(since: Date) async {
        guard let reader = model.historyReader else { return }
        loadingRankings = true; rankingError = nil; trends = []
        do {
            let result = try await reader.appTrends(since: since)
            try Task.checkCancellation()
            trends = result; loadingRankings = false
        } catch {
            guard !Task.isCancelled else { return }
            rankingError = "Could not read app rankings: \(error.localizedDescription)"; loadingRankings = false
        }
    }
    @MainActor private func loadLegacy(since: Date) async {
        guard let reader = model.historyReader else { return }
        loadingLegacy = true; legacyError = nil; legacy = []
        do {
            let result = try await reader.legacyTrends(since: since)
            try Task.checkCancellation()
            legacy = result; loadingLegacy = false
        } catch {
            guard !Task.isCancelled else { return }
            legacyError = "Could not read legacy rankings: \(error.localizedDescription)"; loadingLegacy = false
        }
    }
}
