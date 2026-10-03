// MCPDiagnostics: one place the MCP host says what went wrong.
//
// This feature's entire failure surface, as a user sees it, is "the CLI said no such
// host". Without a log line, that is undiagnosable without attaching a debugger to a
// GUI app. So a failed connection is logged — with the peer pid, and never the token.
//
// The unified log rather than stderr: stderr from a bundled app goes to a terminal
// nobody opened, whereas `log show --predicate subsystem` finds it after the fact.
// Not swift-log either, because its default handler writes to **stdout**, which on
// this project's stdio transport is the JSON-RPC channel — a diagnostic on stdout is a
// line a client will try to parse.

import Foundation
import os

/// Severity is deliberately uniform. These are not errors in Portmaster: a client with
/// a stale token, or a port scanner, is not something the user did wrong, and logging
/// them at `.error` would train everyone to ignore this subsystem.
enum MCPDiagnostics {
    private static let log = Logger(
        subsystem: "app.portmaster",
        category: "mcp-host"
    )

    /// Something the host could not do. `detail` must never contain the endpoint token.
    ///
    /// Autoclosured so a caller pays nothing for the string on the paths that are fine —
    /// which, for a socket that sits idle for hours, is nearly all of them.
    static func hostFailure(_ message: String, detail: @autoclosure () -> String) {
        let reason = detail()
        log.info("\(message, privacy: .public): \(reason, privacy: .public)")
    }

    /// A client was refused. Silence on the wire, a line here.
    ///
    /// The reason is a fixed vocabulary rather than anything derived from what the
    /// client sent: a rejection that quotes the offending bytes is a rejection that
    /// can put a token in the unified log, where it outlives the connection.
    static func clientRefused(_ reason: RefusalReason, pid: pid_t) {
        log.info("refused a client (pid \(pid, privacy: .public)): \(reason.rawValue, privacy: .public)")
    }

    enum RefusalReason: String {
        case noHandshake = "sent no handshake"
        case wrongToken = "presented the wrong token"
        case malformedHandshake = "sent a handshake that is not a handshake"
        case handshakeTimedOut = "did not present a handshake in time"
        case handshakeFailed = "had its handshake read fail"
        case handshakeTooLarge = "sent a handshake larger than a handshake can be"
        case tooManySessions = "was refused because too many sessions are open"
        case notRunning = "connected to a host that was shutting down"
    }
}
