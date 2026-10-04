// Fixture providers: visibly-labeled preview data for development only.
// Never the default source; the app surfaces "Preview data" whenever enabled.
// Battery intentionally stays LIVE in preview mode: it is read-only machine
// state with no process/project data, unlike collectors that could leak or
// mix synthetic pids into live surfaces.
import Foundation

public final class FixtureSystemCollector: SystemCollector, @unchecked Sendable {
    private var phase: Double = 0
    private let lock = NSLock()

    public init() {}

    public func sampleCPU() -> SystemCPU? {
        lock.lock(); defer { lock.unlock() }
        phase += 0.35
        let wave = (sin(phase) + 1) / 2
        let total = 8 + wave * 55
        let cores = (0..<10).map { i in
            (total + Double(i) * 7).truncatingRemainder(dividingBy: 100)
        }
        return SystemCPU(
            totalPercent: total,
            userPercent: total * 0.72,
            systemPercent: total * 0.18,
            idlePercent: 100 - total,
            corePercents: cores,
            coreCount: 10
        )
    }

    public func sampleMemory() -> SystemMemory? {
        let total: UInt64 = 32 * 1024 * 1024 * 1024
        lock.lock(); defer { lock.unlock() }
        phase += 0.1
        let wave = (sin(phase * 0.6) + 1) / 2
        let used = UInt64(Double(total) * (0.52 + wave * 0.28))
        let ratio = Double(used) / Double(total)
        let level: MemoryPressureLevel = ratio > 0.9 ? .critical : ratio > 0.7 ? .elevated : .normal
        return SystemMemory(
            totalBytes: total,
            usedBytes: used,
            pressureLevel: level,
            pressureRatio: ratio,
            swapBytes: 268_435_456,
            freeBytes: total - used,
            appBytes: used * 3 / 5,
            wiredBytes: used / 5,
            compressedBytes: used / 10
        )
    }
}

public final class FixtureProcessCollector: ProcessCollector {
    public init() {}
    private let start = Date().addingTimeInterval(-86_400)
    /// Preview-only synthetic disk counters, advanced deterministically so the
    /// Disk screen's rates and Top Apps have plausible motion. Fixture mode is
    /// always visibly labeled; this data never touches history or alerts.
    private let boot = Date()

    private var fixtures: [(pid: pid_t, name: String, ppid: pid_t?, cpu: Double, mem: UInt64, cwd: String?, isApp: Bool, path: String, writeBps: Double, readBps: Double)] {
        [
            (4821, "node", 912, 41.2, 512_000_000, "/Users/dev/work/api-server", false, "/usr/local/bin/node server.js", 0, 0),
            (4822, "esbuild", 4821, 12.4, 96_000_000, "/Users/dev/work/api-server", false, "/Users/dev/work/api-server/node_modules/.bin/esbuild", 0, 0),
            (5100, "postgres", 1, 3.1, 240_000_000, "/opt/homebrew/var/postgres", false, "/opt/homebrew/bin/postgres", 1_024, 2_048),
            (6210, "python", 912, 27.8, 380_000_000, "/Users/dev/work/ml-trainer", false, "/opt/homebrew/bin/python3 train.py", 0, 0),
            (6211, "ollama", 1, 58.9, 8_200_000_000, "/Users/dev/.ollama", false, "/usr/local/bin/ollama serve", 0, 0),
            (720, "Code", 1, 18.3, 1_400_000_000, nil, true, "/Applications/Visual Studio Code.app/Contents/MacOS/Electron", 2_048, 0),
            (721, "Code Helper (Renderer)", 720, 6.2, 820_000_000, nil, true, "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Renderer).app/Contents/MacOS/Code Helper (Renderer)", 0, 0),
            (722, "Code Helper (Plugin)", 720, 2.1, 310_000_000, nil, true, "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)", 0, 0),
            (912, "Terminal", 1, 1.4, 96_000_000, nil, true, "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal", 0, 0),
            (3344, "Xcode", 1, 22.1, 3_100_000_000, nil, true, "/Applications/Xcode.app/Contents/MacOS/Xcode", 8_192, 5_400),
            (3345, "XcodeBuildService", 3344, 11.8, 900_000_000, nil, true, "/Applications/Xcode.app/Contents/Developer/Library/PrivateFrameworks/XcodeBuildService.framework/Versions/A/XcodeBuildService", 4_096, 12_000),
            (4021, "Google Chrome", 1, 9.7, 1_900_000_000, nil, true, "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", 2_000, 8_000),
            (4022, "Google Chrome Helper (Renderer)", 4021, 14.2, 760_000_000, nil, true, "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)", 1_000, 0),
            (4023, "Google Chrome Helper (GPU)", 4021, 3.4, 240_000_000, nil, true, "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Helper (GPU).app/Contents/MacOS/Google Chrome Helper (GPU)", 0, 0),
        ]
    }

    public func snapshot() -> ProcessSweep? {
        let now = Date()
        let elapsed = now.timeIntervalSince(boot)
        let records = fixtures.map { f in
            RawProcess(
                pid: f.pid, parentPid: f.ppid, name: f.name,
                cpuTicks: UInt64(f.cpu * 1_000_000),
                residentBytes: f.mem,
                startedAt: start.addingTimeInterval(Double(f.pid) * 7),
                isAppBundle: f.isApp,
                executablePath: f.path,
                diskReadBytes: f.readBps > 0 ? UInt64(f.readBps * elapsed) : nil,
                diskWriteBytes: f.writeBps > 0 ? UInt64(f.writeBps * elapsed) : nil
            )
        }
        return ProcessSweep(records: records, at: now)
    }

    public func executablePath(pid: pid_t) -> String? {
        fixtures.first { $0.pid == pid }?.path
    }

    public func commandArguments(pid: pid_t) -> [String]? {
        fixtures.first { $0.pid == pid }.map { ["fixture", "\($0.name)"] }
    }

    public func workingDirectory(pid: pid_t) -> String? {
        fixtures.first { $0.pid == pid }?.cwd
    }
}

public final class FixturePortCollector: PortCollector {
    public init() {}

    public func listeningPorts() -> [ListeningPort]? {
        [
            ListeningPort(port: 3000, pid: 4821, processName: "node", address: "*"),
            ListeningPort(port: 9229, pid: 4821, processName: "node", address: "127.0.0.1"),
            ListeningPort(port: 5432, pid: 5100, processName: "postgres", address: "127.0.0.1"),
            ListeningPort(port: 8000, pid: 6210, processName: "python", address: "*"),
            ListeningPort(port: 11434, pid: 6211, processName: "ollama", address: "127.0.0.1"),
        ]
    }
}

/// Preview-only synthetic nettop provider: cumulative counters that advance
/// at fixed per-pid rates, so the Network tab's rates, session totals, and
/// Top Apps have motion. Fixture mode is always visibly labeled; this data
/// never reaches history or alerts.
public final class FixtureNettopProvider: NettopProviding {
    public init() {}
    private let boot = Date()

    private let fixtures: [(pid: pid_t, name: String, inBps: Double, outBps: Double)] = [
        (4021, "Chrome", 5_200_000, 320_000),
        (720, "Code", 1_200_000, 95_000),
        (3344, "Xcode", 460_000, 40_000),
        (4821, "node", 300_000, 25_000),
        (912, "Terminal", 0, 0),
    ]

    public func sample() -> [ProcessNetUsage]? {
        let elapsed = Date().timeIntervalSince(boot)
        return fixtures.map {
            ProcessNetUsage(
                pid: $0.pid, name: $0.name,
                bytesIn: UInt64($0.inBps * elapsed),
                bytesOut: UInt64($0.outBps * elapsed)
            )
        }
    }
}

/// Preview-only sleep assertions: an ollama model load and an Xcode
/// user-activity claim, matching fixture pids. Fixture mode is always
/// visibly labeled; this data never reaches history or alerts.
public final class FixtureAssertionProvider: SleepAssertionProviding {
    public init() {}

    public func sample() -> [SleepAssertion]? {
        [
            SleepAssertion(
                pid: 6211, processName: "ollama",
                kind: "PreventUserIdleSystemSleep",
                detail: "model loaded"
            ),
            SleepAssertion(
                pid: 3344, processName: "Xcode",
                kind: "UserIsActive",
                detail: nil
            ),
        ]
    }
}

/// Preview-only Docker state: one rabbitmq container, up, with stats
/// attached — mirrors the reference so the Containers surfaces have data.
public final class FixtureDockerProvider: DockerProviding {
    public init() {}

    public func sample() -> DockerSample {
        DockerSample(availability: .running, containers: [
            DockerContainer(
                id: "a1b2c3d4e5f6", name: "rabbitmq", image: "rabbitmq:latest",
                statusText: "Up 8 minutes",
                ports: [5671, 5672, 15672],
                cpuPercent: 0.31, memoryBytes: 190_800_000
            ),
        ])
    }
}

/// Explicit preview sensors; never read the real SMC in fixture mode.
public struct FixtureThermalProvider: ThermalProviding {
    public init() {}
    public func sample() -> ThermalSample? {
        ThermalSample.readings(cpuTempC: 54, gpuTempC: 47, hottestTempC: 56,
                               fans: [FanSample(name: "Preview fan", currentRPM: 1200)])
    }
}

public struct FixtureAudioProvider: AudioProviding {
    public init() {}
    public func sample() -> AudioSample { AudioSample(output: nil, input: nil, clients: []) }
}
public struct FixtureBluetoothProvider: BluetoothProviding {
    public init() {}
    public func sample() -> BluetoothSample { BluetoothSample(devices: [], inventoryAvailable: true) }
}
