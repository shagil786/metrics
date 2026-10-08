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
    /// Files this adapter refuses to parse, by name.
    var failingNames: Set<String> = []

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
        let refusing = failingNames.contains(url.lastPathComponent)
        lock.unlock()
        if refusing {
            throw TokenSourceError.unreadable
        }
        return [
            RawAgentUsage(input: 100, output: 50, cacheRead: nil, reasoning: nil, modelID: "model-a"),
            RawAgentUsage(input: 200, output: 75, cacheRead: nil, reasoning: nil, modelID: "model-b"),
        ]
    }
}

final class AgentSourcePollerTests: XCTestCase {

    /// Wide enough that a file written "now" matches a session connected "now", and
    /// narrow enough that two deliberately-separated sessions get separate windows.
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

    private func candidate(_ name: String, modifiedAt: Date) -> LogCandidate {
        LogCandidate(url: URL(fileURLWithPath: "/logs/\(name)"), modifiedAt: modifiedAt)
    }

    // MARK: - No sessions means no walk

    /// **A machine with no MCP client ever connected must not stat every agent log on it
    /// once a minute to conclude there is nobody to attribute them to.** This is the
    /// common case for anyone who does not use an agent, and it is the whole reason the
    /// guard sits in front of the enumeration rather than after it.
    ///
    /// The spy is what makes this assertable: with a plain adapter, "no records" would
    /// look identical whether the walk happened over an empty list or never happened.
    /// Deleting the guard has to fail here.
    func testAPassWithNoSessionsEnumeratesNothing() throws {
        let store = try makeStore()
        let adapter = CountingTokenAdapter(candidates: [candidate("a.jsonl", modifiedAt: Date())])

        let pass = AgentSourcePoller(store: store, adapters: [adapter], overlap: overlap)
            .pollOnce()

        XCTAssertEqual(adapter.logCandidatesCalls, 0, "no sessions, no filesystem walk")
        XCTAssertEqual(pass.enumerations, 0)
        XCTAssertEqual(pass.sessionsConsidered, 0)
        XCTAssertTrue(pass.records.isEmpty)
        // Nothing was attempted, so there is nothing to be absent about: an absence per
        // session would describe sessions that do not exist.
        XCTAssertTrue(pass.absences.isEmpty)
    }

    /// The mirror of the guard above: one session is enough to make the walk happen. A
    /// guard that refused everything would satisfy the previous test too.
    func testOneSessionIsEnoughToMakeThePassEnumerate() throws {
        let store = try makeStore()
        let now = Date()
        try recordSession(store, connectedAt: now)
        let adapter = CountingTokenAdapter(candidates: [candidate("a.jsonl", modifiedAt: now)])

        let pass = AgentSourcePoller(store: store, adapters: [adapter], overlap: overlap)
            .pollOnce()

        XCTAssertEqual(adapter.logCandidatesCalls, 1)
        XCTAssertEqual(pass.enumerations, 1)
        XCTAssertEqual(pass.sessionsConsidered, 1)
    }

    /// One walk per pass, whatever the session count. The shape this replaced asked the
    /// adapter per session, so three open sessions meant three directory reads to answer
    /// one question the first read had already answered.
    func testThreeSessionsShareOneEnumeration() throws {
        let store = try makeStore()
        let now = Date()
        for offset in [-600.0, -300.0, 0.0] {
            try recordSession(store, connectedAt: now.addingTimeInterval(offset))
        }
        let adapter = CountingTokenAdapter(candidates: [candidate("a.jsonl", modifiedAt: now)])

        let pass = AgentSourcePoller(store: store, adapters: [adapter], overlap: overlap)
            .pollOnce()

        XCTAssertEqual(pass.sessionsConsidered, 3)
        XCTAssertEqual(adapter.logCandidatesCalls, 1, "one walk per pass, not one per session")
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
        let adapter = CountingTokenAdapter(candidates: [candidate("a.jsonl", modifiedAt: now)])

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
        let adapter = CountingTokenAdapter(candidates: [candidate("a.jsonl", modifiedAt: now)])
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

    // MARK: - A failure among many

    /// **One unreadable file must not abandon the rest.** Two sources over one session:
    /// the first refuses its file, the second has a perfectly good one. If the refusal
    /// aborted the pass, the second source would never be asked — and the pass would
    /// then report "nothing here" for a session it never finished looking at.
    func testOneAdapterFailingOnItsFileDoesNotAbortTheOthers() throws {
        let store = try makeStore()
        let now = Date()
        let sessionID = try recordSession(store, connectedAt: now)
        let broken = CountingTokenAdapter(
            identifier: "broken-agent", candidates: [candidate("broken.jsonl", modifiedAt: now)]
        )
        broken.failingNames = ["broken.jsonl"]
        let working = CountingTokenAdapter(
            identifier: "working-agent", candidates: [candidate("live.jsonl", modifiedAt: now)]
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

    /// The other half of the same rule, one level down: a failure on one session must not
    /// skip the sessions after it. Two sessions against the one file this adapter has,
    /// which it refuses — so **both** must be recorded as absences. A pass that stopped at
    /// the first would leave the second session looking like it had never been asked,
    /// which is a different and wrong story from "there is nothing to read".
    func testAFailureOnOneSessionDoesNotSkipTheNext() throws {
        let store = try makeStore()
        let now = Date()
        let first = try recordSession(store, connectedAt: now.addingTimeInterval(-120))
        let second = try recordSession(store, connectedAt: now)
        let adapter = CountingTokenAdapter(candidates: [candidate("only.jsonl", modifiedAt: now)])
        adapter.failingNames = ["only.jsonl"]

        let pass = AgentSourcePoller(store: store, adapters: [adapter], overlap: overlap)
            .pollOnce()

        XCTAssertEqual(adapter.parsedNames, ["only.jsonl", "only.jsonl"], "both sessions were polled")
        XCTAssertEqual(pass.absences.map(\.sessionID), [first, second])
        XCTAssertEqual(Set(pass.absences.map(\.reason)), [.logUnreadable])
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
            candidates: [candidate("old.jsonl", modifiedAt: Date(timeIntervalSince1970: 0))]
        )
        let talking = CountingTokenAdapter(
            identifier: "talking-agent", candidates: [candidate("live.jsonl", modifiedAt: now)]
        )

        let pass = AgentSourcePoller(store: store, adapters: [silent, talking], overlap: overlap)
            .pollOnce()

        XCTAssertEqual(pass.enumerations, 2, "one walk per adapter, per pass")
        XCTAssertEqual(pass.absences, [
            AgentSourceAbsence(sessionID: sessionID, source: "silent-agent", reason: .noSource)
        ])
        XCTAssertEqual(talking.parsedNames, ["live.jsonl"])
        XCTAssertEqual(pass.records.count, 2)
    }

    /// **Two candidates is an absence, and it reaches the pass as one.** The reason a
    /// caller reads to explain a missing figure has to be the same reason the matcher
    /// reached — a pass that reported "no source" here would send the user looking for a
    /// log that exists and was simply not attributable.
    func testAnAmbiguousMatchReachesThePassAsAnAbsence() throws {
        let store = try makeStore()
        let now = Date()
        let sessionID = try recordSession(store, connectedAt: now)
        let adapter = CountingTokenAdapter(candidates: [
            candidate("agent-a.jsonl", modifiedAt: now),
            candidate("agent-b.jsonl", modifiedAt: now),
        ])

        let pass = AgentSourcePoller(store: store, adapters: [adapter], overlap: overlap)
            .pollOnce()

        XCTAssertTrue(pass.records.isEmpty)
        XCTAssertEqual(pass.absences, [
            AgentSourceAbsence(sessionID: sessionID, source: "counting-agent", reason: .ambiguousMatch)
        ])
    }

    /// A machine whose agent has written a log in a shape nobody recognises reports
    /// `unrecognizedFormat`, not zero tokens — the same refusal the runner has always
    /// made, now reachable because something finally calls it.
    func testAnUnreadableShapeIsNamedNotZeroed() throws {
        let store = try makeStore()
        let now = Date()
        let sessionID = try recordSession(store, connectedAt: now)
        let adapter = CountingTokenAdapter(candidates: [candidate("changed.jsonl", modifiedAt: now)])
        adapter.failingNames = ["changed.jsonl"]

        let pass = AgentSourcePoller(store: store, adapters: [adapter], overlap: overlap)
            .pollOnce()

        XCTAssertTrue(pass.records.isEmpty)
        XCTAssertEqual(pass.absences.first?.reason, .logUnreadable)
        XCTAssertEqual(pass.absences.first?.sessionID, sessionID)
        let stored = try XCTUnwrap(try store.sessions().first)
        XCTAssertFalse(stored.usage.isReported, "nothing read must not become a figure of zero")
    }
}