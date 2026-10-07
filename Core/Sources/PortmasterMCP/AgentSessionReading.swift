// Reading agent sessions for the MCP surface.
//
// Split out because both providers need it and neither owns it: the app-hosted
// provider already holds a long-lived store (opened by `AppModel`, passed in), and
// the stdio provider has no app to ask. Sharing the read means the two cannot
// drift on how a session is shaped or on what an unreadable store says.
//
// This is READ-ONLY by design, and the asymmetry with writing is deliberate. The
// CLI does not *write* sessions: the process receiving a report on that path would
// be `portmaster-mcp` itself, so a row would file an agent's tokens against
// Portmaster. Reading is the safe direction — the app is the only writer, and a
// reader sees what the writer committed, exactly as `StoreHistoryReading` does for
// history.

import Foundation
import PortmasterCore

/// What a sessions read produced, including the case where it could not run.
public struct AgentSessionReading: Sendable {
    public let sessions: [AgentSessionSnapshot]
    /// False when the store would not open. Distinct from `sessions.isEmpty`:
    /// one means "no sessions recorded", the other means "nothing could be read".
    public let storeAvailable: Bool
    /// Why the store was unavailable. Never nil when `storeAvailable` is false.
    public let note: String?

    public init(
        sessions: [AgentSessionSnapshot], storeAvailable: Bool, note: String? = nil
    ) {
        self.sessions = sessions
        self.storeAvailable = storeAvailable
        self.note = note
    }

    public static func unavailable(_ note: String) -> AgentSessionReading {
        AgentSessionReading(sessions: [], storeAvailable: false, note: note)
    }
}

/// Something that can produce a sessions reading, or say why it cannot.
public protocol AgentSessionReadingSource: Sendable {
    func sessions(
        limit: Int, openSessionIDs: Set<UUID>
    ) -> AgentSessionReading
}

/// Reads sessions from an already-open store.
public struct StoreAgentSessionReading: AgentSessionReadingSource {
    private let store: AgentSessionStore

    public init(store: AgentSessionStore) {
        self.store = store
    }

    public func sessions(
        limit: Int, openSessionIDs: Set<UUID>
    ) -> AgentSessionReading {
        // `openSessionIDs` is deliberately unused here. Marking a session open is
        // the caller's job — it owns the live set, and the store does not know it.
        // The parameter exists on the protocol so a source that *can* observe
        // liveness (the app host) may use it, and so neither provider has to
        // answer a question about connections it cannot see.
        do {
            // Newest first, which means **sorting**: the store hands back rows
            // oldest-first (`sessions()` sorts ascending by `connectedAt`), and
            // `suffix` preserves the order it was given. Taking a suffix alone
            // would page the newest N while still reading oldest-first within the
            // page, so the first row a caller saw would be the oldest of the set.
            let newestFirst = try store.sessions().reversed()
            return AgentSessionReading(
                sessions: Array(newestFirst.prefix(limit)),
                storeAvailable: true
            )
        } catch {
            return .unavailable(AgentSessionReadingFactory.readFailedMessage)
        }
    }
}

/// Stands in when the store would not open.
public struct UnavailableAgentSessionReading: AgentSessionReadingSource {
    private let message: String

    public init(message: String = AgentSessionReadingFactory.unavailableMessage) {
        self.message = message
    }

    public func sessions(limit: Int, openSessionIDs: Set<UUID>) -> AgentSessionReading {
        .unavailable(message)
    }
}

public enum AgentSessionReadingFactory {
    /// Opens the canonical store on first use, or a reading that says why it could not.
    ///
    /// Lazy for the same reason history is: most tool calls never ask a session
    /// question, and opening a database also creates the directory it lives in — a
    /// write to the user's Application Support directory they did not ask for.
    public static func openDefault() -> any AgentSessionReadingSource {
        guard let store = try? AgentSessionStore(storeURL: nil) else {
            return UnavailableAgentSessionReading()
        }
        return StoreAgentSessionReading(store: store)
    }

    /// `MCPToolError` is documented as safe to show a caller verbatim and these
    /// reach the audit log on disk, so the location is written `~`-relative —
    /// an absolute path would put the account name in both.
    public static let unavailableMessage =
        "Could not open the local agent session database in "
        + "~/Library/Application Support/Portmaster/."

    public static let readFailedMessage =
        "Could not read the local agent session database in "
        + "~/Library/Application Support/Portmaster/."
}
/// Opens the session store once, lazily, on the first session question.
///
/// The same shape and the same reason as `LazyHistory`: most tool calls never ask
/// a session question, and opening a database also creates the directory it lives
/// in. `@unchecked Sendable` because the lock is what makes the memo safe — the
/// same trade `LazyHistory` makes, for the same reason.
final class LazyAgentSessions: @unchecked Sendable {
    private let lock = NSLock()
    private let factory: @Sendable () -> any AgentSessionReadingSource
    private var reading: (any AgentSessionReadingSource)?

    init(_ factory: @escaping @Sendable () -> any AgentSessionReadingSource) {
        self.factory = factory
    }

    func get() -> any AgentSessionReadingSource {
        lock.lock()
        defer { lock.unlock() }
        if let reading { return reading }
        let opened = factory()
        reading = opened
        return opened
    }
}
