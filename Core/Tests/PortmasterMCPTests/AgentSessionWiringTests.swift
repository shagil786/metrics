// AgentSessionWiringTests: `report_usage` reaching a real store.
//
// Task 4 shipped a tool that `tools/list` advertises and that refuses every real
// invocation, because neither production `ToolExecutor` call site passed a
// `sessionRecorder`. These tests are the end-to-end answer to "and now?", and they
// are mostly about the id rather than the write.
//
// The hazard they exist to catch is the one that does not look like a bug. A session
// id placed on `HostMCPCallContext` — which is built once and shared by every
// connection the socket host admits — would stamp each connection's reports with the
// same id. Every row would exist, every read would succeed, every UUID would be valid,
// and every one of them would name the wrong connection. One connection reporting
// looks perfect. So the tests here drive **two** connections and check they cannot see
// each other's usage, rather than driving one and checking it can be read back.
//
// Everything is real: a real `AgentSessionStore` in a temp directory, a real
// `MCPHostServer` on a real socket, a real `HostMCPCallContext` over a stub provider
// (so no test can touch the machine), and a real `SocketMCPClient` speaking MCP to it.
import Foundation
import PortmasterCore
@testable import PortmasterMCP
import XCTest

final class AgentSessionWiringTests: XCTestCase {

    // MARK: - One connection, end to end

    /// The assertion this whole task exists to make possible: a real MCP client
    /// calling `report_usage` over a real socket lands a record the store's
    /// session-scoped reads can see, against the session row the connection itself
    /// wrote.
    ///
    /// Asserted against a **reopened** store rather than the live one, because that is
    /// what the app will do and it is the only way to prove the record was flushed: an
    /// unsaved insert is visible to the context that made it and to nothing else.
    func testARealUsageReportOverTheSocketIsVisibleToASessionScopedRead() async throws {
        let fixture = try SessionFixture()
        let harness = try MCPHostHarness.make(
            self, context: fixture.context, sessionStore: fixture.store
        )
        try harness.start()
        let client = try await connectUsageClient(to: harness)

        let outcome = await client.call(
            name: "report_usage",
            arguments: ["input": "1200", "output": "340", "model": "test-model-1"]
        )

        XCTAssertFalse(outcome.isError, "a wired host must record, not refuse: \(outcome.text)")

        let sessions = try fixture.reopened().sessions()
        XCTAssertEqual(sessions.count, 1, "one connection, one session")
        let session = try XCTUnwrap(sessions.first)
        XCTAssertEqual(
            session.usage, .reported(input: 1200, output: 340, provenance: .selfReported),
            "the report must be readable through the session it arrived on"
        )
        XCTAssertEqual(
            try fixture.reopened().usage(for: session.id),
            .reported(input: 1200, output: 340, provenance: .selfReported),
            "and through the id, which is the read every cost figure is built from"
        )
    }

    /// The accept-time row is the real one: the peer pid and connect time the
    /// connection layer knows, not zeros and not the report's own idea of the session.
    ///
    /// This is the clobber guard at the wiring level rather than the recorder's. Task 4
    /// proved `StoreSessionRecorder` does not overwrite the row; what had not been
    /// proved is that the wiring *supplies* a row worth keeping. A wiring that wrote
    /// its own at report time would pass every assertion above and leave the user with
    /// a session attributed to nobody.
    func testTheSessionRowTheConnectionWroteSurvivesTheUsageReport() async throws {
        let fixture = try SessionFixture()
        let harness = try MCPHostHarness.make(
            self, context: fixture.context, sessionStore: fixture.store
        )
        try harness.start()
        let client = try await connectUsageClient(to: harness)

        let before = try XCTUnwrap(
            try fixture.reopened().sessions().first,
            "the row must exist before any tool is called: it is written at accept time"
        )
        XCTAssertEqual(
            before.peerPID, pid_t(ProcessInfo.processInfo.processIdentifier),
            "the row must carry the pid of the process that actually connected"
        )
        XCTAssertEqual(before.usage, .notReported(reason: .awaitingFirstReport))

        _ = await client.call(
            name: "report_usage", arguments: ["input": "10", "output": "5", "model": "m1"]
        )

        let after = try XCTUnwrap(try fixture.reopened().sessions().first)
        XCTAssertEqual(
            after.id, before.id,
            "a report must not create a second session"
        )
        XCTAssertEqual(after.peerPID, before.peerPID, "and must not reset the peer pid")
        XCTAssertEqual(
            after.connectedAt, before.connectedAt,
            "nor restate when the session connected"
        )
    }

    // MARK: - Two connections

    /// The test that a single connection cannot make pass.
    ///
    /// `HostMCPCallContext` is constructed once (`MCPHostController.makeContext`) and
    /// handed to every connection this host will serve, so an id stored on it — or on
    /// the recorder beside it — would give both of these the same session. Then each
    /// client's report would be appended to that one row, and the totals would be
    /// "right" in the sense that no error was raised: one session carrying two
    /// connections' tokens, which is a wrong number rather than an absence.
    ///
    /// Asserted on both sides: the ids differ, and each session holds only its own
    /// connection's report.
    func testTwoConnectionsAreTwoSessionsAndNeitherSeesTheOtherUsage() async throws {
        let fixture = try SessionFixture()
        let harness = try MCPHostHarness.make(
            self, context: fixture.context, sessionStore: fixture.store
        )
        try harness.start()

        let first = try await connectUsageClient(to: harness)
        let second = try await connectUsageClient(to: harness)

        let one = await first.call(
            name: "report_usage", arguments: ["input": "100", "output": "10", "model": "m1"]
        )
        let two = await second.call(
            name: "report_usage", arguments: ["input": "900", "output": "90", "model": "m1"]
        )
        XCTAssertFalse(one.isError, one.text)
        XCTAssertFalse(two.isError, two.text)

        let sessions = try fixture.reopened().sessions()
        // Guarded rather than indexed: a shared id collapses these two into one row,
        // and a test that then reads `sessions[1]` would crash on the very bug it
        // exists to report. Failing here with the count is the diagnosis; the
        // per-session checks below are what say *which* connection was wrong.
        guard sessions.count == 2 else {
            return XCTFail(
                "two connections are two sessions, not \(sessions.count): "
                    + "a shared id merges two intentions into one row"
            )
        }
        XCTAssertNotEqual(
            sessions[0].id, sessions[1].id,
            "an id shared between connections would merge two intentions into one row"
        )

        // Each session must hold its own report alone. A shared id would show up here
        // as one session carrying 1000/100 — every record written, no error raised,
        // and a cost figure that describes neither agent.
        for session in sessions {
            guard case .reported(let input, let output, _) = session.usage else {
                return XCTFail("every session must carry a report: \(session.usage)")
            }
            XCTAssertTrue(
                input + output == 110 || input + output == 990,
                "a session must hold exactly one connection's tokens, not both: "
                    + "\(input) in / \(output) out"
            )
        }
    }

    /// A connection that has reported nothing is a session, not a gap — and it is
    /// visible as one. This is the shape that makes the two-connection test above
    /// meaningful from the other side: a wiring that never wrote the accept-time row
    /// would still produce the reporting session, and only this assertion would notice
    /// the silent one.
    func testAConnectionThatReportsNothingIsStillASession() async throws {
        let fixture = try SessionFixture()
        let harness = try MCPHostHarness.make(
            self, context: fixture.context, sessionStore: fixture.store
        )
        try harness.start()

        let silent = try await connectUsageClient(to: harness)
        let loud = try await connectUsageClient(to: harness)
        _ = await loud.call(
            name: "report_usage", arguments: ["input": "5", "output": "5", "model": "m1"]
        )
        _ = await silent.call(name: "get_settings", arguments: [:])

        let sessions = try fixture.reopened().sessions()
        XCTAssertEqual(sessions.count, 2)
        let unreported = sessions.filter { $0.usage == .notReported(reason: .awaitingFirstReport) }
        XCTAssertEqual(
            unreported.count, 1,
            "a connection that asked for nothing is still a session the user can see"
        )
    }

    // MARK: - No store

    /// The refusal, and what it must not leave behind.
    ///
    /// A host with no store still serves every other tool: refusing `report_usage` is a
    /// refusal of *one* tool, not a broken server. And it must write nothing — the
    /// hazard being that a wiring which "helpfully" invented a session would leave a
    /// usage record under an id no row names, which passes every check here and is
    /// invisible to every session-scoped read.
    func testWithNoStoreTheToolRefusesWithAReasonAndTheServerStillWorks() async throws {
        let fixture = try SessionFixture()
        // No `sessionStore`, and no recorder either: this is the shape of an app whose
        // database could not be opened.
        let harness = try MCPHostHarness.make(
            self, context: fixture.contextWithoutRecorder
        )
        try harness.start()
        let client = try await connectUsageClient(to: harness)

        let refused = await client.call(
            name: "report_usage", arguments: ["input": "10", "output": "5", "model": "m1"]
        )
        XCTAssertTrue(refused.isError, "with nowhere to record, the tool must refuse")
        XCTAssertTrue(
            refused.text.contains("no session store available"), refused.text
        )

        // The rest of the surface is untouched.
        let read = await client.call(name: "get_settings", arguments: [:])
        XCTAssertFalse(read.isError, "one unwired tool must not take the server down: \(read.text)")

        // And the store this host would have written to has no sessions in it, which
        // is the property an invented id would have broken.
        XCTAssertEqual(
            try fixture.store.sessions().count, 0,
            "a refused report must not leave a session or an orphan usage record behind"
        )
    }

    /// Both refusals are reachable, in a defined order, and each says something the
    /// caller can act on.
    ///
    /// Order is the assertion. `ToolExecutor` refuses a report with no session id *and*
    /// a recorder can refuse having nowhere to put it; the more fundamental absence is
    /// the second one, so it is asked first. Asserted here at the seam both live on,
    /// because the order used to be arbitrary and an arbitrary order here means a CLI
    /// is told "I cannot tell which session this is" when the answer is "there is no
    /// store" — true, and no use to anybody.
    func testTheUnavailableRecorderRefusesBeforeTheSessionIsEvenNeeded() throws {
        XCTAssertThrowsError(try UnavailableSessionRecorder().requireAvailable()) { error in
            XCTAssertEqual(
                (error as? MCPToolError)?.message,
                "Portmaster has no session store available, so this report was not recorded."
            )
        }
        // A real recorder stays silent: the "nowhere to record" check is about the
        // store, and an available one must not claim otherwise.
        XCTAssertNoThrow(
            try StoreSessionRecorder(store: AgentSessionStore(
                storeURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("agent-sessions-\(UUID().uuidString).sqlite")
            )).requireAvailable()
        )
    }

    // MARK: - The CLI

    /// The CLI refuses, and says something true.
    ///
    /// Not a test that it *can* refuse — it already did, being unwired. It is pinned
    /// because the refusal is the decision: on this path the process taking the report
    /// *is* `portmaster-mcp`, so there is no agent to attribute the tokens to, and a
    /// second `ModelContext` over the app's file would write rows the app's own reader
    /// never observes. See `LocalMCPCallContext.noSessionNote` for the full reasoning.
    ///
    /// **What the message must not say is the assertion.** `.onDemand` is reached
    /// because the user forced `PORTMASTER_MCP=on-demand` as well as because no app
    /// answered, and in the forced case an app is very likely up and healthy — that is
    /// usually why it was forced. A refusal claiming Portmaster is not running would be
    /// the one untrue thing this process says, and an agent may act on it. `MCPRoute`
    /// already splits its stderr notice for exactly this reason; this result must not
    /// reintroduce the claim the split exists to avoid.
    func testTheOnDemandCLIRefusesWithoutClaimingPortmasterIsNotRunning() async throws {
        let directory = try makeTemporaryDirectory(prefix: "pmusage")
        let context = LocalMCPCallContext(
            provider: StubProvider(),
            loadSettings: { MCPSettings(mode: .off) },
            auditDirectory: directory,
            settingsDirectory: directory
        )

        let outcome = await context.call(
            name: "report_usage", arguments: ["input": "10", "output": "5", "model": "m1"]
        )

        XCTAssertTrue(outcome.isError)
        XCTAssertEqual(outcome.text, LocalMCPCallContext.noSessionNote)
        // The false claims, named so a reworded message cannot reintroduce any of them.
        for claim in ["not running", "Start Portmaster", "isn't running"] {
            XCTAssertFalse(
                outcome.text.contains(claim),
                "the on-demand path may be forced while an app is up and healthy, so the "
                    + "refusal must not claim Portmaster is not running: \(outcome.text)"
            )
        }
        // The true statement: it is about this session, and it names the path that works.
        XCTAssertTrue(
            outcome.text.contains("not connected to Portmaster"),
            "the refusal must be about the session's own connection: \(outcome.text)"
        )
        XCTAssertTrue(
            outcome.text.contains("socket session"),
            "and must name the route that would record it: \(outcome.text)"
        )
    }

    /// The relayed CLI records through the app, so the *relay* is not the unwired path.
    ///
    /// Worth pinning separately from the refusal above, because the two sit on the same
    /// tool: `SocketMCPClient` reaching a host that has a store must produce a record,
    /// and the only thing that makes it work is the session the host minted for that
    /// connection. If a future change stopped the host binding one, this fails while
    /// the refusal test above keeps passing.
    func testARelayedReportIsRecordedByTheHostOnTheClientsBehalf() async throws {
        let fixture = try SessionFixture()
        let harness = try MCPHostHarness.make(
            self, context: fixture.context, sessionStore: fixture.store
        )
        try harness.start()
        let relayed = try await connectUsageClient(to: harness)

        let outcome = await relayed.call(
            name: "report_usage", arguments: ["input": "77", "output": "7", "model": "m1"]
        )

        XCTAssertFalse(outcome.isError, "a relayed report reaches the app's store: \(outcome.text)")
        // Unwrapped rather than indexed, so a host that recorded no session fails with
        // the count instead of trapping.
        let session = try XCTUnwrap(
            try fixture.reopened().sessions().first,
            "the relayed connection must have a session row of its own"
        )
        XCTAssertEqual(
            session.usage, .reported(input: 77, output: 7, provenance: .selfReported)
        )
    }

    // MARK: - Fixture

    /// A real store, a real host context over it, and a way to reach both from a test.
    ///
    /// `context` and `contextWithoutRecorder` differ in exactly one thing, so the test
    /// that asserts the refusal is asserting the *absence of a store* rather than some
    /// other difference between two contexts nobody can otherwise compare.
    private struct SessionFixture {
        let store: AgentSessionStore
        let context: HostMCPCallContext
        let contextWithoutRecorder: HostMCPCallContext
        private let url: URL

        init() throws {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("agent-sessions-\(UUID().uuidString).sqlite")
            store = try AgentSessionStore(storeURL: url)
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("pmusage-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            context = Self.context(in: directory, recorder: StoreSessionRecorder(store: store))
            contextWithoutRecorder = Self.context(in: directory, recorder: nil)
        }

        /// The app's own shape: a stub provider (so a test cannot touch the machine),
        /// mutations off, and the recorder under test.
        private static func context(
            in directory: URL, recorder: (any SessionRecording)?
        ) -> HostMCPCallContext {
            HostMCPCallContext(
                provider: StubProvider(),
                broker: ConfirmationBroker(timeout: 1),
                present: { _ in XCTFail("report_usage must never ask a person") },
                loadSettings: { MCPSettings(mode: .off) },
                appRunning: { true },
                auditDirectory: directory,
                settingsDirectory: directory,
                sessionRecorder: recorder
            )
        }

        /// A second store over the same file, so a read proves the write was flushed.
        func reopened() throws -> AgentSessionStore {
            try AgentSessionStore(storeURL: url)
        }

        }
}

extension XCTestCase {
    /// A real client on the harness's socket, disconnected when the test ends.
    ///
    /// The teardown runs off the main thread on purpose: disconnecting awaits the
    /// SDK's message-loop task, and a teardown block runs on the main thread, so
    /// awaiting there is a deadlock rather than a slow test.
    func connectUsageClient(to harness: MCPHostHarness) async throws -> SocketMCPClient {
        let client = try XCTUnwrap(
            SocketMCPClient(endpointDirectory: harness.endpointDirectory),
            "a started host must be connectable"
        )
        let opened = await client.open()
        XCTAssertTrue(opened, "initialize over the socket must complete")
        let stopped = DispatchSemaphore(value: 0)
        addTeardownBlock {
            DispatchQueue.global(qos: .userInitiated).async {
                Task {
                    await client.disconnect()
                    stopped.signal()
                }
            }
            _ = stopped.wait(timeout: .now() + 30)
        }
        return client
    }
}