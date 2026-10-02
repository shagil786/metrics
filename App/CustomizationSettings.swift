import SwiftUI
import PortmasterCore

struct CustomizationSettings: View {
    @EnvironmentObject private var model: AppModel
    @State private var adding: MenuBarMetric = .memoryPressure
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Menu bar").font(.title2.bold())
            Toggle("Compact readouts", isOn: $model.prefs.presentation.compact)
            Text("Each readout is a separate item. Hold ⌘ and drag in the macOS menu bar to move it. At least one readout stays available.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(Array(model.prefs.presentation.statusItems.enumerated()), id: \.element.id) { index, item in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label(item.metric.label, systemImage: item.metric.symbol).font(.headline)
                        Spacer()
                        Button("Remove") { model.prefs.presentation.statusItems.removeAll { $0.id == item.id } }
                            .disabled(model.prefs.presentation.statusItems.count <= 1)
                    }
                    Picker("Display", selection: $model.prefs.presentation.statusItems[index].style) {
                        Text("Value").tag(ReadoutStyle.value); Text("Graph").tag(ReadoutStyle.graph); Text("Both").tag(ReadoutStyle.both)
                    }.pickerStyle(.segmented)
                    HStack {
                        Toggle("Icon", isOn: $model.prefs.presentation.statusItems[index].icon)
                        Toggle("Caption", isOn: $model.prefs.presentation.statusItems[index].caption)
                    }
                    HStack {
                        Text("Live preview:").foregroundStyle(.secondary)
                        if item.icon { Image(systemName: item.metric.symbol) }
                        if item.caption { Text(item.metric.label) }
                        if item.style != .graph || model.statusValue(item.metric) == nil { Text(model.statusText(item.metric)).monospacedDigit() }
                        if item.style != .value { StripSparkline(values: AppDelegate.shared?.statusItems?.history(item.metric) ?? [], tint: .blue).frame(width: 60, height: 18).accessibilityLabel("Live graph of this metric") }
                    }.font(.caption)
                }.padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                Picker("Add readout", selection: $adding) { ForEach(MenuBarMetric.allCases) { Text($0.label).tag($0) } }
                Button("Add") { model.prefs.presentation.statusItems.append(StatusReadout(metric: adding)) }
                    .disabled(model.prefs.presentation.statusItems.contains { $0.metric == adding })
            }
            Text("Memory pressure shows the kernel state. Its graph tracks Normal, Elevated and Critical; it is not memory occupancy.").font(.caption).foregroundStyle(.secondary)
            Picker("Temperature follows", selection: $model.prefs.presentation.temperatureSource) {
                Text("Hottest sensor").tag(TemperatureSource.hottest); Text("CPU").tag(TemperatureSource.cpu); Text("GPU").tag(TemperatureSource.gpu)
            }
            Divider()
            Text("Dropdown").font(.title2.bold())
            Picker("Overview", selection: $model.prefs.presentation.panelLayout) {
                Text("Tiles").tag(PanelLayout.tiles); Text("List").tag(PanelLayout.list)
            }
            Toggle("Translucent background", isOn: $model.prefs.presentation.glass)
            DisclosureGroup("Dropdown tabs") {
                LayoutEditor(title: "Order and visibility", catalog: PanelTab.allCases.map { ($0.rawValue, MainTab(rawValue: $0.rawValue)?.label ?? $0.rawValue.capitalized) }, layout: $model.prefs.presentation.panelTabs)
            }
            DisclosureGroup("Dropdown overview tiles") {
                LayoutEditor(title: "Order and visibility", catalog: LayoutCatalog.panelTiles, layout: $model.prefs.presentation.panelTiles)
            }
            Divider()
            DisclosureGroup("Window tabs") {
                LayoutEditor(title: "Order and visibility", catalog: MainTab.allCases.map { ($0.rawValue, $0.label) }, layout: $model.prefs.presentation.windowTabs)
            }
            Divider()
            DisclosureGroup("Overview cards") {
                LayoutEditor(title: "Order and visibility", catalog: LayoutCatalog.overview, layout: $model.prefs.presentation.overviewCards)
            }
            Text("Use Arrange in each window tab to customise its available sections. A statistics strip moves as a group.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(20)
    }
}

struct ShortcutEditor: View {
    let title: String
    @Binding var shortcut: KeyboardShortcutPreference
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Picker(title, selection: $shortcut.key) {
                Text("None").tag("")
                ForEach(KeyboardShortcutPreference.keys, id: \.self) { Text($0).tag($0) }
            }
            if shortcut.enabled {
                HStack(spacing: 12) {
                    Toggle("⌘", isOn: $shortcut.command).accessibilityLabel("Command")
                    Toggle("⌥", isOn: $shortcut.option).accessibilityLabel("Option")
                    Toggle("⌃", isOn: $shortcut.control).accessibilityLabel("Control")
                    Toggle("⇧", isOn: $shortcut.shift).accessibilityLabel("Shift")
                    Spacer()
                    Text(shortcut.label).monospacedDigit()
                }
            }
            if !shortcut.valid { Text("Include Command, Option or Control.").font(.caption).foregroundStyle(.red) }
        }
    }
}

struct ShortcutRegistrationStatus: View {
    @ObservedObject var shortcuts: GlobalShortcuts
    var body: some View {
        if let error = shortcuts.error { Text(error).font(.caption).foregroundStyle(.red) }
    }
}
