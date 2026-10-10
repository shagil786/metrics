// HandoffCoordinatorTests: the coordinator's flow — dry run before launch,
// refusals that name their reason, the brief written before anything spawns,
// and the once-only record.

import XCTest
import Foundation
import PortmasterCore
@testable import PortmasterMCP

final class HandoffCoordinatorTests: XCTestCase {

    private final class FakeLauncher: HandoffLaunching, @unchecked Sendable {
        var resolveResult: ((String) -> String?)?
        private(set) var launches: [(executable: String, arguments: [String], cwd: String, stdin: String)] = []
        private(set) var terminated: [Int32] = []
        var nextPID: Int32 = 4242

        func resolve(_ executable: String, path: String?) -> String? {
            // A set resolver is authoritative, including its nil ("not
            // installed"): `resolveResult?(executable) ?? executable` would
            // fall back to the name for a nil *result* as well as for an
            // absent resolver, and the missing-CLI test could never be pinned.
            guard let resolveResult else { return executable }
            return resolveResult(executable)
        }

        func launch(
            executable: String, arguments: [String],
            workingDirectory: String, stdinText: String
        ) throws -> Int32 {
            launches.append((executable, arguments, workingDirectory, stdinText))
            return nextPID
        }

        func terminate(pid: Int32) { terminated.append(pid) }
    }

    private final class Harness {
        let root: URL
        let projectsRoot: URL
        let handoffDir: URL
        let store: AgentSessionStore
        let launcher: FakeLauncher
        let defaults: UserDefaults
        let sessionID = UUID()
        let connectedAt = Date(timeIntervalSinceNow: -100)
        let workingDir: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("handoff-\(UUID().uuidString)", isDirectory: true)
            projectsRoot = root.appendingPathComponent("projects", isDirectory: true)
            handoffDir = root.appendingPathComponent("handoffs", isDirectory: true)
            workingDir = root.appendingPathComponent("work", isDirectory: true)
            for dir in [projectsRoot, handoffDir, workingDir] {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            store = try AgentSessionStore(
                storeURL: root.appendingPathComponent("sessions.sqlite")
            )
            launcher = FakeLauncher()
            defaults = UserDefaults(suiteName: "handoff-\(UUID().uuidString)")!
        }

        func writeLog(_ lines: [String]) throws -> URL {
            let dir = projectsRoot.appendingPathComponent("-tmp-work", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("\(sessionID.uuidString).jsonl")
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            return url
        }

        func recordSession() throws {
            try store.recordSession(
                id: sessionID, peerPID: 1, clientName: nil, clientVersion: nil,
                connectedAt: connectedAt
            )
            try store.flush()
        }

        func makeCoordinator() throws -> HandoffCoordinator {
            HandoffCoordinator(
                store: store,
                adapter: ClaudeCodeLogAdapter(projectsRoot: projectsRoot),
                launcher: launcher,
                defaults: defaults,
                handoffDirectory: handoffDir
            )
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: defaults.dictionaryRepresentation()["SuiteName"] as? String ?? "")
        }
    }

    /// Timestamps spread around `connectedAt` so the conversation's interval
    /// contains the connection (AgentLogMatcher's rule), all in the past so
    /// nothing reads as a future clock artefact. Line numbers are the fixture's.
    private func fixture(workingDir: String, withCwd: Bool = true) -> [String] {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func ts(_ offset: TimeInterval) -> String {
            fmt.string(from: Date(timeIntervalSinceNow: offset))
        }
        let cwdField = withCwd ? #","cwd":"\#(workingDir)""# : ""
        return [
            #"{"type":"user","timestamp":"\#(ts(-120))"\#(cwdField),"message":{"role":"user","content":"Fix the flaky retry test."}}"#,
            #"{"type":"assistant","timestamp":"\#(ts(-115))","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"swift test"}}]}}"#,
            #"{"type":"assistant","timestamp":"\#(ts(-110))","message":{"role":"assistant","content":[{"type":"text","text":"Running the tests now."}]}}"#,
        ]
    }

    func testHappyPathWritesTheBriefThenLaunchesThenRecords() throws {
        let h = try Harness()
        defer { h.cleanup() }
        try h.recordSession()
        _ = try h.writeLog(fixture(workingDir: h.workingDir.path))
        let coordinator = try h.makeCoordinator()

        let outcome = try coordinator.handoff(sessionID: h.sessionID, target: "codex")

        XCTAssertEqual(outcome.launchedPID, 4242)
        XCTAssertEqual(outcome.target, "codex")
        let brief = try String(contentsOf: URL(fileURLWithPath: outcome.briefPath), encoding: .utf8)
        XCTAssertTrue(brief.contains("## Goal\nFix the flaky retry test. (line 1)"))
        XCTAssertTrue(brief.contains("Working directory: \(h.workingDir.path)"))
        XCTAssertEqual(outcome.citedLines, [1, 2, 3])
        XCTAssertEqual(h.launcher.launches.count, 1)
        XCTAssertEqual(h.launcher.launches[0].cwd, h.workingDir.path)
        XCTAssertTrue(h.launcher.launches[0].stdin.contains("## Goal"),
                      "the brief is what the agent reads, not a path it must go fetch")

        // The record survives a reopen: a crash after launch must not orphan the chain.
        let reopened = try AgentSessionStore(storeURL: h.root.appendingPathComponent("sessions.sqlite"))
        let snapshot = try XCTUnwrap(reopened.sessions().first { $0.id == h.sessionID })
        XCTAssertEqual(snapshot.handoffTargetPID, 4242)
        XCTAssertEqual(snapshot.handoffTargetName, "codex")
    }

    func testTheKillSwitchRefusesBeforeAnythingHappens() throws {
        let h = try Harness()
        defer { h.cleanup() }
        try h.recordSession()
        _ = try h.writeLog(fixture(workingDir: h.workingDir.path))
        var prefs = AppPreferences()
        prefs.contextHandoffsEnabled = false
        prefs.save(to: h.defaults)
        let coordinator = try h.makeCoordinator()

        XCTAssertThrowsError(try coordinator.handoff(sessionID: h.sessionID, target: "codex")) {
            XCTAssertTrue("\($0)".contains("disabled in Portmaster settings"))
        }
        XCTAssertEqual(h.launcher.launches.count, 0, "a disabled feature spawns nothing")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: h.handoffDir.path).count, 0,
            "and writes nothing"
        )
    }

    func testAnUnknownTargetNamesTheOnesThatExist() throws {
        let h = try Harness()
        defer { h.cleanup() }
        try h.recordSession()
        _ = try h.writeLog(fixture(workingDir: h.workingDir.path))
        let coordinator = try h.makeCoordinator()

        XCTAssertThrowsError(try coordinator.handoff(sessionID: h.sessionID, target: "gpt9")) {
            let message = "\($0)"
            XCTAssertTrue(message.contains("Unknown handoff target"))
            XCTAssertTrue(message.contains("claude"), "the refusal teaches the valid values")
            XCTAssertTrue(message.contains("codex"))
        }
        XCTAssertEqual(h.launcher.launches.count, 0)
    }

    func testASecondHandoffIsRefusedAndNothingSpawns() throws {
        let h = try Harness()
        defer { h.cleanup() }
        try h.recordSession()
        _ = try h.writeLog(fixture(workingDir: h.workingDir.path))
        let coordinator = try h.makeCoordinator()
        _ = try coordinator.handoff(sessionID: h.sessionID, target: "codex")

        XCTAssertThrowsError(try coordinator.handoff(sessionID: h.sessionID, target: "claude")) {
            XCTAssertTrue("\($0)".contains("already handed off"))
        }
        XCTAssertEqual(h.launcher.launches.count, 1, "the thread forks only once")
    }

    func testALogWithNoCwdSavesTheBriefThenRefusesToLaunch() throws {
        let h = try Harness()
        defer { h.cleanup() }
        try h.recordSession()
        _ = try h.writeLog(fixture(workingDir: "", withCwd: false))
        let coordinator = try h.makeCoordinator()

        XCTAssertThrowsError(try coordinator.handoff(sessionID: h.sessionID, target: "codex")) {
            let message = "\($0)"
            XCTAssertTrue(message.contains("working directory"), "the refusal names the fact")
            XCTAssertTrue(message.contains("brief was saved"), "…and offers the brief (§6)")
        }
        XCTAssertEqual(h.launcher.launches.count, 0)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: h.handoffDir.path),
            ["\(h.sessionID.uuidString).md"],
            "the dry run produced the brief even though the launch did not happen"
        )
    }

    func testAMissingCLISavesTheBriefThenFailsWithThatReason() throws {
        let h = try Harness()
        defer { h.cleanup() }
        try h.recordSession()
        _ = try h.writeLog(fixture(workingDir: h.workingDir.path))
        h.launcher.resolveResult = { _ in nil }
        let coordinator = try h.makeCoordinator()

        XCTAssertThrowsError(try coordinator.handoff(sessionID: h.sessionID, target: "codex")) {
            let message = "\($0)"
            XCTAssertTrue(message.contains("not installed"), "§6: fails with that reason")
            XCTAssertTrue(message.contains("brief was saved"))
        }
        XCTAssertEqual(h.launcher.launches.count, 0)
    }

    func testAnUnsourcedLogIsRefusedWithNothingWritten() throws {
        let h = try Harness()
        defer { h.cleanup() }
        try h.recordSession()
        _ = try h.writeLog([
            #"{"type":"system","message":"booting"}"#,
            #"{"type":"mode","mode":"plan"}"#,
        ])
        let coordinator = try h.makeCoordinator()

        XCTAssertThrowsError(try coordinator.handoff(sessionID: h.sessionID, target: "codex")) {
            XCTAssertTrue("\($0)".contains("nothing to hand off"), "§5: refuse an unsourced brief")
        }
        XCTAssertEqual(h.launcher.launches.count, 0)
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: h.handoffDir.path)) ?? []
        XCTAssertTrue(contents.isEmpty, "a brief we cannot cite is never written")
    }

    func testNoMatchingLogIsRefusedBeforeExtraction() throws {
        let h = try Harness()
        defer { h.cleanup() }
        try h.recordSession()
        // projectsRoot exists but holds no logs at all.
        let coordinator = try h.makeCoordinator()

        XCTAssertThrowsError(try coordinator.handoff(sessionID: h.sessionID, target: "codex")) {
            XCTAssertTrue("\($0)".contains("not uniquely attributable"))
        }
        XCTAssertEqual(h.launcher.launches.count, 0)
    }
}
