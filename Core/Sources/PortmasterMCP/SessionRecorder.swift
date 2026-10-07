// Recording what an agent says about itself.
//
// `report_usage` is deliberately not a mutation. It is a declaration, not an
// action on the machine: it cannot quit a process, change a setting or read
// anything. Requiring a confirmation click for it would mean a click that carries
// no risk, and teaching people to click through prompts that do not matter is how
// prompts that do matter get dismissed.
//
// It is still a write. It is scoped to the caller's own accounting and it only
// appends, which is the boundary that keeps it safe.

import Foundation
import PortmasterCore

public protocol SessionRecording: Sendable {
    /// Checks that this recorder can record at all, before a report is attributed to
    /// a session.
    ///
    /// Its own step, and it is first, because **the two refusals are not equally
    /// informative and the order used to be arbitrary.** `ToolExecutor` also refuses a
    /// report with no session id, and whether that check ran before this one decided
    /// which reason the caller read. "There is nowhere to record" is the more
    /// fundamental absence and the one worth acting on: a caller told only "I cannot
    /// tell which session this is" cannot do anything with that, while the recorder
    /// refusal can name what to change. So the recorder answers first, and a recorder
    /// that is fine being called stays silent here.
    ///
    /// The default is the "fine" case, so adding a recorder does not have to
    /// implement this to be usable.
    func requireAvailable() throws

    /// Appends one self-reported usage observation against a session the caller
    /// already owns. Returns a sentence the caller can hand back to the agent, so a
    /// refusal and a success are both legible.
    ///
    /// `sessionID` names an existing session; the recorder never creates one. See
    /// `StoreSessionRecorder`.
    func record(
        sessionID: UUID,
        input: Int, output: Int, cacheRead: Int?, reasoning: Int?, modelID: String
    ) throws -> String
}

extension SessionRecording {
    /// Available by default: a recorder that cannot record says so by overriding this.
    public func requireAvailable() throws {}
}

/// Writes into the SwiftData store. Fails loudly rather than swallowing: a report
/// that vanishes would leave the session reading `notReported` with no way to tell
/// a lost write from an agent that never reported.
///
/// **Appends only; it never writes the session row.** The caller owns that row's
/// identity — peer pid, client name, client version, connect time — and knows all
/// four. `AgentSessionStore.recordSession` is an upsert that overwrites, so writing
/// it from here with anything less than the real values would reset the pid to `0`
/// and the client name to `nil` on the first report of a session the connection
/// layer had already described correctly. `clientName` and `clientVersion` were
/// removed from `record` for the same reason: they exist only to populate that row,
/// and a recorder that no longer writes the row has no use for them.
public struct StoreSessionRecorder: SessionRecording {
    private let store: AgentSessionStore

    public init(store: AgentSessionStore) {
        self.store = store
    }

    /// Available — and saying so with nothing is the point: a refusal here would be a
    /// claim about *this* report's session id, which `ToolExecutor` checks separately
    /// and better, because it is the one that has the id in hand.
    public func requireAvailable() throws {}

    public func record(
        sessionID: UUID,
        input: Int, output: Int, cacheRead: Int?, reasoning: Int?, modelID: String
    ) throws -> String {
        try store.recordUsage(TokenUsageRecord(
            sessionID: sessionID,
            recordedAt: Date(),
            input: input, output: output,
            cacheRead: cacheRead, reasoning: reasoning,
            modelID: modelID,
            provenance: .selfReported
        ))
        try store.flush()
        return "Recorded \(input) input and \(output) output tokens for \(modelID)."
    }
}

/// Used when no store is wired. Reports are refused with a reason rather than
/// accepted and dropped — an agent told "recorded" when nothing was is worse than
/// one told it cannot report.
public struct UnavailableSessionRecorder: SessionRecording {
    private let message: String

    /// - Parameter message: why there is nowhere to record. The default names the
    ///   absence; a caller that knows *why* passes its own, because "no store" and
    ///   "no app to own the store" send the reader to different places. The default
    ///   exists so a caller with nothing to add cannot accidentally invent a reason.
    public init(
        message: String = "Portmaster has no session store available, so this report was not recorded."
    ) {
        self.message = message
    }

    /// Refuses here rather than in `record`, so the reason is given **before** a
    /// report is attributed to a session it has nowhere to store. See
    /// `SessionRecording.requireAvailable`.
    public func requireAvailable() throws {
        throw MCPToolError(message: message)
    }

    public func record(
        sessionID: UUID,
        input: Int, output: Int, cacheRead: Int?, reasoning: Int?, modelID: String
    ) throws -> String {
        throw MCPToolError(message: message)
    }
}
