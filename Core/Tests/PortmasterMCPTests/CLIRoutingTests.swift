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
        XCTAssertEqual(relayed.count, 13, "the catalog is 13 tools")
    }

    /// The relay is a relay: the call arrives at the host's own call surface with the
    /// arguments the client sent, and the answer the host produced is what comes back.
    ///
    /// A client that quietly ran the call locally as well would pass a "does the tool
    /// work" test and fail this one, and it would also mean two gates had ruled on the
    /// same mutation.
    func testProxiedMutationReachesTheHostsBroker() async throws {
        let hostContext = RecordingHostContext(text: "quit_app: done by the app")
        let host = try makeHost(hostContext, in: self)
        try host.host.start()
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
            hostContext.calls.count, 1,
            "exactly one call must arrive at the host — a second would mean two authorities"
        )
        XCTAssertEqual(hostContext.calls.first?.name, "quit_app")
        XCTAssertEqual(
            hostContext.calls.first?.arguments,
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
        flipped.replaceSubrange(other.startIndex..<other.index(after: other.startIndex),
                               with: String(replacement))
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

    // MARK: - Helpers

    /// A host on its own socket in its own directory, over `context`, stopped when the
    /// test ends.
    private func makeHost(
        _ context: some MCPToolCalling,
        in test: XCTestCase,
        socketName: String = "mcp.sock"
    ) throws -> HostFixture {
        let directory = try test.makeTemporaryDirectory(prefix: "pm")
        let socketURL = directory.appendingPathComponent(socketName)
        let host = MCPHostServer(
            socketURL: socketURL,
            endpointDirectory: directory,
            context: context
        )
        test.addTeardownBlock {
            // Started off the main thread: a teardown block blocks the thread it runs
            // on, and `stop` is async.
            let stopped = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInitiated).async {
                Task {
                    await host.stop()
                    stopped.signal()
                }
            }
            _ = stopped.wait(timeout: .now() + 30)
        }
        return HostFixture(host: host, directory: directory)
    }

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

    private func connect(to fixture: HostFixture) async throws -> SocketMCPClient {
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

/// A host, and the directory its endpoint file lives in.
private struct HostFixture {
    let host: MCPHostServer
    let directory: URL
}

/// Stands in for the app's own call surface: records what arrived, answers with a
/// canned outcome, and touches nothing on this machine.
///
/// A recording context rather than a real executor is what makes the relay observable.
/// The app's own gate, broker and audit live behind *this* seam — replacing it is what
/// makes the assertion "the call arrived with these arguments" mean something.
private final class RecordingHostContext: MCPToolCalling, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(name: String, arguments: [String: String])] = []
    private let text: String

    init(text: String) { self.text = text }

    var calls: [(name: String, arguments: [String: String])] {
        lock.withLock { recorded }
    }

    func call(name: String, arguments: [String: String]) async -> ToolOutcome {
        lock.withLock { recorded.append((name, arguments)) }
        return ToolOutcome(text: text, isError: false)
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
