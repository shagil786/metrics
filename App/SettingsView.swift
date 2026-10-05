// Settings: menu bar metric, sampling, history retention, login item,
// privacy summary, the MCP host, and the clearly-labeled preview (fixture) mode.
import AppKit
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

    /// The MCP host page: what an AI client may do here, whether Portmaster is
    /// listening, where the audit log is, how to install the client-side binary, and who
    /// is connected right now.
    ///
    /// A separate view so it can hold `@ObservedObject` on the controller — the sidebar's
    /// host is the app delegate, not an environment object, so an observed reference has
    /// to be made where it is read.
    @ViewBuilder
    private var mcpTab: some View {
        if let host = AppDelegate.shared?.mcpHost {
            MCPSettingsTab(host: host)
        } else {
            Text("Portmaster's MCP host is not available in this build.")
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

// MARK: - The MCP page

/// Settings for the MCP host: the mutation policy, whether the host is listening, where
/// the audit log is, how to install the client-side binary, and who is connected.
///
/// Its own view because it observes `MCPHostController` directly. The sidebar's other
/// pages read `AppModel` from the environment; this one reads the app delegate's host,
/// which is `@MainActor` and owned for the life of the process rather than injected.
///
/// The words are `MCPSettingsCopy`'s and the install path is `MCPInstallCommand`'s,
/// because the app target has no test target and a sentence nothing can check is a
/// sentence that drifts. What is left here is drawing, and the three actions that are
/// genuinely the app's: copying to the pasteboard, asking Finder to reveal the log, and
/// writing the chosen mode through `setMode`.
struct MCPSettingsTab: View {
    @ObservedObject var host: MCPHostController
    /// Set by the copy button, and cleared by the timer, so the confirmation is a fact
    /// about this click rather than a permanent claim that something was copied.
    @State private var copied = false
    @State private var copyTimer: Timer?

    /// The `claude mcp add` line for the binary on this machine, or `nil` when it has not
    /// been built.
    ///
    /// Resolved once for the life of the process, not per appearance: it is a filesystem
    /// question, and asking it on every redraw would stat four paths per frame for a value
    /// that cannot change while Settings is open. The cost of that choice is that an app
    /// launched before `swift build` ran keeps saying the binary is missing until it is
    /// relaunched — which is a stale label rather than a wrong command, since the notice
    /// it shows is the build command, not a path.
    private static let installCommand: String? = {
        let candidates = MCPInstallCommand.binDirectories(
            packagePath: MCPInstallCommand.compiledPackagePath
        ).map { MCPInstallCommand.binaryPath(in: $0, relativeTo: "") }
        return MCPInstallCommand.locateBinary(
            in: candidates, isExecutableFile: { FileManager.default.isExecutableFile(atPath: $0) }
        ).map(MCPInstallCommand.command(binaryPath:))
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            policy
            Divider()
            status
            Divider()
            auditLog
            Divider()
            install
            Divider()
            clients
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    // MARK: The policy

    private var policy: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What an AI assistant may do here").font(.headline)
            Picker("Mutation mode", selection: Binding(
                get: { host.mode },
                set: { host.setMode($0) }
            )) {
                ForEach(MCPMutationMode.allCases, id: \.self) { mode in
                    Text(MCPSettingsCopy.modeTitle(for: mode)).tag(mode)
                }
            }
            .pickerStyle(.radioGroup)
            .accessibilityHint("How much an AI client connected to Portmaster may change")
            Text(MCPSettingsCopy.modeConsequence(for: host.mode))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Text("Reads — CPU, memory, apps, containers, projects, history — are always available in every mode.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: The status

    private var status: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Is Portmaster listening").font(.headline)
            Text(statusText)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusText: String {
        switch host.status {
        case .listening(let socket): return MCPSettingsCopy.listening(socket: socket)
        case .notRunning: return MCPSettingsCopy.notRunning
        case .failed(let reason): return MCPSettingsCopy.failed(reason: reason)
        }
    }

    // MARK: The audit log

    private var auditLog: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Audit log").font(.headline)
            Text(MCPSettingsCopy.auditLogCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(MCPSettingsCopy.auditLogPath(host.auditLogURL))
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Button("Reveal in Finder") { revealAuditLog() }
        }
    }

    // MARK: Installing the CLI

    private var install: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Use Portmaster from an AI assistant").font(.headline)
            if let command = Self.installCommand {
                Text(command)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Copy install command") { copy(command) }
                    if copied {
                        Label("Copied", systemImage: "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(.teal)
                    }
                }
            } else {
                // No path to offer rather than a path that does not exist: a clipboard
                // holding `claude mcp add` pointed at an unbuilt binary is a command that
                // fails for the person who trusted it.
                Text(MCPSettingsCopy.binaryNotBuiltNotice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(MCPSettingsCopy.installCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Asks Finder to show the audit log, or the directory holding it when the log has
    /// never been written.
    ///
    /// The alternative — always revealing the file — is a button that appears to do
    /// nothing on a machine where no mutation has been attempted, which is most machines
    /// when somebody first opens this page.
    private func revealAuditLog() {
        let url = host.auditLogURL
        NSWorkspace.shared.activateFileViewerSelecting([
            MCPSettingsCopy.revealTarget(
                logURL: url, fileExists: FileManager.default.fileExists(atPath: url.path)
            )
        ])
    }

    /// Puts the command on the pasteboard, and says so for a moment.
    ///
    /// The confirmation is cleared on a timer rather than left up: "Copied" that never goes
    /// away stops being a fact about the last click and becomes part of the page.
    private func copy(_ command: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        copied = true
        copyTimer?.invalidate()
        copyTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { _ in
            copied = false
        }
    }

    // MARK: Who is connected

    private var clients: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Connected AI clients").font(.headline)
            if host.clients.isEmpty {
                Text(MCPSettingsCopy.noClients)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(host.clients) { client in
                    Text(MCPSettingsCopy.clientRow(
                        pid: client.pid,
                        connectedAt: client.connectedAt,
                        lastCallAt: client.lastCallAt
                    ))
                    .font(.callout)
                }
            }
        }
    }
}
