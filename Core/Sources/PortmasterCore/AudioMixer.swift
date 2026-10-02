import Foundation
import CoreAudio
import PMShim

public enum AudioRoutingError: LocalizedError {
    case unsupported(String)
    case operation(String, OSStatus)
    public var errorDescription: String? {
        switch self {
        case .unsupported(let reason): return reason
        case .operation(let name, let status): return "\(name) failed (Core Audio \(status)). Control was not enabled. Check Audio Recording permission in System Settings."
        }
    }
}

public protocol AppAudioRouting: AnyObject, Sendable {
    var processObjects: [UInt32] { get }
    var outputDevice: UInt32 { get }
    var failed: Bool { get }
    func setVolume(_ level: Float)
    @discardableResult func stop() -> Bool
}

/// Owns the real-time state. The IO block retains it until HAL releases the
/// callback, even if device teardown fails; its memory cannot be freed early.
private final class AudioGainState: @unchecked Sendable {
    let pointer: UnsafeMutableRawPointer
    init(rate: Double) throws {
        guard let p = pm_audio_gain_create(rate) else { throw AudioRoutingError.unsupported("Unable to allocate audio control state.") }
        pointer = p
    }
    deinit { pm_audio_gain_destroy(pointer) }
}

/// Temporary, opt-in route for a specific set of HAL process objects.
/// Supports mono/stereo float32 hardware streams. Does not change default devices.
@available(macOS 14.2, *)
public final class AppAudioRoute: AppAudioRouting, @unchecked Sendable {
    public let processObjects: [UInt32]
    public let outputDevice: UInt32
    private let expectedClients: [AudioClient]
    private var tap: AudioObjectID = 0
    private var aggregate: AudioObjectID = 0
    private var io: AudioDeviceIOProcID?
    private var gain: AudioGainState?
    private var initialTapFormat: AudioStreamBasicDescription?
    private var started = false

    public init(clients: [AudioClient], output: AudioDeviceReading) throws {
        let processObjects = clients.map(\.id)
        self.processObjects = processObjects.sorted()
        expectedClients = clients
        outputDevice = output.id
        guard !processObjects.isEmpty, clients.allSatisfy({ Self.matches($0, output: output.id) }),
              AudioHAL.uint(UInt32(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice) == output.id,
              let streams = AudioHAL.ids(output.id, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput),
              streams.count == 1 else { throw AudioRoutingError.unsupported("Control needs the current default output with one mono/stereo stream.") }
        do {
            let hardware = try Self.format(streams[0], selector: kAudioStreamPropertyVirtualFormat)
            try Self.validate(hardware)
            let description = CATapDescription(processes: processObjects, deviceUID: output.uid, stream: 0)
            description.name = "Portmaster app volume"
            description.isPrivate = true
            description.muteBehavior = .mutedWhenTapped
            if #available(macOS 26.0, *) { description.isProcessRestoreEnabled = false }
            try Self.check(AudioHardwareCreateProcessTap(description, &tap), "Create app audio tap")
            let tapped = try Self.format(tap, selector: kAudioTapPropertyFormat)
            try Self.validate(tapped)
            initialTapFormat = tapped
            guard tapped.mSampleRate == hardware.mSampleRate else { throw AudioRoutingError.unsupported("The app tap and output sample rates differ.") }
            let tapUID = AudioHAL.string(tap, kAudioTapPropertyUID) ?? description.uuid.uuidString
            let dictionary: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Portmaster temporary app route",
                kAudioAggregateDeviceUIDKey: "dev.portmaster.mix." + UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceMainSubDeviceKey: output.uid,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output.uid, kAudioSubDeviceInputChannelsKey: 0]],
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]],
                kAudioAggregateDeviceTapAutoStartKey: true
            ]
            try Self.check(AudioHardwareCreateAggregateDevice(dictionary as CFDictionary, &aggregate), "Create temporary audio route")
            guard Self.channels(aggregate, scope: kAudioObjectPropertyScopeInput) == tapped.mChannelsPerFrame,
                  Self.channels(aggregate, scope: kAudioObjectPropertyScopeOutput) == tapped.mChannelsPerFrame else {
                throw AudioRoutingError.unsupported("This device exposes additional input/output channels. Portmaster will not open its microphone or alter its routing.")
            }
            for scope in [UInt32(kAudioObjectPropertyScopeInput), UInt32(kAudioObjectPropertyScopeOutput)] {
                guard let routeStreams = AudioHAL.ids(aggregate, kAudioDevicePropertyStreams, scope: scope), !routeStreams.isEmpty else {
                    throw AudioRoutingError.unsupported("The temporary route has no audio stream.")
                }
                for stream in routeStreams {
                    let format = try Self.format(stream, selector: kAudioStreamPropertyVirtualFormat)
                    guard Self.isFloat32(format), format.mSampleRate == hardware.mSampleRate else {
                        throw AudioRoutingError.unsupported("The temporary route uses an unsupported sample format.")
                    }
                }
            }
            let state = try AudioGainState(rate: hardware.mSampleRate)
            gain = state
            try Self.check(AudioDeviceCreateIOProcIDWithBlock(&io, aggregate, nil) { _, input, _, output, _ in
                pm_audio_render(state.pointer, input, output)
            }, "Create audio callback")
            // Revalidate immutable process object IDs immediately before routing.
            let live = Set(AudioHAL.ids(UInt32(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList) ?? [])
            guard processObjects.allSatisfy(live.contains), clients.allSatisfy({ Self.matches($0, output: output.id) }),
                  AudioHAL.uint(UInt32(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice) == output.id else {
                throw AudioRoutingError.unsupported("The app or output device changed. Try enabling control again.")
            }
            try Self.check(AudioDeviceStart(aggregate, io), "Start app volume control")
            started = true
        } catch { stop(); throw error }
    }
    public var failed: Bool {
        let live = Set(AudioHAL.ids(UInt32(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList) ?? [])
        guard processObjects.allSatisfy(live.contains), expectedClients.allSatisfy({ client in
            AudioHAL.uint(client.id, kAudioProcessPropertyPID).map { Int32(bitPattern: $0) } == client.pid
        }), let gain, pm_audio_gain_failed(gain.pointer) == 0,
              let original = initialTapFormat,
              let current = try? Self.format(tap, selector: kAudioTapPropertyFormat) else { return true }
        return !Self.isFloat32(current) || current.mSampleRate != original.mSampleRate
            || current.mChannelsPerFrame != original.mChannelsPerFrame
    }
    public func setVolume(_ level: Float) { if let gain { pm_audio_gain_set(gain.pointer, level) } }
    @discardableResult public func stop() -> Bool {
        func removed(_ status: OSStatus) -> Bool { status == noErr || status == kAudioHardwareBadObjectError }
        if aggregate != 0 {
            if let io {
                if started { _ = AudioDeviceStop(aggregate, io) }
                if removed(AudioDeviceDestroyIOProcID(aggregate, io)) { self.io = nil }
            }
            if removed(AudioHardwareDestroyAggregateDevice(aggregate)) { aggregate = 0; io = nil; started = false }
        }
        if tap != 0, removed(AudioHardwareDestroyProcessTap(tap)) { tap = 0 }
        if aggregate == 0 && tap == 0 { gain = nil; return true }
        // Retain failed IDs for an explicit removal retry; callback-owned state
        // remains alive until HAL releases its IO block.
        return false
    }
    deinit { stop() }
    private static func matches(_ client: AudioClient, output: UInt32) -> Bool {
        AudioHAL.uint(client.id, kAudioProcessPropertyPID).map { Int32(bitPattern: $0) } == client.pid
            && AudioHAL.uint(client.id, kAudioProcessPropertyIsRunningOutput) == 1
            && (AudioHAL.ids(client.id, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput)?.contains(output) == true)
    }
    private static func check(_ status: OSStatus, _ name: String) throws {
        if status != noErr { throw AudioRoutingError.operation(name, status) }
    }
    private static func isFloat32(_ format: AudioStreamBasicDescription) -> Bool {
        format.mFormatID == kAudioFormatLinearPCM && format.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && format.mBitsPerChannel == 32 && format.mSampleRate.isFinite && format.mSampleRate > 0
            && format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0
            && format.mBytesPerFrame == (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? 4 : format.mChannelsPerFrame * 4)
    }
    private static func validate(_ format: AudioStreamBasicDescription) throws {
        guard isFloat32(format), (1...2).contains(format.mChannelsPerFrame) else {
            throw AudioRoutingError.unsupported("Per-app control supports mono/stereo float32 output. This device uses a different format.")
        }
    }
    private static func format(_ object: UInt32, selector: UInt32) throws -> AudioStreamBasicDescription {
        var address = AudioHAL.address(selector), value = AudioStreamBasicDescription(), size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value), "Read audio stream format")
        return value
    }
    private static func channels(_ device: UInt32, scope: UInt32) -> UInt32? {
        var address = AudioHAL.address(kAudioDevicePropertyStreamConfiguration, scope: scope), size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              size >= MemoryLayout<AudioBufferList>.size, size < 1_048_576 else { return nil }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, buffer) == noErr else { return nil }
        let list = UnsafeMutableAudioBufferListPointer(buffer.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + $1.mNumberChannels }
    }
}
