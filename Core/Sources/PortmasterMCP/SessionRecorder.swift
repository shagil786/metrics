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
    /// Appends one self-reported usage observation. Returns a sentence the caller
    /// can hand back to the agent, so a refusal and a success are both legible.
    func record(
        sessionID: UUID?, clientName: String?, clientVersion: String?,
        input: Int, output: Int, cacheRead: Int?, reasoning: Int?, modelID: String
    ) throws -> String
}

/// Writes into the SwiftData store. Fails loudly rather than swallowing: a report
/// that vanishes would leave the session reading `notReported` with no way to tell
/// a lost write from an agent that never reported.
public struct StoreSessionRecorder: SessionRecording {
    private let store: AgentSessionStore

    public init(store: AgentSessionStore) {
        self.store = store
    }

    public func record(
        sessionID: UUID?, clientName: String?, clientVersion: String?,
        input: Int, output: Int, cacheRead: Int?, reasoning: Int?, modelID: String
    ) throws -> String {
        let id = sessionID ?? UUID()
        // The session row is only written when a session id was supplied. A usage
        // record for an id no session row names is unreachable through every
        // session-scoped read, so an unattributed report is a caller that could
        // name its own session and did not.
        if let sessionID {
            try store.recordSession(
                id: sessionID,
                peerPID: 0,
                clientName: clientName,
                clientVersion: clientVersion,
                connectedAt: Date()
            )
        }
        try store.recordUsage(TokenUsageRecord(
            sessionID: id,
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
    public init() {}

    public func record(
        sessionID: UUID?, clientName: String?, clientVersion: String?,
        input: Int, output: Int, cacheRead: Int?, reasoning: Int?, modelID: String
    ) throws -> String {
        throw MCPToolError(
            message: "Portmaster has no session store available, so this report was not recorded."
        )
    }
}
