// MCPApprovalPresentationTests: the words a person answers an AI client with, and what
// a button press means to the broker.
//
// `App/MCPConfirmationWindow.swift` has no test target — the app scheme builds and
// nothing runs — so the two parts of it that are *decisions* rather than drawing live
// here as a library type: `MCPApprovalCopy`'s wording (what each kind of change is
// called, what it will do, and exactly which processes/containers/preferences it will
// touch) and its mapping from a button press to the broker's `ApprovalOutcome`.
//
// Three properties are worth holding still, because each is a way this feature can be
// quietly wrong rather than loudly broken:
//
//  1. **The window shows the request, not a guess at it.** Every target line has to
//     appear in the wording, so "the exact processes" cannot be a claim the copy makes
//     and the view does not keep.
//  2. **One implementation of each sentence.** `HostMCPCallContext` builds the question
//     the broker holds; the window shows words from `MCPApprovalCopy`. A test walks the
//     catalog and fails if those two ever disagree, which is the failure a person would
//     otherwise see as the app asking about something the client never asked for.
//  3. **Every button ends the request.** Approve is `.approved`; Deny, closing the
//     window, and a window that could not be shown are all refusals *with a reason*,
//     checked against a real broker so a mapping that never reaches `decide` is a red
//     test rather than a 60-second wait in production.

import Foundation
@testable import PortmasterMCP
import XCTest

final class MCPApprovalPresentationTests: XCTestCase {

    // MARK: - What each kind of change is called

    /// The heading above the question. Four different sentences for four different
    /// changes: a prompt that called every mutation "Change" would tell a person
    /// nothing about what they are about to agree to.
    func testEveryKindIsNamedInPlainLanguage() {
        XCTAssertEqual(MCPApprovalCopy.summary(for: .quitApp), "Quit an app")
        XCTAssertEqual(MCPApprovalCopy.summary(for: .stopContainer), "Stop a container")
        XCTAssertEqual(MCPApprovalCopy.summary(for: .stopProject), "Stop a project")
        XCTAssertEqual(
            MCPApprovalCopy.summary(for: .setPreference),
            "Change a Portmaster preference"
        )
        let headings = MCPApprovalRequest.Kind.allCasesForTests.map {
            MCPApprovalCopy.summary(for: $0)
        }
        XCTAssertEqual(
            Set(headings).count, headings.count,
            "two kinds must not share one heading: \(headings)"
        )
    }

    /// The button that grants consent says what it grants, so a person is never
    /// approving an unnamed "OK".
    func testEveryKindNamesItsOwnApproveButton() {
        XCTAssertEqual(MCPApprovalCopy.approveTitle(for: .quitApp), "Quit App")
        XCTAssertEqual(MCPApprovalCopy.approveTitle(for: .stopProject), "Quit Project")
        XCTAssertEqual(MCPApprovalCopy.approveTitle(for: .stopContainer), "Stop Container")
        XCTAssertEqual(MCPApprovalCopy.approveTitle(for: .setPreference), "Change Preference")
    }

    // MARK: - What the request will do, and to what

    func testAQuitNamesTheAppAndEveryProcessItWillQuit() {
        let detail = MCPApprovalCopy.detail(
            for: .quitApp,
            arguments: ["id": "app:Chrome", "force": "false"],
            targets: ["Chrome — PID 4321", "Chrome Helper — PID 4322"]
        )

        XCTAssertTrue(
            detail.contains("app:Chrome"), "the app the client named: \(detail)"
        )
        XCTAssertTrue(
            detail.contains("asking each to close cleanly first"),
            "a graceful quit must say it asks first: \(detail)"
        )
        XCTAssertTrue(detail.contains("2 processes"), "the count of what is affected: \(detail)")
        XCTAssertTrue(detail.contains("• Chrome — PID 4321"), "process name and pid: \(detail)")
        XCTAssertTrue(
            detail.contains("• Chrome Helper — PID 4322"),
            "every member, not just the first: \(detail)"
        )
    }

    func testAForcedQuitSaysItWillNotAskToSave() {
        let detail = MCPApprovalCopy.detail(
            for: .quitApp,
            arguments: ["id": "app:Chrome", "force": "true"],
            targets: ["Chrome — PID 4321"]
        )
        XCTAssertTrue(
            detail.contains("without asking it to save first"),
            "a force quit does not ask, so the copy must not imply it does: \(detail)"
        )
        XCTAssertFalse(
            detail.contains("asking each to close cleanly first"),
            "the two force states must not read alike: \(detail)"
        )
    }

    func testAProjectListsItsProcessesToo() {
        let detail = MCPApprovalCopy.detail(
            for: .stopProject,
            arguments: ["id": "/src/api"],
            targets: ["api — PID 900", "node — PID 901"]
        )
        XCTAssertTrue(detail.contains("/src/api"), "the project path: \(detail)")
        XCTAssertTrue(detail.contains("• api — PID 900"), "its first process: \(detail)")
        XCTAssertTrue(detail.contains("• node — PID 901"), "and its second: \(detail)")
    }

    /// A container has no process list, so the copy must not invent one: what it names
    /// is the container and the command that will be run against it.
    func testAContainerNamesTheContainerAndTheCommand() {
        let detail = MCPApprovalCopy.detail(
            for: .stopContainer, arguments: ["id": "web"], targets: ["web"]
        )
        XCTAssertTrue(detail.contains("docker stop web"), "the command: \(detail)")
        XCTAssertTrue(detail.contains("• web"), "the one target: \(detail)")
        XCTAssertFalse(
            detail.contains("PID"), "a container has no pid to show: \(detail)"
        )
    }

    func testAPreferenceChangeShowsTheKeyAndTheValue() {
        let detail = MCPApprovalCopy.detail(
            for: .setPreference,
            arguments: ["key": "temperatureUnit", "value": "celsius"],
            targets: ["temperatureUnit = celsius"]
        )
        XCTAssertTrue(detail.contains("temperatureUnit"), "the key: \(detail)")
        XCTAssertTrue(detail.contains("celsius"), "the value: \(detail)")
        XCTAssertTrue(
            detail.contains("• temperatureUnit = celsius"),
            "the change as one line a person can check against Settings: \(detail)"
        )
    }

    /// The list is additive. The question the broker holds was written before anything
    /// resolved, so with nothing to list the detail has to be the sentence alone — which
    /// is also what makes the anti-drift test below meaningful.
    func testWithNothingToListTheDetailIsTheSentenceAlone() {
        let detail = MCPApprovalCopy.detail(
            for: .quitApp, arguments: ["id": "app:Chrome"], targets: []
        )
        XCTAssertEqual(
            detail,
            "Quit every process of app:Chrome, asking each to close cleanly first."
        )
        XCTAssertFalse(detail.contains("•"), "no targets, no bullets: \(detail)")
    }

    /// Arguments the client did not supply must not produce a sentence with a hole in
    /// it. The executor rejects those calls first; the copy is what a person would read
    /// if one ever reached them, and "Quit every process of , asking…" is not that.
    func testAnUnnamedRequestStillReadsAsASentence() {
        let detail = MCPApprovalCopy.detail(for: .quitApp, arguments: [:], targets: [])
        XCTAssertTrue(
            detail.contains("did not name"),
            "a missing name is named as missing, not left blank: \(detail)"
        )
        XCTAssertFalse(detail.contains("of ,"), "no empty name: \(detail)")
        XCTAssertFalse(detail.contains("  "), "no hole where the name was: \(detail)")
        let preference = MCPApprovalCopy.detail(
            for: .setPreference, arguments: ["key": "  "], targets: []
        )
        XCTAssertTrue(
            preference.contains("did not name"),
            "a blank key is not a name: \(preference)"
        )
        XCTAssertFalse(preference.contains("'s  "), "no blank key: \(preference)")
    }

    /// One implementation of each sentence.
    ///
    /// `HostMCPCallContext.request` builds what the broker holds and the window shows
    /// `MCPApprovalCopy`'s words; if those ever come from two places, the app asks about
    /// one change and shows another. Walking the catalog rather than a hand-written list
    /// means a fifth mutation fails this test instead of arriving undescribed.
    func testTheQuestionAskedIsTheOneTheWindowShows() throws {
        var kinds: Set<MCPApprovalRequest.Kind> = []
        var mutations = 0
        for tool in ToolExecutor.catalog where tool.effect == .mutation {
            mutations += 1
            let arguments = try XCTUnwrap(
                Self.sampleArguments(for: tool.name),
                "\(tool.name) has no sample arguments, so this test cannot describe it"
            )
            let request = HostMCPCallContext.request(for: tool, arguments: arguments)
            kinds.insert(request.kind)
            XCTAssertEqual(
                request.detail,
                MCPApprovalCopy.detail(for: request.kind, arguments: arguments, targets: []),
                "\(tool.name) is asked about in one set of words"
            )
            XCTAssertFalse(
                request.summary.isEmpty, "\(tool.name) is asked with no question"
            )
            XCTAssertFalse(
                MCPApprovalCopy.summary(for: request.kind).isEmpty,
                "\(tool.name) is shown with no heading"
            )
        }
        XCTAssertEqual(kinds.count, MCPApprovalRequest.Kind.allCasesForTests.count)
        XCTAssertEqual(mutations, MCPApprovalRequest.Kind.allCasesForTests.count)
    }

    // MARK: - What else the window says

    /// Only when there is something to say: an empty string is what keeps a lone
    /// request from claiming it is one of many.
    func testTheQueuedNoticeCountsWhatIsBehind() {
        XCTAssertEqual(MCPApprovalCopy.queuedNotice(additional: 0), "")
        XCTAssertEqual(
            MCPApprovalCopy.queuedNotice(additional: 1),
            "1 more request is waiting behind this one."
        )
        XCTAssertEqual(
            MCPApprovalCopy.queuedNotice(additional: 3),
            "3 more requests are waiting behind this one."
        )
    }

    /// The client gives up at 60 seconds whether or not a person is looking, so the
    /// window counts it down rather than waiting to be discovered as a spinner.
    func testTheCountdownNamesTheBudgetTheClientWillGiveUpOn() {
        XCTAssertEqual(
            MCPApprovalCopy.countdown(remaining: 42),
            "No answer in 42s — Portmaster refuses this action and tells the AI client."
        )
        XCTAssertEqual(
            MCPApprovalCopy.countdown(remaining: 1),
            "No answer in 1s — Portmaster refuses this action and tells the AI client."
        )
        XCTAssertEqual(
            MCPApprovalCopy.countdown(remaining: 0),
            "The AI client's budget is spent; this action is being refused."
        )
        XCTAssertEqual(
            MCPApprovalCopy.countdown(remaining: -3),
            MCPApprovalCopy.countdown(remaining: 0),
            "a budget already spent must not read as a countdown"
        )
        XCTAssertEqual(
            MCPApprovalCopy.countdown(remaining: 0.2),
            MCPApprovalCopy.countdown(remaining: 1),
            "a budget with a fraction left still counts as one whole second"
        )
    }

    // MARK: - What a button press means to the broker

    func testApprovingIsAnApprovalAndNothingElse() {
        XCTAssertEqual(MCPApprovalCopy.outcome(for: .approve), .approved)
    }

    func testDenyingIsARefusalCarryingAReason() throws {
        guard case .denied(let reason) = MCPApprovalCopy.outcome(for: .deny) else {
            return XCTFail("a denial must be a denial")
        }
        XCTAssertEqual(reason, MCPApprovalCopy.deniedReason)
        XCTAssertTrue(reason.contains("not taken"), "what happened: \(reason)")
    }

    /// Closing the window is the default answer, so it has to be a refusal too — and a
    /// person who closes it has not said "yes", whatever they meant.
    func testClosingTheWindowIsARefusalCarryingItsOwnReason() throws {
        guard case .denied(let reason) = MCPApprovalCopy.outcome(for: .closed) else {
            return XCTFail("a closed window must be a denial")
        }
        XCTAssertEqual(reason, MCPApprovalCopy.closedReason)
        XCTAssertNotEqual(
            reason, MCPApprovalCopy.deniedReason,
            "closing and denying are different acts and reach the client differently"
        )
    }

    /// The reason a window that could not be shown gives. Pinned exactly: it is what
    /// an AI client reports when the app could not ask, and a paraphrase here would be
    /// a second, worse explanation of the same fact.
    func testAWindowThatCannotBeShownSaysSo() {
        XCTAssertEqual(
            MCPApprovalCopy.couldNotPresentReason,
            "Portmaster could not show the confirmation window."
        )
    }

    // MARK: - The mapping, against a real broker

    /// The whole point of the mapping: a press reaches `decide` and the waiting caller
    /// comes back. Checked against the broker rather than against a recording closure,
    /// because "the closure ran" and "the request was answered" are different claims.
    func testApproveAnswersTheWaitingCaller() async throws {
        let broker = ConfirmationBroker(timeout: 5)
        let box = ask(broker, makeRequest())

        let id = try await waitForPendingID(broker)
        await broker.decide(id: id, outcome: MCPApprovalCopy.outcome(for: .approve))

        let outcome = try await waitForOutcome(box)
        XCTAssertEqual(outcome, .approved)
        let remaining = await broker.queuedCount
        XCTAssertEqual(remaining, 0, "the queue must be empty afterwards")
    }

    func testDenyAnswersTheWaitingCallerWithTheReason() async throws {
        let broker = ConfirmationBroker(timeout: 5)
        let box = ask(broker, makeRequest())

        let id = try await waitForPendingID(broker)
        await broker.decide(id: id, outcome: MCPApprovalCopy.outcome(for: .deny))

        let outcome = try await waitForOutcome(box)
        XCTAssertEqual(outcome, .denied(reason: MCPApprovalCopy.deniedReason))
    }

    func testClosingTheWindowAnswersTheWaitingCallerWithTheReason() async throws {
        let broker = ConfirmationBroker(timeout: 5)
        let box = ask(broker, makeRequest())

        let id = try await waitForPendingID(broker)
        await broker.decide(id: id, outcome: MCPApprovalCopy.outcome(for: .closed))

        let outcome = try await waitForOutcome(box)
        XCTAssertEqual(outcome, .denied(reason: MCPApprovalCopy.closedReason))
    }

    /// A window that could not be shown must not make the client wait out a 60-second
    /// budget for an answer nobody can give. The assertion is about the wait, not the
    /// words: it has to come back in well under the budget it would otherwise burn.
    func testAWindowThatCannotBeShownIsRefusedWithoutWaiting() async throws {
        let broker = ConfirmationBroker(timeout: ConfirmationBroker.defaultTimeout)
        let box = ask(broker, makeRequest())
        let started = Date()

        let id = try await waitForPendingID(broker)
        await broker.decide(
            id: id, outcome: .denied(reason: MCPApprovalCopy.couldNotPresentReason)
        )

        let outcome = try await waitForOutcome(box)
        XCTAssertEqual(outcome, .denied(reason: MCPApprovalCopy.couldNotPresentReason))
        XCTAssertLessThan(
            Date().timeIntervalSince(started), 2,
            "an unanswerable prompt must be refused at once, not at the budget"
        )
    }

    /// A press for a request that is no longer waiting must be inert rather than
    /// landing on whatever is at the head of the queue now. This is the window that was
    /// already answered (or already timed out) while it was still on screen.
    func testAPressForAnAlreadyAnsweredRequestReachesNobody() async throws {
        let broker = ConfirmationBroker(timeout: 5)
        let stale = makeRequest(summary: "Quit app:Stale?")
        let box = ask(broker, stale)
        let id = try await waitForPendingID(broker)
        await broker.decide(id: id, outcome: .approved)
        let approved = try await waitForOutcome(box)
        XCTAssertEqual(approved, .approved)

        // The next request arrives and the old window's button is pressed late.
        let current = makeRequest(kind: .stopContainer, summary: "Stop container web?")
        let next = ask(broker, current)
        let currentID = try await waitForPendingID(broker)
        await broker.decide(id: id, outcome: MCPApprovalCopy.outcome(for: .approve))

        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(
            next.outcome, "a late answer must not resume the request now waiting"
        )
        await broker.decide(id: currentID, outcome: .denied(reason: MCPApprovalCopy.deniedReason))
        let nextOutcome = try await waitForOutcome(next)
        XCTAssertEqual(nextOutcome, .denied(reason: MCPApprovalCopy.deniedReason))
    }

    // MARK: - Helpers

    /// One valid argument set per mutation, so the anti-drift test describes every tool
    /// the catalog declares. A mutation added without one fails there rather than being
    /// quietly skipped.
    private static func sampleArguments(for tool: String) -> [String: String]? {
        switch tool {
        case "quit_app": return ["id": "app:Chrome", "force": "false"]
        case "stop_container": return ["id": "web"]
        case "stop_project": return ["id": "/src/api"]
        case "set_preference": return ["key": "temperatureUnit", "value": "celsius"]
        default: return nil
        }
    }

    private func makeRequest(
        kind: MCPApprovalRequest.Kind = .quitApp,
        summary: String = "Quit app:Chrome?",
        detail: String = "Quit every process of app:Chrome, asking each to close cleanly first."
    ) -> MCPApprovalRequest {
        MCPApprovalRequest(kind: kind, summary: summary, detail: detail)
    }

    /// Puts a request on the broker in its own task, so the test can ask whether it
    /// came back without awaiting something meant to be suspended.
    private func ask(_ broker: ConfirmationBroker, _ request: MCPApprovalRequest) -> ApprovalBox {
        let box = ApprovalBox()
        Task { box.store(await broker.request(request)) }
        return box
    }

    private func waitForPendingID(
        _ broker: ConfirmationBroker, timeout: TimeInterval = 2
    ) async throws -> UUID {
        let deadline = Date().addingTimeInterval(timeout)
        var latest: [UUID] = []
        while Date() < deadline {
            latest = await broker.pending.map(\.id)
            if let first = latest.first { return first }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("no request was ever presented; saw \(latest)")
        throw ApprovalTestFailure.neverPresented
    }

    private func waitForOutcome(
        _ box: ApprovalBox, timeout: TimeInterval = 2
    ) async throws -> ApprovalOutcome {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let outcome = box.outcome { return outcome }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("the request never came back")
        throw ApprovalTestFailure.neverReturned
    }

    /// `@unchecked Sendable` because the request task writes it and the test task reads
    /// it; the lock is what makes that safe.
    private final class ApprovalBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: ApprovalOutcome?

        var outcome: ApprovalOutcome? { lock.withLock { stored } }

        func store(_ outcome: ApprovalOutcome) {
            lock.withLock { stored = outcome }
        }
    }
}

private enum ApprovalTestFailure: Error {
    case neverPresented
    case neverReturned
}

private extension MCPApprovalRequest.Kind {
    /// Every kind the type can hold, so a test can cover the set rather than a list
    /// somebody remembered to update.
    static var allCasesForTests: [MCPApprovalRequest.Kind] {
        [.quitApp, .stopContainer, .stopProject, .setPreference]
    }
}
