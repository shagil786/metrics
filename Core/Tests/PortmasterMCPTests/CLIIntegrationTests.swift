// CLIIntegrationTests: the `portmaster-mcp` executable as its clients see it.
//
// These tests spawn the built binary and speak newline-delimited JSON-RPC to it
// over real pipes, because everything the stdio surface depends on — the SDK's
// transport, the message loop, the run loop the sampler needs — only exists when
// the process is a process. A test that constructed the same handlers in-process
// would pass with the executable still being a stub.
//
// The binary is located through `swift build --show-bin-path` rather than a
// hard-coded path, so the test tracks whatever build directory SwiftPM chose.

import Foundation
import XCTest

@testable import PortmasterMCP

final class CLIIntegrationTests: XCTestCase {

    /// A cold sampler pays for a process sweep, a port scan and a `nettop` pass
    /// before it has anything to report, and the read budget that waits for it is
    /// 10 seconds. The handshake, by contrast, is instant, so the two have very
    /// different deadlines and use them separately.
    static let handshakeTimeout: TimeInterval = 20
    static let liveReadTimeout: TimeInterval = 60
    /// Long enough for whatever work the session still has outstanding, plus the
    /// server's drain on EOF, plus slack. The drain's cap is derived from the
    /// provider's own read budget (`OnDemandProvider.defaultSnapshotTimeout` plus
    /// the quiet period), so it is not a fixed number to quote here — this has to
    /// outlast it, and a comment naming the wrong cap would rot the moment that
    /// expression changed, which is exactly what happened last round.
    static let eofExitTimeout: TimeInterval = 30

    // MARK: Handshake, catalog, and a real tool call

    func testInitializeToolsListAndCallGetSettings() async throws {
        let server = try MCPServerProcess.launch()

        let initialized = try server.request(
            """
            {"jsonrpc":"2.0","id":1,"method":"initialize","params":\
            {"protocolVersion":"2025-06-18","capabilities":{},\
            "clientInfo":{"name":"test","version":"0"}}}
            """,
            timeout: Self.handshakeTimeout
        )
        XCTAssertNil(initialized["error"], "initialize must not fail: \(initialized)")
        let result = try XCTUnwrap(initialized["result"] as? [String: Any])
        let serverInfo = try XCTUnwrap(
            result["serverInfo"] as? [String: Any], "initialize result must carry serverInfo"
        )
        XCTAssertEqual(serverInfo["name"] as? String, "portmaster-mcp")

        // The client announces itself as initialized; the server must not answer a
        // notification, so the next line read must be the tools/list reply.
        try server.notify(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)

        let listed = try server.request(
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            timeout: Self.handshakeTimeout
        )
        let listedTools = try XCTUnwrap(listed["result"] as? [String: Any])
        let names = ((listedTools["tools"] as? [[String: Any]]) ?? []).compactMap {
            $0["name"] as? String
        }
        XCTAssertEqual(
            names.sorted(),
            ToolExecutor.catalog.map(\.name).sorted(),
            "tools/list must expose exactly the catalog, in the catalog's set"
        )

        let called = try server.request(
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_settings","arguments":{}}}"#,
            timeout: Self.handshakeTimeout
        )
        let callResult = try XCTUnwrap(called["result"] as? [String: Any])
        XCTAssertEqual(
            callResult["isError"] as? Bool, false,
            "get_settings must not fail: \(callResult["content"] as Any)"
        )
        let text = try Self.contentText(callResult)
        let payload = try jsonObject(text)
        XCTAssertNotNil(
            payload["mutationMode"], "get_settings must report the mutation mode: \(text)"
        )
    }

    // MARK: Failures are data, not transport errors

    func testUnknownToolCallReturnsToolError() async throws {
        let server = try MCPServerProcess.launch()
        try server.initialize(id: 1)

        let response = try server.request(
            """
            {"jsonrpc":"2.0","id":2,"method":"tools/call",\
            "params":{"name":"nope","arguments":{}}}
            """,
            timeout: Self.handshakeTimeout
        )
        // The call failed, so the failure belongs in the tool result: a JSON-RPC
        // error would tell the caller the transport was broken.
        XCTAssertNil(response["error"], "\(response)")
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        XCTAssertTrue(
            try Self.contentText(result).contains("nope"),
            "the error text must name the tool that was not found"
        )
    }

    // MARK: EOF, and the drain that has to happen before it

    /// The `echo … | portmaster-mcp` shape, and the reason `MCPStdioRunner`
    /// drains before it stops.
    ///
    /// A whole conversation is written and stdin is closed before the server has
    /// answered anything — which is what a shell pipeline does, and what a person
    /// trying the server by hand does. The SDK's message loop ends the moment its
    /// input does, so without a drain the process exits having written nothing,
    /// and the very first manual check anyone runs reports a broken server.
    ///
    /// Asserted against what the process actually wrote before it exited, so this
    /// fails if the drain is removed or its cap is shortened below the work.
    func testRepliesAreWrittenBeforeTheProcessExitsOnEOF() async throws {
        let server = try MCPServerProcess.launch()
        try server.writeAndClose([
            """
            {"jsonrpc":"2.0","id":1,"method":"initialize","params":\
            {"protocolVersion":"2025-06-18","capabilities":{},\
            "clientInfo":{"name":"test","version":"0"}}}
            """,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            """
            {"jsonrpc":"2.0","id":2,"method":"tools/call",\
            "params":{"name":"get_settings","arguments":{}}}
            """,
        ])

        let replies = try server.linesWrittenBeforeExit(timeout: Self.eofExitTimeout)
        let byID = Dictionary(
            uniqueKeysWithValues: replies.compactMap { line -> (Int, [String: Any])? in
                guard let object = try? MCPServerProcess.jsonObject(line),
                    let id = object["id"] as? Int
                else { return nil }
                return (id, object)
            }
        )

        let initialized = try XCTUnwrap(byID[1], "the initialize reply was never written")
        XCTAssertNotNil(
            (initialized["result"] as? [String: Any])?["serverInfo"], "\(initialized)"
        )

        let called = try XCTUnwrap(
            byID[2], "the tools/call reply was never written; stdout held: \(replies)"
        )
        let result = try XCTUnwrap(called["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false, "\(result)")
        let text = try Self.contentText(result)
        XCTAssertNotNil(try jsonObject(text)["mutationMode"], text)
    }

    // MARK: The live read, and the run loop it depends on

    /// Pins the run loop requirement.
    ///
    /// `SamplingEngine` publishes `latest` on the main dispatch queue, so a
    /// server process that never runs its main run loop answers every live read
    /// with "No reading available yet". This test fails if the executable ever
    /// grows that bug, which is why it asks the running binary for a real
    /// machine reading instead of exercising the executor in-process.
    ///
    /// A **timeout** skips rather than fails. This test spends up to a minute
    /// waiting on a cold sampler, and a loaded machine can spend it there without
    /// anything being wrong; a failure that only appears when CI is busy trains
    /// the team to ignore the whole file, including the run-loop regression it
    /// exists to catch. A server that answers with the *wrong* payload still
    /// fails — only the absence of an answer within the budget is skipped.
    func testGetSystemOverviewAnswersFromLiveSampler() async throws {
        let server = try MCPServerProcess.launch()
        try server.initialize(id: 1)

        let response: [String: Any]
        do {
            response = try server.request(
                """
                {"jsonrpc":"2.0","id":2,"method":"tools/call",\
                "params":{"name":"get_system_overview","arguments":{}}}
                """,
                timeout: Self.liveReadTimeout
            )
        } catch is ServerTimeout {
            throw XCTSkip(
                "no live reading within \(Self.liveReadTimeout)s on this machine; "
                    + "the run-loop regression this guards against reports an answer "
                    + "with isError, which still fails above"
            )
        }
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let text = try Self.contentText(result)
        XCTAssertEqual(
            result["isError"] as? Bool, false,
            "a live sampler behind a running main run loop must answer: \(text)"
        )
        let payload = try jsonObject(text)
        XCTAssertNotNil(payload["cpu"], text)
        XCTAssertNotNil(payload["memory"], text)
    }

    // MARK: Routing, in the executable

    /// `runMain`'s routing, end to end, in the process it actually runs in.
    ///
    /// Nothing else here covers it: every routing test in `CLIRoutingTests` calls
    /// `MCPRouteSelector` or `SocketMCPClient` directly, so the wiring this task added to
    /// `runMain` — choose the route once inside the serving task, serve stdio with
    /// `route.context`, disconnect the relayed socket on the way out — could be deleted
    /// and every one of them would still pass. And stderr was previously read only to
    /// explain a failure, so a CLI that printed nothing on the fallback, or printed a
    /// paragraph, would also have passed.
    ///
    /// Both halves are asserted on one session: exactly one stderr line saying what
    /// happened, and a session that answers normally regardless. The second half is the
    /// one that matters most — the fallback line is on the *success* path, so a version
    /// of this code that wrote to stdout to announce it would break every other test in
    /// this file by corrupting the JSON-RPC channel, and this is where that would be
    /// caught.
    func testForcedOnDemandWritesOneStderrLineAndStillServesStdio() async throws {
        let server = try MCPServerProcess.launch()

        try server.initialize(id: 1)
        let listed: [String: Any] = try server.request(
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            timeout: Self.handshakeTimeout
        )
        XCTAssertNil(listed["error"], "\(listed)")
        let tools = try XCTUnwrap(listed["result"] as? [String: Any])
        XCTAssertEqual(
            ((tools["tools"] as? [[String: Any]]) ?? []).count, 13,
            "the fallback must serve the same catalog the app would"
        )

        // Read after the session has answered, so the line is known to have been written
        // before it is asserted on rather than merely not written *yet*.
        let stderrLines = server.stderrLines
        XCTAssertEqual(
            stderrLines.count, 1,
            "the fallback is one line on stderr: \(stderrLines)"
        )
        XCTAssertTrue(
            stderrLines.first?.contains("PORTMASTER_MCP") == true,
            "the line must name the reason it fell back, so the user knows which thing to "
                + "unset: \(stderrLines)"
        )
        // The line must not claim Portmaster *is* up: this branch runs before any probe,
        // so it cannot know, and on a machine with nothing running the claim would be the
        // one untrue thing the process says.
        XCTAssertTrue(
            stderrLines.first?.contains("may be up") == true,
            "the forced path never probes, so it may only say Portmaster *may* be up: "
                + "\(stderrLines)"
        )
    }

    /// The other route, in the process it actually runs in.
    ///
    /// `runMain`'s proxy arm is the one that decides who the authority is for every
    /// relayed call — it captures the relayed client and closes it on the way out — and
    /// nothing else in the suite reaches it: `CLIRoutingTests` drives
    /// `SocketMCPClient` directly, never `runMain`. Deleting the arm outright would leave
    /// every test green, which is not a state this feature should be in: a CLI that
    /// relays and never closes its socket leaves a session the app's Settings shows as
    /// connected to a process that has gone.
    ///
    /// The host is started *here*, in this process, and the child is pointed at it with
    /// `PORTMASTER_MCP_ENDPOINT_DIR`. Without that override the child would read the
    /// developer's real `~/.portmaster` — which is why the rest of this suite forces the
    /// on-demand path instead. Two suites, both isolated, one from each direction.
    ///
    /// The evidence that the call was *relayed* rather than answered locally is the
    /// answer text and the recorded arguments: the app's stub produces that text, and the
    /// CLI's own fallback has no way to know it.
    func testProxiedSessionReachesTheHostAndDisconnectsOnExit() async throws {
        let fixture = try startRecordingHost(text: "quit_app: stopped by the app")

        let server = try MCPServerProcess.launch(
            environment: [MCPRouteSelector.endpointDirectoryVariable: fixture.directory.path]
        )
        try server.initialize(id: 1)

        let listed: [String: Any] = try server.request(
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            timeout: Self.handshakeTimeout
        )
        let tools = try XCTUnwrap(listed["result"] as? [String: Any], "\(listed)")
        XCTAssertEqual(
            ((tools["tools"] as? [[String: Any]]) ?? []).count, 13,
            "a relayed session must list the same catalog the app serves"
        )

        let called: [String: Any] = try server.request(
            """
            {"jsonrpc":"2.0","id":3,"method":"tools/call",\
            "params":{"name":"quit_app","arguments":{"id":"app:Somewhere","reason":"because"}}}
            """,
            timeout: Self.handshakeTimeout
        )
        let result = try XCTUnwrap(called["result"] as? [String: Any], "\(called)")
        XCTAssertEqual(result["isError"] as? Bool, false, "\(result)")
        XCTAssertEqual(
            try Self.contentText(result), "quit_app: stopped by the app",
            "the answer must be the app's, not one the CLI invented"
        )
        XCTAssertEqual(
            fixture.recordedCalls.count, 1,
            "exactly one call must reach the app — a second would mean two authorities"
        )
        XCTAssertEqual(fixture.recordedCalls.first?.name, "quit_app")
        XCTAssertEqual(
            fixture.recordedCalls.first?.arguments,
            ["id": "app:Somewhere", "reason": "because"],
            "the arguments must survive the relay unchanged"
        )
        XCTAssertEqual(fixture.connectedClients().count, 1, "the child is one authenticated client")
        XCTAssertEqual(server.stderrLines, [], "a proxied session has nothing to explain")

        // EOF is the session's end, and `runMain` must close the relayed socket on the
        // way out — a child that exits holding one leaves the app showing a client that
        // is not there.
        server.stop(expectingExit: true)
        try await fixture.waitForNoClients()
    }

    // MARK: Helpers

    /// The text of a single-content tool result.
    static func contentText(_ result: [String: Any]) throws -> String {
        let content = try XCTUnwrap(result["content"] as? [[String: Any]], "result must carry content")
        let first = try XCTUnwrap(content.first, "result must carry at least one content block")
        XCTAssertEqual(first["type"] as? String, "text", "tools answer in text")
        return try XCTUnwrap(first["text"] as? String, "text content must carry text")
    }
}

// MARK: - The server process

/// One spawned `portmaster-mcp`, spoken to over real pipes.
final class MCPServerProcess {
    private let process: Process
    private let toServer: Pipe
    private let fromServer: LineReader
    private let stderrReader: LineReader

    private init(
        process: Process,
        toServer: Pipe,
        fromServer: LineReader,
        stderrReader: LineReader
    ) {
        self.process = process
        self.toServer = toServer
        self.fromServer = fromServer
        self.stderrReader = stderrReader
    }

    /// Launches the binary, or skips the test when it cannot be built for
    /// reasons that have nothing to do with this code — a broken toolchain is
    /// not a verdict on the server. An assertion failure never skips.
    ///
    /// The child is launched with `PORTMASTER_MCP=on-demand` **merged into** this
    /// process's environment, and that is load-bearing rather than tidiness.
    /// `portmaster-mcp` now routes at startup: it reads the endpoint file at
    /// `~/.portmaster/mcp-endpoint.json` and, if a Portmaster with MCP enabled is
    /// running on this machine, it would relay to it. Then every test below would be
    /// measuring the app's live sampler and its live gate instead of this process's
    /// fallback, and would pass or fail as a function of whether the developer happened
    /// to have the app open. These tests are about the local surface, so they ask for it.
    ///
    /// Merged rather than assigned: `Process.environment` replaces the child's
    /// environment outright, and a binary with no `PATH` or `HOME` fails in ways that
    /// have nothing to do with what is under test.
    static func launch(environment additions: [String: String] = ["PORTMASTER_MCP": "on-demand"])
        throws -> MCPServerProcess
    {
        let binary = try resolveBinary()
        let process = Process()
        process.executableURL = binary
        process.environment = ProcessInfo.processInfo.environment.merging(additions) {
            _, forced in forced
        }
        let toServer = Pipe()
        let fromServer = Pipe()
        let errors = Pipe()
        process.standardInput = toServer
        process.standardOutput = fromServer
        process.standardError = errors
        try process.run()
        let server = MCPServerProcess(
            process: process,
            toServer: toServer,
            fromServer: LineReader(handle: fromServer.fileHandleForReading),
            stderrReader: LineReader(handle: errors.fileHandleForReading)
        )
        // Weak: this closure is retained by `process`, and `server` holds `process`. A
        // strong capture is a cycle, so `deinit` never runs and neither the child
        // nor either pipe is ever released for the rest of the test run.
        process.terminationHandler = { [weak server] finished in
            server?.fromServer.noteExit("status \(finished.terminationStatus)")
            server?.stop(expectingExit: false)
        }
        return server
    }

    deinit { stop(expectingExit: false) }

    /// Everything the server has written to stderr so far, as lines.
    ///
    /// Read from a pipe rather than a captured file: the whole point of this file's
    /// routing assertion is that the fallback line arrives while the session is still
    /// open, so the test must not have to wait for the process to exit to see it.
    var stderrLines: [String] {
        stderrReader.text.split(separator: "\n").map(String.init)
    }

    /// Whether the child is still running. Asserted on so "it disconnected" is never
    /// confused with "it exited and the kernel closed the socket".
    var processIsRunning: Bool { process.isRunning }

    /// Closes stdin, which is how an MCP client ends a stdio session, and waits
    /// for the process to exit — the server's promise that EOF ends the session.
    /// Bounded, so a regression fails this test instead of hanging the run.
    func stop(expectingExit shouldExit: Bool = true) {
        guard process.isRunning else { return }
        try? toServer.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        guard process.isRunning else { return }
        process.terminate()
        if shouldExit {
            XCTFail("the server was still running 5s after its stdin closed")
        }
    }

    /// Writes one JSON-RPC line.
    func send(_ line: String) throws {
        try toServer.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
    }

    /// Writes a notification, which has no id and must never be answered.
    func notify(_ line: String) throws { try send(line) }

    /// Writes a whole conversation and closes stdin immediately — the shape
    /// `echo '…' | portmaster-mcp` produces.
    func writeAndClose(_ lines: [String]) throws {
        for line in lines { try send(line) }
        try toServer.fileHandleForWriting.close()
    }

    /// Waits for the server to exit after its stdin closed, then returns every
    /// line it wrote before going. Throws if it is still running at the deadline,
    /// because "it never exited" and "it exited having written nothing" are the
    /// two ways this can be broken and they need different messages.
    func linesWrittenBeforeExit(timeout: TimeInterval) throws -> [String] {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        guard !process.isRunning else {
            process.terminate()
            throw ServerFailure(
                reason: "the server was still running \(timeout)s after its stdin closed"
            )
        }
        process.waitUntilExit()
        // stdout reaches EOF as soon as the child is gone, so the reader thread
        // finishes on its own; give it a moment, then take what it collected.
        let readDeadline = Date().addingTimeInterval(5)
        while !fromServer.isClosed, Date() < readDeadline { usleep(20_000) }
        assertNoFramingNoise()
        return fromServer.drain()
    }

    /// The stdio transport is newline-delimited, so a blank line is not
    /// whitespace to be tidy about — it is a line a client tries to parse.
    ///
    /// Asserted here because this is the one place a test inspects a whole
    /// session's stdout. Elsewhere a blank line is skipped rather than parsed,
    /// which is right for reading replies and exactly why a stray `print` in the
    /// executable can pass every other test in this file unremarked.
    private func assertNoFramingNoise() {
        let blanks = fromServer.blankLineCount
        guard blanks > 0 else { return }
        XCTFail(
            """
            \(blanks) blank line(s) on stdout. This server's stdout is \
            newline-delimited JSON-RPC, so a blank line is framing noise a client \
            will try to parse — in the executable that means a stray print or a \
            log line written to the wrong stream.
            """
        )
    }

    /// Sends a request and returns the reply carrying the same id. Any other line
    /// — a notification, or a reply to an earlier call — is passed over rather
    /// than returned, so a test cannot assert against a line that is not its
    /// answer.
    @discardableResult
    func request(_ line: String, timeout: TimeInterval) throws -> [String: Any] {
        try send(line)
        let id = try Self.jsonObject(line)["id"].flatMap { $0 as? Int }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let replyLine = try fromServer.nextLine(
                timeout: deadline.timeIntervalSinceNow, stderr: stderrReader.text
            )
            let reply = try Self.jsonObject(replyLine)
            guard let id, reply["id"] as? Int == id else { continue }
            return reply
        }
    }

    /// The `initialize` handshake, so a test can go straight to its own request.
    func initialize(id: Int) throws {
        let reply = try request(
            """
            {"jsonrpc":"2.0","id":\(id),"method":"initialize","params":\
            {"protocolVersion":"2025-06-18","capabilities":{},\
            "clientInfo":{"name":"test","version":"0"}}}
            """,
            timeout: CLIIntegrationTests.handshakeTimeout
        )
        XCTAssertNil(reply["error"], "\(reply)")
        try notify(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
    }

    /// The built `portmaster-mcp`, or a skip explaining why there isn't one.
    private static func resolveBinary() throws -> URL {
        if let cached = cachedBinary { return cached }
        guard let buildDirectory = buildDirectory() else {
            throw XCTSkip(
                "could not work out the build directory: the loaded test bundle "
                    + "is at \(Bundle(for: CLIIntegrationTests.self).bundleURL.path), not a .xctest bundle"
            )
        }
        let binary = buildDirectory.appendingPathComponent("portmaster-mcp")
        if FileManager.default.isExecutableFile(atPath: binary.path) {
            cachedBinary = binary
            return binary
        }
        // The product was not built. A test run that has only compiled the test
        // targets need not have built the executable, so ask for it — under a
        // deadline, because `swift build` invoked from inside `swift test` waits
        // on the build lock the outer run still holds.
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // PortmasterMCPTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // Core
        let build = try run(
            ["swift", "build", "--product", "portmaster-mcp"],
            in: packageRoot,
            timeout: 180
        )
        guard build.status == 0, FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw XCTSkip(
                "`swift build --product portmaster-mcp` did not produce \(binary.path):\n"
                    + (build.timedOut ? "timed out" : "exit status \(build.status)") + "\n"
                    + build.stdout + build.stderr
            )
        }
        cachedBinary = binary
        return binary
    }

    /// The directory `swift build --show-bin-path` would have printed.
    ///
    /// Asked of the toolchain rather than derived from a path: that command takes
    /// SwiftPM's build lock, and `swift test` is still holding it while these
    /// tests run, so a nested `swift build` blocks until it is released — which
    /// never happens inside the run that asked for it. SwiftPM links the test
    /// bundle into exactly the directory `--show-bin-path` reports, so this asks
    /// the loaded bundle where it lives instead of asking the toolchain twice.
    private static func buildDirectory() -> URL? {
        let bundle = Bundle(for: CLIIntegrationTests.self).bundleURL
        guard bundle.pathExtension == "xctest" else { return nil }
        return bundle.deletingLastPathComponent()
    }

    /// Resolved once per test run; the build directory does not move mid-run.
    private static var cachedBinary: URL?

    /// Runs a command to completion, or gives up and returns `timedOut` — a
    /// command that hangs must not hang the test run with it.
    ///
    /// Both pipes are drained concurrently, before the wait. Draining one to EOF
    /// and *then* the other blocks here until the child exits, which is precisely
    /// the case the deadline exists for: this runs when the binary is missing,
    /// and a `swift build` that hangs on SwiftPM's build lock would otherwise
    /// park the whole test run before the deadline was ever consulted.
    private static func run(
        _ arguments: [String], in directory: URL, timeout: TimeInterval
    ) throws -> CommandOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        // Started before `run()` so nothing can fill a pipe buffer while the
        // parent is elsewhere: a build that writes more than the buffer holds
        // would block the child forever.
        let captured = CapturedOutput()
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global().async {
            captured.setStdout(out.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global().async {
            captured.setStderr(err.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }

        do {
            try process.run()
        } catch {
            // Never started, so nothing will ever close these for the readers.
            try? out.fileHandleForWriting.close()
            try? err.fileHandleForWriting.close()
            _ = readers.wait(timeout: .now() + 2)
            throw error
        }

        let exited = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            process.waitUntilExit()
            exited.signal()
        }
        let finished = exited.wait(timeout: .now() + timeout) == .success
        if !finished {
            process.terminate()
            _ = exited.wait(timeout: .now() + 10)
        }
        // The pipes close with the child, so the readers finish on their own.
        // Bounded anyway: this join is for completeness of the output, not for
        // the process, which is already accounted for.
        _ = readers.wait(timeout: .now() + 5)

        return CommandOutput(
            status: finished ? process.terminationStatus : -1,
            stdout: captured.stdout,
            stderr: captured.stderr,
            timedOut: !finished
        )
    }

    /// A command's output, filled in from two queues at once.
    private final class CapturedOutput: @unchecked Sendable {
        private let lock = NSLock()
        private var outData = Data()
        private var errData = Data()

        func setStdout(_ data: Data) { lock.withLock { outData = data } }
        func setStderr(_ data: Data) { lock.withLock { errData = data } }

        var stdout: String { lock.withLock { String(decoding: outData, as: UTF8.self) } }
        var stderr: String { lock.withLock { String(decoding: errData, as: UTF8.self) } }
    }

    /// A JSON-RPC line as a dictionary. `JSONSerialization` is used rather than
    /// the SDK's types because these tests are about what is on the wire, and the
    /// test target deliberately does not depend on the MCP module.
    static func jsonObject(_ text: String) throws -> [String: Any] {
        guard
            let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
            let object = parsed as? [String: Any]
        else {
            throw ServerFailure(reason: "the server sent a line that is not a JSON object: \(text)")
        }
        return object
    }

    struct CommandOutput {
        let status: Int32
        let stdout: String
        let stderr: String
        /// True when the command had to be killed rather than finishing.
        let timedOut: Bool
    }
}

/// A server that would not talk to us.
///
/// A failure rather than a skip: the binary exists and was started, so silence
/// is a verdict on this code, not on the toolchain.
struct ServerFailure: Error, CustomStringConvertible {
    let reason: String
    var description: String { reason }
    var localizedDescription: String { reason }
}

/// The server was still silent when its budget ran out.
///
/// Its own type so a test can tell "it never answered" from "it answered wrongly":
/// the run-loop test skips on this and still fails on every other `ServerFailure`,
/// because a slow machine is not a broken server but a wrong answer is.
struct ServerTimeout: Error, CustomStringConvertible {
    let reason: String
    var description: String { reason }
    var localizedDescription: String { reason }
}

// MARK: - Line reader

/// Reads newline-delimited lines off a pipe on its own thread.
///
/// A blocking read cannot share a thread with the test, and an async reader would
/// need a continuation per line; a dedicated thread with a lock-guarded queue is
/// the smallest thing that gives the test a deadline it can assert against.
///
/// One byte at a time, deliberately. `FileHandle.read(upToCount:)` does not
/// return as soon as *any* data is available — it waits for the whole count, or
/// for the pipe to close. A JSON-RPC reply is a few hundred bytes to a few
/// kilobytes, so a 4 KiB read would sit there until the server exited, and every
/// test would report a server that answered nothing. One byte returns as soon as
/// that byte lands, which is the only thing this needs.
final class LineReader: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private var pending: [String] = []
    private var closed = false
    private var blankLines = 0
    private var collected: [String] = []

    init(handle: FileHandle) {
        self.handle = handle
        let thread = Thread { self.readLoop() }
        thread.start()
    }

    /// Everything read so far. Used only to explain a failure.
    var text: String {
        lock.withLock { collected.joined(separator: "\n") }
    }

    /// The next line, or a failure naming what was read instead.
    func nextLine(timeout: TimeInterval, stderr: String) throws -> String {
        let deadline = Date().addingTimeInterval(max(0.05, timeout))
        while true {
            lock.lock()
            if !pending.isEmpty {
                let line = pending.removeFirst()
                lock.unlock()
                return line
            }
            let finished = closed
            let seen = collected.joined(separator: "\n")
            lock.unlock()
            let stdout = seen.isEmpty ? "<nothing>" : seen
            if finished {
                throw ServerFailure(
                    reason: "the server closed stdout without answering "
                        + "(\(processExitDescription)). stdout so far: \(stdout) "
                        + "stderr: \(stderr.isEmpty ? "<nothing>" : stderr)"
                )
            }
            guard Date() < deadline else {
                throw ServerTimeout(
                    reason: "timed out waiting for a line from the server "
                        + "(stdout so far: \(stdout) "
                        + "stderr: \(stderr.isEmpty ? "<nothing>" : stderr))"
                )
            }
            usleep(2_000)
        }
    }

    /// Filled in by the process wrapper so a failure can say how the server died.
    var processExitDescription: String {
        lock.withLock { storedExit ?? "still running" }
    }
    private var storedExit: String?

    func noteExit(_ description: String) { lock.withLock { storedExit = description } }

    /// True once the pipe reached EOF and nothing more can arrive.
    var isClosed: Bool { lock.withLock { closed } }

    /// Empty lines seen on the pipe.
    ///
    /// Counted rather than discarded. Skipping them silently is what let the
    /// executable's placeholder `print("")` survive every test in this file: the
    /// one artifact the stdio framing rules actually forbid, and the one no
    /// assertion was looking at.
    var blankLineCount: Int { lock.withLock { blankLines } }

    /// Takes every line read so far and empties the queue.
    func drain() -> [String] { lock.withLock { defer { pending.removeAll() }; return pending } }

    private func readLoop() {
        var buffer = Data()
        while true {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: 1)
            } catch {
                chunk = nil
            }
            guard let byte = chunk?.first else { break }
            buffer.append(byte)
            guard byte == UInt8(ascii: "\n") else { continue }
            let text = String(decoding: buffer.dropLast(), as: UTF8.self)
            buffer.removeAll(keepingCapacity: true)
            // Not a message, so not queued — but counted, so a test that inspects
            // a whole session can say the executable wrote framing noise. The
            // stdio transport drops empty lines for the same reason; that is why
            // the noise is invisible unless something here looks for it.
            guard !text.isEmpty else {
                lock.withLock { blankLines += 1 }
                continue
            }
            lock.withLock {
                collected.append(text)
                pending.append(text)
            }
        }
        lock.withLock { closed = true }
    }
}
