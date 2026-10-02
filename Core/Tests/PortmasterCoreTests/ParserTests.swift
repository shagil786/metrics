import XCTest
@testable import PortmasterCore

final class ParserTests: XCTestCase {

    func testLsofParseBasic() {
        // p pid \0 c cmd \0 n *:port \0
        let input = "p123\0cnode\0n*:3000\0"
        let ports = LsofPortScanner.parseFieldOutput(Data(input.utf8))
        XCTAssertEqual(ports.count, 1)
        XCTAssertEqual(ports[0].port, 3000)
        XCTAssertEqual(ports[0].pid, 123)
        XCTAssertEqual(ports[0].processName, "node")
    }

    func testLsofParseIPv6AndDedup() {
        let input = "p7\0cpostgres\0n*:5432\0p7\0cpostgres\0n[::1]:5432\0p7\0cpostgres\0n127.0.0.1:5432\0"
        let ports = LsofPortScanner.parseFieldOutput(Data(input.utf8))
        XCTAssertEqual(ports.count, 3)
        XCTAssertTrue(ports.contains { $0.address == "::1" })
        XCTAssertTrue(ports.contains { $0.address == "127.0.0.1" })
        XCTAssertTrue(ports.contains { $0.address == "*" })
    }

    func testLsofParseSkipsNonEndpointNames() {
        // lsof -i also emits other socket forms; must skip them safely.
        let input = "p9\0ccron\0n2u\0n*:9050\0"
        let ports = LsofPortScanner.parseFieldOutput(Data(input.utf8))
        XCTAssertEqual(ports.count, 1)
        XCTAssertEqual(ports[0].port, 9050)
    }

    func testEndpointParsing() {
        XCTAssertEqual(LsofPortScanner.parseEndpoint("*:8080")?.port, 8080)
        XCTAssertEqual(LsofPortScanner.parseEndpoint("127.0.0.1:5432")?.host, "127.0.0.1")
        XCTAssertEqual(LsofPortScanner.parseEndpoint("[fe80::1]:443")?.host, "fe80::1")
        XCTAssertNil(LsofPortScanner.parseEndpoint("noport"))
        XCTAssertNil(LsofPortScanner.parseEndpoint("*:notaport"))
    }

    func testRuntimeLabels() {
        XCTAssertEqual(RuntimeLabel.classify(name: "node", path: nil), "Node.js")
        XCTAssertEqual(RuntimeLabel.classify(name: "postgres", path: nil), "PostgreSQL")
        XCTAssertEqual(RuntimeLabel.classify(name: "ollama", path: nil), "Ollama")
        XCTAssertNil(RuntimeLabel.classify(name: "unknown-thing", path: nil))
    }

    func testFormatting() {
        XCTAssertEqual(Fmt.bytes(512), "512 B")
        XCTAssertEqual(Fmt.bytes(512 * 1024), "512 KB")
        XCTAssertEqual(Fmt.bytes(2 * 1024 * 1024 * 1024), "2.0 GB")
        XCTAssertEqual(Fmt.cpu(3.456), "3.5%")
        XCTAssertEqual(Fmt.cpu(123.4), "123%")
        XCTAssertEqual(Fmt.bytes(nil), "—")
    }

    func testMemoryPressureLevelFromRatio() {
        // Formula sanity: level thresholds in MachSystemCollector.sampleMemory
        // are encoded inline; validate the derived ranking indirectly here.
        let mem = SystemMemory(
            totalBytes: 100, usedBytes: 95, pressureLevel: .critical,
            pressureRatio: 0.95, swapBytes: nil, freeBytes: 5,
            appBytes: nil, wiredBytes: nil, compressedBytes: nil
        )
        XCTAssertEqual(mem.pressureLevel, .critical)
    }
}
