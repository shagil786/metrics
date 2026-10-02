import Foundation

/// Outcome of a `PermissionGate` check. A `deny` carries a user-facing reason so
/// the tool layer can surface it verbatim and record it in the audit log.
public enum GateDecision: Equatable, Sendable {
    case allow
    case deny(reason: String)
}

/// Default-deny gate for MCP tool calls.
///
/// Every mutation (quit app, stop container/project, change a preference) passes
/// through `decide`, and only `allowSession` can open that path. Reads are
/// always allowed because they observe state without changing it.
///
/// Slice 1 has no in-app confirmation channel, so `confirmEach` always denies:
/// the app cannot approve a prompt it is never asked to show. Task 8 documents
/// the slice-2 behavior that lets the running app prompt the user.
public struct PermissionGate: Sendable {
    private let settings: MCPSettings
    private let appRunning: Bool

    /// - Parameters:
    ///   - settings: the persisted mutation policy; re-read by the caller to pick
    ///     up a mode change without restarting the server.
    ///   - appRunning: whether the Portmaster UI is currently running. Snapshot
    ///     at construction — liveness is the caller's to observe.
    public init(settings: MCPSettings, appRunning: Bool) {
        self.settings = settings
        self.appRunning = appRunning
    }

    /// Returns `.allow` for reads, and for mutations only under `allowSession`
    /// while Portmaster is running. Every other path denies with a reason the
    /// user can act on.
    public func decide(isMutation: Bool) -> GateDecision {
        guard isMutation else { return .allow }

        switch settings.mode {
        case .off:
            return .deny(reason: "MCP mutations are disabled in Portmaster settings.")
        case .confirmEach:
            // Slice 1 cannot prompt, so the honest answer is always no. The
            // reason names the missing capability rather than the chosen mode.
            return .deny(reason: "Portmaster must be open to approve this action.")
        case .allowSession:
            guard appRunning else {
                return .deny(reason: "Session grants apply only while Portmaster is running.")
            }
            return .allow
        }
    }
}
