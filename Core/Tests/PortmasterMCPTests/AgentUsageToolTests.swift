// report_usage: an agent declaring a fact about itself.
//
// Deliberately outside the permission gate. It is not an action on the machine —
// it cannot quit a process or change a setting — so requiring confirmation for it
// would train users to click through prompts that carry no risk, which makes the
// prompts that do matter easier to dismiss.
//
// Every rejection test asserts the refusal *text*, not just `isError`. `execute` has
// several failure paths that all set `isError`, and a spy that recorded nothing
// would look identical under all of them — including "Unknown tool", which a
// misspelled name would produce. Naming the refusal is what makes the test say which
// check refused.
import XCTest
import Foundation
import PortmasterCore
@testable import PortmasterMCP

final class AgentUsageToolTests: XCTestCase {

    /// In-memory recorder so the tool's validation is tested without a store.
    /// Records the optional counts too: "the caller sent nothing" and "the caller
    /// sent zero" have to be distinguishable here, or the absence assertions below
    /// would pass against a recorder that defaulted them.
    final class SpyRecorder: SessionRecording, @unchecked Sendable {
        typealias Call = (
            sessionID: UUID, modelID: String,
            input: Int, output: Int, cacheRead: Int?, reasoning: Int?
        )
        private let lock = NSLock()
        private var recorded: [Call] = []

        var calls: [Call] {
            lock.lock(); defer { lock.unlock() }
            return recorded
        }

        func record(
            sessionID: UUID,
            input: Int, output: Int, cacheRead: Int?, reasoning: Int?, modelID: String
        ) throws -> String {
            lock.lock()
            recorded.append((sessionID, modelID, input, output, cacheRead, reasoning))
            lock.unlock()
            return "recorded"
        }
    }

    private func executor(
        _ recorder: SpyRecorder, sessionID: UUID? = UUID()
    ) throws -> ToolExecutor {
        let directory = try makeTemporaryDirectory(prefix: name)
        return ToolExecutor(
            provider: StubProvider(),
            gate: PermissionGate(settings: MCPSettings(mode: .off), appRunning: false),
            audit: AuditLog(directory: directory),
            settingsDirectory: directory,
            sessionRecorder: recorder,
            sessionID: sessionID
        )
    }

    // MARK: - Catalog

    func testToolIsInTheCatalog() {
        XCTAssertTrue(ToolExecutor.catalog.contains { $0.name == "report_usage" })
    }

    func testToolIsNotAMutation() {
        guard let tool = ToolExecutor.catalog.first(where: { $0.name == "report_usage" }) else {
            return XCTFail("report_usage missing from catalog")
        }
        XCTAssertEqual(tool.effect, .read, "self-report must not require confirmation")
    }

    func testToolDeclaresItsArguments() {
        guard let tool = ToolExecutor.catalog.first(where: { $0.name == "report_usage" }) else {
            return XCTFail("report_usage missing from catalog")
        }
        let names = Set(tool.arguments.map(\.name))
        for required in ["input", "output", "model"] {
            XCTAssertTrue(names.contains(required), "\(required) must be declared")
        }
    }

    /// The catalog count is asserted in the existing MCP conformance test and in the
    /// README, so adding a tool without updating either fails rather than drifting.
    func testCatalogCountIsExplicitlyCheckedSomewhere() {
        XCTAssertEqual(
            ToolExecutor.catalog.filter { $0.name == "report_usage" }.count, 1,
            "report_usage must appear exactly once in the catalog"
        )
    }

    // MARK: - Behaviour

    func testValidReportReachesTheRecorder() async throws {
        let spy = SpyRecorder()
        let session = UUID()
        let outcome = await try executor(spy, sessionID: session).execute(
            name: "report_usage",
            arguments: ["input": "1000", "output": "250", "model": "m1"]
        )
        XCTAssertFalse(outcome.isError, outcome.text)
        XCTAssertFalse(outcome.text.isEmpty)
        XCTAssertEqual(spy.calls.count, 1)
        XCTAssertEqual(spy.calls.first?.modelID, "m1")
        XCTAssertEqual(spy.calls.first?.input, 1000)
        XCTAssertEqual(spy.calls.first?.output, 250)
        // The report belongs to the connection it arrived on, which is the only id
        // any session-scoped read can find it under.
        XCTAssertEqual(spy.calls.first?.sessionID, session)
        // Absence preserved, not defaulted. `nil` is "this agent does not track
        // cache reads"; `0` would be a claim that it tracked them and used none,
        // which is priced differently from a component nobody reports on.
        XCTAssertNil(spy.calls.first?.cacheRead, "an unsupplied count must stay absent")
        XCTAssertNil(spy.calls.first?.reasoning, "an unsupplied count must stay absent")
    }

    func testSuppliedOptionalCountsReachTheRecorder() async throws {
        let spy = SpyRecorder()
        let outcome = await try executor(spy).execute(
            name: "report_usage",
            arguments: [
                "input": "10", "output": "5", "model": "m1",
                "cache_read": "7", "reasoning": "3",
            ]
        )
        XCTAssertFalse(outcome.isError, outcome.text)
        XCTAssertEqual(spy.calls.first?.cacheRead, 7)
        XCTAssertEqual(spy.calls.first?.reasoning, 3)
    }

    /// A measured zero is a different claim from an unreported one, so a zero has to
    /// survive parsing as a zero.
    func testZeroOptionalCountsAreRecordedAsZeroNotAbsent() async throws {
        let spy = SpyRecorder()
        let outcome = await try executor(spy).execute(
            name: "report_usage",
            arguments: [
                "input": "10", "output": "5", "model": "m1",
                "cache_read": "0", "reasoning": "0",
            ]
        )
        XCTAssertFalse(outcome.isError, outcome.text)
        XCTAssertEqual(spy.calls.first?.cacheRead, 0)
        XCTAssertEqual(spy.calls.first?.reasoning, 0)
    }

    func testNegativeInputIsRejected() async throws {
        let spy = SpyRecorder()
        let outcome = await try executor(spy).execute(
            name: "report_usage",
            arguments: ["input": "-1", "output": "250", "model": "m1"]
        )
        XCTAssertTrue(outcome.isError)
        XCTAssertEqual(outcome.text, "input must not be negative.")
        XCTAssertEqual(spy.calls.count, 0, "nothing may be recorded from an invalid report")
    }

    func testNonNumericInputIsRejected() async throws {
        let spy = SpyRecorder()
        let outcome = await try executor(spy).execute(
            name: "report_usage",
            arguments: ["input": "lots", "output": "250", "model": "m1"]
        )
        XCTAssertTrue(outcome.isError)
        XCTAssertEqual(outcome.text, "input must be a whole number.")
        XCTAssertEqual(spy.calls.count, 0)
    }

    func testMissingModelIsRejected() async throws {
        let spy = SpyRecorder()
        let outcome = await try executor(spy).execute(
            name: "report_usage", arguments: ["input": "10", "output": "5"]
        )
        XCTAssertTrue(outcome.isError)
        // Named, because `execute`'s required-argument sweep refuses this before the
        // dispatch case is entered, and "the count was refused" would be true of a
        // dozen unrelated failures.
        XCTAssertEqual(outcome.text, "Missing argument: model")
        XCTAssertEqual(spy.calls.count, 0, "a report without a model cannot be priced")
    }

    func testEmptyModelIsRejected() async throws {
        let spy = SpyRecorder()
        let outcome = await try executor(spy).execute(
            name: "report_usage",
            arguments: ["input": "10", "output": "5", "model": "  "]
        )
        XCTAssertTrue(outcome.isError)
        XCTAssertEqual(outcome.text, "Missing argument: model")
        XCTAssertEqual(spy.calls.count, 0)
    }

    // MARK: - Reaching dispatch

    /// `model` is `required: true`, so `execute` refuses a missing or blank one
    /// before dispatch and `Self.nonBlank` cannot be reached through the tool. These
    /// two call the validators directly to keep them from rotting unreferenced; the
    /// tool-level proof that the pre-dispatch sweep is what refuses is in
    /// `testMissingModelIsRejected` / `testEmptyModelIsRejected` above.
    func testNonBlankRejectsWhatExecuteCannotDeliver() throws {
        XCTAssertThrowsError(try ToolExecutor.nonBlank(nil, field: "model")) { error in
            XCTAssertEqual((error as? MCPToolError)?.message, "model is required.")
        }
        XCTAssertThrowsError(try ToolExecutor.nonBlank("   ", field: "model")) { error in
            XCTAssertEqual((error as? MCPToolError)?.message, "model is required.")
        }
    }

    func testNonNegativeRejectsUnusableCounts() throws {
        XCTAssertThrowsError(try ToolExecutor.nonNegative("many", field: "input")) { error in
            XCTAssertEqual((error as? MCPToolError)?.message, "input must be a whole number.")
        }
        XCTAssertThrowsError(try ToolExecutor.nonNegative("-1", field: "input")) { error in
            XCTAssertEqual((error as? MCPToolError)?.message, "input must not be negative.")
        }
        XCTAssertEqual(try ToolExecutor.nonNegative(" 42 ", field: "input"), 42)
    }

    /// Absent and blank are the same "not supplied" for an optional count, and both
    /// differ from a supplied zero.
    func testOptionalNonNegativeReadsAbsenceAsAbsent() throws {
        XCTAssertNil(try ToolExecutor.optionalNonNegative(nil, field: "cache_read"))
        XCTAssertNil(try ToolExecutor.optionalNonNegative("   ", field: "cache_read"))
        XCTAssertEqual(try ToolExecutor.optionalNonNegative("0", field: "cache_read"), 0)
        XCTAssertThrowsError(
            try ToolExecutor.optionalNonNegative("-2", field: "cache_read")
        ) { error in
            XCTAssertEqual(
                (error as? MCPToolError)?.message, "cache_read must not be negative."
            )
        }
    }

    /// `cache_read` and `reasoning` are `required: false`, so they are the only
    /// counts that get past `execute`'s sweep and are actually range-checked in
    /// dispatch. These are the tests that reach the dispatch case.
    func testNegativeOptionalCountIsRejectedInsideDispatch() async throws {
        let spy = SpyRecorder()
        let outcome = await try executor(spy).execute(
            name: "report_usage",
            arguments: ["input": "10", "output": "5", "model": "m1", "cache_read": "-4"]
        )
        XCTAssertTrue(outcome.isError)
        XCTAssertEqual(
            outcome.text, "cache_read must not be negative.",
            "only an optional count reaches dispatch's own validation"
        )
        XCTAssertEqual(spy.calls.count, 0, "a rejected optional must not record the rest")
    }

    func testNonNumericOptionalCountIsRejectedInsideDispatch() async throws {
        let spy = SpyRecorder()
        let outcome = await try executor(spy).execute(
            name: "report_usage",
            arguments: ["input": "10", "output": "5", "model": "m1", "reasoning": "some"]
        )
        XCTAssertTrue(outcome.isError)
        XCTAssertEqual(outcome.text, "reasoning must be a whole number.")
        XCTAssertEqual(spy.calls.count, 0)
    }

    /// No session to attribute the report to is its own refusal, distinct from a
    /// malformed count — and it must refuse rather than invent an id, because a
    /// usage record under an id no session row names is invisible to every
    /// session-scoped read.
    func testAReportWithNoSessionIsRefusedRatherThanAttributedToAFreshID() async throws {
        let spy = SpyRecorder()
        let outcome = await try executor(spy, sessionID: nil).execute(
            name: "report_usage",
            arguments: ["input": "10", "output": "5", "model": "m1"]
        )
        XCTAssertTrue(outcome.isError)
        XCTAssertTrue(
            outcome.text.contains("cannot tell which session"), outcome.text
        )
        XCTAssertEqual(spy.calls.count, 0)
    }

    // MARK: - The recorder against a real store

    /// The connection layer owns the session row; a report must not disturb it.
    ///
    /// This is the clobber guard. `AgentSessionStore.recordSession` upserts and
    /// overwrites, so a recorder that wrote the row itself would reset `peerPID` to
    /// 0 and `clientName` to nil on the first report — erasing the identity the
    /// connection layer had already recorded correctly. Asserted against a real store
    /// rather than a spy because the harm is to the row, which a spy never had.
    func testRecordingAUsageReportLeavesTheConnectionOwnSessionRowIntact() throws {
        // A directory, via the shared helper: removing the `.sqlite` path alone leaves
        // the `-wal` and `-shm` sidecars SQLite writes beside it, so a store opened
        // this way leaks two files per run.
        let directory = try makeTemporaryDirectory(prefix: "agent-sessions")
        let store = try AgentSessionStore(
            storeURL: directory.appendingPathComponent("agent-sessions.sqlite")
        )

        let sessionID = UUID()
        let connectedAt = Date(timeIntervalSince1970: 1_700_000_000)
        try store.recordSession(
            id: sessionID, peerPID: 4242,
            clientName: "probe-agent", clientVersion: "1.2.3",
            connectedAt: connectedAt
        )
        try store.flush()

        let note = try StoreSessionRecorder(store: store).record(
            sessionID: sessionID,
            input: 1000, output: 250, cacheRead: nil, reasoning: nil,
            modelID: "m1"
        )
        XCTAssertFalse(note.isEmpty)

        let reopened = try AgentSessionStore(
            storeURL: directory.appendingPathComponent("agent-sessions.sqlite")
        )
        let sessions = try reopened.sessions()
        XCTAssertEqual(sessions.count, 1, "a report must not create a second session")
        XCTAssertEqual(sessions.first?.id, sessionID)
        XCTAssertEqual(sessions.first?.peerPID, 4242, "a report must not reset the peer pid")
        XCTAssertEqual(sessions.first?.clientName, "probe-agent")
        XCTAssertEqual(sessions.first?.clientVersion, "1.2.3")
        XCTAssertEqual(
            sessions.first?.connectedAt, connectedAt,
            "a report must not restate when the session connected"
        )
        // And the report did land, under that session.
        XCTAssertEqual(try reopened.usage(for: sessionID), .reported(
            input: 1000, output: 250, provenance: .selfReported
        ))
    }

    /// No store means no report. An agent told "recorded" when nothing was stored
    /// would leave a session reading `notReported` for a reason nobody can find.
    func testTheUnavailableRecorderRefusesWithAReason() {
        XCTAssertThrowsError(
            try UnavailableSessionRecorder().record(
                sessionID: UUID(), input: 1, output: 1,
                cacheRead: nil, reasoning: nil, modelID: "m1"
            )
        ) { error in
            XCTAssertEqual(
                (error as? MCPToolError)?.message,
                "Portmaster has no session store available, so this report was not recorded."
            )
        }
    }
}
