// Tests for the slow-lane collectors added with the Containers / Keeping-
// This-Mac-Awake features: pmset assertion parsing, docker ps/stats parsing,
// and the AppBreakdown categorizer. All pure-parse, no subprocesses.
import XCTest
@testable import PortmasterCore

final class SlowLaneCollectorTests: XCTestCase {

    // MARK: - pmset assertions

    func testAssertionParseKeepsAwakeKindsAndFiltersOthers() {
        let output = """
        2026-09-30 10:39:52 +0300
        Assertion status system-wide:
           BackgroundTask                 0
           ApplePushServiceTask           0
           UserIsActive                   1
           PreventUserIdleDisplaySleep    0
           PreventSystemSleep             0
           PreventUserIdleSystemSleep     1

        Listed by owning process:
           pid 345(coreaudiod): [0x0000d00100019193] 00:00:00 PreventUserIdleSystemSleep named: "com.apple.audio.context.preventuseridlesleep.483"
           pid 512(Screen Studio): [0x000012e5000192ab] 00:05:23 PreventUserIdleSystemSleep named: "Screen Recording"
           pid 100(hidd): [0x0000bc4d00019351] 00:00:00 HidActivity named: "com.apple.hid.system.useractivity"
           pid 780(Xcode): [0x0000ad2b000192cd] 00:01:02 UserIsActive
           pid 42(launchd): [0x0000000100019301] 00:00:00 BackgroundTask named: "some background task"

        Assertion summary by process: ...
        """
        let results = PmsetAssertionCollector.parse(output)
        // HidActivity and BackgroundTask don't keep the Mac awake.
        XCTAssertEqual(results.count, 3)
        let screen = results.first { $0.processName == "Screen Studio" }
        XCTAssertEqual(screen?.pid, 512)
        XCTAssertEqual(screen?.kind, "PreventUserIdleSystemSleep")
        XCTAssertEqual(screen?.detail, "Screen Recording")
        let xcode = results.first { $0.processName == "Xcode" }
        XCTAssertEqual(xcode?.kind, "UserIsActive")
        XCTAssertNil(xcode?.detail)
        XCTAssertNil(results.first { $0.processName == "hidd" })
        XCTAssertNil(results.first { $0.processName == "launchd" })
    }

    func testAssertionParseDeduplicates() {
        let output = """
        Listed by owning process:
           pid 512(Screen Studio): [0x000012e5000192ab] 00:05:23 PreventUserIdleSystemSleep named: "Screen Recording"
           pid 512(Screen Studio): [0x000012e5000192ab] 00:05:23 PreventUserIdleSystemSleep named: "Screen Recording"
        """
        XCTAssertEqual(PmsetAssertionCollector.parse(output).count, 1)
    }

    func testAssertionParseEmptyInput() {
        XCTAssertEqual(PmsetAssertionCollector.parse("").count, 0)
        XCTAssertEqual(PmsetAssertionCollector.parse("garbage\nlines\nonly").count, 0)
    }

    // MARK: - docker ps

    func testDockerPSParseExtractsPortsAndStatus() {
        let output = """
        a1b2c3d4e5f6\trabbitmq\trabbitmq:latest\tUp 8 minutes\t0.0.0.0:5671->5671/tcp, :::5671->5671/tcp, 0.0.0.0:5672->5672/tcp, :::5672->5672/tcp, 0.0.0.0:15672->15672/tcp, :::15672->15672/tcp
        ff6e5d4c3b2a\tweb\tnginx:alpine\tExited (0) 2 days ago\t
        """
        let containers = DockerCollector.parsePS(output)
        XCTAssertEqual(containers.count, 2)
        XCTAssertEqual(containers[0].name, "rabbitmq")
        XCTAssertEqual(containers[0].ports, [5671, 5672, 15672])
        XCTAssertTrue(containers[0].isRunning)
        XCTAssertEqual(containers[1].name, "web")
        XCTAssertEqual(containers[1].ports, [])
        XCTAssertFalse(containers[1].isRunning)
    }

    func testDockerPSParseSkipsMalformedLines() {
        XCTAssertEqual(DockerCollector.parsePS("only-one-field").count, 0)
        XCTAssertEqual(DockerCollector.parsePS("").count, 0)
    }

    // MARK: - docker stats

    func testDockerStatsParse() {
        let output = """
        rabbitmq\t0.10%\t190MiB / 7.656GiB
        web\t1.53%\t42MiB / 7.656GiB
        """
        let stats = DockerCollector.parseStats(output)
        XCTAssertEqual(stats["rabbitmq"]?.cpu ?? -1, 0.10, accuracy: 0.001)
        XCTAssertEqual(stats["rabbitmq"]?.mem, 199_229_440) // 190 MiB
        XCTAssertEqual(stats["web"]?.cpu ?? -1, 1.53, accuracy: 0.001)
        XCTAssertEqual(stats["web"]?.mem, 44_040_192) // 42 MiB
    }

    func testDockerStatsIgnoresUnparsableRows() {
        let output = "rabbitmq\tnot-a-percent\tnot-bytes"
        XCTAssertTrue(DockerCollector.parseStats(output).isEmpty)
    }

    func testDockerPercentAndBytesHelpers() {
        XCTAssertEqual(DockerCollector.percent("0.10%") ?? -1, 0.10, accuracy: 0.001)
        XCTAssertNil(DockerCollector.percent("0.10"))
        XCTAssertEqual(DockerCollector.bytes("190MiB / 7.656GiB"), 199_229_440)
        XCTAssertEqual(DockerCollector.bytes("512B"), 512)
        XCTAssertEqual(DockerCollector.bytes("1.5GiB"), 1_610_612_736)
        XCTAssertNil(DockerCollector.bytes("??"))
    }

    // MARK: - AppBreakdown

    private func row(
        _ pid: pid_t, _ name: String, mem: UInt64, cpu: Double = 0, path: String? = nil
    ) -> ProcessRow {
        ProcessRow(
            pid: pid, name: name, parentPid: nil, isAppBundle: true,
            cpuPercent: cpu, memoryBytes: mem, executablePathHint: path
        )
    }

    func testChromiumBreakdownGroupsHelpers() {
        var chrome = AppRollup(
            id: "/Applications/Google Chrome.app",
            displayName: "Google Chrome", isAppBundle: true
        )
        chrome.processes = [
            row(1, "Google Chrome", mem: 900_000_000, cpu: 8.0,
                path: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"),
            row(2, "Google Chrome Helper (Renderer)", mem: 700_000_000, cpu: 14.0),
            row(3, "Google Chrome Helper (Renderer)", mem: 500_000_000, cpu: 2.0),
            row(4, "Google Chrome Helper (GPU)", mem: 200_000_000),
            row(5, "Google Chrome Helper (Plugin)", mem: 100_000_000),
            row(6, "Google Chrome Helper (Utility)", mem: 50_000_000),
        ]
        let groups = AppBreakdown.build(for: chrome)
        let ids = groups.map(\.id)
        XCTAssertTrue(ids.contains("tabs"))
        XCTAssertTrue(ids.contains("gpu"))
        XCTAssertTrue(ids.contains("extensions"))
        XCTAssertTrue(ids.contains("browser"))
        XCTAssertTrue(ids.contains("other")) // utility helper
        // Tabs dominate memory → headline group is Tabs.
        XCTAssertEqual(groups.first?.id, "tabs")
        XCTAssertEqual(groups.first?.count, 2)
        // Share math: tabs = 1.2 GB of 2.45 GB total.
        let tabsShare = Double(groups.first!.memoryBytes) / Double(chrome.totalMemory)
        XCTAssertEqual(tabsShare, 1_200_000_000.0 / 2_450_000_000.0, accuracy: 0.0001)
    }

    func testSafariBreakdownMapsWebKitProcesses() {
        var safari = AppRollup(
            id: "/Applications/Safari.app", displayName: "Safari", isAppBundle: true
        )
        safari.processes = [
            row(1, "Safari", mem: 300_000_000,
                path: "/Applications/Safari.app/Contents/MacOS/Safari"),
            row(2, "com.apple.WebKit.WebContent", mem: 800_000_000),
            row(3, "com.apple.WebKit.GPU", mem: 100_000_000),
            row(4, "com.apple.WebKit.Networking", mem: 90_000_000),
        ]
        let groups = AppBreakdown.build(for: safari)
        XCTAssertEqual(groups.first?.id, "tabs")
        XCTAssertNotNil(groups.first { $0.id == "gpu" })
        XCTAssertNotNil(groups.first { $0.id == "network" })
        XCTAssertNotNil(groups.first { $0.id == "browser" })
    }

    func testDockerBreakdownSeparatesEngine() {
        var docker = AppRollup(
            id: "/Applications/Docker.app", displayName: "Docker", isAppBundle: true
        )
        docker.processes = [
            row(1, "Docker", mem: 400_000_000,
                path: "/Applications/Docker.app/Contents/MacOS/Docker"),
            row(2, "com.docker.backend", mem: 1_500_000_000),
        ]
        let groups = AppBreakdown.build(for: docker)
        XCTAssertEqual(groups.first?.id, "engine")
        XCTAssertEqual(groups.first?.label, "Engine (Linux VM)")
        XCTAssertNotNil(groups.first { $0.id == "main" })
    }

    func testGenericAppFallsBackToMainAndOther() {
        var terminal = AppRollup(
            id: "/System/Applications/Utilities/Terminal.app",
            displayName: "Terminal", isAppBundle: true
        )
        terminal.processes = [
            row(1, "Terminal", mem: 90_000_000,
                path: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"),
            row(2, "login", mem: 6_000_000),
        ]
        let groups = AppBreakdown.build(for: terminal)
        XCTAssertEqual(groups.map(\.id), ["main", "other"])
        XCTAssertEqual(groups[0].label, "Main Process")
    }
}
