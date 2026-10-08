// The pass that actually asks.
//
// Everything else in this feature was reachable only from a test: the adapter parsed
// a real file, the runner mapped every outcome onto a named absence, and nothing ever
// called either. These tests are about the wiring — that a pass runs at all, that it
// touches the filesystem once, that what it finds is persisted, and that one failure
// among many does not take the rest with it.
import XCTest
import Foundation
@testable import PortmasterCore

/// Counts its own enumerations and parses.
///
/// **A counter rather than an assertion about the filesystem**, because "no walk
/// happened" is the claim that matters here and a spy is the only thing that can
/// establish it: an empty result proves nothing, since an enumeration over an empty
/// directory also yields nothing.
final class CountingTokenAdapter: TokenSourceAdapter, @unchecked Sendable {
    let identifier: String
    let candidates: [LogCandidate]
    /// What `parse` throws for a given file, by name. **A file that is not named parses
    /// normally**, so one refusal can be isolated from the files beside it — which is the
    /// case the poller has to survive, and the only way to reach
    /// `.unrecognizedFormat` as distinct from `.logUnreadable`.
    var parseFailures: [String: TokenSourceError] = [:]

    private let lock = NSLock()
    private var _logCandidatesCalls = 0
    private var _parsedNames: [String] = []

    init(identifier: String = "counting-agent", candidates: [LogCandidate]) {
        self.identifier = identifier
        self.candidates = candidates
    }

    var logCandidatesCalls: Int {
        lock.lock(); defer { lock.unlock() }
        return _logCandidatesCalls
    }

    /// Every file this adapter was asked to read, in the order it was asked.
    var parsedNames: [String] {
        lock.lock(); defer { lock.unlock() }
        return _parsedNames
    }

    func logCandidates() -> [LogCandidate] {
        lock.lock(); defer { lock.unlock() }
        _logCandidatesCalls += 1
        return candidates
    }

    func parse(_ url: URL) throws -> [RawAgentUsage] {
        lock.lock()
        _parsedNames.append(url.lastPathComponent)
        let failure = parseFailures[url.lastPathComponent]
        lock.unlock()
        if let failure { throw failure }
        return [
            RawAgentUsage(input: 100, output: 50, cacheRead: nil, reasoning: nil, modelID: "model-a"),
            RawAgentUsage(input: 200, output: 75, cacheRead: nil, reasoning: nil, modelID: "model-b"),
        ]
    }
}

final class AgentSourcePollerTests: XCTestCase {

    /// Wide enough that a file written "now" matches a session connected "now", and
    /// narrow enough that a deliberately-separated session's window excludes it.
    private let overlap: TimeInterval = 600

    private func makeStore() throws -> AgentSessionStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-poller-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try AgentSessionStore(storeURL: directory.appendingPathComponent("agent-sessions.sqlite"))
    }

    private func recordSession(_ store: AgentSessionStore, connectedAt: Date) throws -> UUID {
        let id = UUID()
        try store.recordSession(
            id: id, peerPID: 4242, clientName: "fixture", clientVersion: nil, connectedAt: connectedAt
        )
        return id
    }

    /// A conversation written between two instants. `to == from` is a conversation whose
    /// every line carries the same timestamp, which is what a `fileModification` fallback
    /// looks like and is enough for any matching assertion here.
    private func candidate(_ name: String, from: Date, to: Date? = nil) -> LogCandidate {
        LogCandidate(
            url: URL(fileURLWithPath: "/logs/\(name)"),
            interval: LogInterval(start: from, end: to ?? from, evidence: .lineTimestamps)
        )
    }

    // MARK: - No sessions means no walk

    /// **A machine with no MCP client ever connected must not stat every agent log on it
    /// once a minute to conclude there is nobody to attribute them to.** This is the
    /// common case for anyone who does not use an agent, and it is the whole reason the
    /// guard sits in front of the first source rather than after it.
    ///
    /// The spy is what makes this assertable: with a plain adapter, "no records" would
    /// look identical whether the walk happened over an empty list or never happened.
    /// Deleting the guard has to fail here.
    func testAPassWithNoSessionsAsksNoSource() throws {
        let store = try makeStore()
        let adapter = CountingTokenAdapter(candidates: [candidate("a.jsonl", from: Date())])

        let pass = AgentSourcePoller(store: store, adapters: [adapter], overlap: overlap)
            .pollOnce()

        XCTAssertEqual(adapter.logCandidatesCalls, 0, "no sessions, no filesystem walk")
        XCTAssertEqual(pass.sessionsConsidered, 0)
        XCTAssertEqual(pass.sourcesQueried, 0, "no session to ask about, so no source was asked")
        XCTAssertTrue(pass.records.isEmpty)
        // Nothing was attempted, so there is nothing to be absent about: an absence per
        // session would describe sessions that do not exist.
        XCTAssertTrue(pass.absences.isEmpty)
    }

    /// The mirror of the guard above: one session is enough to make the pass ask. A guard
    /// that refused everything would satisfy the previous test too.
    func testOneSessionIsEnoughToMakeThePassAsk() throws {
        let store = try makeStore()
        let now = Date()
        try recordSession(store, connectedAt: now)
        let adapter = CountingTokenAdapter(candidates: [candidate("a.jsonl", from: now)])

        let pass = AgentSourcePoller(store: store, adapters: [adapter], overlap: overlap)
            .pollOnce()

        XCTAssertEqual(adapter.logCandidatesCalls, 1)
        XCTAssertEqual(pass.sourcesQueried, 1)
        XCTAssertEqual(pass.sessionsConsidered, 1)
    }

    /// One ask per pass, whatever the session count. The shape this replaced asked the
    /// adapter per session, so three open sessions meant three directory reads to answer
    /// a question the first read had already answered.
    ///
    /// **And the figures it must not write are the point of the assertion.** Under the
    /// per-session rule these three sessions all contain the one live file, so all three
    /// matched it and the pass wrote six records — the same 100in + 50out and 200in + 75out
    /// three times over, three sessions each looking like it had done distinct work.
    /// `latestPerSegment` keys on `sessionID`, so the fold saw three plausible segments
    /// and priced all of them.
    func testThreeSessionsShareOneAskAndDoNotShareItsFigure() throws {
        let store = try makeStore()
        let now = Date()
        for offset in [-600.0, -300.0, 0.0] {
            try recordSession(store, connectedAt: now.addingTimeInterval(offset))
        }
        let adapter = CountingTokenAdapter(candidates: [candidate("a.jsonl", from: now)])

        let pass = AgentSourcePoller(store: store, adapters: [adapter], overlap: overlap)
            .pollOnce()

        XCTAssertEqual(pass.sessionsConsidered, 3)
        XCTAssertEqual(adapter.logCandidatesCalls, 1, "one ask per pass, not one per session")
        XCTAssertTrue(pass.records.isEmpty, "one log, three sessions: no figure for any of them")
        XCTAssertEqual(pass.absences.count, 3)
        XCTAssertEqual(Set(pass.absences.map(\.reason)), [.ambiguousMatch])

        for session in try store.sessions() {
            XCTAssertFalse(session.usage.isReported, "a contested log must leave no figure behind")
        }
    }

    // MARK: - What a pass persists

    /// One record per model the log attributed usage to, stamped with the session that
    /// was polled and reaching the store's own read.
    ///
    /// Read back through `store.sessions()` rather than through the returned pass, so
    /// the claim is that the figure is *in the store* — which is the only place anything
    /// downstream will ever look for it.
    func testAPassPersistsOneRecordPerParsedModel() throws {
        let store = try makeStore()
        let now = Date()
        let sessionID = try recordSession(store, connectedAt: now)
        let adapter = CountingTokenAdapter(candidates: [candidate("a.jsonl", from: now)])

        let pass = AgentSourcePoller(store: store, adapters: [adapter], overlap: overlap)
            .pollOnce()

        XCTAssertEqual(pass.records.count, 2, "one record per model, never one collapsed total")
        XCTAssertEqual(pass.records.map(\.modelID), ["model-a", "model-b"])
        XCTAssertTrue(pass.records.allSatisfy { $0.sessionID == sessionID })
        XCTAssertTrue(pass.records.allSatisfy { $0.provenance == .parsedFromLog })

        let stored = try XCTUnwrap(try store.sessions().first)
        guard case .reported(let segments) = stored.usage else {
            return XCTFail("expected a figure, got \(stored.usage)")
        }
        XCTAssertEqual(segments.map(\.modelID), ["model-a", "model-b"])
        XCTAssertEqual(segments.first?.input, 100)
        XCTAssertEqual(segments.last?.output, 75)
    }

    /// Running the poll twice must not double the session's tokens.
    ///
    /// The fold is latest-per-segment, so this *should* hold — which is exactly why it
    /// is asserted rather than assumed. "Should hold" is how a store that appended twice
    /// and folded once kept looking fine until someone read the cost from the raw rows.
    func testPollingTwiceDoesNotDoubleCount() throws {
        let store = try makeStore()
        let now = Date()
        try recordSession(store, connectedAt: now)
        let adapter = CountingTokenAdapter(candidates: [candidate("a.jsonl", from: now)])
        let poller = AgentSourcePoller(store: store, adapters: [adapter], overlap: overlap)

        poller.pollOnce()
        let second = poller.pollOnce()

        XCTAssertEqual(second.records.count, 2, "the second pass re-read the same cumulative log")
        let stored = try XCTUnwrap(try store.sessions().first)
        guard case .reported(let segments) = stored.usage else {
            return XCTFail("expected a figure, got \(stored.usage)")
        }
        // Two models, one reading each — not four segments and not doubled counts.
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments.first?.input, 100)
        XCTAssertEqual(segments.first?.output, 50)
        XCTAssertEqual(segments.last?.input, 200)
        XCTAssertEqual(segments.last?.output, 75)
    }

    /// **Two conversations and two connections, one each, both counted.** The
    /// counterweight to the contention test above: a rule that refused whenever the store
    /// held more than one connection would be refusing *here*, and would be leaving the
    /// ordinary case — an agent talking to Portmaster twice in an afternoon — uncounted.
    ///
    /// The conversations are hours apart and each connection sits inside one of them,
    /// against a ten-minute tolerance, so no padding crosses between them.
    func testTwoConnectionsInTwoSeparateConversationsBothGetTheirFigure() throws {
        let store = try makeStore()
        let now = Date()
        let older = try recordSession(store, connectedAt: now.addingTimeInterval(-60 * 60 * 7))
        let newer = try recordSession(store, connectedAt: now.addingTimeInterval(-60 * 60))
        let adapter = CountingTokenAdapter(candidates: [
            candidate(
                "older.jsonl",
                from: now.addingTimeInterval(-60 * 60 * 8),
                to: now.addingTimeInterval(-60 * 60 * 6)
            ),
            candidate(
                "newer.jsonl",
                from: now.addingTimeInterval(-60 * 60 * 2),
                to: now
            ),
        ])

        let pass = AgentSourcePoller(store: store, adapters: [adapter], overlap: overlap)
            .pollOnce()

        XCTAssertEqual(pass.records.count, 4, "two models in each of two conversations")
        XCTAssertEqual(pass.records.filter { $0.sessionID == older }.count, 2)
        XCTAssertEqual(pass.records.filter { $0.sessionID == newer }.count, 2)
        XCTAssertTrue(pass.absences.isEmpty)

        for session in try store.sessions() {
            guard case .reported(let segments) = session.usage else {
                return XCTFail("every connection here is inside its own conversation")
            }
            XCTAssertEqual(segments.map(\.modelID), ["model-a", "model-b"])
        }
    }

    // MARK: - A failure among many

    /// **One unreadable file must not abandon the rest.** Two sources over one session:
    /// the first refuses its file, the second has a perfectly good one. If the refusal
    /// aborted the pass, the second source would never be asked — and the pass would then
    /// report "nothing here" for a session it never finished looking at.
    func testOneAdapterFailingOnItsFileDoesNotAbortTheOthers() throws {
        let store = try makeStore()
        let now = Date()
        let sessionID = try recordSession(store, connectedAt: now)
        let broken = CountingTokenAdapter(
            identifier: "broken-agent", candidates: [candidate("broken.jsonl", from: now)]
        )
        broken.parseFailures = ["broken.jsonl": .unreadable]
        let working = CountingTokenAdapter(
            identifier: "working-agent", candidates: [candidate("live.jsonl", from: now)]
        )

        let pass = AgentSourcePoller(store: store, adapters: [broken, working], overlap: overlap)
            .pollOnce()

        XCTAssertEqual(broken.parsedNames, ["broken.jsonl"], "the broken source was read and refused")
        XCTAssertEqual(working.parsedNames, ["live.jsonl"], "the source after it was still read")
        XCTAssertEqual(pass.absences, [
            AgentSourceAbsence(sessionID: sessionID, source: "broken-agent", reason: .logUnreadable)
        ])
        XCTAssertEqual(pass.records.count, 2, "the readable source's models still reached the store")
        XCTAssertTrue(pass.failures.isEmpty, "a parse refusal is an absence, not a pass failure")
    }

    /// The same rule one level down and outward: a refusal must not stop the pass for the
    /// **next adapter** *or* the **next session**. Both are asserted together because a
    /// pass is one loop over both, and a `throw` out of the inner body loses both.
    ///
    /// Built so the refusal is reachable at all: the log sits where only the older
    /// session's window can see it, because a log two sessions share is contested and
    /// never parsed in the first place.
    func testARefusalDoesNotStopTheNextAdapterOrTheNextSession() throws {
        let store = try makeStore()
        let now = Date()
        let older = try recordSession(store, connectedAt: now.addingTimeInterval(-60 * 60 * 6))
        let newer = try recordSession(store, connectedAt: now.addingTimeInterval(-60 * 60 * 2))
        let oldLog = candidate(
            "old.jsonl",
            from: now.addingTimeInterval(-60 * 60 * 7),
            to: now.addingTimeInterval(-60 * 60 * 5)
        )
        let broken = CountingTokenAdapter(identifier: "broken-agent", candidates: [oldLog])
        broken.parseFailures = ["old.jsonl": .unreadable]
        let silent = CountingTokenAdapter(identifier: "silent-agent", candidates: [])

        let pass = AgentSourcePoller(store: store, adapters: [broken, silent], overlap: overlap)
            .pollOnce()

        XCTAssertEqual(broken.parsedNames, ["old.jsonl"])
        XCTAssertEqual(silent.logCandidatesCalls, 1, "the next adapter was still asked")
        XCTAssertEqual(
            Set(pass.absences.map(\.sessionID)), [older, newer],
            "the next session was still polled, and reported its own absence"
        )
        XCTAssertTrue(pass.records.isEmpty)
    }

    /// One source's refusal is that source's and never another's: a silent source must
    /// not make the pass look empty for a source that did find something.
    func testOneAdapterFindingNothingDoesNotSilenceAnother() throws {
        let store = try makeStore()
        let now = Date()
        let sessionID = try recordSession(store, connectedAt: now)
        let silent = CountingTokenAdapter(
            identifier: "silent-agent",
            candidates: [candidate(
                "old.jsonl",
                from: Date(timeIntervalSince1970: 0),
                to: Date(timeIntervalSince1970: 60)
            )]
        )
        let talking = CountingTokenAdapter(
            identifier: "talking-agent", candidates: [candidate("live.jsonl", from: now)]
        )

        let pass = AgentSourcePoller(store: store, adapters: [silent, talking], overlap: overlap)
            .pollOnce()

        XCTAssertEqual(pass.sourcesQueried, 2, "one ask per adapter, per pass")
        XCTAssertEqual(pass.absences, [
            AgentSourceAbsence(sessionID: sessionID, source: "silent-agent", reason: .noSource)
        ])
        XCTAssertEqual(talking.parsedNames, ["live.jsonl"])
        XCTAssertEqual(pass.records.count, 2)
    }

    /// **Two logs for one session is an absence, and it reaches the pass as one.** The
    /// reason a caller reads to explain a missing figure has to be the same reason the
    /// matcher reached — a pass that reported "no source" here would send the user
    /// looking for a log that exists and was simply not attributable.
    func testTwoLogsForOneSessionReachThePassAsAnAbsence() throws {
        let store = try makeStore()
        let now = Date()
        let sessionID = try recordSession(store, connectedAt: now)
        let adapter = CountingTokenAdapter(candidates: [
            candidate("agent-a.jsonl", from: now),
            candidate("agent-b.jsonl", from: now),
        ])

        let pass = AgentSourcePoller(store: store, adapters: [adapter], overlap: overlap)
            .pollOnce()

        XCTAssertTrue(pass.records.isEmpty)
        XCTAssertEqual(pass.absences, [
            AgentSourceAbsence(sessionID: sessionID, source: "counting-agent", reason: .ambiguousMatch)
        ])
    }

    // MARK: - An unreadable shape is a named absence, not a zero

    /// **A log whose shape changed reports `unrecognizedFormat`** — the case a user
    /// actually hits, when the vendor changes their format and every session's figure
    /// silently disappears. It is a different message from "the file would not open", and
    /// telling them the log was unreadable sends them to check file permissions instead
    /// of to wait for a release that understands the new shape.
    func testAChangedLogShapeIsNamedUnrecognizedFormat() throws {
        let store = try makeStore()
        let now = Date()
        let sessionID = try recordSession(store, connectedAt: now)
        let adapter = CountingTokenAdapter(candidates: [candidate("changed.jsonl", from: now)])
        adapter.parseFailures = ["changed.jsonl": .unrecognizedFormat]

        let pass = AgentSourcePoller(store: store, adapters: [adapter], overlap: overlap)
            .pollOnce()

        XCTAssertTrue(pass.records.isEmpty)
        XCTAssertEqual(pass.absences, [
            AgentSourceAbsence(
                sessionID: sessionID, source: "counting-agent", reason: .unrecognizedFormat
            )
        ])
        let stored = try XCTUnwrap(try store.sessions().first)
        XCTAssertFalse(stored.usage.isReported, "nothing read must not become a figure of zero")
    }

    /// The same refusal for a file that will not open, which is a different fact about
    /// the machine and gets its own word.
    func testAnUnreadableLogIsNamedLogUnreadable() throws {
        let store = try makeStore()
        let now = Date()
        let sessionID = try recordSession(store, connectedAt: now)
        let adapter = CountingTokenAdapter(candidates: [candidate("locked.jsonl", from: now)])
        adapter.parseFailures = ["locked.jsonl": .unreadable]

        let pass = AgentSourcePoller(store: store, adapters: [adapter], overlap: overlap)
            .pollOnce()

        XCTAssertEqual(pass.absences.map(\.reason), [.logUnreadable])
        XCTAssertEqual(pass.absences.first?.sessionID, sessionID)
        let stored = try XCTUnwrap(try store.sessions().first)
        XCTAssertFalse(stored.usage.isReported)
    }
}