// Reading token counts out of an agent's own session logs.
//
// One adapter per vendor. The isolation is the point: parsing one agent's private
// file format must not be able to break another's, and a new adapter must be
// addable without touching the record or the query surface.
//
// No adapter ships in this slice. The protocol and the outcome mapping are what
// phase C needs, and the fixture in the tests is a fixture — nothing here has been
// run against a real agent's log, and saying otherwise is the failure this whole
// design exists to prevent.

import Foundation

public enum TokenSourceError: Error, Hashable, Sendable {
    /// The file was read and its shape was not understood — the vendor changed it.
    /// Deliberately not a partial parse: a half-understood file that yields plausible
    /// numbers is worse than no file.
    case unrecognizedFormat
    case unreadable
}

/// Counts as they appear in a vendor's log, before conversion.
public struct RawAgentUsage: Hashable, Sendable {
    public let input: Int
    public let output: Int
    public let cacheRead: Int?
    public let reasoning: Int?
    public let modelID: String

    public init(input: Int, output: Int, cacheRead: Int?, reasoning: Int?, modelID: String) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.reasoning = reasoning
        self.modelID = modelID
    }
}

public protocol TokenSourceAdapter: Sendable {
    /// Stable name for this source, used in diagnostics.
    var identifier: String { get }

    /// The log file for a session, or nil when there is none. **Nil is normal**, not
    /// an error: most sessions have no readable log, and that must read as "no
    /// source" rather than as a failure.
    func locateSessionLog(for session: AgentSessionSnapshot) -> URL?

    /// Parses a located log. Throws `TokenSourceError.unrecognizedFormat` rather
    /// than returning partial counts.
    func parse(_ url: URL) throws -> RawAgentUsage
}

/// What an adapter run produced: a record to append, or a reason there is none.
public enum TokenSourceOutcome: Hashable, Sendable {
    case reported(TokenUsageRecord)
    case notReported(reason: UsageUnavailableReason)
}

/// Runs one adapter against one session and maps every failure onto a named
/// absence, so no caller has to interpret an error to know what it does not know.
public struct TokenSourceRunner: Sendable {
    private let adapter: any TokenSourceAdapter
    private let sessionID: UUID
    private let now: @Sendable () -> Date

    public init(
        adapter: any TokenSourceAdapter,
        sessionID: UUID,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.adapter = adapter
        self.sessionID = sessionID
        self.now = now
    }

    public func run(session: AgentSessionSnapshot) -> TokenSourceOutcome {
        guard let url = adapter.locateSessionLog(for: session) else {
            return .notReported(reason: .noSource)
        }
        do {
            let raw = try adapter.parse(url)
            return .reported(TokenUsageRecord(
                sessionID: sessionID,
                recordedAt: now(),
                input: raw.input,
                output: raw.output,
                cacheRead: raw.cacheRead,
                reasoning: raw.reasoning,
                modelID: raw.modelID,
                provenance: .parsedFromLog
            ))
        } catch TokenSourceError.unrecognizedFormat {
            return .notReported(reason: .unrecognizedFormat)
        } catch TokenSourceError.unreadable {
            return .notReported(reason: .logUnreadable)
        } catch {
            // An adapter throwing something of its own is still an absence, and
            // still must not become a number.
            return .notReported(reason: .logUnreadable)
        }
    }

    /// Convenience for the common case where the caller already has the session.
    public func run() -> TokenSourceOutcome {
        run(session: AgentSessionSnapshot(
            id: sessionID, peerPID: 0, clientName: adapter.identifier,
            clientVersion: nil, connectedAt: now(), endedAt: nil,
            usage: .notReported(reason: .noSource), cost: .noUsage
        ))
    }
}
