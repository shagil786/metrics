import Foundation

public enum TemperatureUnit: String, Codable, CaseIterable, Sendable { case celsius, fahrenheit }
public enum NetworkUnit: String, Codable, CaseIterable, Sendable { case bytes, bits }
public enum CPUScale: String, Codable, CaseIterable, Sendable { case perCore, perMac }
public enum TemperatureSource: String, Codable, CaseIterable, Sendable { case hottest, cpu, gpu }
public enum ReadoutStyle: String, Codable, CaseIterable, Sendable { case value, graph, both }
public enum PanelLayout: String, Codable, CaseIterable, Sendable { case tiles, list }

public struct StatusReadout: Codable, Hashable, Identifiable, Sendable {
    public var metric: MenuBarMetric
    public var style: ReadoutStyle
    public var icon: Bool
    public var caption: Bool
    public var id: String { metric.rawValue }
    public init(metric: MenuBarMetric = .cpu, style: ReadoutStyle = .value, icon: Bool = false, caption: Bool = false) {
        self.metric = metric; self.style = style; self.icon = icon; self.caption = caption
    }
}

/// Separate order and visibility preserve a hidden item's place when re-enabled.
public struct LayoutOrder: Codable, Equatable, Sendable {
    public var order: [String]
    public var hidden: Set<String>
    public init(order: [String] = [], hidden: Set<String> = []) { self.order = order; self.hidden = hidden }
    public func resolved(_ catalog: [String]) -> [String] {
        var seen = Set<String>()
        return (order + catalog).filter { catalog.contains($0) && seen.insert($0).inserted }
    }
    public func visible(_ catalog: [String], keepOne: Bool = true) -> [String] {
        let ordered = resolved(catalog), visible = ordered.filter { !hidden.contains($0) }
        return visible.isEmpty && keepOne ? Array(ordered.prefix(1)) : visible
    }
}

public struct KeyboardShortcutPreference: Codable, Equatable, Sendable {
    public var key: String
    public var command: Bool
    public var option: Bool
    public var control: Bool
    public var shift: Bool
    public init(key: String = "", command: Bool = true, option: Bool = true, control: Bool = false, shift: Bool = false) {
        self.key = key; self.command = command; self.option = option; self.control = control; self.shift = shift
    }
    public var enabled: Bool { !key.isEmpty }
    public var valid: Bool {
        key.isEmpty || (Self.keys.contains(key) && (command || option || control))
    }
    public var label: String {
        key.isEmpty ? "None" : (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "") + key
    }
    public static let keys = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789").map(String.init) + (1...12).map { "F\($0)" }
}

public struct PresentationPreferences: Codable, Sendable {
    public var statusItems: [StatusReadout]
    public var compact: Bool = false
    public var temperatureUnit: TemperatureUnit = .celsius
    public var networkUnit: NetworkUnit = .bytes
    public var cpuScale: CPUScale = .perCore
    public var temperatureSource: TemperatureSource = .hottest
    public var windowTabs = LayoutOrder()
    public var panelTabs = LayoutOrder()
    public var panelTiles = LayoutOrder()
    public var overviewCards = LayoutOrder()
    public var sections: [String: LayoutOrder] = [:]
    public var panelLayout: PanelLayout = .tiles
    public var glass: Bool = true
    public var windowShortcut = KeyboardShortcutPreference()
    public var panelShortcut = KeyboardShortcutPreference()
    public init(statusItems: [StatusReadout] = [StatusReadout()]) { self.statusItems = statusItems }
    enum CodingKeys: String, CodingKey { case statusItems, compact, temperatureUnit, networkUnit, cpuScale, temperatureSource, windowTabs, panelTabs, panelTiles, overviewCards, sections, panelLayout, glass, windowShortcut, panelShortcut }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        statusItems = try c.decodeIfPresent([StatusReadout].self, forKey: .statusItems) ?? [StatusReadout()]
        compact = try c.decodeIfPresent(Bool.self, forKey: .compact) ?? false
        temperatureUnit = try c.decodeIfPresent(TemperatureUnit.self, forKey: .temperatureUnit) ?? .celsius
        networkUnit = try c.decodeIfPresent(NetworkUnit.self, forKey: .networkUnit) ?? .bytes
        cpuScale = try c.decodeIfPresent(CPUScale.self, forKey: .cpuScale) ?? .perCore
        temperatureSource = try c.decodeIfPresent(TemperatureSource.self, forKey: .temperatureSource) ?? .hottest
        windowTabs = try c.decodeIfPresent(LayoutOrder.self, forKey: .windowTabs) ?? LayoutOrder()
        panelTabs = try c.decodeIfPresent(LayoutOrder.self, forKey: .panelTabs) ?? LayoutOrder()
        panelTiles = try c.decodeIfPresent(LayoutOrder.self, forKey: .panelTiles) ?? LayoutOrder()
        overviewCards = try c.decodeIfPresent(LayoutOrder.self, forKey: .overviewCards) ?? LayoutOrder()
        sections = try c.decodeIfPresent([String: LayoutOrder].self, forKey: .sections) ?? [:]
        panelLayout = try c.decodeIfPresent(PanelLayout.self, forKey: .panelLayout) ?? .tiles
        glass = try c.decodeIfPresent(Bool.self, forKey: .glass) ?? true
        windowShortcut = try c.decodeIfPresent(KeyboardShortcutPreference.self, forKey: .windowShortcut) ?? KeyboardShortcutPreference()
        panelShortcut = try c.decodeIfPresent(KeyboardShortcutPreference.self, forKey: .panelShortcut) ?? KeyboardShortcutPreference()
    }
    public var effectiveStatusItems: [StatusReadout] {
        var seen = Set<String>()
        let items = statusItems.filter { seen.insert($0.id).inserted }
        return items.isEmpty ? [StatusReadout()] : items
    }
}

/// Collector units remain unchanged; these conversions are presentation-only.
public enum DisplayUnits {
    public static func temperature(_ celsius: Double?, unit: TemperatureUnit, decimals: Int = 0) -> String {
        guard let celsius, celsius.isFinite else { return "—" }
        let value = unit == .fahrenheit ? celsius * 9 / 5 + 32 : celsius
        return String(format: decimals == 0 ? "%.0f" : "%.1f", value) + (unit == .celsius ? "°C" : "°F")
    }
    public static func processCPU(_ percent: Double?, scale: CPUScale, cores: Int) -> Double? {
        guard let percent, percent.isFinite, percent >= 0 else { return nil }
        if scale == .perMac { guard cores > 0 else { return nil }; return percent / Double(cores) }
        return percent
    }
    public static func networkParts(_ bytes: Double, unit: NetworkUnit) -> (value: String, unit: String) {
        guard bytes.isFinite, bytes >= 0 else { return ("—", unit == .bits ? "bit/s" : "B/s") }
        if unit == .bytes { return Fmt.rateParts(bytes) }
        let bits = bytes * 8
        guard bits.isFinite else { return ("—", "bit/s") }
        let labels = ["bit/s", "kbit/s", "Mbit/s", "Gbit/s", "Tbit/s"]
        var value = bits, index = 0
        while value >= 1000 && index < labels.count - 1 { value /= 1000; index += 1 }
        return (String(format: index == 0 ? "%.0f" : "%.1f", value), labels[index])
    }
}
