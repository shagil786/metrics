import XCTest
import CoreAudio
import PMShim
@testable import PortmasterCore

final class AudioPeripheralTests: XCTestCase {
    func testBluetoothAddressNormalizationAndInvalidValues() {
        XCTAssertEqual(BluetoothCollector.address("AA:BB:CC:DD:EE:FF"), "aabbccddeeff")
        XCTAssertEqual(BluetoothCollector.address("aa-bb-cc-dd-ee-ff"), "aabbccddeeff")
        XCTAssertNil(BluetoothCollector.address("not-an-address"))
        for value: Any in [-1, 101, 255, Double.nan, 2.5, true, "unknown"] {
            XCTAssertNil(BluetoothCollector.percent(value))
        }
        XCTAssertEqual(BluetoothCollector.percent("63%"), 63)
        XCTAssertEqual(BluetoothCollector.percent(0), 0)
    }
    func testRegistryOnlyIncludesBluetoothAndPreservesUnknownBattery() {
        var dict: [String: Any] = ["Transport": "Bluetooth", "DeviceAddress": "aa-bb-cc-dd-ee-ff", "Product": "Keyboard", "BatteryPercent": 63]
        XCTAssertEqual(BluetoothCollector.parseRegistry(dict)?.batteries["Battery"], 63)
        dict["BatteryPercent"] = 255
        XCTAssertEqual(BluetoothCollector.parseRegistry(dict)?.batteries, [:])
        dict["Transport"] = "USB"
        XCTAssertNil(BluetoothCollector.parseRegistry(dict))
    }
    func testInventoryExcludesDisconnectedDevicesAndReadsComponents() throws {
        let object: [String: Any] = ["SPBluetoothDataType": [[
            "device_connected": [["Headphones": ["device_address": "AA:BB:CC:DD:EE:FF", "device_batteryLevelLeft": "80%", "device_batteryLevelRight": "70%", "device_batteryLevelCase": "50%"]]],
            "device_not_connected": [["Old headphones": ["device_address": "11:22:33:44:55:66", "device_batteryLevelMain": "90%"]]]
        ]]]
        let parsed = try XCTUnwrap(BluetoothCollector.parseInventory(JSONSerialization.data(withJSONObject: object)))
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].batteries, ["Left": 80, "Right": 70, "Case": 50])
        XCTAssertNil(BluetoothCollector.parseInventory(Data("bad".utf8)))
    }
    func testSignalMathAttenuatesWithoutAmplification() {
        XCTAssertEqual(pm_audio_attenuate(0.8, 0.5), 0.4, accuracy: 0.00001)
        XCTAssertEqual(pm_audio_attenuate(-0.8, 0), 0)
        XCTAssertEqual(pm_audio_attenuate(0.8, 1), 0.8)
        XCTAssertEqual(pm_audio_attenuate(.nan, 1), 0)
        XCTAssertEqual(pm_audio_attenuate(0.8, 2), 0)
        let signal: [Float] = [0.5, -0.5, 0.5, -0.5]
        signal.withUnsafeBufferPointer { XCTAssertEqual(pm_audio_rms($0.baseAddress, UInt32($0.count)), 0.5, accuracy: 0.00001) }
        XCTAssertEqual(pm_audio_rms(nil, 0), 0)
    }
    func testAtomicGainRejectsInvalidControlValues() throws {
        let state = try XCTUnwrap(pm_audio_gain_create(48_000)); defer { pm_audio_gain_destroy(state) }
        pm_audio_gain_set(state, 0.25)
        XCTAssertEqual(pm_audio_gain_get(state), 0.25)
        for value: Float in [.nan, -.infinity, -1, 2] { pm_audio_gain_set(state, value) }
        XCTAssertEqual(pm_audio_gain_get(state), 0.25)
    }
    private func withList(_ buffers: [AudioBuffer], body: (UnsafeMutablePointer<AudioBufferList>) -> Void) {
        let size = MemoryLayout<AudioBufferList>.size + max(0, buffers.count - 1) * MemoryLayout<AudioBuffer>.stride
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let pointer = raw.assumingMemoryBound(to: AudioBufferList.self)
        pointer.pointee.mNumberBuffers = UInt32(buffers.count)
        let list = UnsafeMutableAudioBufferListPointer(pointer)
        for i in buffers.indices { list[i] = buffers[i] }
        body(pointer)
    }
    func testStereoRoutingConvertsInterleavedToPlanarAndRampsGain() throws {
        let state = try XCTUnwrap(pm_audio_gain_create(48_000)); defer { pm_audio_gain_destroy(state) }
        pm_audio_gain_set(state, 0.5)
        var input = (0..<1024).map { Float($0 % 2 == 0 ? 1 : -1) }
        var left = [Float](repeating: 0, count: 512), right = left
        input.withUnsafeMutableBytes { src in
            left.withUnsafeMutableBytes { dstLeft in
                right.withUnsafeMutableBytes { dstRight in
                    withList([AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(src.count), mData: src.baseAddress)]) { i in
                        withList([AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(dstLeft.count), mData: dstLeft.baseAddress),
                                  AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(dstRight.count), mData: dstRight.baseAddress)]) { o in
                            pm_audio_render(state, i, o)
                        }
                    }
                }
            }
        }
        XCTAssertEqual(left.last ?? 0, 0.5, accuracy: 0.0001)
        XCTAssertEqual(right.last ?? 0, -0.5, accuracy: 0.0001)
        XCTAssertTrue(left.allSatisfy { (0.5...1).contains($0) })
        XCTAssertEqual(pm_audio_gain_failed(state), 0)
    }
    func testMonoRoutingReachesMuteWithoutChangingChannelLayout() throws {
        let state = try XCTUnwrap(pm_audio_gain_create(48_000)); defer { pm_audio_gain_destroy(state) }
        pm_audio_gain_set(state, 0)
        var input = [Float](repeating: 0.5, count: 1024), output = input
        input.withUnsafeMutableBytes { source in
            output.withUnsafeMutableBytes { destination in
                withList([AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(source.count), mData: source.baseAddress)]) { i in
                    withList([AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(destination.count), mData: destination.baseAddress)]) { o in
                        pm_audio_render(state, i, o)
                    }
                }
            }
        }
        XCTAssertEqual(output.last, 0)
        XCTAssertTrue(output.allSatisfy { (0...0.5).contains($0) })
        XCTAssertEqual(pm_audio_gain_failed(state), 0)
    }
    func testInvalidRoutingBuffersSignalFailureAndSilenceOutput() throws {
        let state = try XCTUnwrap(pm_audio_gain_create(48_000)); defer { pm_audio_gain_destroy(state) }
        var output = [Float](repeating: 1, count: 16)
        output.withUnsafeMutableBytes { data in
            withList([AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(data.count), mData: data.baseAddress)]) { pm_audio_render(state, nil, $0) }
        }
        XCTAssertEqual(pm_audio_gain_failed(state), 1)
        XCTAssertTrue(output.allSatisfy { $0 == 0 })
    }
    func testPreviewProvidersNeverQueryHardware() {
        XCTAssertEqual(FixtureAudioProvider().sample().clients?.count, 0)
        XCTAssertNil(FixtureAudioProvider().sample().output)
        XCTAssertTrue(FixtureBluetoothProvider().sample().devices.isEmpty)
    }
    func testLiveReadOnlyPeripheralSmoke() {
        let audio = AudioCollector().sample()
        if let volume = audio.output?.volume { XCTAssertTrue(volume.isFinite && (0...1).contains(volume)) }
        let bluetooth = BluetoothCollector().sample()
        for device in bluetooth.devices { XCTAssertTrue(device.batteries.values.allSatisfy { (0...100).contains($0) }) }
        print("AUDIO LIVE:", audio.output?.name ?? "none", "clients", audio.clients?.count ?? -1)
        print("BLUETOOTH LIVE:", bluetooth.devices.map { ($0.name, $0.batteries) })
    }
}
