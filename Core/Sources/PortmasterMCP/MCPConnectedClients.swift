// MCPConnectedClients: who is connected, and what Settings shows about them.
//
// Its own file because this is the one part of the host that is about *presentation*
// rather than transport. Task 6 and Task 9 add settings rows and a menu; none of that
// belongs in the file that owns `accept`.

import Foundation

// MARK: - The row

/// One authenticated client, as Settings shows it.
///
/// Deliberately four fields. The token is what makes this connection legitimate, and
/// Settings must never be one more place it can be read from — so a client is
/// identified by who it is and when it acted, and nothing else.
public struct MCPConnectedClient: Identifiable, Sendable {
    /// Identifies the *connection*, and is unique.
    ///
    /// Not the peer pid, which cannot be: an agent that opens two connections to
    /// answer two questions is one process with two pids' worth of intent, and giving
    /// both the same `id` makes `Identifiable` a lie that a SwiftUI `List` acts on by
    /// collapsing the rows. One pid may back several ids; an id may outlive its pid if
    /// the process exits while the socket is still open.
    public let id: UUID
    /// The peer process, for display. 0 when the kernel will not say — `LOCAL_PEERPID`
    /// is a `getsockopt` that can simply fail. A client that cannot be named is still
    /// listed, because "something is connected" is the useful half of this row.
    public let pid: pid_t
    public let connectedAt: Date
    /// When this client last *called a tool*. `initialize` and `tools/list` do not
    /// count: a client that connected and asked nothing has not called anything.
    public var lastCallAt: Date?

    public init(id: UUID, pid: pid_t, connectedAt: Date, lastCallAt: Date? = nil) {
        self.id = id
        self.pid = pid
        self.connectedAt = connectedAt
        self.lastCallAt = lastCallAt
    }
}

// MARK: - The registry

/// One live connection: who it is, its descriptor (so shutdown can reach it), and when
/// it last called.
///
/// Self-contained on purpose — it owns its own lock and stamps itself, so recording a
/// call never has to reach back into the host. A callback from here into the host that
/// then asked this to record again is a cycle, and cycles on a tool-call path are not
/// something to debug under load.
final class ClientConnection: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: MCPConnectedClient
    let socket: UnixSocket

    init(id: UUID, pid: pid_t, socket: UnixSocket) {
        self.socket = socket
        self.stored = MCPConnectedClient(id: id, pid: pid, connectedAt: Date())
    }

    var client: MCPConnectedClient { lock.withLock { stored } }

    func recordCall() { lock.withLock { stored.lastCallAt = Date() } }
}

/// How many sessions may be open at once, and why that is the bound.
///
/// `listen(16)` bounds the backlog of connections waiting to be accepted, not the
/// number being served: each session costs a descriptor, a task and a reader thread, so
/// without a cap a client that opens sockets and authenticates would grow the host until
/// the machine noticed.
///
/// An idle deadline was the other candidate and was rejected. A dead connection cleans
/// itself up — its `read` returns EOF and the session ends — so what needs protecting
/// against is *concurrent* sessions, not old ones. An idle timeout would kill a
/// legitimate long-running agent session, which is the normal case for this client, and
/// save nothing.
enum SessionLimit {
    static let maximum = 32
}

/// The authenticated connections a host is currently serving, and whether it is still
/// willing to accept any.
///
/// **Admission and shutdown contend on this one lock**, which is the whole reason the
/// registry holds a `closed` flag rather than the host checking its own `running` and
/// then calling in. Those are two locks, and between them sits a window: a connection
/// accepted before `stop()` can be sitting in a ten-second handshake read, so
/// `stop()` finishes its snapshot, returns, and *then* the handshake completes and the
/// session starts on a descriptor nothing will ever close. Checking a flag and then
/// adding under a different lock cannot close that window; deciding both under one lock
/// can.
///
/// Lock order: the host's lock may be held while this one is taken, never the reverse —
/// nothing reachable from here takes the host's lock. `ClientConnection` is a leaf
/// beneath both, which is why its own lock can never deadlock against either.
final class ClientRegistry: @unchecked Sendable {

    /// Why a connection was not admitted, so the caller can log which it was. A single
    /// boolean would conflate "the host is shutting down" with "the host is full", and
    /// those need different words: one is expected during quit, the other is a bug
    /// report.
    enum Admission {
        case admitted
        case hostClosed
        case atCapacity
    }

    private let lock = NSLock()
    private var connections: [UUID: ClientConnection] = [:]
    private var closed = false

    /// Admits `connection` if the host is still accepting and there is room.
    ///
    /// Checked and taken in one step, for the same reason as the `closed` flag above,
    /// and for the ordinary one too: as two calls it is a race, two connections accepted
    /// at the same moment both see 31 sessions and both are admitted, and a bound that
    /// is only usually true is not a bound.
    func add(_ connection: ClientConnection, ifUnder limit: Int) -> Admission {
        lock.withLock {
            guard !closed else { return .hostClosed }
            guard connections.count < limit else { return .atCapacity }
            connections[connection.client.id] = connection
            return .admitted
        }
    }

    func remove(id: UUID) {
        lock.withLock { _ = connections.removeValue(forKey: id) }
    }

    /// Everything currently connected, oldest first.
    func clients() -> [MCPConnectedClient] {
        lock.withLock {
            connections.values.map(\.client).sorted { $0.connectedAt < $1.connectedAt }
        }
    }

    /// Stops accepting, and takes out everything admitted so far, in one step.
    ///
    /// Atomic with `add` on purpose. Because the flag and the snapshot are taken under
    /// the same lock, there is no point at which a session can be admitted into a
    /// registry whose contents shutdown has already taken: a connection is either in
    /// what this returns, or its `add` returns `.hostClosed` and it closes its own
    /// socket. A re-snapshot-until-empty loop cannot promise that, because "empty" and
    /// "nothing more can arrive" are two different observations.
    func closeAndTakeAll() -> [ClientConnection] {
        lock.withLock {
            closed = true
            let live = Array(connections.values)
            connections.removeAll()
            return live
        }
    }
}

// MARK: - Recording

/// Stamps a connection's `lastCallAt` every time an executor is asked for.
///
/// The stamp is the point, and it is exact: `MCPCallContext.makeExecutor` is called
/// once per `tools/call` and never once per process, so this fires for tool calls and
/// for nothing else. No slice-1 wiring is changed to arrange it.
struct RecordingContext: MCPCallContext {
    let base: any MCPCallContext
    let onCall: @Sendable () -> Void

    func makeExecutor() -> ToolExecutor {
        onCall()
        return base.makeExecutor()
    }
}
