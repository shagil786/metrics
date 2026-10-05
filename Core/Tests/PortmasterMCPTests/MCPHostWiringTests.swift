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
// directory, and the "person" is a closure — which is the whole of what the
// controller injects.
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
    /// sampler, and `SamplingEngine` pauses itself after five idle minutes — the
    /// normal state of a menu-bar app. So the host nudges it once and waits for that
    /// one tick.
    ///
    /// Both halves are here because they are different code paths: a wake that lands
    /// answers, and a wake that does not is refused in the same words as one that was
    /// never tried — with exactly one nudge either way, since a second attempt is how a
    /// "wake the sampler" feature turns into a retry loop.
    func testAStaleMirrorIsWokenOnceAndAnsweredFromTheNewReading() async throws {
        let stale = Self.snapshot(at: Date().addingTimeInterval(-600))
        let fresh = Self.snapshot(at: Date())
        let nudges = WakeCounter()
        let clock = WakeCounter()

        let woken = await LiveDataProvider.wake(
            replacing: stale,
            budget: 1,
            nudge: {
                nudges.record()
                // The tick is scheduled, not synchronous: the reading lands on a later
                // poll, which is the whole reason the wake waits at all.
                clock.record(fresh)
            },
            latest: { clock.newest }
        )

        XCTAssertEqual(nudges.count, 1, "one nudge, one attempt")
        XCTAssertEqual(woken.at, fresh.at)
        XCTAssertNoThrow(try LiveDataProvider.requireReadable(woken))
    }

    /// A sampler that does not answer the nudge is refused for being idle, and only
    /// after the budget — with the age named, because that is what tells a client
    /// whether to come back.
    func testAMirrorThatStaysStaleIsRefusedAfterOneWake() async throws {
        let stale = Self.snapshot(at: Date().addingTimeInterval(-600))
        let nudges = WakeCounter()

        let woken = await LiveDataProvider.wake(
            replacing: stale,
            budget: 0.1,
            nudge: { nudges.record() },
            latest: { stale }
        )

        XCTAssertEqual(nudges.count, 1, "a wake that did not land must not be retried")
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
        let fresh = Self.snapshot(at: Date())
        let nudges = WakeCounter()

        let woken = await LiveDataProvider.wake(
            replacing: .empty,
            budget: 1,
            nudge: { nudges.record() },
            latest: { fresh }
        )

        XCTAssertEqual(nudges.count, 1)
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

/// How many times a nudge was asked for, and what it produced.
private final class WakeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var nudges = 0
    private var readings: [ObservationSnapshot] = []

    func record() { lock.withLock { nudges += 1 } }

    /// Records the reading a tick would have produced, in order.
    func record(_ reading: ObservationSnapshot) { lock.withLock { readings.append(reading) } }

    var count: Int { lock.withLock { nudges } }

    /// The newest reading recorded, or `.empty` while none has landed.
    var newest: ObservationSnapshot {
        lock.withLock { readings.max(by: { $0.at < $1.at }) } ?? .empty
    }
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
