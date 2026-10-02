import AppKit
import SwiftUI
import Combine
import PortmasterCore

extension MenuBarMetric {
    var symbol: String {
        switch self {
        case .cpu, .topProcessCPU: return "cpu"
        case .memoryPressure, .memoryUsed: return "memorychip"
        case .temperature: return "thermometer.medium"
        case .gpu: return "square.3.layers.3d"
        case .networkDown: return "arrow.down"
        case .networkUp: return "arrow.up"
        case .diskWrite: return "internaldrive"
        }
    }
}

@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let model: AppModel
    private var items: [String: NSStatusItem] = [:]
    private var series: [String: [Double]] = [:]
    private var lastAt = Date.distantPast
    private var countedSurface = false
    private var lastFixtureMode: Bool?
    private var subscriptions = Set<AnyCancellable>()
    private let popover = NSPopover()
    private var keyMonitor: Any?
    private weak var currentAnchor: NSStatusBarButton?
    init(model: AppModel) {
        self.model = model; super.init()
        popover.behavior = .transient; popover.delegate = self
        let host = NSHostingController(rootView: MenuBarPanel().environmentObject(model))
        popover.contentViewController = host
        popover.contentSize = NSSize(width: 340, height: 700)
        model.$prefs.combineLatest(model.$snapshot).receive(on: RunLoop.main).sink { [weak self] _, _ in self?.update() }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .portmasterPanelSize).sink { [weak self] note in
            if let size = note.object as? NSSize { self?.popover.contentSize = size }
        }.store(in: &subscriptions)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.popover.isShown, event.window == self.popover.contentViewController?.view.window else { return event }
            if event.keyCode == 53 { self.close(); return nil }
            // Command digits follow visible, arranged tab order. Tab is reserved
            // for navigation; Shift reverses it without swallowing text editors.
            if event.modifierFlags.contains(.command), let key = event.charactersIgnoringModifiers,
               let digit = Int(key), (0...9).contains(digit) {
                NotificationCenter.default.post(name: .portmasterPanelNavigate, object: digit == 0 ? 9 : digit - 1)
                return nil
            }
            if event.keyCode == 48 && !(event.window?.firstResponder is NSTextView) {
                NotificationCenter.default.post(name: .portmasterPanelStep, object: event.modifierFlags.contains(.shift) ? -1 : 1)
                return nil
            }
            return event
        }
    }
    private func update() {
        if lastFixtureMode != model.prefs.fixtureMode {
            series.removeAll(); lastAt = .distantPast; lastFixtureMode = model.prefs.fixtureMode
        }
        let configs = model.prefs.presentation.effectiveStatusItems
        let wanted = Set(configs.map(\.id))
        if let anchor = currentAnchor, !items.contains(where: { wanted.contains($0.key) && $0.value.button === anchor }) { close() }
        for id in Array(items.keys) where !wanted.contains(id) { if let item = items.removeValue(forKey: id) { NSStatusBar.system.removeStatusItem(item) } }
        if model.snapshot.at != lastAt {
            lastAt = model.snapshot.at
            for metric in MenuBarMetric.allCases {
                if let value = metric == .topProcessCPU ? model.snapshot.processes.compactMap(\.cpuPercent).max() : model.statusValue(metric), value.isFinite { var values = series[metric.rawValue] ?? []; values.append(value); series[metric.rawValue] = Array(values.suffix(24)) }
                else { series[metric.rawValue] = [] }
            }
        }
        for config in configs {
            let item: NSStatusItem
            if let existing = items[config.id] { item = existing }
            else {
                item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                item.autosaveName = config.id
                items[config.id] = item
                item.button?.target = self; item.button?.action = #selector(clicked(_:))
                item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            }
            guard let button = item.button else { continue }
            let title = (model.statusWarning(config.metric) ? "⚠ " : "") + (config.caption ? config.metric.label + " " : "") + (model.prefs.fixtureMode ? "P " : "") + (config.style == .graph ? (model.statusValue(config.metric) == nil ? "—" : "") : model.statusText(config.metric))
            button.title = title
            button.font = .monospacedDigitSystemFont(ofSize: model.prefs.presentation.compact ? 10 : 12, weight: .regular)
            button.image = makeImage(config)
            button.imagePosition = .imageLeft
            button.toolTip = "\(model.prefs.fixtureMode ? "Preview: " : "")\(config.metric.label): \(model.statusText(config.metric)) — click to open Portmaster; right-click for actions"
            if config.metric == .memoryPressure { button.toolTip! += "; graph tracks Normal / Elevated / Critical states" }
            button.setAccessibilityLabel(button.toolTip)
            // Reserve a fixed value width so ordinary numeric changes don't move neighbors.
            let captionWidth = config.caption ? CGFloat(config.metric.label.count * 7) : 0
            item.length = (model.prefs.presentation.compact ? 66 : 94) + captionWidth + (config.icon ? 18 : 0) + (config.style != .value ? 40 : 0)
        }
    }
    private func makeImage(_ config: StatusReadout) -> NSImage? {
        if config.style == .value { return config.icon ? NSImage(systemSymbolName: config.metric.symbol, accessibilityDescription: config.metric.label) : nil }
        let values = history(config.metric)
        let image = NSImage(size: NSSize(width: config.icon ? 56 : 38, height: 18), flipped: false) { bounds in
            if config.icon { NSImage(systemSymbolName: config.metric.symbol, accessibilityDescription: nil)?.draw(in: NSRect(x: 0, y: 1, width: 16, height: 16)) }
            guard !values.isEmpty else { return true }
            let offset: CGFloat = config.icon ? 18 : 0, maxValue = config.metric == .memoryPressure ? 2 : max(1, values.max() ?? 1)
            let path = NSBezierPath(); path.lineWidth = 1.2
            for (i, value) in values.enumerated() {
                let point = NSPoint(x: offset + CGFloat(i) / CGFloat(max(1, values.count - 1)) * 36, y: 1 + CGFloat(max(0, value) / maxValue) * 16)
                if i == 0 { path.move(to: point) } else { path.line(to: point) }
            }
            NSColor.labelColor.setStroke(); path.stroke(); return true
        }
        image.isTemplate = true; return image
    }
    @objc private func checkUpdates() { AppDelegate.shared?.checkForUpdates() }
    @objc private func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            close()
            let menu = NSMenu()
            menu.addItem(withTitle: "Open Portmaster", action: #selector(openWindow), keyEquivalent: "")
            menu.addItem(withTitle: "Settings…", action: #selector(settings), keyEquivalent: "")
            let updateItem = menu.addItem(withTitle: "Check for Updates…", action: #selector(checkUpdates), keyEquivalent: "")
            updateItem.isEnabled = AppDelegate.shared?.updates.canCheck == true
            menu.autoenablesItems = false
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit Portmaster", action: #selector(quit), keyEquivalent: "")
            for entry in menu.items { entry.target = self }
            NSMenu.popUpContextMenu(menu, with: NSApp.currentEvent!, for: sender)
        } else { toggle(anchor: sender) }
    }
    func toggle(anchor: NSStatusBarButton? = nil) {
        if popover.isShown { close(); return }
        guard let button = anchor ?? model.prefs.presentation.effectiveStatusItems.first.flatMap({ items[$0.id]?.button }) else { return }
        model.engine.noteUserActivity()
        currentAnchor = button
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        popover.contentViewController?.view.window?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }
    func history(_ metric: MenuBarMetric) -> [Double] {
        let values = series[metric.rawValue] ?? []
        return metric == .topProcessCPU ? values.compactMap { model.processCPUValue($0) } : values
    }
    func popoverDidShow(_ notification: Notification) {
        if !countedSurface { model.surfaceAppeared(); countedSurface = true }
    }
    func popoverDidClose(_ notification: Notification) {
        if countedSurface { model.surfaceDisappeared(); countedSurface = false }
    }
    func show() {
        guard !popover.isShown else { return }
        toggle()
        guard !popover.isShown else { return }
        // A hidden or crowded menu bar may not provide a usable status anchor.
        // Keep the same live panel available beside the main window instead.
        AppDelegate.shared?.openMainWindow()
        guard let view = AppDelegate.shared?.mainWindow?.contentView else { return }
        currentAnchor = nil
        let anchor = NSRect(x: max(0, view.bounds.width - 40),
                            y: view.isFlipped ? 12 : max(0, view.bounds.height - 40), width: 24, height: 24)
        popover.show(relativeTo: anchor, of: view, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        popover.contentViewController?.view.window?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }
    func close() { popover.performClose(nil) }
    @objc private func openWindow() { AppDelegate.shared?.openMainWindow() }
    @objc private func settings() { AppDelegate.shared?.openSettingsWindow() }
    @objc private func quit() { NSApp.terminate(nil) }
    deinit { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) } }
}

extension Notification.Name {
    static let portmasterPanelSize = Notification.Name("dev.portmaster.panelSize")
    static let portmasterPanelNavigate = Notification.Name("dev.portmaster.panelNavigate")
    static let portmasterPanelStep = Notification.Name("dev.portmaster.panelStep")
}
