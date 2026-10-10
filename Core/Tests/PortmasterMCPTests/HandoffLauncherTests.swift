// Core/Tests/PortmasterMCPTests/HandoffLauncherTests.swift
import XCTest
import Foundation
import PortmasterMCP

final class HandoffLauncherTests: XCTestCase {

    private func temporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("launch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testResolveFindsAnExecutableOnAGivenPath() throws {
        let dir = try temporaryDirectory()
        let stub = dir.appendingPathComponent("agentx")
        try "#!/bin/sh\nexit 0\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

        let launcher = SystemHandoffLauncher()
        XCTAssertEqual(launcher.resolve("agentx", path: dir.path), stub.path)
        XCTAssertNil(launcher.resolve("not-installed-xyz", path: dir.path),
                     "a missing CLI is a fact the handoff must be able to report")
    }

    func testResolveAcceptsAnAbsolutePathThatExists() throws {
        let launcher = SystemHandoffLauncher()
        XCTAssertEqual(launcher.resolve("/bin/sh", path: "/nowhere"), "/bin/sh")
        XCTAssertNil(launcher.resolve("/definitely/not/here", path: "/nowhere"))
    }

    /// The brief arrives on stdin: `/bin/sh -c 'cat > file'` is the receiving
    /// agent in miniature, and the file is the assertion.
    func testTheBriefRidesStdinToTheChild() throws {
        let dir = try temporaryDirectory()
        let received = dir.appendingPathComponent("received.txt")
        let launcher = SystemHandoffLauncher()

        _ = try launcher.launch(
            executable: "/bin/sh",
            arguments: ["-c", "cat > \(received.path)"],
            workingDirectory: dir.path,
            stdinText: "# Handoff brief\n\n## Goal\ndo the thing (line 1)\n"
        )

        let deadline = Date().addingTimeInterval(5)
        var content = ""
        while Date() < deadline {
            content = (try? String(contentsOf: received, encoding: .utf8)) ?? ""
            if content.contains("do the thing") { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertTrue(content.contains("## Goal\ndo the thing (line 1)"),
                      "the receiving agent reads the brief from stdin, verbatim")
    }

    func testAMissingWorkingDirectoryIsRefusedNotGuessed() throws {
        let launcher = SystemHandoffLauncher()
        XCTAssertThrowsError(try launcher.launch(
            executable: "/bin/sh", arguments: ["-c", "true"],
            workingDirectory: "/definitely/not/a/dir-\(UUID().uuidString)",
            stdinText: "x"
        )) { error in
            XCTAssertTrue("\(error)".contains("working directory"), "the refusal names the fact")
        }
    }
}
