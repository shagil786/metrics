import SwiftUI
import PortmasterCore

struct AudioPane: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var controls: AudioControls
    var compact = false
    @State private var outputDraft: Float = 0
    @State private var draggingOutput = false
    private var sample: AudioSample? { model.snapshot.audio }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let error = controls.error { ErrorBanner(message: error) { controls.clearError() } }
            ArrangedSections(scope: "audio", sections: [
                (id: "output", title: "Output", view: AnyView(outputSection)),
                (id: "apps", title: "App mixer", view: AnyView(appSection)),
                (id: "input", title: "Input", view: AnyView(inputSection))
            ])
        }
        .padding(compact ? 10 : 16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onChange(of: sample?.output?.volume, initial: true) { _, value in
            if !draggingOutput { outputDraft = value ?? 0 }
        }
        .onChange(of: sample?.output?.id) { _, _ in draggingOutput = false; outputDraft = sample?.output?.volume ?? 0 }
    }

    private var outputSection: some View {
        HStack(spacing: 14) {
            Image(systemName: "speaker.wave.2.fill").foregroundStyle(.purple)
                .frame(width: 32, height: 32).background(.purple.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                Text("Output").font(.system(size: 13, weight: .semibold))
                Text(sample?.output?.name ?? (sample == nil ? "Gathering audio data…" : "No output device"))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(compact ? 2 : 1)
            }.frame(maxWidth: compact ? .infinity : 190, alignment: .leading)
            if let output = sample?.output, output.volume != nil && output.volumeWritable {
                Slider(value: $outputDraft, in: 0...1, onEditingChanged: { editing in
                    draggingOutput = editing
                    if !editing { controls.setSystemVolume(device: output.id, value: outputDraft, preview: model.prefs.fixtureMode) }
                }).disabled(model.prefs.fixtureMode)
                    .accessibilityLabel("Output volume").accessibilityValue("\(Int(outputDraft * 100)) percent")
                    .frame(maxWidth: compact ? 80 : 320)
                Text("\(Int(outputDraft * 100))%").font(.system(size: 13, weight: .semibold)).monospacedDigit().frame(width: 42, alignment: .trailing)
            } else {
                Spacer(minLength: 0)
                Text("Volume unavailable").font(.caption).foregroundStyle(.secondary)
                    .help("This output does not expose a writable volume control.")
            }
            if !compact { Spacer(minLength: 0) }
        }.padding(16).frame(minHeight: 70).cardBackground(cornerRadius: 14)
    }

    private var inputSection: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                let inputClients = sample?.clients?.filter { $0.inputActive == true } ?? []
                if sample?.clients == nil {
                    Text("Input activity is unavailable.").font(.caption).foregroundStyle(.secondary)
                } else if inputClients.isEmpty {
                    Text(sample?.clients?.contains { $0.inputActive == nil } == true ? "No active input confirmed; some readings are unavailable." : "No active input streams reported.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(inputClients) { client in Text(clientName(client)).font(.caption) }
                    Text("Input activity can include virtual devices.").font(.caption2).foregroundStyle(.secondary)
                }
                HStack {
                    if controls.micEnabled {
                        ProgressView(value: Double(controls.micLevel)).tint(.green).frame(maxWidth: 220)
                        Text(String(format: "%.0f dBFS", 20 * log10(max(0.000001, controls.micLevel)))).font(.caption.monospaced())
                        Button("Stop meter") { controls.stopMeter() }
                    } else {
                        Button("Enable microphone meter…") { controls.startMeter(preview: model.prefs.fixtureMode) }
                            .disabled(sample?.input == nil || model.prefs.fixtureMode)
                    }
                }
                Text("Requires microphone access. Samples stay in memory and are never saved or sent.")
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(.top, 10)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "mic.fill").foregroundStyle(.purple)
                Text("Microphone").font(.system(size: 13, weight: .medium))
                Spacer()
                Text(sample?.input?.name ?? "Input unavailable").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
        }.padding(14).cardBackground(cornerRadius: 14)
    }

    private var appSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text("App").frame(maxWidth: .infinity, alignment: .leading)
                if !compact { Text("Status").frame(width: 70, alignment: .leading) }
                Text("Volume").frame(width: compact ? 132 : 240, alignment: .leading)
                if !compact { Text("Level").frame(width: 44, alignment: .trailing) }
            }.font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 10)
            Divider().padding(.horizontal, 14)
            if #available(macOS 14.2, *) {
                let apps = activeApps
                if apps.isEmpty {
                    Text(sample?.clients == nil ? "App audio activity unavailable." : "Play audio in an app to show its volume control.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).padding(18)
                }
                ForEach(apps) { app in
                    mixerRow(app)
                    if app.id != apps.last?.id { Divider().padding(.leading, 48) }
                }
            } else {
                Text("Per-app control requires macOS 14.2 or later.").font(.caption).padding(18)
            }
            DisclosureGroup("About app volume control") {
                Text("Enabling control may request Audio Recording access. 100% preserves the original level. Controls reset when removed or the app quits; nothing is recorded.")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 6)
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(14)
        }.cardBackground(cornerRadius: 14)
    }

    private var activeApps: [AppRollup] {
        let pids = Set(sample?.clients?.filter {
            $0.outputActive == true && $0.pid != ProcessInfo.processInfo.processIdentifier
                && $0.outputDevices?.contains(sample?.output?.id ?? 0) == true
        }.map(\.pid) ?? [])
        return model.snapshot.rollups.filter { app in controls.levels[app.id] != nil || app.processes.contains { pids.contains($0.pid) } }
            .sorted { $0.displayName == $1.displayName ? $0.id < $1.id : $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }
    private func clientName(_ client: AudioClient) -> String {
        model.snapshot.rollups.first { $0.processes.contains { $0.pid == client.pid } }?.displayName ?? client.bundleID ?? "Audio client"
    }
    private func audioStatus(_ app: AppRollup) -> String {
        let pids = Set(app.processes.map(\.pid))
        let clients = sample?.clients?.filter { pids.contains($0.pid) } ?? []
        if clients.contains(where: { $0.outputActive == true }) { return "Playing" }
        if !clients.isEmpty && clients.allSatisfy({ $0.outputActive == false }) { return "Silent" }
        return "—"
    }
    private func enable(_ app: AppRollup) {
        let pids = Set(app.processes.map(\.pid))
        let clients = sample?.clients?.filter { pids.contains($0.pid) && $0.outputActive == true && $0.outputDevices?.contains(sample?.output?.id ?? 0) == true } ?? []
        controls.enable(id: app.id, clients: clients, preview: model.prefs.fixtureMode)
    }
    @ViewBuilder private func mixerRow(_ app: AppRollup) -> some View {
        if compact { compactMixerRow(app) } else {
        HStack(spacing: 12) {
            AppIconView(bundlePath: app.isAppBundle ? app.id : nil, name: app.displayName).frame(width: 22, height: 22)
            Text(app.displayName).font(.system(size: 13, weight: .medium)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            if !compact { Text(audioStatus(app)).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 70, alignment: .leading) }
            Group {
                if let level = controls.levels[app.id] {
                    HStack(spacing: 6) {
                        Button { controls.mute(app.id) } label: { Image(systemName: level == 0 ? "speaker.slash" : "speaker.wave.2") }
                            .accessibilityLabel(level == 0 ? "Unmute \(app.displayName)" : "Mute \(app.displayName)")
                        Slider(value: Binding(get: { Double(controls.levels[app.id] ?? 1) }, set: { controls.setLevel(id: app.id, value: Float($0)) }), in: 0...1)
                            .accessibilityLabel("\(app.displayName) volume").accessibilityValue("\(Int(level * 100)) percent")
                        Button { controls.disable(app.id) } label: { Image(systemName: "xmark.circle") }
                            .accessibilityLabel("Remove \(app.displayName) volume control")
                    }
                } else {
                    Button(controls.busy.contains(app.id) ? "Enabling…" : "Enable control…") { enable(app) }
                        .disabled(model.prefs.fixtureMode || controls.busy.contains(app.id))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help("May request Audio Recording permission")
                }
            }.frame(width: compact ? 132 : 240)
            Text(controls.levels[app.id].map { "\(Int($0 * 100))%" } ?? "—")
                .font(.system(size: 12)).monospacedDigit().frame(width: 44, alignment: .trailing)
        }.buttonStyle(.borderless).padding(.horizontal, 14).padding(.vertical, 10)
        }
    }
    private func compactMixerRow(_ app: AppRollup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                AppIconView(bundlePath: app.isAppBundle ? app.id : nil, name: app.displayName).frame(width: 22, height: 22)
                Text(app.displayName).font(.system(size: 12, weight: .medium)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                if let level = controls.levels[app.id] {
                    Button { controls.mute(app.id) } label: { Image(systemName: level == 0 ? "speaker.slash" : "speaker.wave.2") }
                        .accessibilityLabel(level == 0 ? "Unmute \(app.displayName)" : "Mute \(app.displayName)")
                    Button { controls.disable(app.id) } label: { Image(systemName: "xmark.circle") }
                        .accessibilityLabel("Remove \(app.displayName) volume control")
                } else {
                    Button(controls.busy.contains(app.id) ? "Enabling…" : "Enable…") { enable(app) }
                        .disabled(model.prefs.fixtureMode || controls.busy.contains(app.id))
                        .accessibilityLabel("Enable \(app.displayName) volume control")
                }
            }
            if let level = controls.levels[app.id] {
                HStack {
                    Slider(value: Binding(get: { Double(controls.levels[app.id] ?? 1) }, set: { controls.setLevel(id: app.id, value: Float($0)) }), in: 0...1)
                        .accessibilityLabel("\(app.displayName) volume").accessibilityValue("\(Int(level * 100)) percent")
                    Text("\(Int(level * 100))%").font(.system(size: 11)).monospacedDigit().frame(width: 36)
                }
            }
        }.buttonStyle(.borderless).padding(.horizontal, 14).padding(.vertical, 10)
    }
}

struct BluetoothPane: View {
    @EnvironmentObject private var model: AppModel
    var compact = false
    private var devices: [BluetoothBatteryDevice] { model.snapshot.bluetooth?.devices ?? [] }
    private var lowest: (name: String, value: Int)? {
        devices.flatMap { device in device.batteries.values.map { (name: device.name, value: $0) } }.min { $0.value < $1.value }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(systemName: "antenna.radiowaves.left.and.right").foregroundStyle(.blue)
                    .frame(width: 32, height: 32).background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.snapshot.bluetooth == nil ? "Gathering devices…" : "\(devices.count) connected").font(.system(size: 13, weight: .semibold))
                    if let lowest { Text("Lowest battery: \(lowest.name), \(lowest.value)%").lineLimit(1).font(.system(size: 11)).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Button("Refresh") { model.engine.refreshPeripherals() }.buttonStyle(.borderless).font(.system(size: 12))
            }.padding(16).frame(minHeight: 70).cardBackground(cornerRadius: 14)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Device").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Battery").frame(width: compact ? 80 : 180, alignment: .leading)
                    Text("Level").frame(width: 42, alignment: .trailing)
                }.font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 10)
                Divider().padding(.horizontal, 14)
                if devices.isEmpty { Text(model.snapshot.bluetooth == nil ? "Gathering connected-device data…" : "No connected devices reported.").font(.caption).foregroundStyle(.secondary).padding(18) }
                ForEach(devices) { device in
                    deviceRows(device)
                    if device.id != devices.last?.id { Divider().padding(.leading, 48) }
                }
                Text(model.snapshot.bluetooth?.inventoryAvailable == false ? "Showing exposed battery readings; device inventory is unavailable." : "Readings update periodically. Some devices do not report battery levels.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).padding(14)
            }.cardBackground(cornerRadius: 14)
        }.padding(compact ? 10 : 16).frame(maxWidth: .infinity, alignment: .topLeading)
    }
    private func deviceRows(_ device: BluetoothBatteryDevice) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: symbol(device.name)).foregroundStyle(.blue).frame(width: 24, height: 24)
                    .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                Text(device.name).font(.system(size: 13, weight: .medium)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).help(device.name)
                if device.batteries.count == 1, let value = device.batteries.values.first { batteryReading(value) }
                else if device.batteries.isEmpty { Text("Not reported").font(.caption).foregroundStyle(.secondary) }
            }
            if device.batteries.count > 1 {
                ForEach(device.batteries.keys.sorted(), id: \.self) { label in
                    HStack {
                        Text(label).font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        batteryReading(device.batteries[label] ?? 0)
                    }.padding(.leading, 34)
                }
            }
        }.padding(.horizontal, 14).padding(.vertical, 12)
    }
    private func batteryReading(_ value: Int) -> some View {
        HStack(spacing: 12) {
            GeometryReader { geo in
                Capsule().fill(Color.primary.opacity(0.08))
                    .overlay(alignment: .leading) { Capsule().fill(value < 20 ? Color.orange : .blue).frame(width: geo.size.width * CGFloat(min(100, max(0, value))) / 100) }
            }.frame(width: compact ? 80 : 180, height: 5)
            Text("\(value)%").font(.system(size: 12)).monospacedDigit().frame(width: 42, alignment: .trailing)
        }.accessibilityElement(children: .ignore).accessibilityLabel("Battery \(value) percent")
    }
    private func symbol(_ name: String) -> String {
        let n = name.lowercased()
        if n.contains("keyboard") { return "keyboard" }
        if n.contains("mouse") { return "computermouse" }
        if n.contains("trackpad") { return "rectangle.and.hand.point.up.left" }
        if n.contains("airpod") || n.contains("headphone") { return "headphones" }
        return "antenna.radiowaves.left.and.right"
    }
}
