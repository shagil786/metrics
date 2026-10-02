import Foundation
import PortmasterCore

extension AppModel {
    func processCPUValue(_ percent: Double?) -> Double? {
        DisplayUnits.processCPU(percent, scale: prefs.presentation.cpuScale, cores: snapshot.system.cpu.coreCount)
    }
    func cpuText(_ percent: Double?) -> String {
        Fmt.cpu(DisplayUnits.processCPU(percent, scale: prefs.presentation.cpuScale, cores: snapshot.system.cpu.coreCount))
    }
    func temperatureText(_ value: Double?, decimals: Int = 0) -> String {
        DisplayUnits.temperature(value, unit: prefs.presentation.temperatureUnit, decimals: decimals)
    }
    func networkParts(_ value: Double) -> (value: String, unit: String) {
        DisplayUnits.networkParts(value, unit: prefs.presentation.networkUnit)
    }
    func networkText(_ value: Double?) -> String {
        guard let value else { return "—" }; let parts = networkParts(value)
        return parts.value + " " + parts.unit
    }
    var selectedTemperature: Double? {
        switch prefs.presentation.temperatureSource {
        case .cpu: return snapshot.system.thermal?.cpuTempC
        case .gpu: return snapshot.system.thermal?.gpuTempC
        case .hottest: return snapshot.system.thermal?.hottestTempC
        }
    }
    /// Optional numeric readings keep unavailable graphs distinct from zero.
    func statusValue(_ metric: MenuBarMetric) -> Double? {
        let system = snapshot.system
        guard snapshot.at != .distantPast else { return nil }
        switch metric {
        case .cpu: return system.cpu.coreCount > 0 ? system.cpu.totalPercent : nil
        case .memoryPressure:
            guard system.memory.totalBytes > 0 else { return nil }
            // A categorical pressure-state graph, never an occupancy percentage.
            switch system.memory.pressureLevel { case .normal: return 0; case .elevated: return 1; case .critical: return 2 }
        case .memoryUsed: return system.memory.totalBytes > 0 ? Double(system.memory.usedBytes) / 1_073_741_824 : nil
        case .topProcessCPU: return DisplayUnits.processCPU(snapshot.processes.compactMap(\.cpuPercent).max(), scale: prefs.presentation.cpuScale, cores: system.cpu.coreCount)
        case .temperature: return selectedTemperature
        case .gpu: return system.gpu?.utilizationPercent
        case .networkDown: return system.network?.downBytesPerSec
        case .networkUp: return system.network?.upBytesPerSec
        case .diskWrite: return system.disk?.writeBytesPerSec
        }
    }
    func statusText(_ metric: MenuBarMetric) -> String {
        guard let value = statusValue(metric), value.isFinite else { return "—" }
        switch metric {
        case .memoryPressure: return Theme.stateWord(snapshot.system.memory.pressureLevel)
        case .temperature: return temperatureText(value)
        case .memoryUsed: return String(format: "%.1f GB", value)
        case .networkDown, .networkUp: return networkText(value)
        case .diskWrite: return Fmt.rate(value)
        default: return Fmt.percent(value)
        }
    }
    func statusWarning(_ metric: MenuBarMetric) -> Bool {
        switch metric {
        case .cpu: return (statusValue(metric) ?? 0) >= 50
        case .memoryPressure: return snapshot.system.memory.totalBytes > 0 && snapshot.system.memory.pressureLevel != .normal
        case .topProcessCPU: return (snapshot.processes.compactMap(\.cpuPercent).max() ?? 0) >= 50
        default: return false
        }
    }
}
