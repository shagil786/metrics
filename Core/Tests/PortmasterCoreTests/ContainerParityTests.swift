import XCTest
@testable import PortmasterCore

final class ContainerParityTests: XCTestCase {
    func testRatesRequireBaselineAndValidTime() {
        let c = DockerIOCounters(networkIn: 1200, networkOut: 800, diskRead: 200, diskWrite: 100)
        XCTAssertNil(c.rates(since: nil, seconds: 15).networkIn)
        XCTAssertNil(c.rates(since: c, seconds: 0).networkIn)
        XCTAssertNil(c.rates(since: c, seconds: .infinity).diskWrite)
    }
    func testRatesUseDeltasAndResetIndependently() {
        let old = DockerIOCounters(networkIn: 1000, networkOut: 100, diskRead: 200, diskWrite: 300)
        let new = DockerIOCounters(networkIn: 1200, networkOut: 300, diskRead: 100, diskWrite: 300)
        let rate = new.rates(since: old, seconds: 10)
        XCTAssertEqual(rate.networkIn, 20)
        XCTAssertEqual(rate.networkOut, 20)
        XCTAssertNil(rate.diskRead)
        XCTAssertEqual(rate.diskWrite, 0)
    }
    func testIOParsesBothDirectionsAndBinaryUnits() {
        let io = DockerCollector.parseIO("abc\t1%\t1MiB / 2GiB\t1kB / 2kB\t3MiB / 4MiB")["abc"]
        XCTAssertEqual(io?.networkIn, 1000)
        XCTAssertEqual(io?.networkOut, 2000)
        XCTAssertEqual(io?.diskRead, 3 * 1_048_576)
        XCTAssertEqual(io?.diskWrite, 4 * 1_048_576)
        XCTAssertTrue(DockerCollector.parseIO("abc\t1%\t1B\tbad / 2B\t1B / 2B").isEmpty)
    }
    func testInvalidNumbersCannotTrapOrFabricateReadings() {
        for text in ["nanB", "infB", "-1B", "1e100B", "18446744073709551616B"] {
            XCTAssertNil(DockerCollector.bytes(text), text)
        }
        XCTAssertNil(DockerCollector.percent("nan%"))
        XCTAssertNil(DockerCollector.percent("-1%"))
        XCTAssertEqual(DockerCollector.percent("250%"), 250)
    }
    func testStopIDsRejectNamesOptionsAndInjection() {
        XCTAssertTrue(DockerCollector.validContainerID("abcdef123456"))
        XCTAssertTrue(DockerCollector.validContainerID(String(repeating: "a", count: 64)))
        for id in ["web", "--all", "abc;rm", "abcdef12345z", ""] {
            XCTAssertFalse(DockerCollector.validContainerID(id))
        }
    }
    func testCollectorUsesIDsAndRebaselinesAfterFailureAndReplacement() {
        let firstID = String(repeating: "a", count: 64)
        let replacementID = String(repeating: "b", count: 64)
        var id = firstID
        var bytes = 1000
        var failed = false
        var time = Date(timeIntervalSince1970: 100)
        var commands: [[String]] = []
        let collector = DockerCollector(command: { args in
            commands.append(args)
            if args.first == "ps" { return "\(id)\tweb\timage\tUp\t" }
            if failed { return nil }
            return "\(id)\t1%\t10MiB / 1GiB\t\(bytes)B / 0B\t0B / 0B"
        }, now: { time })
        XCTAssertNil(collector.sample().containers.first?.networkInBytesPerSec)
        time.addTimeInterval(10); bytes = 1200
        XCTAssertEqual(collector.sample().containers.first?.networkInBytesPerSec, 20)
        time.addTimeInterval(10); id = replacementID; bytes = 9000
        XCTAssertNil(collector.sample().containers.first?.networkInBytesPerSec)
        time.addTimeInterval(10); failed = true
        XCTAssertNil(collector.sample().containers.first?.memoryBytes)
        time.addTimeInterval(10); failed = false; bytes = 10000
        XCTAssertNil(collector.sample().containers.first?.networkInBytesPerSec)
        XCTAssertTrue(commands.contains { $0.contains("--no-trunc") && $0.last?.contains("{{.ID}}") == true })
    }
    func testStopRequiresCommandSuccessAndConfirmedState() {
        let id = "abcdef123456"
        var commands: [[String]] = []
        XCTAssertTrue(DockerCollector.performStop(id: id) { args in
            commands.append(args)
            return args.first == "stop" ? id : "false\n"
        })
        XCTAssertEqual(commands, [["stop", "--timeout", "10", id], ["inspect", "--format", "{{.State.Running}}", id]])
        XCTAssertFalse(DockerCollector.performStop(id: id) { _ in nil })
        XCTAssertFalse(DockerCollector.performStop(id: id) { _ in "true" })
        XCTAssertFalse(DockerCollector.performStop(id: "--all") { _ in XCTFail("Invalid ID reached command runner"); return "false" })
    }
    func testContainerMemoryTotalSaturates() {
        let c = DockerContainer(id: "a", name: "web", image: "test", statusText: "Up", ports: [], cpuPercent: nil, memoryBytes: .max)
        XCTAssertEqual(DockerSample(availability: .running, containers: [c, c]).totalMemoryBytes, .max)
    }
    func testHistoryDeduplicatesCachedReadingsAndPreservesUnknownRates() {
        let c = DockerContainer(id: "a", name: "web", image: "test", statusText: "Up", ports: [], cpuPercent: 1, memoryBytes: 100)
        let sample = DockerSample(availability: .running, containers: [c], at: Date(timeIntervalSince1970: 100))
        var history = DockerHistory()
        history.append(sample); history.append(sample)
        XCTAssertEqual(history.points.count, 1)
        XCTAssertNil(history.points.first?.networkBytesPerSec)
        history.append(DockerSample(availability: .daemonDown, containers: [], at: Date(timeIntervalSince1970: 2000)))
        XCTAssertTrue(history.points.isEmpty)
    }
    func testHistoryCombinesRatesAndRetainsContainerIdentity() {
        let c = DockerContainer(id: "a", name: "web", image: "test", statusText: "Up", ports: [], cpuPercent: 1, memoryBytes: nil,
                                networkInBytesPerSec: 10, networkOutBytesPerSec: 20, diskReadBytesPerSec: 30, diskWriteBytesPerSec: 40)
        var history = DockerHistory()
        history.append(DockerSample(availability: .running, containers: [c]))
        XCTAssertEqual(history.points.first?.containerID, "a")
        XCTAssertEqual(history.points.first?.networkBytesPerSec, 30)
        XCTAssertEqual(history.points.first?.diskBytesPerSec, 70)
    }
}
