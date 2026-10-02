// Compact titlebar navigation with the reference tabs and a menu for
// Portmaster-specific tools. App details remain beside the active tab.
import SwiftUI
import Charts
import PortmasterCore

enum MainTab: String, CaseIterable, Identifiable {
    case overview, cpu, memory, disk, network, gpu, power, projects, containers
    case audio, bluetooth, processes, alerts, history
    var id: String { rawValue }

    var label: String {
        switch self {
        case .overview: "Overview"
        case .cpu: "CPU"
        case .memory: "Memory"
        case .disk: "Disk"
        case .network: "Network"
        case .gpu: "GPU"
        case .power: "Battery"
        case .projects: "Projects"
        case .containers: "Containers"
        case .audio: "Sound"
        case .bluetooth: "Bluetooth"
        case .processes: "Processes"
        case .alerts: "Alerts"
        case .history: "History"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .disk: "internaldrive"
        case .network: "network"
        case .gpu: "square.3.layers.3d"
        case .power: "powerplug.fill"
        case .projects: "folder"
        case .containers: "shippingbox"
        case .audio: "speaker.wave.2"
        case .bluetooth: "antenna.radiowaves.left.and.right"
        case .processes: "list.bullet"
        case .alerts: "bell.badge"
        case .history: "clock.arrow.circlepath"
        }
    }

    var tint: Color {
        switch self {
        case .overview: .blue
        case .cpu: .blue
        case .memory: .indigo
        case .disk: .orange
        case .network: .green
        case .gpu: .pink
        case .power: .mint
        case .projects: .orange
        case .containers: .green
        case .audio: .purple
        case .bluetooth: .blue
        case .processes: .secondary
        case .alerts: .coral
        case .history: .secondary
        }
    }

    /// The reference tab group comes first; product tabs after a divider.
    static let primary: [MainTab] = [.overview, .cpu, .memory, .disk, .network, .gpu, .power, .audio, .bluetooth, .projects, .containers]
    static let secondary: [MainTab] = [.processes, .alerts, .history]
    static var allCases: [MainTab] { primary + secondary }
}

struct MainWindow: View {
    @EnvironmentObject private var model: AppModel
    /// Initial tab: .overview normally. Debug/UI-testing affordance —
    /// `PORTMASTER_TAB=containers open Portmaster.app` (any MainTab rawValue)
    /// starts on that tab so surfaces can be captured without UI scripting.
    @State private var tab: MainTab = {
        if let raw = ProcessInfo.processInfo.environment["PORTMASTER_TAB"]?.lowercased(),
           let t = MainTab(rawValue: raw) {
            return t
        }
        return .overview
    }()
    @State private var showingMore = false
    @State private var pendingMoreTab: MainTab?
    @State private var pendingDropdown = false
    private var visibleTabs: [MainTab] {
        model.prefs.presentation.windowTabs.visible(MainTab.allCases.map(\.rawValue)).compactMap(MainTab.init(rawValue:))
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            if let err = model.historyError {
                ErrorBanner(message: err)
            }
            if let err = model.engine.collectionError {
                ErrorBanner(message: err) {
                    model.engine.clearCollectionError()
                }
            }

            HStack(spacing: 0) {
                tabContent(tab).frame(maxWidth: .infinity, maxHeight: .infinity)
                if let app = model.selectedMenuApp {
                    Divider()
                    InsideAppSheet(rollup: app, sidebar: true)
                        .id(app.id).environmentObject(model)
                }
            }
            HStack {
                Text("\(model.snapshot.rollups.filter { $0.isAppBundle }.count) apps · \(model.snapshot.processes.count) processes")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
            }.padding(.horizontal, 18).frame(height: 24).background(Theme.chrome)
        }
        .background(Theme.canvas)
        .ignoresSafeArea(.container, edges: .top)
        .sheet(item: $model.menuStopTarget) { target in
            StopSheet(target: target).environmentObject(model)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openPortmasterTab)) { note in
            if let destination = note.object as? String, let requested = MainTab(rawValue: destination) {
                Task { @MainActor in
                    if showingMore { pendingMoreTab = requested; showingMore = false }
                    else { tab = requested }
                }
            }
        }
        // Detail cards (e.g. CPU's Top App) can deep-link into Processes.
        .onReceive(NotificationCenter.default.publisher(for: .openPortmasterProcesses)) { _ in
            withAnimation(.easeOut(duration: 0.12)) { tab = .processes }
        }
        // The Overview "Worth a Look" strip deep-links into Alerts.
        .onReceive(NotificationCenter.default.publisher(for: .openPortmasterAlerts)) { _ in
            withAnimation(.easeOut(duration: 0.12)) { tab = .alerts }
        }
        .onAppear {
            if !visibleTabs.contains(tab) { tab = visibleTabs.first ?? .overview }
            model.start()
            model.surfaceAppeared()
        }
        .onChange(of: visibleTabs) { _, tabs in if !tabs.contains(tab) { tab = tabs.first ?? .overview } }
        .onDisappear {
            model.surfaceDisappeared()
        }
    }

    private var tabBar: some View {
        GeometryReader { geo in
        HStack(spacing: 10) {
            if geo.size.width >= 1280 {
                Text("Portmaster").font(.system(size: geo.size.width >= 1440 ? 14 : 12, weight: .semibold))
            }
            Spacer(minLength: 0)
            HStack(spacing: 2) {
                ForEach(visibleTabs.filter { MainTab.primary.contains($0) }) { t in
                    Button { tab = t } label: {
                        Label(t.label, systemImage: t.symbol)
                            .font(.system(size: geo.size.width < 1080 ? 9 : geo.size.width >= 1440 ? 12 : 11, weight: tab == t ? .semibold : .medium))
                            .lineLimit(1).fixedSize()
                            .foregroundStyle(tab == t ? t.tint : .secondary)
                            .padding(.horizontal, geo.size.width < 1080 ? 5 : geo.size.width >= 1440 ? 10 : 7).frame(height: 28)
                            .background(tab == t ? t.tint.opacity(0.15) : .clear, in: Capsule())
                    }.buttonStyle(.plain).accessibilityLabel(t.label)
                        .accessibilityAddTraits(tab == t ? [.isSelected] : [])
                }
                Button { showingMore = true } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(MainTab.secondary.contains(tab) ? Color.accentColor : Color.secondary)
                        .frame(width: 24, height: 28)
                }.buttonStyle(.plain).accessibilityLabel("More tabs").help("Processes, Alerts and History")
                    .popover(isPresented: $showingMore, arrowEdge: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(visibleTabs.filter { MainTab.secondary.contains($0) }) { t in
                                Button { pendingMoreTab = t; showingMore = false } label: {
                                    Label(t.label, systemImage: tab == t ? "checkmark" : t.symbol)
                                        .frame(maxWidth: .infinity, alignment: .leading).padding(7)
                                }.buttonStyle(.plain).accessibilityLabel(t.label)
                            }
                            Divider()
                            Button { pendingDropdown = true; showingMore = false } label: {
                                Label("Show dropdown", systemImage: "menubar.rectangle")
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(7)
                            }.buttonStyle(.plain)
                        }.padding(8).frame(width: 170)
                            .presentationBackground(Theme.card)
                            .onDisappear {
                                // Tear down the popover before replacing the host's content.
                                // AppKit's material renderer can still be drawing the old surface.
                                Task { @MainActor in
                                    if let destination = pendingMoreTab { tab = destination; pendingMoreTab = nil }
                                    if pendingDropdown { pendingDropdown = false; AppDelegate.shared?.statusItems?.show() }
                                }
                            }
                    }

            }.padding(4).background(Color.primary.opacity(0.07), in: Capsule())
            Spacer(minLength: 0)
            if tab == .overview || LayoutCatalog.sections[tab.rawValue] != nil {
                ArrangeButton(scope: tab.rawValue).labelStyle(.iconOnly).buttonStyle(.borderless).help("Arrange this tab")
            }
            Button { AppDelegate.shared?.openSettingsWindow() } label: { Image(systemName: "gearshape.fill") }
                .buttonStyle(.borderless).help("Settings").accessibilityLabel("Settings")
        }
        .padding(.leading, 78).padding(.trailing, 16).frame(height: 52)
        }.frame(height: 52).background(Theme.chrome)
    }

    @ViewBuilder
    private func tabContent(_ t: MainTab) -> some View {
        switch t {
        case .overview: OverviewView()
        case .cpu: WindowCpuDetail()
        case .memory: WindowMemoryDetail()
        case .disk: WindowDiskDetail()
        case .network: WindowNetworkDetail()
        case .gpu: WindowGpuDetail()
        case .power: WindowPowerDetail()
        case .projects: WindowProjectsDetail()
        case .containers: WindowContainersDetail()
        case .audio: ScrollView { AudioPane(controls: model.audioControls) }
            .onAppear { model.engine.refreshPeripherals() }
        case .bluetooth: ScrollView { BluetoothPane() }
            .onAppear { model.engine.refreshPeripherals() }
        case .processes: ProcessesView()
        case .alerts: AlertsView()
        case .history: HistoryView()
        }
    }
}

extension Notification.Name {
    static let openPortmasterTab = Notification.Name("dev.portmaster.openTab")
    static let openPortmasterSettings = Notification.Name("dev.portmaster.openSettings")
    static let openPortmasterProcesses = Notification.Name("dev.portmaster.openProcesses")
    static let openPortmasterAlerts = Notification.Name("dev.portmaster.openAlerts")
}
