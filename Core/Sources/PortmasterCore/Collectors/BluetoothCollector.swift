import Foundation
import IOKit

public struct BluetoothBatteryDevice: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let batteries: [String: Int]
}
public struct BluetoothSample: Sendable {
    public let devices: [BluetoothBatteryDevice]
    public let inventoryAvailable: Bool
    public init(devices: [BluetoothBatteryDevice], inventoryAvailable: Bool) {
        self.devices = devices; self.inventoryAvailable = inventoryAvailable
    }
}
public protocol BluetoothProviding: Sendable { func sample() -> BluetoothSample }

public struct BluetoothCollector: BluetoothProviding {
    public init() {}
    public func sample() -> BluetoothSample {
        let registry = registryDevices()
        // system_profiler includes connected audio peripherals, whose component
        // batteries may not appear in HID registry entries. No active scan/pairing.
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json", "-timeout", "5"]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return BluetoothSample(devices: registry, inventoryAvailable: false) }
        let timeout = DispatchWorkItem { [weak process] in
            if let process, process.isRunning { process.terminate() }
        }
        let force = DispatchWorkItem { [weak process] in
            if let process, process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 6, execute: timeout)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 8, execute: force)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit(); timeout.cancel(); force.cancel()
        guard process.terminationStatus == 0, let parsed = Self.parseInventory(data) else {
            return BluetoothSample(devices: registry, inventoryAvailable: false)
        }
        var merged = Dictionary(parsed.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for device in registry {
            let prior = merged[device.id]
            merged[device.id] = BluetoothBatteryDevice(id: device.id, name: prior?.name ?? device.name,
                                                      batteries: (prior?.batteries ?? [:]).merging(device.batteries) { _, new in new })
        }
        return BluetoothSample(devices: merged.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, inventoryAvailable: true)
    }
    private func registryDevices() -> [BluetoothBatteryDevice] {
        var result: [BluetoothBatteryDevice] = []
        for cls in ["AppleDeviceManagementHIDEventService", "IOBluetoothHIDDriver"] {
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(cls), &iterator) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iterator) }
            var entry = IOIteratorNext(iterator)
            while entry != 0 {
                var raw: Unmanaged<CFMutableDictionary>?
                if IORegistryEntryCreateCFProperties(entry, &raw, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                   let dict = raw?.takeRetainedValue() as? [String: Any], let device = Self.parseRegistry(dict) { result.append(device) }
                IOObjectRelease(entry); entry = IOIteratorNext(iterator)
            }
        }
        return result
    }
    static func address(_ text: String) -> String? {
        let value = text.lowercased().filter { $0 != ":" && $0 != "-" }
        guard value.count == 12, value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        return value
    }
    static func percent(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
                  number.doubleValue.rounded() == number.doubleValue, (0...100).contains(number.doubleValue) else { return nil }
            return number.intValue
        }
        if let text = value as? String, let number = Int(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "")), (0...100).contains(number) { return number }
        return nil
    }
    static func parseRegistry(_ dict: [String: Any]) -> BluetoothBatteryDevice? {
        guard (dict["Transport"] as? String)?.lowercased() == "bluetooth",
              let rawAddress = dict["DeviceAddress"] as? String, let id = address(rawAddress),
              let name = dict["Product"] as? String else { return nil }
        return BluetoothBatteryDevice(id: id, name: name,
                                      batteries: percent(dict["BatteryPercent"]).map { ["Battery": $0] } ?? [:])
    }
    static func parseInventory(_ data: Data) -> [BluetoothBatteryDevice]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = root["SPBluetoothDataType"] as? [[String: Any]] else { return nil }
        var devices: [BluetoothBatteryDevice] = []
        for controller in controllers {
            for group in controller["device_connected"] as? [[String: [String: Any]]] ?? [] {
                for (name, properties) in group {
                    guard let text = properties["device_address"] as? String, let id = address(text) else { continue }
                    let keys = ["device_batteryLevelMain": "Battery", "device_batteryLevelLeft": "Left", "device_batteryLevelRight": "Right", "device_batteryLevelCase": "Case"]
                    var batteries: [String: Int] = [:]
                    for (key, label) in keys { if let value = percent(properties[key]) { batteries[label] = value } }
                    devices.append(BluetoothBatteryDevice(id: id, name: name, batteries: batteries))
                }
            }
        }
        return devices
    }
}
