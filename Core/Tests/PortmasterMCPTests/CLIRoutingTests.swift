// CLIRoutingTests: the CLI as a router.
//
// The CLI's whole job in slice 2 is a decision made once, at startup: relay to the
// running app, or do the work itself as slice 1 did. Everything a client can observe
// afterwards is downstream of that decision, so these tests are about the decision and
// about what the two branches produce — never about a tool's behaviour, which belongs to
// the executor tests and must stay identical either way.
//
// The proxy tests drive a *real* `MCPHostServer` on a socket in their own temp
// directory. That is the point: a fake transport would prove the client agrees with
// itself, not with the host. The handshake in particular is transport-level and answers
// nothing on success, so the only way to know the CLI and the app agree is to run them
// against each other.

import Foundation
import PortmasterCore
@testable import PortmasterMCP
import XCTest

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

final class CLIRoutingTests: XCTestCase {

    /// The bound the stalled-call test gives its client. Small enough to prove a timer
    /// fired, large enough that the call is genuinely dispatched before it expires.
    static let stallBudget: TimeInterval = 0.5

    // MARK: - Not available

    /// No endpoint file means no app, and no app means slice 1's path with nothing
    /// said about it beyond one line on stderr. A CLI that cannot reach an app must
    /// never look broken to the agent on the other end of the pipe.
    func testSelectsOnDemandWhenTheEndpointFileIsAbsent() async throws {
        let directory = try makeTemporaryDirectory(prefix: name)

        let captured = try await captureStderr {
            await MCPRouteSelector.select(environment: [:], endpointDirectory: directory)
        }

        guard case .onDemand = captured.value else {
            return XCTFail(
                "with no endpoint file there is no app to relay to, so the route must be onDemand"
            )
        }
        XCTAssertEqual(
            captured.stderr.split(separator: "\n").count, 1,
            "falling back is one line on stderr, not a paragraph: \(captured.stderr)"
        )
    }

    /// The wedged-app escape hatch. An app that is listening but not answering — the
    /// user sees its window, the tools hang — must be reachable with one variable,
    /// without quitting anything.
    ///
    /// The host here is real and healthy, which is what makes this a test rather than a
    /// tautology: if the environment were consulted *after* the probe rather than
    /// instead of it, this would proxy and the escape hatch would be a no-op.
    func testSelectsOnDemandWhenTheEnvironmentForcesIt() async throws {
        let harness = try MCPHostHarness.make(self)
        try harness.start()

        let captured = try await captureStderr {
            await MCPRouteSelector.select(
                environment: ["PORTMASTER_MCP": "on-demand"],
                endpointDirectory: harness.endpointDirectory
            )
        }

        guard case .onDemand = captured.value else {
            return XCTFail(
                "PORTMASTER_MCP=on-demand must win over a live host, or there is no "
                    + "escape hatch for a wedged app"
            )
        }
        XCTAssertEqual(
            captured.stderr.split(separator: "\n").count, 1,
            "one line on stderr, and the client's stdin/stdout untouched: \(captured.stderr)"
        )
    }

    /// A live socket with the right token is the only thing that earns `.proxy`.
    func testSelectsProxyWhenARealHostAnswers() async throws {
        let harness = try MCPHostHarness.make(self)
        try harness.start()

        let route = await MCPRouteSelector.select(
            environment: [:], endpointDirectory: harness.endpointDirectory
        )
        defer { Task { await client(from: route)?.disconnect() } }

        guard case .proxy(let client) = route else {
            return XCTFail("a started host on a fresh socket must be reached, not fallen back from")
        }
        XCTAssertTrue(client.isConnected, "the proxy route is only taken once MCP is up")
    }

    // MARK: - Relayed

    /// `tools/list` is relayed untouched, so an agent cannot tell from the catalog
    /// whether it reached the app or the fallback — which is the whole reason the
    /// catalog has one definition and two ways of reaching it.
    func testProxiedToolsListMatchesTheLocalCatalog() async throws {
        let harness = try MCPHostHarness.make(self)
        try harness.start()
        let client = try await connect(to: harness)

        let relayed = try await client.listedToolNames()

        XCTAssertEqual(
            relayed.sorted(),
            ToolExecutor.catalog.map(\.name).sorted(),
            "the app must answer with exactly the catalog the CLI would serve itself"
        )
        XCTAssertEqual(relayed.count, 15, "the catalog is 15 tools")
    }

    /// The relay is a relay: the call arrives at the host's own call surface with the
    /// arguments the client sent, and the answer the host produced is what comes back.
    ///
    /// A client that quietly ran the call locally as well would pass a "does the tool
    /// work" test and fail this one, and it would also mean two gates had ruled on the
    /// same mutation.
    func testProxiedMutationReachesTheHostsBroker() async throws {
        let host = try startRecordingHost(text: "quit_app: done by the app")
        let client = try await connect(to: host)

        let outcome = await client.call(
            name: "quit_app", arguments: ["id": "app:Somewhere", "reason": "because"]
        )

        XCTAssertFalse(outcome.isError, outcome.text)
        XCTAssertEqual(
            outcome.text, "quit_app: done by the app",
            "the answer must be the host's, not one the CLI invented"
        )
        XCTAssertEqual(
            host.recordedCalls.count, 1,
            "exactly one call must arrive at the host — a second would mean two authorities"
        )
        XCTAssertEqual(host.recordedCalls.first?.name, "quit_app")
        XCTAssertEqual(
            host.recordedCalls.first?.arguments,
            ["id": "app:Somewhere", "reason": "because"],
            "the arguments must survive the relay unchanged"
        )
    }

    // MARK: - Failures are the client's problem, not the client's fault

    /// The app quits while a relayed session is open — the single most common real
    /// failure, because the user quitting Portmaster is not an error anyone should have
    /// to debug.
    ///
    /// It arrives as a tool result with `isError`, not as a thrown error and not as a
    /// broken connection: the host renders it, and an agent reads it. A transport error
    /// here would tell the caller its connection broke, which is a different and wrong
    /// story about what happened.
    func testProxyFailureMidCallIsReportedAsAToolErrorNotATransportError() async throws {
        let harness = try MCPHostHarness.make(self)
        try harness.start()
        let client = try await connect(to: harness)
        disconnectOnTeardown(client, in: self)

        await harness.host.stop()

        // The call itself is what must not throw: it is `await`ed with no `try`, so
        // anything the transport threw would fail this test at the call site.
        let outcome = await client.call(name: "get_settings", arguments: [:])

        XCTAssertTrue(outcome.isError, "a dead host is a failed call, not a silent one")
        XCTAssertEqual(
            outcome.text, SocketMCPClient.unavailableText,
            "the message must say what happened in the agent's language"
        )
    }

    /// A socket file left behind by a crash is the failure this design has to get right,
    /// because the file *looks* like an app: it exists, it is a real socket, and it was
    /// written by a real launch. The pid in it is the only thing that says the process is
    /// gone.
    ///
    /// Both halves are real rather than mocked: the socket at `socketPath` was bound by
    /// `UnixSocketBinding.listen` and then its listener closed, which is exactly what a
    /// killed host leaves behind — a bound socket file with nothing behind it, so a
    /// connect is refused with `ECONNREFUSED`. And the pid is genuinely gone, which the
    /// test asserts before relying on it.
    func testFallsBackWhenTheHostDiesBeforeSelection() async throws {
        // Short prefix, like `MCPHostHarness`: `sockaddr_un.sun_path` holds 103 bytes
        // and this test binds a real socket, so a directory named after the test method
        // would not fit.
        let directory = try makeTemporaryDirectory(prefix: "pm")
        let socketPath = directory.appendingPathComponent("mcp.sock")
        let listener = try UnixSocketBinding.listen(path: socketPath.path)
        close(listener)
        // A socket file with no listener is what a `kill -9` leaves; a regular file is
        // not, and using one would let the test pass without either check working.
        XCTAssertNil(
            UnixSocketBinding.connect(path: socketPath.path),
            "the socket file must be a real leftover, or this test proves nothing"
        )

        let dead: pid_t = 0x7FFF_FFFF
        XCTAssertEqual(kill(dead, 0), -1, "the pid this test calls dead must actually be dead")
        try EndpointFileStore.write(
            EndpointFile(socket: socketPath, token: try EndpointFileStore.newToken(), pid: dead),
            directory: directory
        )

        let route = await MCPRouteSelector.select(environment: [:], endpointDirectory: directory)

        guard case .onDemand = route else {
            return XCTFail("an endpoint file naming a dead process must not be believed")
        }
    }

    /// The same leftover with a **live** pid, which is the only way to tell the two
    /// staleness checks apart.
    ///
    /// With the test's own pid in the file, the endpoint passes every liveness check and
    /// the refusal has to come from the refused connect. Together with the test above —
    /// same leftover socket, dead pid — the two cover each mechanism independently
    /// instead of both passing because *something* failed.
    func testFallsBackWhenTheSocketIsRefusedEvenWithALivePID() async throws {
        let directory = try makeTemporaryDirectory(prefix: "pm")
        let socketPath = directory.appendingPathComponent("mcp.sock")
        let listener = try UnixSocketBinding.listen(path: socketPath.path)
        close(listener)

        try EndpointFileStore.write(
            EndpointFile(
                socket: socketPath,
                token: try EndpointFileStore.newToken(),
                pid: ProcessInfo.processInfo.processIdentifier
            ),
            directory: directory
        )
        // The file passes `read` — a live pid, a well-formed token — so whatever makes
        // this fall back is the refused connect and nothing else.
        XCTAssertNotNil(
            EndpointFileStore.read(directory: directory),
            "this case must get past the liveness check, or it is the test above again"
        )

        let route = await MCPRouteSelector.select(environment: [:], endpointDirectory: directory)

        guard case .onDemand = route else {
            return XCTFail("a socket file nothing is listening on is not an app")
        }
    }

    /// A wrong token is "app not available", and the refusal is the branch of the
    /// handshake judgement that nothing else here reaches.
    ///
    /// Every other test in this file connects with the token the host minted, so the
    /// only thing that distinguishes "admitted" from "closed" — the 250 ms wait for a
    /// close that a refusal produces and an admission does not — is exercised here. Without
    /// it, a client that treated every handshake as admitted would pass the whole file:
    /// the cost of that bug is a CLI that believes in a socket it was just refused by,
    /// and then waits `probeTimeout` for MCP that will never come.
    func testWrongTokenIsAppNotAvailable() async throws {
        let harness = try MCPHostHarness.make(self)
        try harness.start()

        // Same live socket, same live pid, a well-formed token that is not this launch's.
        let real = try XCTUnwrap(EndpointFileStore.read(directory: harness.endpointDirectory))
        let wrong = try Self.someOtherToken(real.token)
        try EndpointFileStore.write(
            EndpointFile(socket: real.socket, token: wrong, pid: real.pid),
            directory: harness.endpointDirectory
        )

        XCTAssertNil(
            SocketMCPClient(endpointDirectory: harness.endpointDirectory),
            "a refused handshake must read as 'no app', not as a client that may speak"
        )

        let captured = try await captureStderr {
            await MCPRouteSelector.select(environment: [:], endpointDirectory: harness.endpointDirectory)
        }
        guard case .onDemand = captured.value else {
            return XCTFail("a wrong token must fall back, or every stale-token CLI hangs")
        }
        XCTAssertEqual(
            captured.stderr.split(separator: "\n").count, 1,
            "a refusal is one line on stderr and nothing the client can see: \(captured.stderr)"
        )
        XCTAssertFalse(
            captured.stderr.contains(wrong),
            "not even the token that was refused may be repeated back: \(captured.stderr)"
        )
    }

    /// A well-formed 64-character hex token that is not `other`.
    ///
    /// The host only compares tokens it has been given, so the wrong one has to look
    /// right to reach the comparison — a short or non-hex token would be refused as
    /// malformed and would never test the branch this is for. Differing in exactly one
    /// character is also the closest case to a real one: a token that is wrong everywhere
    /// is a typo of a different kind.
    private static func someOtherToken(_ other: String) throws -> String {
        let replacement: Character = other.first == "0" ? "1" : "0"
        var flipped = other
        flipped.replaceSubrange(
            other.startIndex..<other.index(after: other.startIndex),
            with: String(replacement)
        )
        XCTAssertNotEqual(flipped, other, "the replacement token must actually differ")
        return flipped
    }

    // MARK: - The token

    /// The token is the one secret in this feature, and the CLI is the half that reads
    /// it. It goes out in one place — the handshake line — and must appear nowhere else:
    /// not in a diagnostic, not in an error string, not in anything an agent will read.
    ///
    /// Both halves are asserted here rather than reasoned about: connecting and calling
    /// with stderr captured must write nothing at all, and the one line a deliberate
    /// fallback writes must not carry the token either.
    func testConnectDoesNotLogOrEchoTheToken() async throws {
        let harness = try MCPHostHarness.make(self)
        try harness.start()
        let token = try harness.token
        var client: SocketMCPClient?

        let quiet = try await captureStderr {
            let connected = try XCTUnwrap(
                SocketMCPClient(endpointDirectory: harness.endpointDirectory),
                "a live host must be reachable: the token and the socket are both there"
            )
            let opened = await connected.open()
            XCTAssertTrue(opened, "initialize over a live socket must complete")
            client = connected
            return await connected.call(name: "get_settings", arguments: [:])
        }
        defer { if let client { Task { await client.disconnect() } } }

        XCTAssertFalse(
            quiet.value.isError,
            "the host answers get_settings; the client must not turn that into a "
                + "failure: \(quiet.value.text)"
        )
        XCTAssertEqual(
            quiet.stderr, "",
            "connecting and calling must write nothing to stderr: \(quiet.stderr)"
        )
        XCTAssertFalse(
            quiet.value.text.contains(token),
            "a relayed result must never carry the endpoint token"
        )

        let fallback = try await captureStderr {
            await MCPRouteSelector.select(
                environment: ["PORTMASTER_MCP": "on-demand"],
                endpointDirectory: harness.endpointDirectory
            )
        }
        XCTAssertEqual(
            fallback.stderr.split(separator: "\n").count, 1,
            "the fallback notice is one line: \(fallback.stderr)"
        )
        XCTAssertFalse(
            fallback.stderr.contains(token),
            "the fallback notice must not carry the token either: \(fallback.stderr)"
        )
    }

    /// `select`'s own parameter outranks the environment, which is the precedence its
    /// documentation claims.
    ///
    /// Asserted **through `select`**, not through the helper: the helper test says the
    /// parser reads the variable, and nothing says `select` prefers its argument over it.
    /// The two hosts disagree on purpose — one is started and reachable, the other is a
    /// plain empty directory — so a `select` that quietly followed the environment would
    /// fall back while one that preferred its argument would relay.
    func testSelectPrefersItsArgumentOverTheEnvironmentEndpointDirectory() async throws {
        let harness = try MCPHostHarness.make(self)
        try harness.start()
        let empty = try makeTemporaryDirectory(prefix: "pm")

        let route = await MCPRouteSelector.select(
            environment: [MCPRouteSelector.endpointDirectoryVariable: empty.path],
            endpointDirectory: harness.endpointDirectory
        )
        defer { Task { await client(from: route)?.disconnect() } }

        guard case .proxy(let client) = route else {
            return XCTFail(
                """
                the argument is the specific directory and the environment's is empty; \
                relaying proves the argument won, and falling back proves it did not
                """
            )
        }
        XCTAssertTrue(client.isConnected, "the route is only taken once MCP is up")
    }

    /// The endpoint directory the environment names is honoured, and an unusable value is
    /// ignored rather than believed.
    ///
    /// This is the seam that lets the spawned-binary suite point a real `portmaster-mcp`
    /// at a host the test started, so it is worth pinning on its own: a regression here
    /// is silent everywhere else, because every other routing test passes an explicit
    /// directory and never consults the variable.
    ///
    /// The empty case is the half that matters. `URL(fileURLWithPath: "")` resolves to the
    /// current working directory, so believing an empty value would send the CLI looking
    /// for an endpoint file in a real place that has none — a "the app is not available"
    /// that looks like a correct answer to a question nobody asked.
    func testEndpointDirectoryOverrideIsHonouredAndEmptyIsIgnored() throws {
        let harness = try MCPHostHarness.make(self)
        try harness.start()

        XCTAssertEqual(
            MCPRouteSelector.endpointDirectoryFromEnvironment(
                [MCPRouteSelector.endpointDirectoryVariable: harness.endpointDirectory.path]
            )?.standardizedFileURL.path,
            harness.endpointDirectory.standardizedFileURL.path,
            "a named directory must be the one the CLI reads the endpoint from"
        )
        for unusable in ["", "   "] {
            XCTAssertNil(
                MCPRouteSelector.endpointDirectoryFromEnvironment(
                    [MCPRouteSelector.endpointDirectoryVariable: unusable]
                ),
                "\(unusable.debugDescription) is not a directory, and must not become one"
            )
        }
        XCTAssertNil(
            MCPRouteSelector.endpointDirectoryFromEnvironment([:]),
            "unset means the per-user default, which is not this test's to read"
        )
    }

    /// A relayed call that never gets an answer must end anyway, and must say so.
    ///
    /// The failure this covers cannot be produced by closing the host: a host that quits
    /// fails the next `write`, which is fast and obvious. What needs the bound is a host
    /// that is *alive and silent* — the confirmation window waiting on a person, or a
    /// tool wedged behind one. There the SDK's message loop is still receiving, so the
    /// pending request is never resumed and only a deadline ends the wait.
    func testRelayedCallThatNeverAnswersIsBoundedAndReportsIt() async throws {
        let fixture = try startHost(context: StallingHostContext())
        let client = try XCTUnwrap(
            // A budget of the test's choosing, not the production one: what is under test
            // is that the watchdog fires and says so, and the production bound's *value*
            // is pinned separately by `testRelayedCallBoundOutlastsTheConfirmationWindow`
            // — because that value is 75 seconds of real waiting.
            SocketMCPClient(endpointDirectory: fixture.directory, callBudget: Self.stallBudget),
            "the host is up, so the client must connect"
        )
        let opened = await client.open()
        XCTAssertTrue(opened, "a host that answers initialize must be reachable")
        disconnectOnTeardown(client, in: self)

        let began = Date()
        let outcome = await client.call(name: "get_settings", arguments: [:])
        let elapsed = Date().timeIntervalSince(began)

        XCTAssertTrue(outcome.isError, outcome.text)
        // Its own sentence, not `unavailableText`. The host in this test is *alive and
        // silent* — the shape a confirmation window waiting on a person has — so
        // "Portmaster isn't running" is the one thing the client cannot know and must not
        // say. It sends whoever reads it looking for an app that was running the whole
        // time.
        XCTAssertEqual(
            outcome.text,
            SocketMCPClient.timeoutText(seconds: Self.stallBudget)
        )
        XCTAssertGreaterThan(
            elapsed, Self.stallBudget * 0.5,
            "the answer must have come from the bound, not from something failing early"
        )
        XCTAssertLessThan(
            elapsed, Self.stallBudget * 4,
            "the bound must be the cost of a failed call and no more"
        )
        XCTAssertFalse(
            client.isConnected,
            "a client that gave up must not keep claiming a session — it would strand one "
                + "in the app's Settings"
        )
        // The host's own client list is deliberately *not* asserted here: it keeps the
        // session until its own EOF drain finishes, and that drain is waiting on the very
        // call that never answered — which is the host's policy to hold, not the client's
        // to release. What the client owes is that it stopped holding the session open,
        // which is the assertion above.
    }

    /// A host that accepts the connection and then never speaks MCP is not available.
    ///
    /// The shape the spec calls wedged, and the only one a handshake can rule out: the
    /// token is right, so nothing is refused, and `initialize` is never answered. A probe
    /// that waited on the app instead of bounding itself would sit here until the user
    /// killed the CLI.
    ///
    /// The listener here is a raw descriptor rather than an `MCPHostServer`, because the
    /// SDK's server always answers `initialize` — standing in for "answers" is the one
    /// thing this test needs to *not* have.
    func testAHostThatNeverSpeaksMCPIsAppNotAvailable() async throws {
        let directory = try makeTemporaryDirectory(prefix: "pm")
        let socketPath = directory.appendingPathComponent("mcp.sock")
        let listener = try UnixSocketBinding.listen(path: socketPath.path)
        addTeardownBlock { close(listener) }

        let holdingOpen = DispatchSemaphore(value: 0)
        let thread = Thread {
            let accepted = accept(listener, nil, nil)
            guard accepted >= 0 else { return }
            // Read the handshake — so the client's admission check sees no EOF, which is
            // what "accepted" means — and then say nothing, ever.
            var chunk = [UInt8](repeating: 0, count: 512)
            _ = read(accepted, &chunk, chunk.count)
            holdingOpen.signal()
            Thread.sleep(forTimeInterval: 30)
            close(accepted)
        }
        thread.start()

        try EndpointFileStore.write(
            EndpointFile(
                socket: socketPath,
                token: try EndpointFileStore.newToken(),
                pid: ProcessInfo.processInfo.processIdentifier
            ),
            directory: directory
        )

        let client = SocketMCPClient(endpointDirectory: directory)
        let opened = try XCTUnwrap(
            client, "the connection is accepted, so the handshake is not refused"
        )
        XCTAssertEqual(
            holdingOpen.wait(timeout: .now() + 5), .success,
            "the fake host must have read the handshake before this means anything"
        )

        let reached = await opened.open()
        XCTAssertFalse(
            reached,
            "an app that never answers initialize is not available, however healthy it looks"
        )
        XCTAssertFalse(opened.isConnected, "a failed probe must not leave a claimed session")
    }

    /// The relayed bound must be able to outlast what the app makes it wait for.
    ///
    /// This is a comparison, not a measurement, and deliberately so: the thing being
    /// protected is a number nobody runs to find out. A relayed `quit_app` under
    /// `confirmEach` reaches the app, the app asks a person, and the answer arrives when
    /// they decide — a wait bounded by `ConfirmationBroker.defaultTimeout`, not by anything
    /// in this process. A client whose bound is shorter fires first, disconnects, and
    /// answers "Portmaster isn't running", which is false and points at an app that is
    /// running perfectly.
    ///
    /// So the assertion is a floor, not an equality: a larger bound is fine (it costs
    /// nothing but a slow failure), a smaller one is the trap. Whoever shortens either
    /// budget — the broker's, or the read budget underneath it — meets this failure
    /// instead of a bug report.
    func testRelayedCallBoundOutlastsTheConfirmationWindow() {
    XCTAssertGreaterThanOrEqual(
        SocketMCPClient.callTimeout,
        ConfirmationBroker.defaultTimeout + OnDemandProvider.defaultSnapshotTimeout,
        """
        the relayed bound must cover a person's decision plus a live read; at \
        \(SocketMCPClient.callTimeout)s it does not, so a slow answer under confirmEach \
        would be reported as a missing app
        """
    )
    XCTAssertGreaterThan(
        SocketMCPClient.relayedCallMargin, 0,
        "the sum of two declared budgets is exactly the slowest designed case; a margin is "
            + "what keeps the next undocumented cost past it from truncating a call"
    )
    // And neither refusal may name a cause the client cannot know. `unavailableText` is
    // for a *probe* that failed — no endpoint, no socket, refused token — where "isn't
    // running" is the honest summary. A call that was **truncated** is a different fact:
    // the app answered the handshake and then went quiet, so it gets its own text, and
    // the two must not be the same string.
    XCTAssertTrue(
        SocketMCPClient.unavailableText.contains("isn't running"),
        "this is what a failed probe says, and it is only true there"
    )
    XCTAssertFalse(
        SocketMCPClient.timeoutText(seconds: 75).contains("isn't running"),
        "a truncated call is not a missing app; the host answered and then went quiet"
    )
    XCTAssertTrue(
        SocketMCPClient.timeoutText(seconds: 75).contains("75"),
        "and it must name the bound it gave up at, because that is what the reader needs"
    )
}

    // MARK: - Helpers

    private func connect(to harness: MCPHostHarness) async throws -> SocketMCPClient {
        let client = try XCTUnwrap(
            SocketMCPClient(endpointDirectory: harness.endpointDirectory),
            "a started host must be connectable"
        )
        let opened = await client.open()
        XCTAssertTrue(opened, "initialize over the socket must complete, or the route is not .proxy")
        disconnectOnTeardown(client, in: self)
        return client
    }

    private func connect(to fixture: TestMCPHost) async throws -> SocketMCPClient {
        let client = try XCTUnwrap(
            SocketMCPClient(endpointDirectory: fixture.directory),
            "a started host must be connectable"
        )
        let opened = await client.open()
        XCTAssertTrue(opened, "initialize over the socket must complete, or the route is not .proxy")
        disconnectOnTeardown(client, in: self)
        return client
    }

    private func client(from route: MCPRoute) -> SocketMCPClient? {
        guard case .proxy(let client) = route else { return nil }
        return client
    }

    /// Disconnecting awaits the SDK's message-loop task, so it cannot be driven from
    /// the main thread a teardown block runs on — the same reason `MCPHostHarness`
    /// stops its host from a background queue.
    private func disconnectOnTeardown(_ client: SocketMCPClient, in test: XCTestCase) {
        test.addTeardownBlock {
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInitiated).async {
                Task {
                    await client.disconnect()
                    done.signal()
                }
            }
            _ = done.wait(timeout: .now() + 30)
        }
    }
}

/// The app's own answer to `tools/list`.
///
/// Lives here rather than in `SocketMCPClient` because nothing in production asks it: it
/// exists so "the catalog is the same either way" can be checked against a real host
/// rather than against this process's idea of what the host would say.
private extension SocketMCPClient {
    func listedToolNames() async throws -> [String] {
        let client = try XCTUnwrap(
            mcpClient, "the client must be connected before its catalog can be asked for"
        )
        return try await client.listTools().tools.map(\.name)
    }
}

/// Runs `body` with this process's stderr redirected into a temporary file, and returns
/// what was written to it.
///
/// The descriptor is moved rather than a `stderr` closure swapped in, because the code
/// under test writes through `FileHandle.standardError` — there is nothing to inject.
/// That is the point of capturing the real thing: a test that passed a logger in would
/// prove nothing about the line a user sees.
private func captureStderr<T>(
    _ body: () async throws -> T
) async throws -> (value: T, stderr: String) {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("pm-stderr-\(UUID().uuidString).txt")
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let capture = open(url.path, O_WRONLY)
    let saved = dup(2)
    guard capture >= 0, saved >= 0 else {
        if capture >= 0 { close(capture) }
        if saved >= 0 { close(saved) }
        throw NSError(
            domain: "CLIRoutingTests", code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))]
        )
    }
    defer {
        dup2(saved, 2)
        close(capture)
        close(saved)
        try? FileManager.default.removeItem(at: url)
    }
    dup2(capture, 2)
    let value = try await body()
    // Read before restoring: nothing else is writing, and the file is still there.
    let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    return (value: value, stderr: text)
}
