import SwiftUI
import AVFoundation
import CoreAudio
import PortmasterCore
import PMShim

@MainActor
final class AudioControls: ObservableObject {
    @Published private(set) var levels: [String: Float] = [:]
    @Published private(set) var busy = Set<String>()
    @Published private(set) var error: String?
    @Published private(set) var micEnabled = false
    @Published private(set) var micLevel: Float = 0
    private var routes: [String: AppAudioRouting] = [:]
    private var routeTimer: Timer?
    private var priorLevels: [String: Float] = [:]
    private var latest: AudioSample?
    private var engine: AVAudioEngine?
    private var meterTimer: Timer?
    private var meterConfigurationObserver: NSObjectProtocol?
    private var meterInputID: UInt32?
    private var generation = 0
    private var micRequestInFlight = false

    func reconcile(_ sample: AudioSample?, rollups: [AppRollup]) {
        latest = sample
        for (id, route) in Array(routes) {
            let live = Set(sample?.clients?.map(\.id) ?? [])
            let app = rollups.first { $0.id == id }
            let pids = Set(app?.processes.map(\.pid) ?? [])
            let active = Set(sample?.clients?.filter {
                pids.contains($0.pid) && $0.outputActive == true && $0.outputDevices?.contains(route.outputDevice) == true
            }.map(\.id) ?? [])
            if app == nil || sample?.output?.id != route.outputDevice || !route.processObjects.allSatisfy(live.contains) || !active.isSubset(of: Set(route.processObjects)) || route.failed {
                if disable(id) { error = "Audio processes or output changed. App control was removed; enable it again if needed." }
            }
        }
        if micEnabled && sample?.input?.id != meterInputID {
            stopMeter(); error = "The input device changed. Enable the microphone meter again to use the new input."
        }
    }
    func enable(id: String, clients: [AudioClient], preview: Bool) {
        guard !preview, routes[id] == nil, !busy.contains(id), let output = latest?.output else { return }
        guard #available(macOS 14.2, *) else { error = "Per-app control requires macOS 14.2 or later."; return }
        let currentGeneration = generation
        busy.insert(id); error = nil
        Task {
            do {
                let route = try await Task.detached(priority: .userInitiated) { try AppAudioRoute(clients: clients, output: output) }.value
                guard currentGeneration == generation, latest?.output?.id == output.id,
                      Set(latest?.clients?.filter { $0.outputActive == true }.map(\.id) ?? []).isSuperset(of: route.processObjects) else {
                    route.stop(); busy.remove(id); return
                }
                routes[id] = route; levels[id] = 1
                startRouteWatchdog()
            } catch { self.error = error.localizedDescription }
            busy.remove(id)
        }
    }
    func setLevel(id: String, value: Float) {
        guard value.isFinite, (0...1).contains(value), let route = routes[id] else { return }
        levels[id] = value; route.setVolume(value)
    }
    func mute(_ id: String) {
        guard let level = levels[id] else { return }
        if level > 0 { priorLevels[id] = level; setLevel(id: id, value: 0) }
        else { setLevel(id: id, value: priorLevels[id] ?? 1) }
    }
    @discardableResult func disable(_ id: String) -> Bool {
        if let route = routes[id], !route.stop() {
            error = "Core Audio did not confirm removal of the temporary route. Retry removal or quit Portmaster to end its private audio session."
            return false
        }
        routes[id] = nil; levels[id] = nil; priorLevels[id] = nil
        if routes.isEmpty { routeTimer?.invalidate(); routeTimer = nil }
        return true
    }
    private func startRouteWatchdog() {
        guard routeTimer == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let output = AudioHAL.uint(UInt32(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)
                for (id, route) in Array(self.routes) where route.failed || route.outputDevice != output {
                    if self.disable(id) { self.error = "The audio route changed or rejected its buffers. App control was removed to restore normal playback." }
                }
            }
        }
        routeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func setSystemVolume(device: UInt32, value: Float, preview: Bool) {
        guard !preview else { return }
        if !AudioHAL.setOutputVolume(device: device, value: value) { error = "The device rejected its volume change. Refresh to see its current value." }
    }
    func startMeter(preview: Bool) {
        guard !preview, !micEnabled, !micRequestInFlight else { return }
        micRequestInFlight = true
        let currentGeneration = generation
        Task { [weak self] in
            guard let self else { return }
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            micRequestInFlight = false
            guard currentGeneration == generation else { return }
            guard granted else { error = "Microphone access was denied. Enable access in System Settings to use the meter."; return }
            do {
                let audio = AVAudioEngine()
                let input = audio.inputNode
                let format = input.outputFormat(forBus: 0)
                guard format.channelCount > 0, format.sampleRate > 0 else { error = "No usable microphone input is available."; return }
                let meter = try MicrophoneMeterState()
                input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                    guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
                    var rms: Float = 0
                    for c in 0..<Int(buffer.format.channelCount) { rms = max(rms, pm_audio_rms(channels[c], buffer.frameLength)) }
                    pm_audio_gain_set(meter.pointer, rms)
                }
                do { try audio.start() } catch { input.removeTap(onBus: 0); throw error }
                engine = audio; micEnabled = true
                meterInputID = AudioHAL.uint(UInt32(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice)
                meterConfigurationObserver = NotificationCenter.default.addObserver(
                    forName: .AVAudioEngineConfigurationChange, object: audio, queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.stopMeter()
                        self?.error = "The microphone configuration changed. Enable the meter again to resume."
                    }
                }
                meterTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self, self.micEnabled else { return }
                        self.micLevel = pm_audio_gain_get(meter.pointer)
                    }
                }
            } catch { self.error = error.localizedDescription }
        }
    }
    func stopMeter() {
        if let meterConfigurationObserver { NotificationCenter.default.removeObserver(meterConfigurationObserver) }
        meterConfigurationObserver = nil
        if let engine { engine.inputNode.removeTap(onBus: 0); engine.stop() }
        engine = nil; meterTimer?.invalidate(); meterTimer = nil
        micEnabled = false; micLevel = 0; meterInputID = nil
    }
    func stopAll() {
        generation += 1
        for id in Array(routes.keys) { disable(id) }
        stopMeter()
    }
    func clearError() { error = nil }
}

/// Retained by both the AVAudioEngine tap and timer, so callback memory stays
/// alive until the tap has been removed. Level samples are never stored.
private final class MicrophoneMeterState: @unchecked Sendable {
    let pointer: UnsafeMutableRawPointer
    init() throws {
        guard let p = pm_audio_gain_create(48_000) else { throw AudioRoutingError.unsupported("Unable to allocate microphone meter state.") }
        pointer = p; pm_audio_gain_set(pointer, 0)
    }
    deinit { pm_audio_gain_destroy(pointer) }
}
