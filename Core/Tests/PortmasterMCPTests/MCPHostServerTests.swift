// MCPHostServerTests: the running app as an MCP server.
//
// The socket is the whole of slice 2's reach — it is how a CLI reaches a Portmaster
// that is already running — so these tests drive a real `AF_UNIX` listener in a temp
// directory and speak to it with the SDK's own `Client`, rather than reaching into
// the host's internals. That matters because the two things this file checks that
// nothing else can are *transport* facts: that the handshake happens before a single
// MCP byte moves, and that a client who fails it gets silence rather than a reply.
//
// Every test binds inside its own temp directory and stops its host in teardown, so
// no test can leave a live listener or a socket file behind for the next one.

import Foundation
import MCP
import Network
import PortmasterCore
@testable import PortmasterMCP
import XCTest

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

final class MCPHostServerTests: XCTestCase {

    // MARK: - Round trip over the socket

    /// The whole feature in one test: a client that completes the handshake gets a
    /// working MCP server — initialize, the catalog, and a real tool call — over a
    /// Unix socket.
    func testServesInitializeToolsListAndCallOverAUnixSocket() async throws {
        let harness = try MCPHostHarness.make(self)
        try harness.start()

        let session = try await harness.connectClient()
        defer { session.cancel() }

        // `connect` is what performs `initialize`, so reaching here at all is the
        // assertion that the handshake left the connection ready for MCP.
        let tools = try await session.client.listTools()
        XCTAssertEqual(
            tools.tools.map(\.name).sorted(),
            ToolExecutor.catalog.map(\.name).sorted(),
            "tools/list must expose exactly the catalog, in the catalog's set"
        )
        XCTAssertEqual(
            tools.tools.count, 13, "the catalog is 13 tools, and all of them must be listed"
        )

        let called = try await session.client.callTool(name: "get_settings", arguments: [:])
        XCTAssertEqual(called.isError, false, "get_settings must not fail over the socket")
    }

    /// A client has no reason to wait between the handshake and its first message:
    /// the host acknowledges nothing, so there is nothing to wait *for*. One `write`
    /// carrying both is therefore the natural thing to do, and it is what the CLI in
    /// task 6 will do.
    ///
    /// It works only because the handshake read hands back whatever arrived past the
    /// newline. A host that kept the handshake line and dropped the rest would accept
    /// the token, see nothing more, and leave the client waiting on a reply to a
    /// message it had already delivered — until the client's own timeout, with no
    /// error on either side to explain it.
    func testAHandshakeAndInitializeInOneWriteAreBothDelivered() async throws {
        let harness = try MCPHostHarness.make(self)
        try harness.start()

        let descriptor = try harness.connectRawSocket()
        addTeardownBlock { close(descriptor) }

        let initialize = """
            {"jsonrpc":"2.0","id":1,"method":"initialize","params":\
            {"protocolVersion":"2025-06-18","capabilities":{},\
            "clientInfo":{"name":"pipelined","version":"0"}}}
            """
        // One write, one `write` syscall's worth of bytes, both messages.
        try Self.writeAll(
            Data(#"{"token":"\#(try harness.token)"}"# .utf8)
                + Data([0x0A])
                + Data((initialize + "\n").utf8),
            to: descriptor
        )

        let reply = try Self.readUntilClose(from: descriptor, timeout: 10)
        let text = try XCTUnwrap(
            String(data: reply.bytes, encoding: .utf8),
            "the host must answer the initialize that arrived with the handshake"
        )
        let first = try XCTUnwrap(
            text.split(separator: "\n").first.map(String.init),
            "the host sent \(text.count) bytes but no complete line"
        )

        let object = try jsonObject(first)
        XCTAssertNil(object["error"], "initialize must not fail: \(first)")
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        let serverInfo = try XCTUnwrap(result["serverInfo"] as? [String: Any])
        XCTAssertEqual(
            serverInfo["name"] as? String, MCPStdioRunner.serverName,
            "a pipelined initialize must be served exactly like a separate one"
        )
    }

    // MARK: - The handshake

    /// The handshake is transport-level: a connection that has not presented the
    /// token gets closed, and the host writes *nothing* — not a rejection, not an
    /// error, not an MCP frame. A reply here would be the first thing an attacker
    /// learns, that something is listening.
    func testUnauthenticatedConnectionIsClosedBeforeAnyBytesAreWritten() async throws {
        let harness = try MCPHostHarness.make(self)
        try harness.start()

        // Connect and immediately shut down the writing half: what a client that
        // never authenticates looks like when it gives up.
        let descriptor = try harness.connectRawSocket()
        XCTAssertEqual(shutdown(descriptor, SHUT_WR), 0)
        addTeardownBlock { close(descriptor) }

        let silent = try Self.readUntilClose(from: descriptor, timeout: 10)
        XCTAssertEqual(
            silent.bytes.count, 0,
            "an unauthenticated client must receive zero bytes, got \(silent.bytes.count)"
        )
        XCTAssertTrue(
            silent.sawEndOfFile,
            """
            the host must close an unauthenticated connection, not leave it waiting \
            until its handshake timeout — this read gave up after \
            \(Int(silent.elapsed))ms
            """
        )

        // The other half of the same rule: a client that *does* send a first line,
        // but not the right one, is rejected the same way. Silence on a malformed
        // line matters as much as silence on no line — a JSON-RPC parse error would
        // be just as much of an answer.
        let malformed = try harness.connectRawSocket()
        addTeardownBlock { close(malformed) }
        try Self.writeAll(Data(#"{"notAToken":"\#(String(repeating: "0", count: 64))"}"# .utf8 + Data([0x0A])), to: malformed)
        let refused = try Self.readUntilClose(from: malformed, timeout: 10)
        XCTAssertEqual(
            refused.bytes.count, 0,
            "a malformed handshake must be refused in silence, got \(refused.bytes.count) bytes"
        )
        XCTAssertTrue(
            refused.sawEndOfFile,
            "a malformed handshake must be refused by closing the connection"
        )
    }

    /// A rejected connection must not take the host with it: the socket is a
    /// long-lived local service, and one wrong token — a stale endpoint file, a
    /// typo'd argument, a probe — is not a reason to stop serving.
    func testWrongTokenIsRejectedAndTheServerKeepsServing() async throws {
        let harness = try MCPHostHarness.make(self)
        try harness.start()

        let rejected = try harness.connectRawSocket()
        addTeardownBlock { close(rejected) }
        let line = #"{"token":"\#(String(repeating: "0", count: 64))"}"#
        try Self.writeAll(Data((line + "\n").utf8), to: rejected)
        let reply = try Self.readUntilClose(from: rejected, timeout: 10)
        XCTAssertEqual(
            reply.bytes.count, 0,
            "a wrong token must be rejected in silence, never with a reply"
        )
        XCTAssertTrue(
            reply.sawEndOfFile,
            "a wrong token must be rejected by closing, not by leaving the client waiting"
        )

        // The real token, on a second connection, still works.
        let session = try await harness.connectClient()
        defer { session.cancel() }
        let tools = try await session.client.listTools()
        XCTAssertEqual(
            tools.tools.count, 13,
            "the host must keep serving after rejecting a wrong token"
        )
    }

    // MARK: - Binding and shutdown

    /// A socket file survives the app that made it. Binding over one fails with
    /// `EADDRINUSE`, so `start` has to recognise a leftover that nothing is
    /// listening on and replace it — otherwise the feature is dead for good after
    /// the first crash or force-quit.
    func testStaleSocketFileIsReplacedOnBind() throws {
        let harness = try MCPHostHarness.make(self)
        // A plain file where the socket goes: not a socket, nothing listening.
        FileManager.default.createFile(atPath: harness.socketURL.path, contents: Data("stale".utf8))

        XCTAssertNoThrow(try harness.start())
        var status = stat()
        XCTAssertEqual(lstat(harness.socketURL.path, &status), 0)
        XCTAssertEqual(
            status.st_mode & S_IFMT, S_IFSOCK,
            "start must leave a real socket at the path, not the leftover file"
        )
    }

    func testStopRemovesSocketAndEndpointFile() async throws {
        let harness = try MCPHostHarness.make(self)
        try harness.start()
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.socketURL.path))
        XCTAssertNotNil(EndpointFileStore.read(directory: harness.endpointDirectory))

        await harness.host.stop()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: harness.socketURL.path),
            "stop must unlink the socket it created"
        )
        XCTAssertNil(
            EndpointFileStore.read(directory: harness.endpointDirectory),
            "stop must take the endpoint file away, so no CLI can find a host that is gone"
        )
    }

    /// Two connections from one process, which is what an agent does when it asks two
    /// questions at once.
    ///
    /// The identity of a *connection* has to be distinct from the identity of a
    /// *process*, or `Identifiable` is a lie: a SwiftUI `List` given two rows with the
    /// same id shows one of them, and the user watching "connected clients" would lose
    /// a connection without any indication that they had.
    func testTwoConnectionsFromOneProcessHaveDistinctIdsAndTheSamePid() async throws {
        let harness = try MCPHostHarness.make(self)
        try harness.start()

        let first = try await harness.connectClient()
        defer { first.cancel() }
        let second = try await harness.connectClient()
        defer { second.cancel() }

        try await Self.eventually(timeout: 5) { harness.host.connectedClients().count == 2 }
        let clients = harness.host.connectedClients()
        XCTAssertEqual(clients.count, 2)
        // Guarded rather than indexed straight away: XCTest assertions do not stop the
        // test, so `clients[1]` on a one-row list would crash the run and bury the
        // actual failure under a signal.
        guard clients.count == 2 else { return }

        // Two connections, so two identities — this is the assertion the pid-as-id
        // arrangement could not make.
        XCTAssertNotEqual(
            clients[0].id, clients[1].id,
            "two open connections must be two rows, even from one process"
        )
        XCTAssertEqual(Set(clients.map(\.id)).count, 2)

        // …and one process, so one pid. Which is the point of keeping `pid` at all.
        XCTAssertEqual(
            Set(clients.map(\.pid)).count, 1,
            "both connections come from this test process, so both report this pid"
        )
        XCTAssertEqual(
            clients[0].pid, ProcessInfo.processInfo.processIdentifier,
            "the peer pid must be the process on the other end of the socket"
        )
    }

    /// A connection must not be able to become a session *after* `stop()` has finished.
    ///
    /// The window this closes is real and it is ten seconds wide. A client can connect
    /// and then sit silent — the host has no reason to hurry it, and the handshake
    /// timeout is what ends an abandoned connection. If it connects at the wrong moment,
    /// `stop()` runs to completion while it is still in that read: the listener is
    /// closed, the files are unlinked, and the registry has been emptied. The handshake
    /// then completes against the token captured before, and unless admission and
    /// shutdown contend on one lock, the session starts on a descriptor nothing will ever
    /// close — surviving until the client hangs up on its own, with a row in
    /// `connectedClients()` and a reader thread on a host that has stopped.
    ///
    /// Driven deliberately: the raw socket connects first, `stop()` is awaited, and only
    /// then is the handshake written. The host is not accepting anything by then, so the
    /// handshake must get silence and a closed connection.
    func testAHandshakeArrivingAfterStopIsRefused() async throws {
        let harness = try MCPHostHarness.make(self)
        try harness.start()

        // Read the token up front, as a real client does. `stop()` takes the endpoint
        // file away with it, so afterwards there is nothing left to read — which is
        // itself part of why a late handshake cannot be a late *session*.
        let token = try harness.token

        // Connected while the host is running, but saying nothing — so it is inside the
        // handshake read when `stop()` begins.
        let descriptor = try harness.connectRawSocket()
        addTeardownBlock { close(descriptor) }
        try await Task.sleep(for: .milliseconds(100))

        await harness.host.stop()

        // The handshake only now. It must not be authenticated into a stopped host.
        try Self.writeAll(
            Data(#"{"token":"\#(token)"}"# .utf8) + Data([0x0A]),
            to: descriptor
        )

        let reply = try Self.readUntilClose(from: descriptor, timeout: 10)
        XCTAssertEqual(
            reply.bytes.count, 0,
            "a handshake that arrives after stop() must get silence, got \(reply.bytes.count) bytes"
        )
        XCTAssertTrue(
            reply.sawEndOfFile,
            """
            a connection that completes its handshake after stop() must be closed, \
            not left holding a session — this read gave up after \
            \(Int(reply.elapsed))ms
            """
        )

        // And nothing survived: no session, no row, no reader thread.
        XCTAssertEqual(
            harness.host.connectedClients().count, 0,
            "a stopped host must not end up serving a client"
        )
        try await Self.eventually(timeout: 5) { harness.host.liveReaderCount == 0 }
        XCTAssertEqual(
            harness.host.liveReaderCount, 0,
            "a session started after stop() would leave a reader thread running forever"
        )
    }

    // MARK: - Bookkeeping for Settings

    /// Settings has to be able to say "something is connected" without the host
    /// leaking the token, so the client list is a pid and two timestamps and
    /// nothing else.
    func testConnectedClientIsListedWithLastCallTime() async throws {
        let harness = try MCPHostHarness.make(self)
        try harness.start()

        let session = try await harness.connectClient()
        defer { session.cancel() }

        // `tools/call` is what stamps `lastCallAt`; `initialize` and `tools/list`
        // must not, because a client that connects and never asks anything has not
        // "last called" anything.
        _ = try await session.client.listTools()
        try await Self.eventually(timeout: 5) { harness.host.connectedClients().count == 1 }
        guard let connected = harness.host.connectedClients().first else {
            return XCTFail("a connected client must be listed")
        }
        XCTAssertNil(
            connected.lastCallAt,
            "initialize and tools/list are not tool calls, so there is no last call yet"
        )

        _ = try await session.client.callTool(name: "get_settings", arguments: [:])
        try await Self.eventually(timeout: 5) {
            harness.host.connectedClients().first?.lastCallAt != nil
        }
        guard let called = harness.host.connectedClients().first else {
            return XCTFail("the client must still be listed after a call")
        }
        let lastCallAt = try XCTUnwrap(called.lastCallAt)
        XCTAssertGreaterThanOrEqual(
            lastCallAt, connected.connectedAt,
            "lastCallAt must not predate the connection"
        )

        await harness.host.stop()
        XCTAssertEqual(
            harness.host.connectedClients().count, 0,
            "a stopped host must list no clients"
        )
    }

    /// One descriptor, two readers, two deadlines — and `SO_RCVTIMEO` is
    /// per-descriptor state that outlives the caller who set it.
    ///
    /// The handshake read gives a descriptor ten seconds; the MCP session that
    /// follows must have no deadline at all. If the session inherited the
    /// handshake's window, the first client to sit still for ten seconds would have
    /// its session closed underneath it — and the reader, which treats `EAGAIN` as
    /// "nothing yet", would then spin on that descriptor for the life of the process.
    func testAnUnboundedReadClearsAPreviouslySetReadTimeout() async throws {
        let directory = try makeTemporaryDirectory(prefix: "pm")
        let path = directory.appendingPathComponent("pair.sock")
        let listener = try UnixSocketBinding.listen(path: path.path)
        let writer = UnixSocket(try connectUnixSocket(at: path.path))
        let accepted = accept(listener, nil, nil)
        close(listener)
        let reader = UnixSocket(accepted)
        addTeardownBlock { reader.close(); writer.close() }

        var chunk = [UInt8](repeating: 0, count: 16)
        // A short deadline first, so a leaked window would be visible immediately.
        guard case .timedOut = reader.read(into: &chunk, timeout: 0.05) else {
            return XCTFail("a read with no data and a 50ms deadline must time out")
        }

        // Now the session's read: unbounded. It must block, not fail.
        let readInBackground = expectation(description: "unbounded read is blocked")
        let outcome = ReadOutcome()
        DispatchQueue.global(qos: .userInitiated).async {
            // Its own buffer: `chunk` belongs to the read above, and sharing one
            // `var` across a suspension point and into an escaping closure is two
            // threads writing the same memory.
            var backgroundChunk = [UInt8](repeating: 0, count: 16)
            outcome.record(reader.read(into: &backgroundChunk, timeout: .infinity))
            readInBackground.fulfill()
        }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(
            readInBackground.expectedFulfillmentCount, 1,
            "the unbounded read must still be waiting, so the 50ms window did not survive"
        )
        try writer.writeAll(Data("x".utf8))
        await fulfillment(of: [readInBackground], timeout: 5)
        guard case .bytes(let count) = outcome.value else {
            return XCTFail("the unbounded read must deliver the byte, got \(outcome.value)")
        }
        XCTAssertEqual(count, 1)
    }

    /// Every connection this host serves costs a reader thread, and a reader thread
    /// that does not exit is a thread spinning at a core for the life of the process.
    ///
    /// Nothing else would show it: no crash, no log line, no failed assertion — the
    /// session drains and the socket closes perfectly while the thread behind it keeps
    /// calling `read` on a descriptor that returns zero immediately. So the count of
    /// live readers is the assertion, and it has to reach zero after `stop()`.
    func testStopLeavesNoReaderThreadRunning() async throws {
        let harness = try MCPHostHarness.make(self)
        try harness.start()
        XCTAssertEqual(harness.host.liveReaderCount, 0, "a host with no clients has no readers")

        let session = try await harness.connectClient()
        try await Self.eventually(timeout: 5) { harness.host.liveReaderCount == 1 }
        // Prove the reader really is the thing being counted: a live session, not a
        // counter that happens to be zero.
        XCTAssertEqual(harness.host.connectedClients().count, 1)

        await harness.host.stop()

        try await Self.eventually(timeout: 5) { harness.host.liveReaderCount == 0 }
        XCTAssertEqual(
            harness.host.liveReaderCount, 0,
            "stop() must end every reader thread, not just close the descriptors"
        )
        session.cancel()
    }

    /// The same leak by the other exit: a client that goes away on its own, without
    /// anyone calling `stop()`.
    func testAClientDisconnectingEndsItsReaderThread() async throws {
        let harness = try MCPHostHarness.make(self)
        try harness.start()

        let session = try await harness.connectClient()
        try await Self.eventually(timeout: 5) { harness.host.liveReaderCount == 1 }

        session.cancel()

        try await Self.eventually(timeout: 5) { harness.host.liveReaderCount == 0 }
        XCTAssertEqual(
            harness.host.liveReaderCount, 0,
            "a client hanging up must end its reader thread; nothing else will"
        )
        try await Self.eventually(timeout: 5) { harness.host.connectedClients().isEmpty }
    }

    // MARK: - Permissions

    /// Two files, one secret between them. The token is only as private as the
    /// endpoint file, and the endpoint file is only as private as the socket that
    /// accepts on its token — so both are asserted at the bits.
    func testSocketAndEndpointFileAreOwnerOnly() throws {
        let harness = try MCPHostHarness.make(self)
        try harness.start()

        XCTAssertEqual(
            try Self.posixPermissions(of: harness.socketURL), 0o600,
            "the socket must be reachable by its owner and nobody else"
        )
        XCTAssertEqual(
            try Self.posixPermissions(of: EndpointFileStore.defaultURL(
                directory: harness.endpointDirectory
            )), 0o600,
            "the endpoint file holds the token, so it must be owner-only"
        )
        XCTAssertEqual(
            try Self.posixPermissions(of: harness.endpointDirectory), 0o700,
            "the directory around them must be owner-only too"
        )
    }

    /// A write to a socket whose peer has gone raises `SIGPIPE`, whose default
    /// action terminates the process. On the client side that kills a CLI and is
    /// reported as a tool error; on this side it kills Portmaster — a client that
    /// disconnected between the host reading a request and writing the reply
    /// would take the whole app down with it, mid-sample, with nothing in the log.
    ///
    /// Asserted at the bits, on the descriptor the host actually accepted, because
    /// no other symptom exists: the missing option produces no crash report, no
    /// failed assertion and no wrong answer — only a process that is gone.
    func testAnAcceptedSocketCannotRaiseSIGPIPE() async throws {
        let harness = try MCPHostHarness.make(self)
        try harness.start()
        let observations = SIGPIPEObservations()
        harness.host.onSocketAccepted = { socket in
            observations.record(socket.suppressesSIGPIPE)
        }

        let client = try harness.connectRawSocket()
        addTeardownBlock { close(client) }

        try await Self.eventually(timeout: 5) { observations.count > 0 }
        XCTAssertEqual(observations.count, 1, "one connection, one accepted socket")
        XCTAssertTrue(
            observations.allSuppressed,
            "SO_NOSIGPIPE must be set on an accepted socket, or a client that hangs up "
            + "mid-reply terminates the app"
        )
    }

    // MARK: - Helpers

    /// What a rejected connection must produce: nothing at all, and then an end of
    /// file.
    private struct Reply {
        let bytes: Data
        /// Whether the host closed the connection, as opposed to this read running
        /// out of patience. The distinction is the assertion: a host that said
        /// nothing *and* hung is not a host that rejected anybody.
        let sawEndOfFile: Bool
        let elapsed: TimeInterval
    }

    /// Reads until the peer closes or the deadline passes.
    private static func readUntilClose(from descriptor: Int32, timeout: TimeInterval) throws
        -> Reply
    {
        let started = Date()
        var received = Data()
        let deadline = started.addingTimeInterval(timeout)
        while Date() < deadline {
            var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pollDescriptor, 1, 200)
            if ready <= 0 { continue }
            if pollDescriptor.revents & Int16(POLLIN | POLLHUP | POLLERR) == 0 { continue }

            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = chunk.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, 4096) }
            if count > 0 {
                received.append(contentsOf: chunk[0..<count])
                // Keep reading until there is a whole line. A reply can arrive in
                // pieces, and a half-parsed JSON-RPC frame would be this helper's bug
                // rather than the host's. Nothing to wait for in the rejection cases:
                // those never send a byte, so this only ever triggers on EOF.
                if received.contains(0x0A) {
                    return Reply(
                        bytes: received, sawEndOfFile: false,
                        elapsed: Date().timeIntervalSince(started)
                    )
                }
                continue
            }
            if count == 0 {
                return Reply(
                    bytes: received, sawEndOfFile: true,
                    elapsed: Date().timeIntervalSince(started)
                )
            }
            if errno != EINTR && errno != EAGAIN {
                throw NSError(domain: "MCPHostServerTests", code: Int(errno))
            }
        }
        return Reply(
            bytes: received, sawEndOfFile: false,
            elapsed: Date().timeIntervalSince(started)
        )
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        var remaining = data
        while !remaining.isEmpty {
            let written = remaining.withUnsafeBytes {
                Darwin.write(descriptor, $0.baseAddress, $0.count)
            }
            if written < 0 {
                if errno == EINTR { continue }
                throw NSError(
                    domain: "MCPHostServerTests", code: Int(errno),
                    userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))]
                )
            }
            remaining = remaining.dropFirst(written)
        }
    }

    private static func posixPermissions(of url: URL) throws -> UInt16 {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            throw NSError(
                domain: "MCPHostServerTests", code: 0,
                userInfo: [NSLocalizedDescriptionKey: "no file at \(url.path)"]
            )
        }
        return status.st_mode & 0o7777
    }

    /// Retries `condition` until it holds. Polling rather than sleeping a fixed
    /// amount because the thing being waited for — an accept landing, a call being
    /// stamped — happens on another thread and has no deadline of its own.
    private static func eventually(
        timeout: TimeInterval,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("condition did not hold within \(timeout)s")
    }
}

// MARK: - Harness

/// A host on a socket inside a temp directory, with the pieces a test needs to
/// talk to it and to clean it up.
struct MCPHostHarness {
    let host: MCPHostServer
    let socketURL: URL
    let endpointDirectory: URL

    /// Starts a host over a stub context, and stops it when the test ends.
    ///
    /// `makeTemporaryDirectory` names the directory after the test, which is long
    /// enough to push the socket path past the 104 bytes `sockaddr_un.sun_path`
    /// holds on Darwin. The name here is short so the socket always fits.
    static func make(
        _ test: XCTestCase,
        socketName: String = "mcp.sock"
    ) throws -> MCPHostHarness {
        let directory = try test.makeTemporaryDirectory(prefix: "pm")
        let socketURL = directory.appendingPathComponent(socketName)
        let host = MCPHostServer(
            socketURL: socketURL,
            endpointDirectory: directory,
            context: StubMCPContext(auditDirectory: directory, settingsDirectory: directory)
        )
        let harness = MCPHostHarness(
            host: host, socketURL: socketURL, endpointDirectory: directory
        )
        // The `Task` is started from a background queue on purpose. A teardown block
        // runs on the main thread, and this one blocks it waiting: a `Task` started
        // there would be main-actor isolated, so `stop` could never reach the point
        // where it resumes — and every test would sit out this timeout before
        // passing.
        test.addTeardownBlock {
            let stopped = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInitiated).async {
                Task {
                    await host.stop()
                    stopped.signal()
                }
            }
            _ = stopped.wait(timeout: .now() + 30)
        }
        return harness
    }

    func start() throws {
        try host.start()
    }

    /// The token a real CLI would read: from the endpoint file, not from the host.
    var token: String {
        get throws {
            let endpoint = try XCTUnwrapHost(EndpointFileStore.read(directory: endpointDirectory))
            return endpoint.token
        }
    }

    /// Connects with the SDK's own `Client` over the SDK's `NetworkTransport`, on
    /// an `NWConnection` to the Unix socket.
    ///
    /// The connection is started and the handshake is written by hand first, because
    /// the handshake is not MCP: `NetworkTransport` starts the connection itself and
    /// offers no hook for a byte that has to precede everything it sends.
    func connectClient(timeout: TimeInterval = 20) async throws -> SocketSession {
        let connection = NWConnection(to: .unix(path: socketURL.path), using: .tcp)
        let outcome = SocketOutcome()
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: outcome.settle(.ready)
            case .failed(let error), .waiting(let error): outcome.settle(.failed(error))
            default: break
            }
        }
        connection.start(queue: .main)
        try await outcome.waitForReady(timeout: timeout)

        let handshake = Data(#"{"token":"\#(try token)"}"#.utf8) + Data([0x0A])
        connection.send(
            content: handshake,
            completion: .contentProcessed { error in
                if let error { outcome.settle(.failed(error)) }
                outcome.settleSend()
            }
        )
        try await outcome.waitForCompletion(timeout: timeout)

        let client = Client(name: "t", version: "1")
        // Heartbeats and reconnection are off because neither belongs in a test: a
        // heartbeat would put bytes on the wire the host never sends, and a
        // reconnect would hide a failure by retrying it.
        let transport = NetworkTransport(
            connection: connection,
            heartbeatConfig: .disabled,
            reconnectionConfig: .disabled
        )
        do {
            try await client.connect(transport: transport)
        } catch {
            connection.cancel()
            throw error
        }
        return SocketSession(client: client, connection: connection)
    }

    /// A plain POSIX connection, for the tests that are about what the host does
    /// with a client that never gets to speak MCP at all.
    func connectRawSocket() throws -> Int32 {
        try connectUnixSocket(at: socketURL.path)
    }
}

/// Connects a raw descriptor to a Unix socket, with no MCP and no handshake.
///
/// Hand-written rather than reusing the host's own `bind`/`connect` pair because
/// these tests are about what the host does with a descriptor it did not choose the
/// contents of. `socketpair` would be tidier but Darwin declares it variadically,
/// so it is not importable.
private func connectUnixSocket(at path: String) throws -> Int32 {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
        throw NSError(
            domain: "MCPHostServerTests", code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))]
        )
    }
    guard var address = try? UnixSocketBinding.socketAddress(path: path) else {
        close(descriptor)
        throw NSError(
            domain: "MCPHostServerTests", code: 0,
            userInfo: [NSLocalizedDescriptionKey: "cannot address the socket at \(path)"]
        )
    }
    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connected == 0 else {
        let code = errno
        close(descriptor)
        throw NSError(
            domain: "MCPHostServerTests", code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(code))]
        )
    }
    return descriptor
}

private func XCTUnwrapHost<T>(_ value: T?, _ message: String = "unwrapped") throws -> T {
    guard let value else {
        throw NSError(
            domain: "MCPHostServerTests", code: 0,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
    return value
}

/// A context over a stub provider, so a call over the socket cannot reach the
/// machine it runs on.
private struct StubMCPContext: MCPToolCalling {
    let auditDirectory: URL
    let settingsDirectory: URL

    func call(name: String, arguments: [String: String]) async -> ToolOutcome {
        await makeExecutor().execute(name: name, arguments: arguments)
    }

    private func makeExecutor() -> ToolExecutor {
        ToolExecutor(
            provider: StubProvider(),
            gate: PermissionGate(settings: MCPSettings(mode: .off), appRunning: false),
            audit: AuditLog(directory: auditDirectory),
            settingsDirectory: settingsDirectory
        )
    }
}

/// A read result handed back from a background queue. `@unchecked Sendable` because
/// the lock is what guards it.
private final class ReadOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: UnixSocket.ReadResult = .endOfFile

    func record(_ result: UnixSocket.ReadResult) { lock.withLock { stored = result } }
    var value: UnixSocket.ReadResult { lock.withLock { stored } }
}

/// One connected MCP client and the descriptor underneath it, so a test can close
/// the connection it made.
struct SocketSession {
    let client: Client
    let connection: NWConnection

    func cancel() { connection.cancel() }
}

/// How an `NWConnection` attempt ended. `.pending` is the state it starts in, and it
/// is what makes "the socket is not there yet" different from "the socket said no".
private enum SocketState {
    case pending
    case ready
    case failed(any Error)
}

/// A socket state that arrives later, from a callback, waited for without hanging an
/// `XCTestCase` expectation off it.
///
/// Polling rather than an expectation because `NWConnection` reports readiness on the
/// main queue: a test that blocked the main thread waiting for it would be waiting for
/// the thing that has to deliver it. `@unchecked Sendable` because the lock is the
/// only thing guarding the stored state.
private final class SocketOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: SocketState = .pending

    func settle(_ state: SocketState) { lock.withLock { stored = state } }

    /// The settled state, or a throw if nothing settled in time.
    func waitForReady(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            switch lock.withLock({ stored }) {
            case .ready: return
            case .failed(let error): throw error
            case .pending: try await Task.sleep(for: .milliseconds(10))
            }
        }
        throw NSError(
            domain: "MCPHostServerTests", code: 0,
            userInfo: [NSLocalizedDescriptionKey: "the socket never became ready"]
        )
    }

    /// Waits for a one-shot completion, such as a `send` finishing.
    func waitForCompletion(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if lock.withLock({ settledSend }) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(
            domain: "MCPHostServerTests", code: 0,
            userInfo: [NSLocalizedDescriptionKey: "the write never completed"]
        )
    }

    private var settledSend = false

    func settleSend() { lock.withLock { settledSend = true } }
}

/// What the host saw of `SO_NOSIGPIPE` on the descriptors it accepted.
///
/// Handed to the host's test-only observer, which is called from the accept
/// thread, so the results come back across a lock rather than through a
/// variable the test thread would have to hope was written yet.
private final class SIGPIPEObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Bool] = []

    func record(_ suppressed: Bool) { lock.withLock { results.append(suppressed) } }

    var count: Int { lock.withLock { results.count } }

    var allSuppressed: Bool { lock.withLock { !results.isEmpty && results.allSatisfy { $0 } } }
}
