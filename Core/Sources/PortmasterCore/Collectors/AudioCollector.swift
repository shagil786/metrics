import Foundation
import CoreAudio

public struct AudioClient: Identifiable, Hashable, Sendable {
    public let id: UInt32
    public let pid: Int32
    public let bundleID: String?
    public let inputActive: Bool?
    public let outputActive: Bool?
    public let outputDevices: [UInt32]?
}

public struct AudioDeviceReading: Identifiable, Hashable, Sendable {
    public let id: UInt32
    public let uid: String
    public let name: String
    public let volume: Float?
    public let volumeWritable: Bool
}

public struct AudioSample: Sendable {
    public let output: AudioDeviceReading?
    public let input: AudioDeviceReading?
    /// nil means unavailable, distinct from a successful empty client list.
    public let clients: [AudioClient]?
    public init(output: AudioDeviceReading?, input: AudioDeviceReading?, clients: [AudioClient]?) {
        self.output = output; self.input = input; self.clients = clients
    }
}
public protocol AudioProviding: Sendable { func sample() -> AudioSample }

/// HAL activity queries do not capture audio or initiate permission requests.
public struct AudioCollector: AudioProviding {
    public init() {}
    public func sample() -> AudioSample {
        var clients: [AudioClient]?
        if #available(macOS 14.2, *), let objects = AudioHAL.ids(UInt32(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList) {
            clients = objects.compactMap { object in
                guard let rawPID = AudioHAL.uint(object, kAudioProcessPropertyPID), rawPID > 0 else { return nil }
                return AudioClient(id: object, pid: Int32(bitPattern: rawPID),
                                   bundleID: AudioHAL.string(object, kAudioProcessPropertyBundleID),
                                   inputActive: AudioHAL.uint(object, kAudioProcessPropertyIsRunningInput).map { $0 != 0 },
                                   outputActive: AudioHAL.uint(object, kAudioProcessPropertyIsRunningOutput).map { $0 != 0 },
                                   outputDevices: AudioHAL.ids(object, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput))
            }
        }
        return AudioSample(output: device(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeOutput),
                           input: device(kAudioHardwarePropertyDefaultInputDevice, scope: kAudioObjectPropertyScopeInput), clients: clients)
    }
    private func device(_ selector: UInt32, scope: UInt32) -> AudioDeviceReading? {
        guard let id = AudioHAL.uint(UInt32(kAudioObjectSystemObject), selector), id != 0,
              let uid = AudioHAL.string(id, kAudioDevicePropertyDeviceUID) else { return nil }
        let values = AudioHAL.volumeChannels(id, scope: scope)
        return AudioDeviceReading(id: id, uid: uid, name: AudioHAL.string(id, kAudioObjectPropertyName) ?? "Audio device",
                                  volume: values.isEmpty ? nil : values.map(\.value).max(),
                                  volumeWritable: !values.isEmpty && values.allSatisfy { AudioHAL.settable(id, kAudioDevicePropertyVolumeScalar, scope: scope, element: $0.element) })
    }
}

/// Small checked HAL property surface shared by telemetry and opt-in routing.
public enum AudioHAL {
    public static func address(_ selector: UInt32, scope: UInt32 = kAudioObjectPropertyScopeGlobal, element: UInt32 = 0) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }
    public static func uint(_ object: UInt32, _ selector: UInt32, scope: UInt32 = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var a = address(selector, scope: scope), value: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &a, 0, nil, &size, &value) == noErr, size == MemoryLayout<UInt32>.size else { return nil }
        return value
    }
    public static func ids(_ object: UInt32, _ selector: UInt32, scope: UInt32 = kAudioObjectPropertyScopeGlobal) -> [UInt32]? {
        var a = address(selector, scope: scope), size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &a, 0, nil, &size) == noErr,
              size % 4 == 0, size <= 1_048_576 else { return nil }
        if size == 0 { return [] }
        var values = [UInt32](repeating: 0, count: Int(size / 4))
        let result = values.withUnsafeMutableBytes { AudioObjectGetPropertyData(object, &a, 0, nil, &size, $0.baseAddress!) }
        guard result == noErr else { return nil }
        return Array(values.prefix(Int(size / 4)))
    }
    public static func string(_ object: UInt32, _ selector: UInt32) -> String? {
        var a = address(selector), value: Unmanaged<CFString>?, size = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(object, &a, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
    static func scalar(_ object: UInt32, scope: UInt32, element: UInt32) -> Float? {
        var a = address(kAudioDevicePropertyVolumeScalar, scope: scope, element: element), value: Float = 0, size: UInt32 = 4
        guard AudioObjectGetPropertyData(object, &a, 0, nil, &size, &value) == noErr,
              value.isFinite, (0...1).contains(value) else { return nil }
        return value
    }
    public static func settable(_ object: UInt32, _ selector: UInt32, scope: UInt32 = kAudioObjectPropertyScopeGlobal, element: UInt32 = 0) -> Bool {
        var a = address(selector, scope: scope, element: element), writable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(object, &a, &writable) == noErr && writable.boolValue
    }
    static func volumeChannels(_ object: UInt32, scope: UInt32) -> [(element: UInt32, value: Float)] {
        if let value = scalar(object, scope: scope, element: 0) { return [(0, value)] }
        // Only existing channel controls are considered; absent properties are unknown.
        return (1...32).compactMap { channel in scalar(object, scope: scope, element: UInt32(channel)).map { (UInt32(channel), $0) } }
    }
    public static func setOutputVolume(device: UInt32, value: Float) -> Bool {
        guard value.isFinite, (0...1).contains(value),
              uint(UInt32(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice) == device else { return false }
        let scope = kAudioObjectPropertyScopeOutput
        let channels = volumeChannels(device, scope: scope)
        guard !channels.isEmpty, channels.allSatisfy({ settable(device, kAudioDevicePropertyVolumeScalar, scope: scope, element: $0.element) }) else { return false }
        let peak = channels.map(\.value).max() ?? 0
        var written: [(element: UInt32, value: Float)] = []
        for c in channels {
            var a = address(kAudioDevicePropertyVolumeScalar, scope: scope, element: c.element), v = peak > 0 ? value * c.value / peak : value
            if AudioObjectSetPropertyData(device, &a, 0, nil, 4, &v) != noErr {
                for prior in written {
                    var rollback = address(kAudioDevicePropertyVolumeScalar, scope: scope, element: prior.element), old = prior.value
                    _ = AudioObjectSetPropertyData(device, &rollback, 0, nil, 4, &old)
                }
                return false
            }
            written.append(c)
        }
        return true
    }
}
