// Settings: menu bar metric, sampling, history retention, login item,
// privacy summary, the MCP host, and the clearly-labeled preview (fixture) mode.
//
// The MCP page itself lives in MCPSettingsTab.swift; this file is the sidebar and the
// other tabs.
import SwiftUI
import ServiceManagement
import PortmasterCore
import PortmasterMCP

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmingClear = false
    @State private var page = "General"

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(["General", "Layout", "Alerts", "History", "Updates", "Privacy", "MCP"], id: \.self) { name in
                    Button { page = name } label: {
                        Text(name).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                            .background(page == name ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(.plain).accessibilityAddTraits(page == name ? [.isSelected] : [])
                }
                Spacer()
            }.padding(12).frame(width: 145)
            Divider()
            ScrollView {
                switch page {
                case "Layout": CustomizationSettings()
                case "Alerts": alertsTab
                case "History": historyTab
                case "Updates":
                    if let updates = AppDelegate.shared?.updates { UpdateSettings(updates: updates) }
                case "Privacy": privacyTab
                case "MCP": mcpTab
                default: generalTab
                }
            }.frame(maxWidth: .infinity)
                .scrollIndicators(.visible)
                .id(page)
        }.frame(minWidth: 700, minHeight: 500)
    }

    // MARK: General

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Units").font(.headline)
            Picker("Temperature", selection: $model.prefs.presentation.temperatureUnit) {
                Text("Celsius").tag(TemperatureUnit.celsius); Text("Fahrenheit").tag(TemperatureUnit.fahrenheit)
            }
            Text("Example: " + model.temperatureText(40)).font(.caption)
            Picker("Network speed", selection: $model.prefs.presentation.networkUnit) {
                Text("Bytes per second").tag(NetworkUnit.bytes); Text("Bits per second").tag(NetworkUnit.bits)
            }
            Text("Example: " + model.networkText(1_000_000)).font(.caption)
            Picker("App/process CPU", selection: $model.prefs.presentation.cpuScale) {
                Text("Per core (100% = one core)").tag(CPUScale.perCore)
                Text("Per Mac (100% = all cores)").tag(CPUScale.perMac)
            }
            Text("Example: " + model.cpuText(100) + " on this Mac. System CPU and GPU gauges stay whole-chip percentages; collected data and alerts do not change.").font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("Keyboard shortcuts").font(.headline)
            ShortcutEditor(title: "Open window", shortcut: $model.prefs.presentation.windowShortcut)
            ShortcutEditor(title: "Toggle dropdown", shortcut: $model.prefs.presentation.panelShortcut)
            if let shortcuts = AppDelegate.shared?.shortcuts { ShortcutRegistrationStatus(shortcuts: shortcuts) }
            Text("Keys follow physical US key positions. In the dropdown: Tab/Shift-Tab change tabs, ⌘1–⌘0 select the first ten visible tabs, and Esc closes it.").font(.caption).foregroundStyle(.secondary)
            Divider()
            Picker("Sampling", selection: Binding(
                get: { model.prefs.cadence },
                set: { model.prefs.cadence = $0; model.applyCadence() }
            )) {
                ForEach(SamplingCadence.allCases) { c in
                    Text(c.label).tag(c)
                }
            }
            .accessibilityHint("How often live data refreshes; slower when no window is visible")

            Toggle("Launch at login", isOn: Binding(
                get: { SMAppService.mainApp.status == .enabled },
                set: { model.setLaunchAtLogin($0) }
            ))
            Text("Status: \(model.loginItemStatus)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Show in Dock", isOn: Binding(
                get: { model.prefs.showInDock },
                set: { model.prefs.showInDock = $0; model.applyDockPolicy() }
            ))

            Divider()

            Toggle("Use preview data", isOn: Binding(
                get: { model.prefs.fixtureMode },
                set: { model.prefs.fixtureMode = $0; model.rebuildEngineForFixtureMode() }
            ))
            Text("Preview data is synthetic and clearly labeled everywhere it appears. It is never the default and never mixed with live monitoring.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    // MARK: Alerts

    private var alertsTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Acting-up alerts", isOn: Binding(
                get: { model.prefs.alertsEnabled },
                set: { enabled in
                    model.prefs.alertsEnabled = enabled
                    if enabled {
                        Task { await model.enableAlertsRequested() }
                    }
                }
            ))
            Button("Enable Notification Center…") {
                model.prefs.alertsEnabled = true
                Task { await model.enableAlertsRequested() }
            }
            Text(model.notificationStatus).font(.caption).foregroundStyle(.secondary)
            Text("Watches every app for sustained CPU (50%+ average over 10 minutes), memory growth (1 GB+ within an hour), and sustained disk or network hammering (50 MB/s written or 10 MB/s downloaded, averaged over 10 minutes) — then tells you in plain language, at most once per app per hour. Notification Center delivery requires macOS permission.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Text("Not watched")
                .font(.subheadline.weight(.medium))
            Text("Per-app power draw isn't alertable — macOS doesn't expose it through supported APIs. Portmaster never fabricates it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Text("Alerts are observations, not verdicts. A quiet-looking app may be doing exactly what you started it to do.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    // MARK: History

    private var historyTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Keep history for", selection: Binding(
                get: { model.prefs.retention },
                set: { model.prefs.retention = $0; model.pruneNow() }
            )) {
                ForEach(HistoryRetention.allCases) { r in
                    Text(r.label).tag(r)
                }
            }
            .accessibilityHint("Older samples are deleted automatically")

            let counts = model.historyRowCounts
            let extended = model.historyStore?.extendedRowCounts() ?? (apps: 0, resources: 0)
            Text("Stored now: \(extended.apps) app samples, \(extended.resources) resource samples; \(counts.cpu) CPU samples, \(counts.mem) memory samples, \(counts.process) process points, \(counts.port) port events")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("History is stored in Application Support/Portmaster on this Mac and is never uploaded.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Clear All History…", role: .destructive) {
                confirmingClear = true
            }
            .confirmationDialog(
                "Clear all stored history?",
                isPresented: $confirmingClear,
                titleVisibility: .visible
            ) {
                Button("Clear All History", role: .destructive) {
                    model.clearHistory()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This deletes all system, app, process and port history stored on this Mac. It cannot be undone.")
            }

            // Clear failures are shown verbatim — never swallowed silently.
            if let status = model.historyActionStatus {
                Label(status, systemImage: "checkmark.circle").font(.caption).foregroundStyle(.teal)
            }
            if let err = model.clearHistoryError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    // MARK: Privacy

    private var privacyTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("What Portmaster collects", systemImage: "internaldrive")
                .font(.headline)
            VStack(alignment: .leading, spacing: 5) {
                bullet("CPU, memory, and process metrics sampled locally")
                bullet("Listening TCP ports and the processes that own them")
                bullet("Project association derived from working directories")
                bullet("Command paths and arguments, shown only when you open details — kept on this Mac")
                  bullet("Audio device/activity and connected Bluetooth battery readings")
                  bullet("Audio is captured only for an explicitly enabled app control or microphone meter, and is never saved or sent")
            }
            .font(.callout)

            Label("What never happens", systemImage: "shield.lefthalf.filled")
                .font(.headline)
            VStack(alignment: .leading, spacing: 5) {
                bullet("No account, analytics, telemetry, ads, or cloud upload")
                bullet("Process names, paths, ports, and project names never leave this Mac")
                bullet("No automatic process termination — every stop action is user-initiated and confirmed")
                bullet("No permission requests for the read-only dashboard")
            }
            .font(.callout)

            Spacer()
            Button("Show Welcome…") { AppDelegate.shared?.openWelcomeWindow() }
            Text("When release updates are configured, update checks contact that release host. System profiling is disabled and local observations are never uploaded.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    // MARK: MCP

    /// The MCP host page, in its own file (`MCPSettingsTab.swift`).
    ///
    /// A separate view so it can hold `@ObservedObject` on the controller — the sidebar's
    /// host is the app delegate, not an environment object, so an observed reference has
    /// to be made where it is read.
    @ViewBuilder
    private var mcpTab: some View {
        if let host = AppDelegate.shared?.mcpHost {
            MCPSettingsTab(host: host)
        } else {
            Text(MCPSettingsCopy.Chrome.noHostAvailable)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•")
            Text(text)
        }
    }
}
