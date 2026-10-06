// MCPHostWiringTests: the wiring decisions the app makes, in the library.
//
// `App/MCPHostController.swift` has no test target — the app scheme builds and
// nothing runs — so the parts of it that are decisions rather than glue are
// library types with tests here: `HostMCPCallContext`, which is what turns the
// mutation mode and a person's answer into an action or a refusal, and the
// `MCPToolError` the app's snapshot closure must throw when its sampler has
// published nothing.
//
// Nothing here touches a window, a socket or the machine. The provider is the
// shared `StubProvider`, the settings file and the audit log are in a temp
// directory, the "person" is a closure, and the "sampler" is a script that
// publishes on whichever poll the test names — which is the whole of what the
// controller injects, and the reason a test can age a reading by five minutes
// without waiting five minutes.
import Foundation
import PortmasterCore
@testable import PortmasterMCP
import XCTest

final class MCPHostWiringTests: XCTestCase {

    // MARK: - A confirmed mutation

    /// The outcome that matters most and is the easiest to get wrong: a person
    /// said yes, so the action is performed and the audit log says it was
    /// allowed. Three things have to be true at once — the confirmation was
    /// asked, the approval reached the executor rather than being refused a
    /// second time by the gate, and the mutation actually happened.
    func testAnApprovedMutationIsPerformedAndAuditedAllowed() async throws {
        let provider = StubProvider()
        provider.stopReport = StopReport(results: ["4321": "stopped"])
        let directory = try makeTemporaryDirectory(prefix: "pmwiring")
        let broker = ConfirmationBroker(timeout: 5)
        let presented = RecordingPresenter()
        let context = makeContext(
            provider: provider, broker: broker, directory: directory,
            mode: .confirmEach, present: { request in
                presented.record(request)
                Task { await broker.decide(id: request.id, outcome: .approved) }
            }
        )

        let outcome = await context.call(
            name: "quit_app", arguments: ["id": "app:Chrome", "force": "true"]
        )

        XCTAssertFalse(outcome.isError, outcome.text)
        XCTAssertEqual(provider.quitAppCallCount, 1, "an approved mutation must be performed")
        XCTAssertEqual(provider.lastQuitAppID, "app:Chrome")
        XCTAssertEqual(provider.lastQuitAppForce, true)
        XCTAssertEqual(presented.requests.count, 1, "a confirmed mutation is asked about exactly once")
        let request = try XCTUnwrap(presented.requests.first)
        XCTAssertEqual(request.kind, .quitApp)
        XCTAssertEqual(
            request.summary, "Quit app:Chrome?",
            "the summary is what a person reads, so it is pinned"
        )
        XCTAssertTrue(
            request.detail.contains("app:Chrome"),
            "the detail must name what is being acted on: \(request.detail)"
        )
        XCTAssertEqual(
            try auditOutcomes(directory), ["allowed"],
            "the only audit line for an approved mutation is the one the executor wrote"
        )
    }

    // MARK: - A refused confirmation

    /// A person said no: no provider call at all, a refusal the model can read,
    /// and one `denied` line saying why. That line is written by the *host*,
    /// because the refusal happens before the executor sees the call — so the
    /// audit vocabulary has to be checked here rather than assumed.
    func testADeniedConfirmationIsRefusedAndAuditedDenied() async throws {
        let provider = StubProvider()
        let directory = try makeTemporaryDirectory(prefix: "pmwiring")
        let broker = ConfirmationBroker(timeout: 5)
        let context = makeContext(
            provider: provider, broker: broker, directory: directory,
            mode: .confirmEach, present: { request in
                Task {
                    await broker.decide(
                        id: request.id, outcome: .denied(reason: "Not this time.")
                    )
                }
            }
        )

        let outcome = await context.call(name: "stop_project", arguments: ["id": "/src/api"])

        XCTAssertTrue(outcome.isError)
        XCTAssertEqual(outcome.text, "Not this time.", "the reason reaches the caller verbatim")
        XCTAssertEqual(provider.stopProjectCallCount, 0, "a refusal must not perform the action")
        let entry = try XCTUnwrap(try auditEntries(directory).first)
        XCTAssertEqual(entry["outcome"] as? String, "denied")
        XCTAssertEqual(entry["reason"] as? String, "Not this time.")
        XCTAssertEqual(entry["tool"] as? String, "stop_project")
    }

    /// Silence is a refusal. A confirmation nobody answers must end at the
    /// broker's own budget — never as a performed action, and never as a hang —
    /// and it is audited as the denial it is.
    func testAConfirmationNobodyAnswersIsRefusedAtItsBudgetAndAuditedDenied() async throws {
        let provider = StubProvider()
        let directory = try makeTemporaryDirectory(prefix: "pmwiring")
        // A short budget rather than the production 60 seconds, so the test
        // cannot pass by sleeping through the real one.
        let broker = ConfirmationBroker(timeout: 0.2)
        let context = makeContext(
            provider: provider, broker: broker, directory: directory,
            mode: .confirmEach, present: { _ in }  // a window that never opens
        )

        let outcome = await context.call(
            name: "stop_container", arguments: ["id": "abc123"]
        )

        XCTAssertTrue(outcome.isError)
        XCTAssertEqual(outcome.text, HostMCPCallContext.confirmationTimedOutMessage)
        XCTAssertEqual(provider.stopContainerCallCount, 0)
        XCTAssertEqual(try auditOutcomes(directory), ["denied"])
    }

    /// The request a person is shown has to name the exact thing being acted on.
    /// One summary per kind, built from the arguments the executor validated — a
    /// prompt that says "approve?" about an unidentified request is a prompt
    /// nobody can answer honestly.
    func testEveryMutationKindAsksWithItsOwnWords() async throws {
        let broker = ConfirmationBroker(timeout: 5)
        let presented = RecordingPresenter()
        let directory = try makeTemporaryDirectory(prefix: "pmwiring")
        let context = makeContext(
            provider: StubProvider(), broker: broker, directory: directory,
            mode: .confirmEach, present: { request in
                presented.record(request)
                Task { await broker.decide(id: request.id, outcome: .approved) }
            }
        )

        let calls: [(String, [String: String])] = [
            ("quit_app", ["id": "app:Chrome"]),
            ("stop_container", ["id": "web"]),
            ("stop_project", ["id": "/src/api"]),
            ("set_preference", ["key": "temperatureUnit", "value": "celsius"]),
        ]
        for (name, arguments) in calls {
            _ = await context.call(name: name, arguments: arguments)
        }

        XCTAssertEqual(
            presented.requests.map(\.kind),
            [.quitApp, .stopContainer, .stopProject, .setPreference],
            "each mutation is asked about as its own kind of change"
        )
        XCTAssertEqual(
            presented.requests.map(\.summary),
            [
                "Quit app:Chrome?",
                "Stop container web?",
                "Stop project /src/api?",
                "Change temperatureUnit to celsius?",
            ]
        )
        let preference = try XCTUnwrap(presented.requests.last)
        XCTAssertTrue(
            preference.detail.contains("temperatureUnit"),
            "a preference change must name the key: \(preference.detail)"
        )
        XCTAssertTrue(
            preference.detail.contains("celsius"),
            "a preference change must name the value: \(preference.detail)"
        )
    }

    /// A read is never a question. Only the catalog's `effect` decides that, and
    /// a caller cannot talk its way around it by asking to be treated otherwise.
    func testReadsAreNeverPutToAPerson() async throws {
        let broker = ConfirmationBroker(timeout: 5)
        let presented = RecordingPresenter()
        let directory = try makeTemporaryDirectory(prefix: "pmwiring")
        let context = makeContext(
            provider: StubProvider(), broker: broker, directory: directory,
            mode: .confirmEach, present: { request in
                presented.record(request)
                Task { await broker.decide(id: request.id, outcome: .approved) }
            }
        )

        let outcome = await context.call(name: "get_system_overview", arguments: [:])

        XCTAssertFalse(outcome.isError, outcome.text)
        XCTAssertTrue(presented.requests.isEmpty, "a read needs nobody's permission")
        let remaining = await broker.queuedCount
        XCTAssertEqual(remaining, 0, "and must leave nothing waiting on a person")
    }

    // MARK: - Liveness

    /// `allowSession` is a grant that lasts while Portmaster is running, and it
    /// is the same `PermissionGate` that enforces it — the host does not get its
    /// own looser rule for being the app.
    func testSessionGrantsStillFollowLiveness() async throws {
        let provider = StubProvider()
        let directory = try makeTemporaryDirectory(prefix: "pmwiring")
        let context = makeContext(
            provider: provider, broker: ConfirmationBroker(timeout: 5), directory: directory,
            mode: .allowSession, appRunning: { false }
        )

        let outcome = await context.call(name: "quit_app", arguments: ["id": "app:Chrome"])

        XCTAssertTrue(outcome.isError)
        XCTAssertEqual(outcome.text, "Session grants apply only while Portmaster is running.")
        XCTAssertEqual(provider.quitAppCallCount, 0)
        XCTAssertEqual(try auditOutcomes(directory), ["denied"])
    }

    // MARK: - The mutation mode is the server's own

    /// The mode is read per call, so changing it takes effect without restarting
    /// anything — and it is read from the *server's* settings file, which is the
    /// only place it lives. A host built over `.confirmEach` and then handed a
    /// file saying `.off` must stop asking people, which is only true if the file
    /// is re-read rather than captured.
    func testTheMutationModeIsRereadFromTheServersOwnFileOnEveryCall() async throws {
        let directory = try makeTemporaryDirectory(prefix: "pmwiring")
        try MCPSettings(mode: .confirmEach).save(directory: directory)
        let broker = ConfirmationBroker(timeout: 5)
        let presented = RecordingPresenter()
        let provider = StubProvider()
        let context = makeContext(
            provider: provider, broker: broker, directory: directory,
            mode: nil,  // read the file, as the host does
            present: { request in
                presented.record(request)
                Task { await broker.decide(id: request.id, outcome: .approved) }
            }
        )

        let confirmed = await context.call(name: "quit_app", arguments: ["id": "app:Chrome"])
        XCTAssertFalse(confirmed.isError, confirmed.text)
        XCTAssertEqual(presented.requests.count, 1, ".confirmEach asks")

        // The user's other surface changes the mode.
        try MCPSettings(mode: .off).save(directory: directory)
        let nowOff = await context.call(name: "quit_app", arguments: ["id": "app:Chrome"])
        XCTAssertTrue(nowOff.isError)
        XCTAssertEqual(nowOff.text, "MCP mutations are disabled in Portmaster settings.")
        XCTAssertEqual(presented.requests.count, 1, ".off asks nobody")
        XCTAssertEqual(provider.quitAppCallCount, 1, "and performs nothing")
    }

    /// `mcpMode` never reaches the provider: the executor owns that key end to
    /// end, because it is the MCP server's policy rather than an app preference.
    /// The round trip is asserted in both directions — the tool call writes the
    /// file the host reads, and `get_settings` reports what is in that file and
    /// not what the app's preferences would say.
    func testTheMutationModeRoundTripsThroughTheFileTheHostWrites() async throws {
        let directory = try makeTemporaryDirectory(prefix: "pmwiring")
        try MCPSettings(mode: .allowSession).save(directory: directory)
        let app = RecordedAppSurface()
        let context = makeContext(
            provider: liveProvider(app, mode: { MCPSettings.load(directory: directory).mode }),
            broker: ConfirmationBroker(timeout: 5),
            directory: directory,
            mode: nil,
            present: { _ in XCTFail(".allowSession must not put anything to a person") }
        )

        let before = await context.call(name: "get_settings", arguments: [:])
        XCTAssertFalse(before.isError, before.text)
        XCTAssertEqual(
            try reportedMutationMode(before.text), "allowSession",
            "get_settings must report the server's own mode"
        )

        let mutation = await context.call(name: "quit_app", arguments: ["id": "app:Chrome"])
        XCTAssertFalse(mutation.isError, mutation.text)
        XCTAssertEqual(app.stops, ["app:Chrome"], "the app performed the granted stop")

        let applied = await context.call(
            name: "set_preference", arguments: ["key": "mcpMode", "value": "confirmEach"]
        )
        XCTAssertFalse(applied.isError, applied.text)
        XCTAssertEqual(
            MCPSettings.load(directory: directory).mode, .confirmEach,
            "the tool call must write the file the host reads on its next call"
        )
        XCTAssertEqual(
            app.preferenceWrites, [],
            "mcpMode is the server's own policy, so it must never reach the app's preferences"
        )

        let after = await context.call(name: "get_settings", arguments: [:])
        XCTAssertEqual(try reportedMutationMode(after.text), "confirmEach")
    }

    /// The regression this whole file's cancellation half exists for.
    ///
    /// **A confirmation nobody answered must never become an `allowed` line.** Three
    /// runs of `scripts/mcp-e2e.sh` recorded `outcome: "allowed"` for a
    /// `set_preference` whose client had been killed and whose window no person had
    /// touched. The only route to `.approved` is the window's Approve button (pinned
    /// by `MCPApprovalPresentationTests`), and that button used to carry
    /// `.keyboardShortcut(.defaultAction)` on a window that force-raises and
    /// activates the app — so a Return meant for another application was a consent.
    /// The binding is gone; this is the invariant behind that, and it is the one that
    /// holds whatever the presenter does.
    ///
    /// Cancellation is the reachable form of "nobody answered" in a test: the client
    /// goes away, so the awaiting task is cancelled and its continuation will never
    /// be serviced. Two things must be true — the action is not performed, and the
    /// attempt is still on the record, because every mutation attempt leaves a line.
    func testACancelledConfirmationIsNeverPerformedAndIsStillAudited() async throws {
        let provider = StubProvider()
        let directory = try makeTemporaryDirectory(prefix: "pmwiring")
        // A budget long enough that only the cancellation can end this, so the test
        // cannot pass by timing out instead — and the reason is asserted below for
        // the same reason. The broker's budget task is not the caller's task and does
        // not inherit its cancellation, so a cancelled caller still waits the budget
        // out; keeping it short is what stops this suite from spending minutes.
        let broker = ConfirmationBroker(timeout: 1)
        let context = makeContext(
            provider: provider, broker: broker, directory: directory,
            mode: .confirmEach, present: { _ in }  // a window nobody will answer
        )

        let caller = Task { await context.call(name: "quit_app", arguments: ["id": "app:Chrome"]) }
        try await waitUntilPending(broker)
        caller.cancel()
        _ = await caller.value

        XCTAssertEqual(
            provider.quitAppCallCount, 0,
            "a confirmation that was never answered must never perform the action, "
                + "however the waiting ended"
        )
        let outcomes = try auditOutcomes(directory)
        XCTAssertEqual(
            outcomes, ["denied"],
            "an attempt nobody answered is still an attempt: one line, and it is a denial"
        )
        let entry = try XCTUnwrap(try auditEntries(directory).first)
        XCTAssertEqual(entry["tool"] as? String, "quit_app")
        XCTAssertEqual(
            entry["reason"] as? String, HostMCPCallContext.abandonedReason,
            "the caller is gone, so the line has to say that — and saying the timeout "
                + "instead would mean this test could pass without being cancelled"
        )
    }

    /// The same invariant with the approval already in hand.
    ///
    /// A person approved, and *then* the client vanished. Approval is consent to
    /// change the machine on behalf of a caller that is no longer there to receive
    /// the answer — and the audit line would claim a completed action for a client
    /// that never heard back. So a cancelled caller loses the approval, and the line
    /// says the attempt was abandoned rather than performed.
    ///
    /// This is the narrow case that makes the rule above a rule rather than an
    /// accident of ordering: without it, "cancel first" would be the only safe order.
    func testCancellationAfterAnApprovalRefusesRatherThanPerforms() async throws {
        let provider = StubProvider()
        let directory = try makeTemporaryDirectory(prefix: "pmwiring")
        let broker = ConfirmationBroker(timeout: 5)
        let context = makeContext(
            provider: provider, broker: broker, directory: directory,
            mode: .confirmEach, present: { request in
                Task { await broker.decide(id: request.id, outcome: .approved) }
            }
        )

        let caller = Task { await context.call(name: "quit_app", arguments: ["id": "app:Chrome"]) }
        caller.cancel()
        _ = await caller.value

        XCTAssertEqual(
            provider.quitAppCallCount, 0,
            "the caller went away, so there is nobody to carry out the change for"
        )
        XCTAssertEqual(
            try auditOutcomes(directory), ["denied"],
            "and the log must not claim an action happened"
        )
    }

    /// A mutation the person never got asked about is `rejected`, not `denied` —
    /// asserted here as well as in `ToolExecutorMutationTests`, because the hosted
    /// path is the one a real client takes and it goes through this file's own
    /// refusal plumbing.
    func testAMalformedMutationIsAuditedRejectedThroughTheHostPath() async throws {
        let provider = StubProvider()
        let directory = try makeTemporaryDirectory(prefix: "pmwiring")
        let presented = RecordingPresenter()
        let broker = ConfirmationBroker(timeout: 5)
        let context = makeContext(
            provider: provider, broker: broker, directory: directory,
            mode: .confirmEach, present: { request in
                presented.record(request)
                Task { await broker.decide(id: request.id, outcome: .approved) }
            }
        )

        let outcome = await context.call(name: "stop_container", arguments: [:])

        XCTAssertTrue(outcome.isError)
        XCTAssertEqual(outcome.text, "Missing argument: id")
        XCTAssertEqual(provider.stopContainerCallCount, 0)
        XCTAssertEqual(try auditOutcomes(directory), ["rejected"])
    }

    /// Polls until the broker is holding `count` requests, or fails the test.
    /// Bounded on purpose: a broker that never publishes is a failure to report,
    /// not a suite to hang.
    private func waitUntilPending(
        _ broker: ConfirmationBroker,
        _ count: Int = 1,
        timeout: TimeInterval = 2
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var seen = 0
        while Date() < deadline {
            seen = await broker.queuedCount
            if seen == count { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("expected \(count) pending request(s), saw \(seen)")
    }

    /// `mcpMode` under `confirmEach`, end to end.
    ///
    /// This is the change that used to be impossible. The confirmation window asks
    /// `PreferencesStore.validate` whether a change is doable *before* it puts it to a
    /// person, and the validator had no case for `mcpMode` — the one allowlisted key
    /// the app's preferences blob does not own — so it refused the request and named
    /// `mcpMode` as allowed in the same sentence. `allowSession` worked, because that
    /// path asks nobody. So the mode a user had chosen was reachable only by the one
    /// mode that does not check with anybody.
    ///
    /// Asserted as the whole round trip: asked about, answered, written to the file the
    /// gate reads next, and on the record as `allowed`.
    func testTheMutationModeIsConfirmedAndWrittenRatherThanRefused() async throws {
        let directory = try makeTemporaryDirectory(prefix: "pmwiring")
        try MCPSettings(mode: .confirmEach).save(directory: directory)
        let broker = ConfirmationBroker(timeout: 5)
        let presented = RecordingPresenter()
        let app = RecordedAppSurface()
        let context = makeContext(
            provider: liveProvider(app, mode: { MCPSettings.load(directory: directory).mode }),
            broker: broker, directory: directory,
            mode: nil,  // read the file, as the host does
            present: { request in
                presented.record(request)
                Task { await broker.decide(id: request.id, outcome: .approved) }
            }
        )

        let outcome = await context.call(
            name: "set_preference", arguments: ["key": "mcpMode", "value": "allowSession"]
        )

        XCTAssertFalse(outcome.isError, outcome.text)
        let request = try XCTUnwrap(presented.requests.first, "a mode change is asked about")
        XCTAssertEqual(
            request.kind, .setPreference,
            "the mode change reaches a person as a preference change"
        )
        XCTAssertTrue(
            request.summary.contains("mcpMode"), request.summary
        )
        XCTAssertEqual(
            MCPSettings.load(directory: directory).mode, .allowSession,
            "an approved mode change must land in the file the gate reads next"
        )
        XCTAssertEqual(
            app.preferenceWrites, [],
            "the server's own policy is not the app's preferences blob"
        )
        XCTAssertEqual(
            try auditOutcomes(directory), ["allowed"],
            "the one attempt is on the record as the granted change it was"
        )
    }

    /// The other half of the same round trip: the mode a user has just set decides the
    /// very next call, without a restart.
    func testAModeChangedThroughAConfirmationGovernsTheNextCall() async throws {
        let directory = try makeTemporaryDirectory(prefix: "pmwiring")
        try MCPSettings(mode: .confirmEach).save(directory: directory)
        let broker = ConfirmationBroker(timeout: 5)
        let presented = RecordingPresenter()
        let app = RecordedAppSurface()
        let context = makeContext(
            provider: liveProvider(app, mode: { MCPSettings.load(directory: directory).mode }),
            broker: broker, directory: directory,
            mode: nil,
            present: { request in
                presented.record(request)
                Task { await broker.decide(id: request.id, outcome: .approved) }
            }
        )

        _ = await context.call(
            name: "set_preference", arguments: ["key": "mcpMode", "value": "off"]
        )
        let refused = await context.call(name: "quit_app", arguments: ["id": "app:Chrome"])

        XCTAssertTrue(refused.isError)
        XCTAssertEqual(refused.text, "MCP mutations are disabled in Portmaster settings.")
        XCTAssertEqual(app.stops, [], "and nothing was performed")
        XCTAssertEqual(
            presented.requests.count, 1,
            "the second call was refused by the mode, so nobody was asked about it"
        )
    }

    /// The app quitting with a question on screen.
    ///
    /// `MCPHostController.stop()` answers every pending request before it closes the
    /// socket, so this is the ordinary path and it already recorded a line. It is
    /// pinned separately from the cancellation case because they are different events
    /// with different reasons: here the *app* is leaving and nothing will ever answer,
    /// which is what `MCPHostController.quittingReason` is for. The property is the
    /// same one — the attempt is on the record — and it is the last chance to put it
    /// there, because after this there is no process left to write it.
    func testQuittingWithAConfirmationPendingRecordsTheAttempt() async throws {
        let provider = StubProvider()
        let directory = try makeTemporaryDirectory(prefix: "pmwiring")
        let broker = ConfirmationBroker(timeout: 600)  // only the quit can end this
        let context = makeContext(
            provider: provider, broker: broker, directory: directory,
            mode: .confirmEach, present: { _ in }
        )

        let caller = Task {
            await context.call(name: "stop_project", arguments: ["id": "/src/api"])
        }
        try await waitUntilPending(broker)

        // What the app does on the way out, and the reason it gives.
        await broker.cancelAll(reason: "Portmaster is quitting, so this action was not taken.")
        let outcome = await caller.value

        XCTAssertTrue(outcome.isError)
        XCTAssertEqual(provider.stopProjectCallCount, 0, "a quit performs nothing")
        XCTAssertEqual(
            try auditOutcomes(directory), ["denied"],
            "the last process to write this line is the one quitting, so it has to"
        )
        let entry = try XCTUnwrap(try auditEntries(directory).first)
        XCTAssertTrue(
            (entry["reason"] as? String)?.contains("quitting") == true,
            "and it must say the app went away rather than that a person said no: "
                + "\(entry)"
        )
    }

    // MARK: - The refusal the app's own snapshot closure owes a cold sampler

    /// The app's snapshot closure throws this, and `LiveDataProvider` passes
    /// whatever it throws straight through — so the wording is a contract
    /// between two providers rather than a convention. Pinned here, because
    /// nothing else compares them.
    func testTheSamplerNotReadyRefusalIsTheOnDemandPathsOwnWording() async throws {
        XCTAssertEqual(
            MCPToolError.samplerNotReady.message, OnDemandProvider.notReadyMessage,
            "the app's cold-sampler refusal must be the on-demand path's sentence"
        )
        let provider = LiveDataProvider(
            snapshot: { throw MCPToolError.samplerNotReady },
            alerts: { AlertsSnapshot(source: .live, alerts: []) },
            history: { UnavailableHistoryReading(message: "no history") },
            settings: { Self.settingsReporting(mode: .off) },
            applyPreference: { _, _ in },
            stopApp: { _, _ in StopReport(results: [:]) },
            stopContainerNamed: { _ in StopReport(results: [:]) },
            stopProject: { _ in StopReport(results: [:]) }
        )
        do {
            _ = try await provider.systemOverview()
            XCTFail("a sampler that has published nothing must refuse")
        } catch let error as MCPToolError {
            XCTAssertEqual(
                error.message, SnapshotAcquisition.notReadyMessage,
                "the refusal a client reads must be the sentence both providers use"
            )
        }
    }

    // MARK: - Reading a mirrored snapshot

    /// Both sides of the freshness boundary, because the app cannot be asked to
    /// produce an old reading on demand and the rule is a number someone will want to
    /// move: `maximumReadingAge` seconds is the oldest a reading may be and still be
    /// answered with, and one second past it is a refusal that names the age.
    func testAMirroredReadingIsAnsweredUntilItIsTooOld() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let fresh = try LiveDataProvider.requireReadable(
            Self.snapshot(), now: now
        )
        XCTAssertEqual(fresh.at, Self.snapshot().at, "a just-published reading is answerable")

        // Exactly at the bound, and one second past it: the boundary is inclusive, so
        // a sampler that pauses for exactly one interval still answers.
        XCTAssertNoThrow(
            try LiveDataProvider.requireReadable(
                Self.snapshot(at: now.addingTimeInterval(-LiveDataProvider.maximumReadingAge)),
                now: now
            ),
            "a reading exactly at the bound is still current enough to report"
        )
        do {
            _ = try LiveDataProvider.requireReadable(
                Self.snapshot(at: now.addingTimeInterval(-LiveDataProvider.maximumReadingAge - 1)),
                now: now
            )
            XCTFail("a reading past the bound must not be reported as current")
        } catch let error as MCPToolError {
            XCTAssertTrue(error.message.contains("idle"), error.message)
            XCTAssertTrue(
                error.message.contains("2 minutes"),
                "the refusal must name how old the reading is: \(error.message)"
            )
        }
    }

    /// The bound is derived from the app's own cadences, so it is stated as one rather
    /// than asserted by a test that would have to know the number twice.
    func testTheFreshnessBoundIsLongerThanTheSlowestBackgroundCadence() {
        XCTAssertGreaterThan(
            LiveDataProvider.maximumReadingAge, 60,
            "the slowest background cadence samples every 60s, so a bound under that "
            + "would refuse a reading the app published one interval ago"
        )
    }

    /// The refusal's wording switches to minutes at the bound, and switches *because of*
    /// the bound: a literal in `ageDescription` would keep answering "2 minutes" for a
    /// rule that had moved to, say, 90 seconds.
    func testTheAgeWordingTurnsOverAtTheSameNumberAsTheRule() {
        XCTAssertEqual(
            LiveDataProvider.ageDescription(LiveDataProvider.maximumReadingAge - 1),
            "119 seconds"
        )
        XCTAssertEqual(
            LiveDataProvider.ageDescription(LiveDataProvider.maximumReadingAge), "2 minutes"
        )
        XCTAssertEqual(LiveDataProvider.ageDescription(1), "1 second")
        XCTAssertEqual(LiveDataProvider.ageDescription(0), "0 seconds")
    }

    /// The app's own throw site is `LiveDataProvider.requireReadable`, which is what
    /// makes this contract about the app and not about a test's own closure: both
    /// refusals it can raise are the library's, and neither can be worded here.
    func testTheAppPathRefusesWithTheLibrarysOwnSentences() throws {
        // Cold: nothing published at all.
        do {
            _ = try LiveDataProvider.requireReadable(.empty, now: Date())
            XCTFail("an app that has published nothing must refuse")
        } catch let error as MCPToolError {
            XCTAssertEqual(
                error, MCPToolError.samplerNotReady,
                "a cold sampler must be refused in OnDemandProvider's sentence"
            )
            XCTAssertEqual(error.message, OnDemandProvider.notReadyMessage)
        }

        // Idle: something published, but long ago.
        let now = Date()
        let stale = Self.snapshot(at: now.addingTimeInterval(-3_600))
        do {
            _ = try LiveDataProvider.requireReadable(stale, now: now)
            XCTFail("an hour-old reading must not be reported as current")
        } catch let error as MCPToolError {
            XCTAssertTrue(
                error.message.contains("60 minutes"),
                "the refusal must name how old the reading is: \(error.message)"
            )
        }
    }

    /// A preference write must not need the main thread, and the app's hop to its own
    /// actor must be a suspension rather than a block.
    ///
    /// The assertion is made from a detached task, so it fails if `setPreference`
    /// ever requires the caller's thread to be the main one — which is what a
    /// `MainActor.assumeIsolated` inside the provider would have needed, and what the
    /// app's `await MainActor.run` no longer does. `LiveDataProvider`'s seam is `async`
    /// for exactly this reason.
    func testAPreferenceWriteDoesNotNeedTheMainThread() async throws {
        let ranOnMainThread = MainThreadProbe()
        let provider = LiveDataProvider(
            snapshot: { throw MCPToolError.samplerNotReady },
            alerts: { AlertsSnapshot(source: .live, alerts: []) },
            history: { UnavailableHistoryReading(message: "no history") },
            settings: { Self.settingsReporting(mode: .off) },
            applyPreference: { _, _ in ranOnMainThread.record() },
            stopApp: { _, _ in StopReport(results: [:]) },
            stopContainerNamed: { _ in StopReport(results: [:]) },
            stopProject: { _ in StopReport(results: [:]) }
        )

        try await Task.detached(priority: .userInitiated) { [provider] in
            try await provider.setPreference(key: "temperatureUnit", value: "celsius")
        }.value

        XCTAssertEqual(ranOnMainThread.count, 1, "the write must reach the app")
        XCTAssertFalse(
            ranOnMainThread.anyOnMainThread,
            "a preference write must not be pinned to the main thread"
        )
    }

    /// A confirmed mutation presents the instant the broker owns the request, not up
    /// to a polling interval later.
    ///
    /// `onQueued` makes the two the same step, so the window opens from inside
    /// `request`. What is observable here is that a presenter which answers
    /// immediately is always matched — with the answer dropped as "an answer to
    /// nothing" the call would instead end at its budget, and the test below would
    /// see a timeout rather than an action.
    func testAPresenterCanAnswerTheInstantItIsCalled() async throws {
        let provider = StubProvider()
        let broker = ConfirmationBroker(timeout: 5)
        let directory = try makeTemporaryDirectory(prefix: "pmwiring")
        let context = makeContext(
            provider: provider, broker: broker, directory: directory,
            mode: .confirmEach, present: { request in
                Task { await broker.decide(id: request.id, outcome: .approved) }
            }
        )

        let outcome = await context.call(name: "quit_app", arguments: ["id": "app:Chrome"])

        XCTAssertFalse(outcome.isError, outcome.text)
        XCTAssertEqual(
            provider.quitAppCallCount, 1,
            "an approval given the moment the window opened must be matched, not dropped"
        )
    }

    // MARK: - Waking a quiet sampler

    /// A reading older than the bound is not the end of the answer: the app owns the
    /// sampler, and `SamplingEngine` pauses itself after five idle minutes — the normal
    /// state of a menu-bar app. So the host resumes it for one sample and waits.
    ///
    /// **The reading lands on the third poll here, not the first.** That is the real
    /// shape of the thing: `resumeOnce()` schedules a tick on the engine's own queue,
    /// and the reading appears only once that tick has swept and published. A stub
    /// whose reading existed before the first poll would return on iteration one and
    /// never execute the poll interval at all — which is how a 5-second budget, and the
    /// `wakePollInterval` that spends it, ended up with no coverage at all.
    func testAStaleMirrorIsWokenOnceAndAnsweredFromTheLaterReading() async throws {
        let stale = Self.snapshot(at: Date().addingTimeInterval(-600))
        let script = WakeScript(landingAfterPolls: 3)

        let woken = await LiveDataProvider.wake(
            replacing: stale,
            budget: 2,
            // The nudge starts a tick; it publishes nothing by itself, which is the
            // whole reason there is a poll.
            nudge: { script.recordNudge() },
            latest: { await script.reading() }
        )

        XCTAssertEqual(script.nudges, 1, "one nudge, one attempt")
        XCTAssertEqual(
            script.polls, 3,
            "the wake must keep asking until the tick it started has published"
        )
        XCTAssertEqual(
            woken.at, WakeScript.landed.at,
            "the answer must be the reading the tick published, not the one we refused"
        )
        XCTAssertNoThrow(try LiveDataProvider.requireReadable(woken))
    }

    /// The budget is what stops the wait, and it is measured monotonically so a clock
    /// step cannot extend it — a stub that never publishes anything proves the first
    /// half, and the implementation's `ContinuousClock` is what the second half rests
    /// on.
    func testAQuietSamplerGivesUpWhenTheBudgetRunsOut() async throws {
        let stale = Self.snapshot(at: Date().addingTimeInterval(-600))
        let script = WakeScript(landingAfterPolls: .max)

        let started = Date()
        // A budget of 0.5 s against a ceiling of 1.0 s: two polls' worth of headroom
        // for a loaded machine, and still well under the 1.5 s a budget three times
        // over would take — which is the shape of the mistake this catches.
        let woken = await LiveDataProvider.wake(
            replacing: stale,
            budget: 0.5,
            nudge: { script.recordNudge() },
            latest: { await script.reading() }
        )
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(woken.at, stale.at, "nothing published, so nothing newer to report")
        XCTAssertLessThan(
            elapsed, 1.0,
            "the wait must end with its budget, not run on\(script.polls) polls of someone's latency"
        )
        XCTAssertGreaterThan(script.polls, 1, "and it must actually have polled")
    }

    /// A sampler that does not answer the nudge is refused for being idle, and only
    /// after the budget — with the age named, because that is what tells a client
    /// whether to come back.
    func testAMirrorThatStaysStaleIsRefusedAfterOneWake() async throws {
        let stale = Self.snapshot(at: Date().addingTimeInterval(-600))
        let script = WakeScript(landingAfterPolls: .max)

        let woken = await LiveDataProvider.wake(
            replacing: stale,
            budget: 0.1,
            nudge: { script.recordNudge() },
            latest: { await script.reading() }
        )

        XCTAssertEqual(script.nudges, 1, "a wake that did not land must not be retried")
        XCTAssertEqual(woken.at, stale.at, "nothing newer arrived, so the old reading stands")
        do {
            _ = try LiveDataProvider.requireReadable(woken)
            XCTFail("a reading that survived the wake must not be reported as current")
        } catch let error as MCPToolError {
            XCTAssertTrue(error.message.contains("idle"), error.message)
            XCTAssertTrue(error.message.contains("10 minutes"), error.message)
        }
    }

    /// A cold sampler gets the same one wake, because `refreshNow()` is the right
    /// answer to "nothing published yet" too: the app has started, and asking it to
    /// tick is cheaper than telling a client the sampler is still starting when a tick
    /// is one call away.
    func testAColdSamplerIsWokenRatherThanRefused() async throws {
        let script = WakeScript(landingAfterPolls: 2)

        let woken = await LiveDataProvider.wake(
            replacing: .empty,
            budget: 2,
            nudge: { script.recordNudge() },
            latest: { await script.reading() }
        )

        XCTAssertEqual(script.nudges, 1)
        XCTAssertNoThrow(try LiveDataProvider.requireReadable(woken))
    }

    // MARK: - Helpers

    /// The host context over a provider and a disposable directory.
    ///
    /// `mode` is a value-or-nil rather than a closure so a test can change the
    /// file underneath a context that is already built — which is the whole of
    /// the per-call claim. `nil` means "read it from `directory`", which is what
    /// the app does.
    private func makeContext(
        provider: any DataProvider,
        broker: ConfirmationBroker,
        directory: URL,
        mode: MCPMutationMode?,
        appRunning: @escaping @Sendable () -> Bool = { true },
        present: @escaping @Sendable (MCPApprovalRequest) -> Void = { _ in }
    ) -> HostMCPCallContext {
        HostMCPCallContext(
            provider: provider,
            broker: broker,
            present: present,
            loadSettings: {
                MCPSettings(mode: mode ?? MCPSettings.load(directory: directory).mode)
            },
            appRunning: appRunning,
            auditDirectory: directory,
            settingsDirectory: directory
        )
    }

    /// A `LiveDataProvider` shaped the way `MCPHostController` builds it: the
    /// app's preferences for everything, and `MCPSettings` for the mutation mode.
    private func liveProvider(
        _ app: RecordedAppSurface,
        mode: @escaping @Sendable () -> MCPMutationMode
    ) -> LiveDataProvider {
        LiveDataProvider(
            snapshot: { throw MCPToolError.samplerNotReady },
            alerts: { AlertsSnapshot(source: .live, alerts: []) },
            history: { UnavailableHistoryReading(message: "no history") },
            settings: { Self.settingsReporting(mode: mode()) },
            applyPreference: { key, value in app.record(key: key, value: value) },
            stopApp: { id, _ in app.record(stop: id) },
            stopContainerNamed: { id in app.record(stop: id) },
            stopProject: { id in app.record(stop: id) }
        )
    }

    /// A reading published at `at`.
    ///
    /// Built through the model initializer rather than by copying a fixture and moving
    /// its `at`, because `at` is a `let`: the freshness rule is about the instant a
    /// reading claims to be from, and a fixture whose system sample claims a different
    /// one would be a reading that lies about itself.
    private static func snapshot(
        at: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> ObservationSnapshot {
        ObservationSnapshot(
            at: at,
            system: SystemSample(
                at: at,
                cpu: SystemCPU(
                    totalPercent: 12, userPercent: 8, systemPercent: 4,
                    idlePercent: 88, corePercents: [8, 4], coreCount: 2
                ),
                memory: SystemMemory(
                    totalBytes: 16_000_000_000, usedBytes: 8_000_000_000,
                    pressureLevel: .normal, pressureRatio: 0.5, swapBytes: nil,
                    freeBytes: 8_000_000_000, appBytes: nil, wiredBytes: nil,
                    compressedBytes: nil
                )
            ),
            processes: [], ports: [], services: [], rollups: []
        )
    }

    /// One settings payload, with the mutation mode named by the caller so a test
    /// can show which value came from where.
    private static func settingsReporting(mode: MCPMutationMode) -> SettingsSnapshot {
        SettingsSnapshot(
            temperatureUnit: "celsius", networkUnit: "bytes", cpuScale: "perCore",
            temperatureSource: "smc", compactMenuBar: false,
            mutationMode: mode.rawValue, alertsEnabled: false, retention: "days7"
        )
    }

    /// The `mutationMode` a `get_settings` payload reported.
    private func reportedMutationMode(_ text: String) throws -> String {
        let object = try jsonObject(text)
        return try XCTUnwrap(object["mutationMode"] as? String)
    }

    /// Every audit line written in `directory`, oldest first.
    private func auditEntries(_ directory: URL) throws -> [[String: Any]] {
        let url = directory.appendingPathComponent("mcp-audit.log")
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return try contents.split(separator: "\n").map { line in
            try jsonObject(String(line))
        }
    }

    /// Just the outcomes, so an assertion can be about the sequence of decisions
    /// rather than about the shape of the log.
    private func auditOutcomes(_ directory: URL) throws -> [String] {
        try auditEntries(directory).compactMap { $0["outcome"] as? String }
    }
}

/// A sampler that publishes on the poll the test chooses, and counts what it was asked.
///
/// Modelling the delay instead of removing it is the point: the engine's tick is queued
/// on another queue and the reading appears later, so `latest` answering with a reading
/// from the start would be a stub that makes the wait untestable.
private final class WakeScript: @unchecked Sendable {
    private let lock = NSLock()
    private var nudgeCount = 0
    private var pollCount = 0
    private let landingAfterPolls: Int
    private let published: ObservationSnapshot

    /// - Parameters:
    ///   - landingAfterPolls: the poll at which the reading appears. `.max` for a
    ///     sampler that never answers.
    ///   - published: what it publishes when it does.
    init(landingAfterPolls: Int, published: ObservationSnapshot = WakeScript.landed) {
        self.landingAfterPolls = landingAfterPolls
        self.published = published
    }

    /// A reading stamped now, built once so repeated polls report the *same* instant —
    /// a stub that re-stamped per poll would look like a faster sampler.
    static let landed = ObservationSnapshot(
        at: Date(),
        system: SystemSample(
            at: Date(),
            cpu: SystemCPU(
                totalPercent: 1, userPercent: 1, systemPercent: 0,
                idlePercent: 99, corePercents: [1], coreCount: 1
            ),
            memory: SystemMemory(
                totalBytes: 1, usedBytes: 1, pressureLevel: .normal,
                pressureRatio: 0, swapBytes: nil, freeBytes: 0,
                appBytes: nil, wiredBytes: nil, compressedBytes: nil
            )
        ),
        processes: [], ports: [], services: [], rollups: []
    )

    func recordNudge() { lock.withLock { nudgeCount += 1 } }

    /// What the app would report on this poll.
    func reading() async -> ObservationSnapshot {
        lock.withLock {
            pollCount += 1
            return pollCount >= landingAfterPolls ? published : .empty
        }
    }

    var nudges: Int { lock.withLock { nudgeCount } }
    var polls: Int { lock.withLock { pollCount } }
}

/// Where the app's preference write ran, and how many times.
private final class MainThreadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var threads: [Bool] = []

    func record() { lock.withLock { threads.append(Thread.isMainThread) } }

    var count: Int { lock.withLock { threads.count } }
    var anyOnMainThread: Bool { lock.withLock { threads.contains(true) } }
}

/// What a person was asked, in order. The stand-in for the confirmation window:
/// it records the request and answers it, which is all `HostMCPCallContext`
/// requires of a presenter.
private final class RecordingPresenter: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [MCPApprovalRequest] = []

    func record(_ request: MCPApprovalRequest) {
        lock.withLock { recorded.append(request) }
    }

    var requests: [MCPApprovalRequest] { lock.withLock { recorded } }
}

/// What the app was asked to do, instead of the app: the mutations that reached
/// it, so a test can assert the difference between "refused" and "performed".
private final class RecordedAppSurface: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped: [String] = []
    private var preferences: [String] = []

    var stops: [String] { lock.withLock { stopped } }
    var preferenceWrites: [String] { lock.withLock { preferences } }

    func record(stop id: String) -> StopReport {
        lock.withLock { stopped.append(id) }
        return StopReport(results: [:])
    }

    func record(key: String, value: String) {
        lock.withLock { preferences.append("\(key)=\(value)") }
    }
}
