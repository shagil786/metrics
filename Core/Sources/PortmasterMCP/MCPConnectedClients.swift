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

/// The authenticated connections a host is currently serving.
///
/// Owns its own lock so the host's lock is never held while a connection's lock is
/// taken in the other order; `ClientConnection` is a leaf and this is not, which is the
/// only ordering that cannot deadlock.
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

final class ClientRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var connections: [UUID: ClientConnection] = [:]

    /// Live sessions. Doubles as the shutdown's work list.
    var count: Int { lock.withLock { connections.count } }

    /// Admits `connection` if there is room, and records it.
    ///
    /// Checked and taken in one step on purpose. As two calls it would be a race: two
    /// connections accepted at the same moment could both see 31 sessions and both be
    /// admitted, so the limit would be a suggestion. The limit is not security — the
    /// token is — but a bound that is only usually true is not a bound.
    func add(_ connection: ClientConnection, ifUnder limit: Int) -> Bool {
        lock.withLock {
            guard connections.count < limit else { return false }
            connections[connection.client.id] = connection
            return true
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

    /// Every live connection's descriptor, for shutdown to close.
    func allSockets() -> [UnixSocket] {
        lock.withLock { connections.values.map(\.socket) }
    }

    func removeAll() {
        lock.withLock { connections.removeAll() }
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
