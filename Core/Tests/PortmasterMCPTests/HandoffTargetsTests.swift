// Core/Tests/PortmasterMCPTests/HandoffTargetsTests.swift
import XCTest
import Foundation
import PortmasterCore
import PortmasterMCP

final class HandoffTargetsTests: XCTestCase {

    private func temporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("targets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testDefaultsOfferTheTwoAgentsTheSpecNames() {
        let targets = HandoffTargets.load(directory: URL(fileURLWithPath: "/nonexistent"))
        XCTAssertEqual(Set(targets.keys), ["claude", "codex"])
        XCTAssertEqual(targets["claude"]?.executable, "claude")
        XCTAssertEqual(targets["codex"]?.executable, "codex")
        XCTAssertEqual(targets["codex"]?.arguments, [],
                       "invocation shapes are assumed, not confirmed (spec) — bare CLI, brief on stdin")
    }

    func testAValidFileOverridesTheDefaults() throws {
        let dir = try temporaryDirectory()
        let json = #"{"gemini":{"executable":"/opt/gemini/bin/gem","arguments":["--yolo"]}}"#
        try json.write(
            to: dir.appendingPathComponent(HandoffTargets.fileName),
            atomically: true, encoding: .utf8
        )
        let targets = HandoffTargets.load(directory: dir)
        XCTAssertEqual(Set(targets.keys), ["gemini"], "a file that decodes replaces the map")
        XCTAssertEqual(targets["gemini"]?.executable, "/opt/gemini/bin/gem")
        XCTAssertEqual(targets["gemini"]?.arguments, ["--yolo"])
    }

    func testAnUnreadableOrEmptyFileFallsBackToDefaults() throws {
        let dir = try temporaryDirectory()
        let url = dir.appendingPathComponent(HandoffTargets.fileName)
        try "not json at all".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(Set(HandoffTargets.load(directory: dir).keys), ["claude", "codex"])
        try "{}".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(Set(HandoffTargets.load(directory: dir).keys), ["claude", "codex"],
                       "an empty map is nobody's configuration, not every target removed")
    }
}
