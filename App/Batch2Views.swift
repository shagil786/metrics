import SwiftUI
import PortmasterCore

/// All menu-bar app rows share the same navigation and confirmed stop path.
struct MenuAppActions: ViewModifier {
    @EnvironmentObject private var model: AppModel
    let app: AppRollup
    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture { model.openApp(app) }
            .contextMenu {
                Button("Inside \(app.displayName)") { model.openApp(app) }
                Button("Quit \(app.displayName)…") { model.openApp(app, quit: true) }
                    .disabled(model.prefs.fixtureMode)
            }
            .accessibilityAction(named: "Inside App") { model.openApp(app) }
            .accessibilityAction(named: "Quit App") {
                if !model.prefs.fixtureMode { model.openApp(app, quit: true) }
            }
            .help("Click for Inside App; right-click for Quit")
    }
}

struct ThermalContextView: View {
    @EnvironmentObject private var model: AppModel
    private var pressure: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Heat context").font(.callout.weight(.semibold))
            Text("macOS thermal pressure: \(pressure)").font(.caption)
            // Only readings justify pairing heat with per-app CPU activity: with no
            // reading observed, "waiting" is the honest state, and the caption
            // below this branch already says readings cannot attribute heat.
            if model.snapshot.system.thermal?.availability == .available {
                ForEach(Array(model.snapshot.rollups.filter { $0.totalCPU > 0.1 }
                    .sorted { $0.totalCPU > $1.totalCPU }.prefix(3))) { app in
                    Button { model.openApp(app) } label: {
                        HStack {
                            Text(app.displayName).lineLimit(1)
                            Spacer()
                            Text(model.cpuText(app.totalCPU)).monospacedDigit()
                        }
                    }.buttonStyle(.plain).font(.caption)
                }
                Text("Current CPU activity suggests possible heat contributors; sensor readings cannot attribute heat to an app. Per-app GPU activity is unavailable.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("Waiting for sensor readings.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct DockerStopSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let container: DockerContainer
    @State private var busy = false
    @State private var message: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Stop \(container.name)?").font(.title2.bold())
            Text("Docker will ask the container to stop, then kill it after 10 seconds if it hasn't exited. Work in progress may be interrupted. Its files and configuration are retained.")
            Text(container.id).font(.caption.monospaced()).textSelection(.enabled)
            if let message { Text(message).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                Button(busy ? "Stopping…" : "Stop Container", role: .destructive) {
                    guard !model.prefs.fixtureMode else { return }
                    busy = true
                    Task {
                        let id = container.id
                        let stopped = await Task.detached(priority: .utility) { DockerCollector().stop(id: id) }.value
                        busy = false
                        model.engine.refreshContainers()
                        if stopped { dismiss() }
                        else { message = "Docker could not confirm the stop. Check the runtime and refresh before trying again." }
                    }
                }.disabled(busy || model.prefs.fixtureMode)
            }
        }.padding(24).frame(width: 460)
        .interactiveDismissDisabled(busy)
    }
}
