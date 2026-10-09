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
    var candidates: [LogCandidate]
    /// What `parse` throws for a given file, by name. **A file that is not named parses
    /// normally**, so one refusal can be isolated from the files beside it — which is the
    /// case the poller has to survive, and the only way to reach
    /// `.unrecognizedFormat` as distinct from `.logUnreadable`.
    var parseFailures: [String: TokenSourceError] = [:]
    /// What `contextPressure` reports. `nil` (the default) keeps every existing test
    /// asserting what it asserted before this field existed.
    var pressure: PressureReading?
    /// What `parse` returns for a file that parses normally. Replaceable so a test can
    /// model a file with usage worth nothing without a second adapter type.
    var parsedUsage: [RawAgentUsage] = [
        RawAgentUsage(input: 100, output: 50, cacheRead: nil, reasoning: nil, modelID: "model-a"),
        RawAgentUsage(input: 200, output: 75, cacheRead: nil, reasoning: nil, modelID: "model-b"),
    ]

    private let lock = NSLock()
    private var _logCandidatesCalls = 0
    private var _parsedNames: [String] = []

    init(identifier: String = "counting-agent", candidates: [LogCandidate]) {
        self.identifier = identifier
        self.candidates = candidates
    }

    /// Every bound this adapter was asked with, in order, so a test can assert the pass
    /// handed it a real cost bound rather than nothing.
    private var _bounds: [Date?] = []

    var logCandidatesCalls: Int {
        lock.lock(); defer { lock.unlock() }
        return _logCandidatesCalls
    }

    var bounds: [Date?] {
        lock.lock(); defer { lock.unlock() }
        return _bounds
    }

    /// Every file this adapter was asked to read, in the order it was asked.
    var parsedNames: [String] {
        lock.lock(); defer { lock.unlock() }
        return _parsedNames
    }

    func logCandidates(newerThan: Date?) -> [LogCandidate] {
        lock.lock(); defer { lock.unlock() }
        _logCandidatesCalls += 1
        _bounds.append(newerThan)
        guard let newerThan else { return candidates }
        return candidates.filter { ($0.interval?.end ?? .distantPast) >= newerThan }
    }

    func parse(_ url: URL) throws -> [RawAgentUsage] {
        lock.lock()
        _parsedNames.append(url.lastPathComponent)
        let failure = parseFailures[url.lastPathComponent]
        lock.unlock()
        if let failure { throw failure }
        return parsedUsage
    }

    func contextPressure(at url: URL) -> PressureReading? { pressure }
}

/// Records when it was asked, not only how often, so a test can see whether two
/// passes were inside it at once.
///
/// **A concurrency probe rather than another counter.** The claim under test is that
/// one queue owns every pass, and only an adapter that *can* be entered twice at once
/// can fail that claim: each ask here is long enough that a `pollOnce` issued while a
/// scheduled pass is provably inside would be seen entering beside it if the two were
/// not serialized. An adapter that only counted asks would see the same two counts
/// whether they ran one after the other or on top of each other.
final class OverlapProbeAdapter: TokenSourceAdapter, @unchecked Sendable {
    let identifier = "overlap-probe"
    let candidates: [LogCandidate]
    /// How long one ask occupies. Zero where the test only needs the signal, not the
    /// window.
    private let askDuration: TimeInterval
    /// Signalled when the first ask begins, so a test can call `pollOnce` at a moment
    /// when a scheduled pass is inside this adapter — the moment an unsynchronized
    /// implementation would let a second one in.
    let firstAskStarted = DispatchSemaphore(value: 0)

    private let lock = NSLock()
    private var _events: [String] = []
    private var _inside = 0
    private var _maxConcurrent = 0

    init(candidates: [LogCandidate], askDuration: TimeInterval = 0.5) {
        self.candidates = candidates
        self.askDuration = askDuration
    }

    /// `enter` and `exit` in the order they happened. An `enter` with no `exit` before
    /// the next `enter` is two passes walking at once.
    var events: [String] {
        lock.lock(); defer { lock.unlock() }
        return _events
    }

    var maxConcurrentAsks: Int {
        lock.lock(); defer { lock.unlock() }
        return _maxConcurrent
    }

    /// How many asks have begun. `events` records an ask twice — once on entry and
    /// once on exit — so this is the number to assert on when the claim is "how many
    /// passes walked", while `events` stays the thing to assert on when the claim is
    /// "in what order".
    var askCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _events.filter { $0 == "enter" }.count
    }

    func logCandidates(newerThan: Date?) -> [LogCandidate] {
        lock.lock()
        _events.append("enter")
        _inside += 1
        _maxConcurrent = max(_maxConcurrent, _inside)
        let isFirst = _events.count == 1
        lock.unlock()
        if isFirst { firstAskStarted.signal() }
        Thread.sleep(forTimeInterval: askDuration)
        lock.lock()
        _events.append("exit")
        _inside -= 1
        lock.unlock()
        return candidates
    }

    func parse(_ url: URL) throws -> [RawAgentUsage] {
        [RawAgentUsage(input: 100, output: 50, cacheRead: nil, reasoning: nil, modelID: "model-a")]
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
            interval: LogInterval(start: from, end: to ?? from)
        )
    }

    /// The poller's live timer, or `nil` when it holds none.
    ///
    /// Read through `Mirror` because the timer is `private` and there is no accessor —
    /// and because it is the one thing the ask counts structurally cannot see: the next
    /// scheduled tick is thirty seconds out, so a poller left running and a poller
    /// stopped look identical to every assertion about passes within any short window.
    /// A renamed or reshaped `timer` property returns `nil`, which the callers unwrap —
    /// so the tripwire fails loudly rather than passing over nothing.
    private func timer(of poller: AgentSourcePoller) -> DispatchSourceTimer? {
        Mirror(reflecting: poller).children
            .first { $0.label == "timer" }
            .flatMap { $0.value as? DispatchSourceTimer }
    }

    /// Polls a condition on the test's own thread until it holds or the timeout passes.
    private func waitUntil(
        timeout: TimeInterval = 5, _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return condition()
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

    // MARK: - Context pressure

    /// A uniquely matched conversation's pressure reading reaches the session, folded
    /// onto the same row the usage figure would land on.
    func testAUniqueMatchRecordsTheAdaptersPressureReading() throws {
        let store = try makeStore()
        let now = Date()
        let sessionID = try recordSession(store, connectedAt: now)
        let adapter = CountingTokenAdapter(candidates: [candidate("a.jsonl", from: now)])
        adapter.pressure = PressureReading(tokensLeft: 14_999_357, lineNumber: 4)

        let pass = AgentSourcePoller(store: store, adapters: [adapter], overlap: overlap)
            .pollOnce()

        let snapshot = try store.sessions().first { $0.id == sessionID }!
        XCTAssertEqual(snapshot.tokensLeftFirst, 14_999_357)
        XCTAssertEqual(snapshot.tokensLeftWorst, 14_999_357)
        XCTAssertEqual(pass.pressureUpdates, 1, "one matched session, one update")
    }

    /// The one-to-one rule is one rule, not one rule for numbers and another for text:
    /// a conversation several connections contend for attributes nothing.
    func testAContestedSessionGetsNoPressure() throws {
        let store = try makeStore()
        let now = Date()
        var sessionIDs: [UUID] = []
        for offset in [-600.0, -300.0, 0.0] {
            sessionIDs.append(try recordSession(store, connectedAt: now.addingTimeInterval(offset)))
        }
        let adapter = CountingTokenAdapter(candidates: [candidate("a.jsonl", from: now)])
        adapter.pressure = PressureReading(tokensLeft: 14_999_357, lineNumber: 4)

        let pass = AgentSourcePoller(store: store, adapters: [adapter], overlap: overlap)
            .pollOnce()

        for id in sessionIDs {
            let snapshot = try store.sessions().first { $0.id == id }!
            XCTAssertNil(snapshot.tokensLeftWorst, "a contested conversation leaves no pressure behind")
        }
        XCTAssertEqual(pass.pressureUpdates, 0, "no session may claim a contested reading")
    }

    /// Absence of usage and absence of pressure are independent facts: a parse that
    /// finds nothing does not silence a pressure reading the same file carries.
    func testPressureIsRecordedWhenNoUsageWas() throws {
        let store = try makeStore()
        let now = Date()
        let sessionID = try recordSession(store, connectedAt: now)
        let adapter = CountingTokenAdapter(candidates: [candidate("a.jsonl", from: now)])
        adapter.parsedUsage = []
        adapter.pressure = PressureReading(tokensLeft: 14_999_357, lineNumber: 4)

        let pass = AgentSourcePoller(store: store, adapters: [adapter], overlap: overlap)
            .pollOnce()

        XCTAssertTrue(pass.records.isEmpty, "a file with no usage writes no usage")
        XCTAssertEqual(pass.pressureUpdates, 1, "a pressure reading stands on its own")
        let snapshot = try store.sessions().first { $0.id == sessionID }!
        XCTAssertEqual(snapshot.tokensLeftWorst, 14_999_357)
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

    // MARK: - A figure is withdrawn, not left standing

    /// **A second connection opens inside the conversation, and the figure the first pass
    /// wrote stops counting.**
    ///
    /// This is the pass-level form of BLOCKER 2, and it is the whole sequence: a
    /// conversation that is being written *right now* has a one-connection match at pass N,
    /// and gains a second connection inside the same conversation before pass N+1. Both go
    /// to `ambiguousMatch`, and without the withdrawal the store would keep showing a priced
    /// figure for both — the same 16,739 tokens twice, from a pass that knew better and
    /// discarded it.
    func testASecondConnectionInsideTheConversationWithdrawsTheFigureAlreadyWritten() throws {
        let store = try makeStore()
        let now = Date()
        let conversation = candidate(
            "live.jsonl", from: now.addingTimeInterval(-3600), to: now.addingTimeInterval(600)
        )
        let adapter = CountingTokenAdapter(candidates: [conversation])
        let poller = AgentSourcePoller(store: store, adapters: [adapter], overlap: overlap)

        // Pass 1: one connection inside the conversation. It is the only one, so it matches.
        let first = try recordSession(store, connectedAt: now.addingTimeInterval(-1800))
        let before = poller.pollOnce()
        XCTAssertEqual(before.records.count, 2)
        XCTAssertTrue(before.records.allSatisfy { $0.sessionID == first })
        XCTAssertTrue(try XCTUnwrap(try store.sessions().first { $0.id == first }).usage.isReported)

        // Pass 2: a second connection lands inside the same conversation. Now both contend.
        let second = try recordSession(store, connectedAt: now.addingTimeInterval(-300))
        let after = poller.pollOnce()

        XCTAssertTrue(after.records.isEmpty, "no new figures")
        XCTAssertEqual(after.withdrawals.count, 1, "DEBUG one withdrawal")
        print("DEBUG usage(for:) =", try store.usage(for: first))
        print("DEBUG sessions =", try store.sessions().map { ($0.id == first ? "FIRST" : "SECOND", $0.usage) })
        print("DEBUG direct fold =", TokenUsage.aggregating([
            TokenUsageRecord(sessionID: first, recordedAt: now, input: 100, output: 50,
                             cacheRead: nil, reasoning: nil, modelID: "m", provenance: .parsedFromLog),
            TokenUsageRecord(sessionID: first, recordedAt: now.addingTimeInterval(60), input: 0,
                             output: 0, cacheRead: nil, reasoning: nil, modelID: "",
                             provenance: .parseWithdrawn),
        ]))
        XCTAssertEqual(Set(after.absences.map(\.sessionID)), [first, second])
        XCTAssertEqual(Set(after.absences.map(\.reason)), [.ambiguousMatch])

        // **And the store no longer prices the session that had a figure.** This is the
        // assertion the withdrawal exists for; without it, `first` would still read as
        // reported and the same conversation's tokens would be billed for it *and* for
        // nothing else — a priced figure for a session the current rule refuses.
        let withdrawn = try XCTUnwrap(try store.sessions().first { $0.id == first })
        XCTAssertEqual(withdrawn.usage, .notReported(reason: .ambiguousMatch))
        XCTAssertNil(withdrawn.cost.usd, "a withdrawn session must not carry a dollar figure")

        // The second connection never had a figure and never gets a withdrawal, so it reads
        // as awaiting its first report — a different state from `ambiguousMatch`, and both
        // are absences rather than zeros.
        let neverHadOne = try XCTUnwrap(try store.sessions().first { $0.id == second })
        XCTAssertEqual(neverHadOne.usage, .notReported(reason: .awaitingFirstReport))
        XCTAssertNil(neverHadOne.cost.usd)
    }

    /// **A withdrawal is only written where there was a figure.** One connection, no
    /// contention: a pass that withdrew blindly would leave a `parseWithdrawn` record
    /// behind for a session that never had a parsed figure, outliving the figure it was
    /// meant to cancel and turning every later reading on that session into a no-op.
    func testNoWithdrawalIsWrittenForASessionThatNeverHadAFigure() throws {
        let store = try makeStore()
        let now = Date()
        try recordSession(store, connectedAt: now)
        // Nothing in the conversation's window, so the session reads `noSource`.
        let adapter = CountingTokenAdapter(candidates: [
            candidate("ancient.jsonl",
                      from: now.addingTimeInterval(-90 * 24 * 3600),
                      to: now.addingTimeInterval(-90 * 24 * 3600 - 60))
        ])

        let pass = AgentSourcePoller(store: store, adapters: [adapter], overlap: overlap)
            .pollOnce()

        XCTAssertEqual(pass.absences.map(\.reason), [.noSource])
        XCTAssertTrue(pass.records.isEmpty, "a `noSource` absence withdraws nothing")
        for session in try store.sessions() {
            XCTAssertFalse(session.usage.isReported)
        }
    }

    /// **A withdrawal is not a one-way door, and this shows both halves.**
    ///
    /// The conversation the pair contended over is replaced by one that only the *newer*
    /// connection falls inside, so a later pass can match it unambiguously. The newer
    /// session gets a fresh figure — a reading newer than the withdrawal supersedes it. The
    /// older one keeps reading `ambiguousMatch`, because nothing re-established *its*
    /// figure and a withdrawal that expired on its own would be a record the store could
    /// not explain. That is the honest residue and it is stated here rather than left for
    /// someone to read off a card.
    func testAReadingNewerThanAWithdrawalStandsAgainAndTheOlderOneStaysWithdrawn() throws {
        let store = try makeStore()
        let now = Date()
        let live = candidate(
            "live.jsonl", from: now.addingTimeInterval(-3600), to: now.addingTimeInterval(600)
        )
        let adapter = CountingTokenAdapter(candidates: [live])
        let poller = AgentSourcePoller(store: store, adapters: [adapter], overlap: overlap)

        let older = try recordSession(store, connectedAt: now.addingTimeInterval(-1800))
        poller.pollOnce()

        let newer = try recordSession(store, connectedAt: now.addingTimeInterval(-300))
        poller.pollOnce()
        XCTAssertEqual(
            try XCTUnwrap(try store.sessions().first { $0.id == older }).usage,
            .notReported(reason: .ambiguousMatch)
        )

        // A new conversation, inside only the newer connection's window.
        adapter.candidates = [
            candidate("next.jsonl", from: now.addingTimeInterval(-400), to: now.addingTimeInterval(-100))
        ]
        let pass = poller.pollOnce()

        XCTAssertEqual(pass.records.count, 2)
        XCTAssertTrue(pass.records.allSatisfy { $0.sessionID == newer })
        guard case .reported = try XCTUnwrap(try store.sessions().first { $0.id == newer }).usage else {
            return XCTFail("a reading newer than the withdrawal stands again")
        }
        XCTAssertEqual(
            try XCTUnwrap(try store.sessions().first { $0.id == older }).usage,
            .notReported(reason: .ambiguousMatch),
            "and the one with nothing newer stays withdrawn rather than half-resurrected"
        )
    }

    // MARK: - The cost bound handed to every source

    /// **Every source is asked with the earliest instant any session could match**, derived
    /// from the sessions rather than configured. Without it the adapter reads every log on
    /// the machine at any age every 30 seconds — ~2.63 ms per 712 KB, so ~300 conversations
    /// is ~0.8 s a pass and ~1 GB of logs is ~3.7 s, about 12% of a core continuously, spent
    /// on intervals the matcher discards.
    ///
    /// **Earliest, not newest**: a pass with one old and one new session can still match the
    /// old session's log, so bounding on the newest would drop a candidate the matcher would
    /// have accepted.
    func testTheBoundIsTheEarliestConnectionLessTheTolerance() throws {
        let store = try makeStore()
        let now = Date()
        let dayOld = now.addingTimeInterval(-24 * 3600)
        _ = try recordSession(store, connectedAt: dayOld)
        _ = try recordSession(store, connectedAt: now)
        let adapter = CountingTokenAdapter(candidates: [])

        _ = AgentSourcePoller(store: store, adapters: [adapter], overlap: overlap).pollOnce()

        let bound = try XCTUnwrap(adapter.bounds.first)
        XCTAssertEqual(
            try XCTUnwrap(bound).timeIntervalSince(dayOld),
            -overlap, accuracy: 1,
            "the bound is the earliest connection less the tolerance, not a constant"
        )
    }

    // MARK: - One queue: a UI poll and a scheduled pass never run at once

    /// **`pollOnce` waits its turn instead of walking beside a scheduled pass.**
    ///
    /// The guarantee the app's shape rests on: scheduled passes own the lane, and a
    /// caller that wants a blocking answer joins the queue rather than opening a
    /// second walk of somebody else's log directory at the same moment. Both passes
    /// are seen here — two asks — and seen one strictly after the other.
    ///
    /// The `pollOnce` is issued while the scheduled pass is *provably* inside the
    /// adapter (the probe signalled its entry, and each ask lasts half a second), so
    /// a poller whose `pollOnce` ran off-queue would be caught entering beside it
    /// rather than merely racing somewhere the test cannot see.
    func testPollOnceWaitsForTheScheduledPassRatherThanWalkingAlongsideIt() throws {
        let store = try makeStore()
        let now = Date()
        try recordSession(store, connectedAt: now)
        let adapter = OverlapProbeAdapter(candidates: [candidate("a.jsonl", from: now)])
        let poller = AgentSourcePoller(store: store, adapters: [adapter], overlap: overlap)
        addTeardownBlock { poller.stop() }

        poller.start()
        XCTAssertEqual(
            adapter.firstAskStarted.wait(timeout: .now() + 5), .success,
            "the scheduled pass never asked, so there was nothing to wait behind"
        )

        let uiPass = poller.pollOnce()

        XCTAssertEqual(
            adapter.events, ["enter", "exit", "enter", "exit"],
            "the blocking poll ran inside the scheduled pass rather than after it"
        )
        XCTAssertEqual(adapter.maxConcurrentAsks, 1, "one queue, so one pass at a time")
        XCTAssertGreaterThanOrEqual(uiPass.sessionsConsidered, 1, "and it did run a pass")
    }

    /// A request from a surface inside the interval adds no walk: the gate that makes
    /// "a window that opens and closes five times" one pass, not five.
    ///
    /// The first pass is observed rather than assumed, and the probe asks instantly —
    /// so the only thing that can produce a second `enter` within the sleep is the
    /// request itself. The interval is thirty seconds against a third of one, so the
    /// timer's next tick cannot reach into the assertion either.
    func testARequestInsideTheIntervalAddsNoSecondWalk() throws {
        let store = try makeStore()
        let now = Date()
        try recordSession(store, connectedAt: now)
        let adapter = OverlapProbeAdapter(
            candidates: [candidate("a.jsonl", from: now)], askDuration: 0
        )
        let poller = AgentSourcePoller(store: store, adapters: [adapter], overlap: overlap)
        addTeardownBlock { poller.stop() }

        poller.start()
        XCTAssertEqual(
            adapter.firstAskStarted.wait(timeout: .now() + 5), .success,
            "the first pass never asked"
        )

        poller.requestPoll()
        Thread.sleep(forTimeInterval: 0.3)

        XCTAssertEqual(
            adapter.askCount, 1,
            "a request inside the interval is dropped, not stacked into a second walk"
        )
    }

    /// `start()` is called from every surface that appears and from intents, so it
    /// runs more than once per launch — and asking must still happen once.
    ///
    /// The property, not the mechanism: whichever internal guard absorbs the repeat
    /// (and there is more than one that could), two starts must not produce two first
    /// passes, and must not produce two passes running beside each other either —
    /// which is what a second `start()` that quietly added a second queue would do.
    func testStartingTwiceDoesNotAskTwice() throws {
        let store = try makeStore()
        let now = Date()
        try recordSession(store, connectedAt: now)
        let adapter = OverlapProbeAdapter(
            candidates: [candidate("a.jsonl", from: now)], askDuration: 0
        )
        let poller = AgentSourcePoller(store: store, adapters: [adapter], overlap: overlap)
        addTeardownBlock { poller.stop() }

        poller.start()
        poller.start()
        XCTAssertEqual(adapter.firstAskStarted.wait(timeout: .now() + 5), .success)
        Thread.sleep(forTimeInterval: 0.3)

        XCTAssertEqual(adapter.askCount, 1, "two starts, one first pass")
        XCTAssertEqual(adapter.maxConcurrentAsks, 1, "and never two passes at once")
    }

    // MARK: - Stop really stops

    /// **`stop()` cancels the timer `start()` made, so no further scheduled pass can
    /// fire.**
    ///
    /// `stop()` had never been observed doing anything — across every test in this file
    /// it appears only in teardowns, where a broken stop is invisible. Ask counts
    /// cannot see it either: the next scheduled tick is thirty seconds out, so a
    /// poller whose timer was left running looks exactly like a stopped one for the
    /// whole of any short assertion window. What is observable now is the timer
    /// itself — still the same object, and cancelled — which is the whole of what
    /// "the timer stops ticking" means. (`stop()` is not terminal and does not drain
    /// the queue; `AppModel.stopAgentSources`' comment is where those margins are
    /// written down.)
    func testStopCancelsTheTimerSoNoFurtherScheduledPassCanFire() throws {
        let store = try makeStore()
        let now = Date()
        try recordSession(store, connectedAt: now)
        let adapter = OverlapProbeAdapter(
            candidates: [candidate("a.jsonl", from: now)], askDuration: 0
        )
        let poller = AgentSourcePoller(store: store, adapters: [adapter], overlap: overlap)
        addTeardownBlock { poller.stop() }

        poller.start()
        XCTAssertEqual(
            adapter.firstAskStarted.wait(timeout: .now() + 5), .success,
            "the first pass never asked, so there was no timer to stop"
        )
        let live = try XCTUnwrap(
            timer(of: poller), "start() made no timer — nothing for stop() to cancel"
        )
        XCTAssertFalse(live.isCancelled, "the timer the first pass ran on is still live")

        poller.stop()
        XCTAssertTrue(
            waitUntil { live.isCancelled },
            "stop() returned without cancelling the timer it was started with"
        )

        // A smoke window, not the proof — the proof is the cancelled flag above.
        // Inside it the stopped poller must not have been provoked into a pass either.
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(adapter.askCount, 1, "and stop() itself provoked no extra pass")
    }

    /// **The `timer == nil` guard is what makes one `stop()` enough: the second
    /// `start()` reuses the timer the first made, so cancelling one cancels the only
    /// one.**
    ///
    /// Without the guard a second `start()` would quietly add a second live timer;
    /// `stop()` cancels the one it holds, so the first would keep ticking — the
    /// "poller kept polling" leak. No ask-count assertion can see that leak (the
    /// interval gate absorbs the duplicate tick, and the orphaned timer's next fire is
    /// thirty seconds out), which is why this compares the timer objects themselves:
    /// two objects means a leaked one, whatever the passes in between happened to do.
    func testStartingTwiceReusesTheOneTimerSoStopCancelsTheOnlyOne() throws {
        let store = try makeStore()
        let now = Date()
        try recordSession(store, connectedAt: now)
        let adapter = OverlapProbeAdapter(
            candidates: [candidate("a.jsonl", from: now)], askDuration: 0
        )
        let poller = AgentSourcePoller(store: store, adapters: [adapter], overlap: overlap)
        addTeardownBlock { poller.stop() }

        poller.start()
        XCTAssertEqual(
            adapter.firstAskStarted.wait(timeout: .now() + 5), .success,
            "the first pass never asked, so no timer was ever made"
        )
        let first = try XCTUnwrap(timer(of: poller), "start() made no timer")

        poller.start()
        // `pollOnce` joins the poller's own queue behind the second `start()`'s block,
        // so when it returns the second start has had its say about the timer.
        _ = poller.pollOnce()
        let second = try XCTUnwrap(timer(of: poller), "the second start lost the timer")
        XCTAssertTrue(
            first === second,
            "the second start must reuse the first timer, or one stop cannot cancel both"
        )
        XCTAssertFalse(second.isCancelled)

        poller.stop()
        XCTAssertTrue(
            waitUntil { second.isCancelled },
            "stop() did not cancel the timer both starts shared"
        )
    }
}

/// What the Overview card has to be able to say, pinned as a state rather than as a
/// string.
///
/// The card maps `UsageUnavailableReason` to a phrase in its own view code and there is no
/// App test target, so the *phrase* cannot be asserted from here — only the state it is
/// handed. That state is pinned here, because the phrase was wrong for the ordinary case
/// for as long as it existed: `ambiguousMatch` read **"2 logs match"**, which describes
/// neither of the two shapes it now means.
///
/// **And the state is reachable only through a withdrawal.** A session that was never
/// counted reads `awaitingFirstReport` however many things contend over it, because it has
/// no records to withdraw — which is why both tests here take a figure first. That is a
/// good thing to know about the card: its ambiguous phrase describes a session that *was*
/// counted and is no longer attributable, not one that never had a source.
final class AmbiguousMatchStateTests: XCTestCase {

    private func makeStore() throws -> AgentSessionStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ambiguous-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try AgentSessionStore(storeURL: directory.appendingPathComponent("s.sqlite"))
    }

    private func record(_ store: AgentSessionStore, at: Date, label: String) throws -> UUID {
        let id = UUID()
        try store.recordSession(
            id: id, peerPID: 1, clientName: label, clientVersion: nil, connectedAt: at
        )
        return id
    }

    /// **One log, several connections.** The ordinary case: an agent holding a conversation
    /// open across two MCP connections. One adapter, one file, **one** conversation — so
    /// any phrase asserting a number of logs is false here — and the store still reaches
    /// `ambiguousMatch`, because the figure the first pass wrote is withdrawn when the
    /// second connection lands inside the same conversation.
    func testOneConversationAndSeveralConnectionsReachAmbiguousMatchWithOneLog() throws {
        let store = try makeStore()
        let now = Date()
        let adapter = CountingTokenAdapter(candidates: [
            LogCandidate(
                url: URL(fileURLWithPath: "/logs/one-conversation.jsonl"),
                interval: LogInterval(
                    start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(600)
                )
            )
        ])
        let poller = AgentSourcePoller(store: store, adapters: [adapter], overlap: 600)

        let first = try record(store, at: now.addingTimeInterval(-1800), label: "alone")
        poller.pollOnce()
        XCTAssertTrue(try XCTUnwrap(try store.sessions().first { $0.id == first }).usage.isReported)

        // A second connection opens inside the same conversation.
        try record(store, at: now.addingTimeInterval(-300), label: "joined")
        let pass = poller.pollOnce()

        XCTAssertEqual(pass.sourcesQueried, 1, "one source, one file")
        XCTAssertEqual(adapter.parsedNames.count, 1, "one log was ever read")
        XCTAssertEqual(adapter.parsedNames, ["one-conversation.jsonl"])
        XCTAssertEqual(Set(pass.absences.map(\.reason)), [.ambiguousMatch])

        let stored = try XCTUnwrap(try store.sessions().first { $0.id == first })
        XCTAssertEqual(stored.usage, .notReported(reason: .ambiguousMatch))
        XCTAssertNil(stored.cost.usd)
    }

    /// **Several conversations, one connection** — the other thing `ambiguousMatch` means,
    /// and it arrives at the *same* state by the *other* route: a figure taken while only
    /// one conversation was in play, then a second agent's conversation appearing.
    ///
    /// Same state, so the same phrase has to cover it — which is why the phrase can name
    /// neither a count nor a cause, and why naming either would be false for one of the two.
    func testSeveralConversationsAndOneConnectionReachTheSameState() throws {
        let store = try makeStore()
        let now = Date()
        let only = LogCandidate(
            url: URL(fileURLWithPath: "/logs/agent-a.jsonl"),
            interval: LogInterval(
                start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(-1800)
            )
        )
        let adapter = CountingTokenAdapter(candidates: [only])
        let poller = AgentSourcePoller(store: store, adapters: [adapter], overlap: 600)

        let theConnection = try record(
            store, at: now.addingTimeInterval(-2700), label: "one"
        )
        poller.pollOnce()

        // A second agent's conversation, also spanning this connection.
        adapter.candidates = [only, LogCandidate(
            url: URL(fileURLWithPath: "/logs/agent-b.jsonl"),
            interval: LogInterval(
                start: now.addingTimeInterval(-3400), end: now.addingTimeInterval(-1700)
            )
        )]
        let pass = poller.pollOnce()

        XCTAssertEqual(pass.absences.map(\.reason), [.ambiguousMatch])
        XCTAssertEqual(
            try XCTUnwrap(try store.sessions().first { $0.id == theConnection }).usage,
            .notReported(reason: .ambiguousMatch),
            "one state for two shapes, so one phrase has to cover both"
        )
    }

    /// **A session that was never counted is not `ambiguousMatch`**, however many things
    /// contend over it — it has nothing to withdraw. Without this, the card's ambiguous
    /// phrase would read on every session of a busy machine and mean nothing; the honest
    /// state for a session that never reported is `awaitingFirstReport`.
    func testASessionThatWasNeverCountedReadsAwaitingFirstReportNotAmbiguousMatch() throws {
        let store = try makeStore()
        let now = Date()
        let adapter = CountingTokenAdapter(candidates: [
            LogCandidate(
                url: URL(fileURLWithPath: "/logs/one-conversation.jsonl"),
                interval: LogInterval(
                    start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(600)
                )
            )
        ])
        let poller = AgentSourcePoller(store: store, adapters: [adapter], overlap: 600)

        // Both connections are inside the conversation from the start, so no pass ever had a
        // figure to write or withdraw.
        try record(store, at: now.addingTimeInterval(-1800), label: "a")
        try record(store, at: now.addingTimeInterval(-300), label: "b")
        let pass = poller.pollOnce()

        XCTAssertEqual(Set(pass.absences.map(\.reason)), [.ambiguousMatch], "the pass says so")
        XCTAssertTrue(pass.records.isEmpty)
        XCTAssertTrue(pass.withdrawals.isEmpty)
        XCTAssertEqual(
            Set(try store.sessions().map(\.usage)),
            [.notReported(reason: .awaitingFirstReport)],
            "and the store says `awaitingFirstReport`, because there is nothing to withdraw"
        )
    }
}
