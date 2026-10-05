// ConfirmationBrokerTests: the human-in-the-loop gate between an AI client and a
// change to the machine.
//
// The broker is the piece of slice 2 that must never be wrong in the quiet way. A
// request that is never resumed is a tool call that hangs forever; a continuation
// resumed twice traps; two dialogs stacked at once is how a user approves the
// wrong thing. So these tests are about the paths rather than the happy case
// alone: every outcome terminates, nothing is left pending, an answer for an id
// nobody asked about is inert, and a denial does not strand the request behind it.
//
// Nothing here touches a socket or a window. The broker only answers; who shows
// the prompt is a later task's business.
//
// Waiting is done by polling bounded boxes rather than by sleeping for the answer:
// a test that slept long enough to pass would also pass when the broker is broken
// in the other direction, and a test that slept forever would hang the suite
// instead of failing it.

import Foundation
import PortmasterMCP
import XCTest

final class ConfirmationBrokerTests: XCTestCase {
    // MARK: - Approve and deny

    func testApproveReturnsApproved() async throws {
        let broker = ConfirmationBroker(timeout: 5)
        let (box, _) = start(broker, makeRequest())

        let presented = await waitForPending(broker, 1)
        let id = try XCTUnwrap(presented.first?.id, "the request must be presented for a decision")
        await broker.decide(id: id, outcome: .approved)

        let outcome = try await waitForOutcome(box)
        XCTAssertEqual(outcome, .approved)
        let remaining = await pendingIDs(broker)
        XCTAssertEqual(remaining, [], "a decided request must leave the queue")
    }

    func testDenyReturnsDeniedWithTheGivenReason() async throws {
        let broker = ConfirmationBroker(timeout: 5)
        let (box, _) = start(broker, makeRequest())

        let presented = await waitForPending(broker, 1)
        let id = try XCTUnwrap(presented.first?.id)
        await broker.decide(id: id, outcome: .denied(reason: "Portmaster is quitting."))

        // The reason has to survive verbatim: the tool layer shows it to the AI
        // client, and a generic "denied" tells the model nothing about retrying.
        let outcome = try await waitForOutcome(box)
        XCTAssertEqual(outcome, .denied(reason: "Portmaster is quitting."))
        let remaining = await pendingIDs(broker)
        XCTAssertEqual(remaining, [])
    }

    // MARK: - Silence

    func testSilenceTimesOutAtTheConfiguredBudget() async throws {
        let broker = ConfirmationBroker(timeout: 0.05)
        let started = Date()
        let (box, _) = start(broker, makeRequest())
        await waitForPending(broker, 1)

        // Nobody ever decides. The caller must still come back.
        let outcome = try await waitForOutcome(box)
        XCTAssertEqual(outcome, .timedOut)
        let remaining = await pendingIDs(broker)
        XCTAssertEqual(remaining, [], "a timed-out request must leave the queue")
        XCTAssertLessThan(
            Date().timeIntervalSince(started), 5,
            "a 50 ms budget must not be waited out in real minutes"
        )
    }

    // MARK: - Order

    func testSecondRequestWaitsBehindTheFirst() async throws {
        let broker = ConfirmationBroker(timeout: 5)
        let first = makeRequest(kind: .quitApp, summary: "Quit Mail?")
        let second = makeRequest(kind: .stopContainer, summary: "Stop container web")

        let (firstBox, _) = start(broker, first)
        let presented = await waitForPending(broker, 1)
        XCTAssertEqual(presented.map(\.id), [first.id])

        let (secondBox, _) = start(broker, second)
        await waitWhileSuspended(secondBox)
        XCTAssertNil(secondBox.outcome, "a queued request must stay suspended")
        let whileQueued = await pendingIDs(broker)
        XCTAssertEqual(
            whileQueued, [first.id],
            "only the request being decided is presented, or a burst stacks dialogs"
        )

        await broker.decide(id: first.id, outcome: .approved)
        let firstOutcome = try await waitForOutcome(firstBox)
        XCTAssertEqual(firstOutcome, .approved)

        let nowPresented = await waitForPending(broker, 1)
        XCTAssertEqual(
            nowPresented.map(\.id), [second.id],
            "the queued request is presented once the first one is decided"
        )
        await broker.decide(id: second.id, outcome: .approved)
        let secondOutcome = try await waitForOutcome(secondBox)
        XCTAssertEqual(secondOutcome, .approved)
    }

    func testDecideIgnoresAnUnknownID() async throws {
        let broker = ConfirmationBroker(timeout: 5)
        let (box, _) = start(broker, makeRequest())
        let presented = await waitForPending(broker, 1)
        let id = try XCTUnwrap(presented.first?.id)

        // A stale window answering a request that was never asked about, twice.
        await broker.decide(id: UUID(), outcome: .approved)
        await broker.decide(id: UUID(), outcome: .denied(reason: "wrong request"))
        await waitWhileSuspended(box)
        XCTAssertNil(box.outcome, "an unknown id must not resume anything")
        let unchanged = await pendingIDs(broker)
        XCTAssertEqual(unchanged, [id], "an unknown id must leave the queue alone")

        // And the real request is still decidable afterwards, which is what proves
        // the queue was not corrupted rather than merely unchanged.
        await broker.decide(id: id, outcome: .approved)
        let outcome = try await waitForOutcome(box)
        XCTAssertEqual(outcome, .approved)
    }

    // MARK: - Termination

    func testPendingIsEmptyAfterEveryDecisionPath() async throws {
        // Each path gets its own broker: the point is that the queue drains, not
        // that a sequence of outcomes works out.
        let approved = ConfirmationBroker(timeout: 5)
        let approvedRequest = makeRequest(kind: .quitApp)
        let (approvedBox, _) = start(approved, approvedRequest)
        await waitForPending(approved, 1)
        await approved.decide(id: approvedRequest.id, outcome: .approved)
        let approvedOutcome = try await waitForOutcome(approvedBox)
        XCTAssertEqual(approvedOutcome, .approved)
        let afterApprove = await pendingIDs(approved)
        XCTAssertEqual(afterApprove, [], "approved leaves nothing pending")

        let denied = ConfirmationBroker(timeout: 5)
        let deniedRequest = makeRequest(kind: .stopProject)
        let (deniedBox, _) = start(denied, deniedRequest)
        await waitForPending(denied, 1)
        await denied.decide(id: deniedRequest.id, outcome: .denied(reason: "Not now."))
        let deniedOutcome = try await waitForOutcome(deniedBox)
        XCTAssertEqual(deniedOutcome, .denied(reason: "Not now."))
        let afterDeny = await pendingIDs(denied)
        XCTAssertEqual(afterDeny, [], "denied leaves nothing pending")

        let silent = ConfirmationBroker(timeout: 0.05)
        let (silentBox, _) = start(silent, makeRequest(kind: .setPreference))
        await waitForPending(silent, 1)
        let silentOutcome = try await waitForOutcome(silentBox)
        XCTAssertEqual(silentOutcome, .timedOut)
        let afterTimeout = await pendingIDs(silent)
        XCTAssertEqual(afterTimeout, [], "timed out leaves nothing pending")
    }

    /// A burst that nobody answers has to terminate request by request, not just
    /// for the one that happened to be on screen.
    ///
    /// The budget is 0.25 s rather than something tighter: this test has to get two
    /// task spawns and two actor hops inside one budget, and on a loaded machine a
    /// 50 ms budget can lapse before the second request has enqueued — which would
    /// fail the test for being slow rather than for being wrong.
    func testAQueuedRequestTimesOutBehindTheFirst() async throws {
        let broker = ConfirmationBroker(timeout: 0.25)
        let first = makeRequest(kind: .quitApp, summary: "Quit Mail?")
        let second = makeRequest(kind: .stopContainer, summary: "Stop container web")

        let (firstBox, _) = start(broker, first)
        await waitForPending(broker, 1)
        let (secondBox, _) = start(broker, second)
        await waitForQueued(broker, 2)

        // Nobody decides either. The queued one must not be stranded behind the
        // presented one, and must not be resumed by the other's timer either.
        let firstOutcome = try await waitForOutcome(firstBox)
        XCTAssertEqual(firstOutcome, .timedOut)
        let secondOutcome = try await waitForOutcome(secondBox)
        XCTAssertEqual(secondOutcome, .timedOut)
        let remaining = await broker.queuedCount
        XCTAssertEqual(remaining, 0, "a lapsed burst leaves nothing queued")
        let pending = await pendingIDs(broker)
        XCTAssertEqual(pending, [])
    }

    /// Two requests whose deadlines land on the same instant, which is what a
    /// clock frozen between the two `request` calls produces: both budgets are read
    /// at enqueue, so with a clock that does not move they are identical.
    ///
    /// This is the case where a request is not at the head when its own budget
    /// lapses, so it is the case that exercises expiry removing an entry from the
    /// middle of the queue rather than the front — which a real clock cannot produce,
    /// because staggered enqueues offset the 50 ms wake-ups and the head's budget
    /// always runs out first. Both callers must come back `.timedOut` and nothing may
    /// be left queued, whichever entry the timers reach first.
    func testTwoRequestsOnTheSameDeadlineBothTimeOut() async throws {
        let clock = FakeClock()
        let broker = ConfirmationBroker(clock: { clock.now })
        let first = makeRequest(kind: .quitApp, summary: "Quit Mail?")
        let second = makeRequest(kind: .stopContainer, summary: "Stop container web")

        let (firstBox, _) = start(broker, first)
        let (secondBox, _) = start(broker, second)
        // Both are live before anything is decided, so neither deadline has passed
        // and the queue is the thing being asserted, not one request's timing.
        await waitForQueued(broker, 2)
        await waitWhileSuspended(firstBox)
        await waitWhileSuspended(secondBox)
        XCTAssertNil(firstBox.outcome, "a budget that has not elapsed must not expire")
        XCTAssertNil(secondBox.outcome, "a budget that has not elapsed must not expire")

        // One advance past the shared deadline, so both timers lapse together.
        clock.advance(by: ConfirmationBroker.defaultTimeout + 1)
        let firstOutcome = try await waitForOutcome(firstBox)
        XCTAssertEqual(firstOutcome, .timedOut)
        let secondOutcome = try await waitForOutcome(secondBox)
        XCTAssertEqual(secondOutcome, .timedOut)
        let remaining = await broker.queuedCount
        XCTAssertEqual(remaining, 0, "a lapsed pair leaves nothing queued")
        let pending = await pendingIDs(broker)
        XCTAssertEqual(pending, [])
    }

    // MARK: - Answering a request that is not the one on screen

    /// A presenter may be holding a request that has been superseded, or a window
    /// that outlived the queue. `decide` answers by id wherever the request is, so
    /// answering a queued request reaches that caller and leaves the presented one
    /// alone — the alternative, restricting `decide` to the head, would strand
    /// every request behind an answer the user already gave.
    func testDecideAnswersAQueuedRequestWithoutDisturbingTheHead() async throws {
        let broker = ConfirmationBroker(timeout: 5)
        let first = makeRequest(kind: .quitApp, summary: "Quit Mail?")
        let second = makeRequest(kind: .stopContainer, summary: "Stop container web")

        let (firstBox, _) = start(broker, first)
        let presented = await waitForPending(broker, 1)
        XCTAssertEqual(presented.map(\.id), [first.id])
        let (secondBox, _) = start(broker, second)
        await waitForQueued(broker, 2)

        await broker.decide(id: second.id, outcome: .approved)
        let secondOutcome = try await waitForOutcome(secondBox)
        XCTAssertEqual(secondOutcome, .approved, "the answer must reach its own caller")

        await waitWhileSuspended(firstBox)
        XCTAssertNil(
            firstBox.outcome,
            "answering the queued request must not decide the presented one"
        )
        let stillPresented = await pendingIDs(broker)
        XCTAssertEqual(stillPresented, [first.id], "the head is untouched")
        let depth = await broker.queuedCount
        XCTAssertEqual(depth, 1)

        await broker.decide(id: first.id, outcome: .approved)
        let firstOutcome = try await waitForOutcome(firstBox)
        XCTAssertEqual(firstOutcome, .approved)
    }

    func testCancelAllDeniesEverythingPending() async throws {
        let broker = ConfirmationBroker(timeout: 5)
        let first = makeRequest(kind: .quitApp, summary: "Quit Mail?")
        let second = makeRequest(kind: .stopProject, summary: "Stop project web")

        let (firstBox, _) = start(broker, first)
        let presented = await waitForPending(broker, 1)
        XCTAssertEqual(presented.map(\.id), [first.id])
        let (secondBox, _) = start(broker, second)
        // Wait for the enqueue itself rather than a slice of real time: `pending`
        // cannot show a request that is still waiting its turn.
        await waitForQueued(broker, 2)

        await broker.cancelAll(reason: "Portmaster is quitting.")

        // Denied, not left hanging: a caller must never wait out the budget when
        // the answer is already known.
        let firstOutcome = try await waitForOutcome(firstBox)
        XCTAssertEqual(firstOutcome, .denied(reason: "Portmaster is quitting."))
        let secondOutcome = try await waitForOutcome(secondBox)
        XCTAssertEqual(secondOutcome, .denied(reason: "Portmaster is quitting."))
        let remaining = await pendingIDs(broker)
        XCTAssertEqual(remaining, [])

        // `cancelAll` is a bulk denial of what is queued, not a close: whether the
        // broker stops accepting requests is the caller's decision to make, not a
        // side effect of shutting a batch down. A caller that comes back afterwards
        // must be served, or a late tool call would hang for its whole budget.
        let later = makeRequest(kind: .setPreference, summary: "Change temperatureUnit")
        let (laterBox, _) = start(broker, later)
        let laterPresented = await waitForPending(broker, 1)
        XCTAssertEqual(laterPresented.map(\.id), [later.id])
        await broker.decide(id: later.id, outcome: .approved)
        let laterOutcome = try await waitForOutcome(laterBox)
        XCTAssertEqual(laterOutcome, .approved, "the broker keeps serving after a bulk denial")
    }

    func testAFailedDecisionDoesNotLeakTheContinuation() async throws {
        let broker = ConfirmationBroker(timeout: 5)
        let first = makeRequest(kind: .quitApp, summary: "Quit Mail?")
        let second = makeRequest(kind: .stopContainer, summary: "Stop container web")

        let (firstBox, _) = start(broker, first)
        await waitForPending(broker, 1)
        let (secondBox, _) = start(broker, second)
        await waitForQueued(broker, 2)

        // The interesting half of "no leak": a caller that says no must not
        // consume or strand the request waiting behind it.
        await broker.decide(id: first.id, outcome: .denied(reason: "Not this time."))
        let firstOutcome = try await waitForOutcome(firstBox)
        XCTAssertEqual(firstOutcome, .denied(reason: "Not this time."))

        let nowPresented = await waitForPending(broker, 1)
        XCTAssertEqual(nowPresented.map(\.id), [second.id])
        await broker.decide(id: second.id, outcome: .approved)
        let secondOutcome = try await waitForOutcome(secondBox)
        XCTAssertEqual(secondOutcome, .approved)
        let remaining = await pendingIDs(broker)
        XCTAssertEqual(remaining, [])
    }

    // MARK: - A caller that gives up

    /// A caller whose own task is cancelled mid-wait must not disappear from the
    /// queue and must not take the next request with it. The broker owes it an
    /// outcome either way: dropping the entry would leak the continuation, and
    /// resuming it later is legal even though the awaiting task no longer cares.
    func testACancelledCallerDoesNotStrandTheQueue() async throws {
        let broker = ConfirmationBroker(timeout: 5)
        let abandoned = makeRequest(kind: .quitApp, summary: "Quit Mail?")
        let abandonedTask = Task { await broker.request(abandoned) }
        await waitForPending(broker, 1)

        abandonedTask.cancel()

        let next = makeRequest(kind: .stopContainer, summary: "Stop container web")
        let (nextBox, _) = start(broker, next)
        await waitForQueued(broker, 2)
        let afterCancel = await pendingIDs(broker)
        XCTAssertEqual(
            afterCancel, [abandoned.id],
            "the abandoned request is still owed a decision, and still heads the queue"
        )

        await broker.decide(id: abandoned.id, outcome: .denied(reason: "Caller went away."))
        let abandonedOutcome = await abandonedTask.value
        XCTAssertEqual(
            abandonedOutcome, .denied(reason: "Caller went away."),
            "a cancelled caller must still be resumed rather than left suspended"
        )

        let nowPresented = await waitForPending(broker, 1)
        XCTAssertEqual(nowPresented.map(\.id), [next.id])
        await broker.decide(id: next.id, outcome: .approved)
        let nextOutcome = try await waitForOutcome(nextBox)
        XCTAssertEqual(nextOutcome, .approved, "the next request is unaffected")
        let remaining = await pendingIDs(broker)
        XCTAssertEqual(remaining, [])
    }

    /// Ids are how the broker matches an answer to a caller, so two live entries
    /// sharing one id would make the answer a coin toss — and a stale answer could
    /// be handed to the wrong caller. The second request is refused outright
    /// rather than queued behind an id it cannot be told apart from, which keeps
    /// "one entry per id" an invariant the broker maintains instead of assumes.
    func testADuplicateIDIsRefusedRatherThanQueued() async throws {
        let broker = ConfirmationBroker(timeout: 5)
        let shared = UUID()
        let first = makeRequest(kind: .quitApp, summary: "Quit Mail?", id: shared)
        let (firstBox, _) = start(broker, first)
        await waitForPending(broker, 1)

        let (secondBox, _) = start(
            broker, makeRequest(kind: .stopContainer, summary: "Stop container web", id: shared)
        )
        let secondOutcome = try await waitForOutcome(secondBox)
        guard case .denied(let reason) = secondOutcome else {
            return XCTFail("a duplicate id must be denied, got \(secondOutcome)")
        }
        // Matched loosely on purpose: the exact wording is user-facing text that can
        // change without anything breaking, so pinning it here would only make the
        // test a tripwire for a copy edit.
        XCTAssertTrue(
            reason.contains("already awaiting a decision"),
            "the reason must say the id is taken, got: \(reason)"
        )
        let depth = await broker.queuedCount
        XCTAssertEqual(depth, 1, "only the first request is waiting")

        // And the surviving entry is answerable, which is the half that matters:
        // the answer went to the request it was asked about.
        await broker.decide(id: shared, outcome: .approved)
        let firstOutcome = try await waitForOutcome(firstBox)
        XCTAssertEqual(firstOutcome, .approved)
    }

    // MARK: - What a presenter can count down to

    /// A window that closes with two requests behind it has to answer exactly those two,
    /// and `queuedCount` cannot say which two they are — `pending` holds at most the one
    /// being presented. So the ids of the whole queue have to be readable, in order: a
    /// close that swept "whatever is queued" would also sweep a request that arrived in
    /// the gap between the snapshot and the answer.
    func testQueuedIDsNamesEveryWaitingRequestInOrder() async throws {
        let broker = ConfirmationBroker(timeout: 5)
        let empty = await broker.queuedIDs
        XCTAssertEqual(empty, [], "nothing is waiting")

        let first = makeRequest(summary: "Quit Mail?")
        let second = makeRequest(kind: .stopContainer, summary: "Stop container web")
        let (firstBox, _) = start(broker, first)
        let (secondBox, _) = start(broker, second)
        await waitForQueued(broker, 2)

        let queued = await broker.queuedIDs
        XCTAssertEqual(queued, [first.id, second.id], "oldest first, and every one of them")

        await broker.decide(id: second.id, outcome: .approved)
        let secondOutcome = try await waitForOutcome(secondBox)
        XCTAssertEqual(secondOutcome, .approved)
        let afterDecidingOne = await broker.queuedIDs
        XCTAssertEqual(
            afterDecidingOne, [first.id],
            "answering one must not lose track of the other"
        )

        await broker.decide(id: first.id, outcome: .denied(reason: "no"))
        _ = try await waitForOutcome(firstBox)
        let drained = await broker.queuedIDs
        XCTAssertEqual(drained, [], "an answered request leaves the queue")
    }

    /// A presenter shows the remaining budget, and the only honest source for that is
    /// the deadline the budget task was armed with. A presenter that counted from its
    /// own arrival would be measuring a different clock: the budget starts when the
    /// request is *made*, so a request queued behind others — or one whose window took
    /// a moment to appear — has less time left than the presenter thinks.
    func testThePendingDeadlineIsTheBudgetsOwn() async throws {
        let clock = FakeClock()
        let broker = ConfirmationBroker(
            timeout: ConfirmationBroker.defaultTimeout, clock: { clock.now }
        )
        let empty = await broker.pendingDeadline
        XCTAssertNil(empty, "nothing is waiting, so there is no deadline to show")

        let (box, _) = start(broker, makeRequest())
        await waitForPending(broker, 1)
        let armed = await broker.pendingDeadline
        let deadline = try XCTUnwrap(armed)
        XCTAssertEqual(
            deadline.timeIntervalSince(clock.now),
            ConfirmationBroker.defaultTimeout,
            accuracy: 0.001,
            "the deadline must be the armed budget, not the presenter's own clock"
        )

        let presented = await waitForPending(broker, 1)
        let id = try XCTUnwrap(presented.first?.id)
        await broker.decide(id: id, outcome: .approved)
        _ = try await waitForOutcome(box)
        let afterDecision = await broker.pendingDeadline
        XCTAssertNil(afterDecision, "a decided request has no budget left to count down")
    }

    /// The deadline belongs to the request being presented, so it moves when the next
    /// request takes its place rather than describing whoever arrived first.
    func testTheDeadlineFollowsTheRequestBeingPresented() async throws {
        let broker = ConfirmationBroker(timeout: 30)
        let first = makeRequest(summary: "Quit Mail?")
        let (firstBox, _) = start(broker, first)
        await waitForPending(broker, 1)
        let firstDeadlineBox = await broker.pendingDeadline
        let firstDeadline = try XCTUnwrap(firstDeadlineBox)

        let second = makeRequest(kind: .stopContainer, summary: "Stop container web")
        let (secondBox, _) = start(broker, second)
        await waitForQueued(broker, 2)
        let queued = await broker.pendingDeadline
        let whileQueued = try XCTUnwrap(queued)
        XCTAssertEqual(
            whileQueued.timeIntervalSince(firstDeadline), 0, accuracy: 0.001,
            "the request being presented is still the first one"
        )

        await broker.decide(id: first.id, outcome: .approved)
        _ = try await waitForOutcome(firstBox)
        await waitForPending(broker, 1)
        let next = await broker.pendingDeadline
        let secondDeadline = try XCTUnwrap(next)
        XCTAssertGreaterThan(
            secondDeadline, firstDeadline,
            "the next request was made later, so its own budget ends later"
        )
        await broker.decide(id: second.id, outcome: .approved)
        _ = try await waitForOutcome(secondBox)
    }

    // MARK: - The clock is real, not decorative

    /// The budget is measured against the injected clock, not against wall time.
    /// Without this, a 60-second budget could only be tested by not deciding for
    /// 60 seconds, and the default would be the only budget worth trusting.
    func testAnInjectedClockExpiresTheBudgetWithoutWaitingForIt() async throws {
        let clock = FakeClock()
        let broker = ConfirmationBroker(timeout: ConfirmationBroker.defaultTimeout, clock: { clock.now })
        let (box, _) = start(broker, makeRequest())
        await waitForPending(broker, 1)

        await waitWhileSuspended(box)
        XCTAssertNil(box.outcome, "a budget that has not elapsed must not expire")

        clock.advance(by: ConfirmationBroker.defaultTimeout + 1)
        let outcome = try await waitForOutcome(box)
        XCTAssertEqual(outcome, .timedOut, "advancing the clock must expire the default budget")
        let remaining = await pendingIDs(broker)
        XCTAssertEqual(remaining, [])
    }

    /// A presenter that answers after the budget ran out must be inert. This is
    /// the double-resume hazard in its purest form: resuming an already-resumed
    /// `CheckedContinuation` traps, so the outcome has to stay the timeout and
    /// the broker has to keep serving.
    func testALateDecisionAfterATimeoutIsIgnored() async throws {
        let broker = ConfirmationBroker(timeout: 0.05)
        let request = makeRequest()
        let (box, _) = start(broker, request)
        let outcome = try await waitForOutcome(box)
        XCTAssertEqual(outcome, .timedOut)

        await broker.decide(id: request.id, outcome: .approved)
        let afterLateDecision = await pendingIDs(broker)
        XCTAssertEqual(afterLateDecision, [], "a late answer has nothing to answer")
        XCTAssertEqual(box.outcome, .timedOut, "the first outcome stands")

        let next = makeRequest(kind: .stopProject, summary: "Stop project web")
        let (nextBox, _) = start(broker, next)
        let presented = await waitForPending(broker, 1)
        XCTAssertEqual(presented.map(\.id), [next.id])
        await broker.decide(id: next.id, outcome: .approved)
        let nextOutcome = try await waitForOutcome(nextBox)
        XCTAssertEqual(
            nextOutcome, .approved,
            "the broker must still serve requests after a late answer"
        )
    }

    // MARK: - Helpers

    private func makeRequest(
        kind: MCPApprovalRequest.Kind = .quitApp,
        summary: String = "Quit Mail?",
        detail: String = "Portmaster will ask Mail to quit.",
        id: UUID = UUID()
    ) -> MCPApprovalRequest {
        MCPApprovalRequest(id: id, kind: kind, summary: summary, detail: detail)
    }

    /// Runs a request in its own task and records what came back.
    ///
    /// A `Task` cannot be asked whether it is finished, and awaiting one that is
    /// *meant* to be suspended would hang the test instead of failing it. So the
    /// answer lands in a box the test polls, which turns "did it come back?" into
    /// a question with a deadline.
    private func start(
        _ broker: ConfirmationBroker,
        _ request: MCPApprovalRequest
    ) -> (OutcomeBox, Task<Void, Never>) {
        let box = OutcomeBox()
        let task = Task { box.store(await broker.request(request)) }
        return (box, task)
    }

    /// The ids currently presented, hoisted out of the actor because `XCTAssert*`
    /// takes autoclosures, and an autoclosure cannot await.
    private func pendingIDs(_ broker: ConfirmationBroker) async -> [UUID] {
        await broker.pending.map(\.id)
    }

    /// Polls until the queue holds exactly `count` requests, or fails the test.
    ///
    /// This is the deterministic enqueue signal. `pending` cannot be it: it holds
    /// at most the request being presented, so a second request waiting its turn
    /// is invisible and a test can only guess at how long it takes to get there.
    @discardableResult
    private func waitForQueued(
        _ broker: ConfirmationBroker,
        _ count: Int,
        timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        var latest = 0
        while Date() < deadline {
            latest = await broker.queuedCount
            if latest == count { return latest }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("expected \(count) queued request(s), saw \(latest)", file: file, line: line)
        return latest
    }

    /// Polls until exactly `count` requests are presented, or fails the test.
    /// Bounded on purpose: a broker that never publishes is a failure to report,
    /// not a suite to hang.
    @discardableResult
    private func waitForPending(
        _ broker: ConfirmationBroker,
        _ count: Int,
        timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> [MCPApprovalRequest] {
        let deadline = Date().addingTimeInterval(timeout)
        var latest: [MCPApprovalRequest] = []
        while Date() < deadline {
            latest = await broker.pending
            if latest.count == count { return latest }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail(
            "expected \(count) pending request(s), saw \(latest.map(\.id))",
            file: file, line: line
        )
        return latest
    }

    /// Waits for a request to come back, within a bound that keeps a broken broker
    /// from wedging the suite.
    private func waitForOutcome(
        _ box: OutcomeBox,
        timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> ApprovalOutcome {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let outcome = box.outcome { return outcome }
            try await Task.sleep(for: .milliseconds(2))
        }
        // `XCTUnfail` would be the tidier tool — report the diagnosis without
        // failing, and let the throw below be the only failure — but it does not
        // exist in this toolchain's XCTest (checked against the SDK with a
        // standalone type-check, on Swift 6.4). So the diagnosis is carried twice
        // instead: once as the recorded failure, and once in the thrown error's
        // own description, which is what XCTest prints if the body unwinds
        // through here. A `CancellationError` standing in for "this never
        // happened" reads as a failure of something else and hides the cause.
        XCTFail("the request never came back", file: file, line: line)
        throw NeverReturned.theRequestNeverCameBack
    }

    /// Gives a request that must *not* resolve a bounded chance to resolve
    /// wrongly. Only useful as the negative half of an assertion.
    private func waitWhileSuspended(_ box: OutcomeBox, duration: TimeInterval = 0.05) async {
        let deadline = Date().addingTimeInterval(duration)
        repeat {
            if box.outcome != nil { return }
            try? await Task.sleep(for: .milliseconds(2))
        } while Date() < deadline
    }

    /// A recorded outcome. `@unchecked Sendable` because the request task writes
    /// it and the test task reads it; the lock is what makes that safe.
    private final class OutcomeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: ApprovalOutcome?

        var outcome: ApprovalOutcome? { lock.withLock { stored } }

        func store(_ outcome: ApprovalOutcome) {
            lock.withLock { stored = outcome }
        }
    }

    /// A clock a test moves by hand, so a timeout budget can expire without the
    /// test spending real seconds on it.
    private final class FakeClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current: Date

        init(now: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
            current = now
        }

        var now: Date { lock.withLock { current } }

        func advance(by seconds: TimeInterval) {
            lock.withLock { current = current.addingTimeInterval(seconds) }
        }
    }
}

/// Thrown only to abandon a test whose subject never arrived. It lives at file
/// scope rather than nested in the test case because a nested type inherits the
/// case's isolation and could not be constructed from the helper that throws it.
private enum NeverReturned: Error, CustomStringConvertible {
    case theRequestNeverCameBack

    /// Printed by XCTest when a test body unwinds through here, so it has to say
    /// what went wrong rather than name a Swift type.
    var description: String {
        "the request never came back: the broker never resumed it within the wait"
    }
}
